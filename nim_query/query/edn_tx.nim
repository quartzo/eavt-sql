## edn_tx.nim — Native interpreter for Datomic-style EDN transactions.
##
## Executes tx-data op vectors (docs/tx-protocol.md) against EngineOps,
## without the Scheme VM in the write path.  Semantics per spec:
##
##   • tempids are negative int64s (§5.1): if any :db/add of the tempid
##     carries a :db.unique/identity attr, resolution is upsert
##     (lookup-or-allocate); otherwise allocateInPartition(4).  Chaining
##     via tempid in the v slot of a ref attr.
##   • lookup refs [?unique-attr v] resolve in-tx; miss = error (§5.3).
##   • :db/current-tx in the e slot attaches datoms to this tx's entity (§6).
##   • schema-as-data: :db/ident + :db/valueType/:db/cardinality/:db/unique
##     grouped per eid → one declareAttrFromSql (§7); schema ops run first
##     so data ops in the same tx can use the attrs.
##   • one tx = one t: a single allocateTx covers every datom (§2).
##
## Fail-loud (TxError): unknown keywords, unknown tempids, retract on
## :db/current-tx, malformed ops.  All tempid/lookup resolution happens
## before the first write issues, so an unresolved reference aborts the
## tx with no datom applied.

import std/[tables, strutils, options]
import scheme
import hostfns
import types

type
  TxError* = object of CatchableError
  TxReport* = object
    tempids*: Table[int64, int64]  ## tempid → resolved eid
    tx*: int64                     ## the tx entity id (all datoms' t)

const
  PartUser* = 4'u64          ## :db.part/user — all user tempids live here

proc txErr(msg: string): ref TxError =
  newException(TxError, msg)

proc expectKwVal(e: SExpr; what: string): string =
  ## Keyword name of `e` (without the leading colon) or tx error.
  if e.kind != sKeyword:
    raise txErr("tx: expected keyword for " & what & ", got " & $e)
  e.kwval

# ── Slot classification ─────────────────────────────────────────────────────

proc isDbCurrentTx(e: SExpr): bool =
  e.kind == sKeyword and e.kwval == "db/current-tx"

proc isLookupRef(e: SExpr): bool =
  ## [?attr v] with a keyword first element — a two-element entity ref.
  e.kind == sList and e.items.len == 2 and e.items[0].kind == sKeyword

proc isTempid(e: SExpr): bool =
  e.kind == sInt and e.ival < 0

# ── Schema-as-data (§7) ─────────────────────────────────────────────────────

proc isSchemaAttrKw(kw: string): bool =
  kw in ["db/ident", "db/valueType", "db/cardinality", "db/unique"]

proc isSchemaAdd(op: SExpr): bool =
  ## [:db/add eid :db/ident X ...] — a schema declaration datom.
  op.kind == sList and op.items.len >= 4 and
  op.items[0].kind == sKeyword and op.items[0].kwval == "db/add" and
  op.items[2].kind == sKeyword and op.items[2].kwval == "db/ident"

proc isSchemaGroupOp(op: SExpr): bool =
  ## Any :db/add carrying a db/* schema attribute — these never apply as
  ## raw datoms: declareAttrFromSql persists the db.* datoms itself
  ## (eavtDeclareAttr), so writing them again would corrupt the value type.
  op.kind == sList and op.items.len >= 4 and
  op.items[0].kind == sKeyword and op.items[0].kwval == "db/add" and
  op.items[2].kind == sKeyword and op.items[2].kwval.isSchemaAttrKw

const DbValueTypes = [
  "string", "long", "float", "boolean", "bytes", "blob",
  "keyword", "ref", "instant"]

proc vtFromKeyword(kw: string): string =
  ## :db.type/string → "string" (valueTypeFromName accepts the suffix).
  ## Case-insensitive: the SQL parser uppercases type names (STRING, REF...).
  ## Unknown value types are a tx error, not a silent string fallback —
  ## a typo'd :db/valueType must fail loudly (§7).
  let n = kw.toLowerAscii()
  if n.startsWith("db.type/"):
    let vt = n[8 ..^ 1]
    if vt in DbValueTypes: return vt
    raise txErr("tx: unknown :db/valueType keyword: :" & n)
  raise txErr("tx: :db/valueType must be a :db.type/* keyword: :" & n)

proc sameSchemaEntity(a, b: SExpr): bool =
  ## Schema datoms group by their raw eid literal (positive int or keyword
  ## name) — schema entities are never tempids.
  if a.kind != b.kind: return false
  case a.kind
  of sInt: a.ival == b.ival
  of sKeyword: a.kwval == b.kwval
  else: false

proc applySchemaGroup(ops: EngineOps; txdata: seq[SExpr]; seed: SExpr;
                      t: int64) =
  ## Collect the schema datoms of `seed`'s entity and declare the attr once.
  var ident = ""
  var vtName = "string"
  var many = false
  var unique = false
  for op in txdata:
    if not isSchemaGroupOp(op): continue
    if not sameSchemaEntity(op.items[1], seed): continue
    case op.items[2].kwval
    of "db/ident":
      if op.items[3].kind != sKeyword:
        raise txErr("tx: :db/ident value must be a keyword: " & $op.items[3])
      ident = op.items[3].kwval
    of "db/valueType":
      vtName = vtFromKeyword(expectKwVal(op.items[3], ":db/valueType"))
    of "db/cardinality":
      let kw = expectKwVal(op.items[3], ":db/cardinality")
      if kw == "db.cardinality/many": many = true
      elif kw == "db.cardinality/one": many = false
      else: raise txErr("tx: unknown :db/cardinality keyword: :" & kw)
    of "db/unique":
      let kw = expectKwVal(op.items[3], ":db/unique")
      if kw in ["db.unique/identity", "db.unique/value"]:
        unique = true
      else:
        raise txErr("tx: unknown :db/unique keyword: :" & kw)
    else: discard
  if ident.len == 0:
    raise txErr("tx: schema entity has no :db/ident: " & $seed)
  ops.declareAttrFromSql(ident, vtName, many, unique, t)

# ── Main entry ──────────────────────────────────────────────────────────────

proc transactEdn*(ops: EngineOps; txdata: seq[SExpr]): TxReport =
  ## Execute one EDN transaction; returns the tx-report (§3.2).
  ## One allocateTx per transaction — every datom shares its t.
  if txdata.len == 0:
    raise txErr("tx: empty txdata")

  for op in txdata:
    if op.kind != sList or op.items.len != 4:
      raise txErr("tx: op must be a 4-element vector: " & $op)
    if op.items[0].kind != sKeyword:
      raise txErr("tx: op must start with a keyword: " & $op)

  # 1. Allocate the tx entity + txInstant.  Its eid is this tx's t.
  let txEid = ops.allocateTx()
  let t = txEid

  # 2. Schema ops first (same-tx declaration usable by data ops).
  for op in txdata:
    if isSchemaAdd(op):
      ops.applySchemaGroup(txdata, op.items[1], t)

  # 3. Resolve all tempids before any write: upsert anchors (first
  #    :db/add of the tempid with a unique attr) look up or allocate;
  #    bare tempids allocate fresh.  Failure aborts with zero datoms.
  var resolved = initTable[int64, int64]()
  for op in txdata:
    if isSchemaAdd(op): continue
    let eSlot = op.items[1]
    if not isTempid(eSlot): continue
    let tid = eSlot.ival
    if tid in resolved: continue
    var anchorAttr = ""
    var anchorVal = SExpr(kind: sVoid)
    for later in txdata:
      if isSchemaAdd(later): continue
      if later.items[0].kwval == "db/add" and
         isTempid(later.items[1]) and later.items[1].ival == tid and
         later.items[2].kind == sKeyword and
         ops.isUniqueAttr(later.items[2].kwval):
        anchorAttr = later.items[2].kwval
        anchorVal = later.items[3]
        break
    if anchorAttr.len > 0:
      let found = ops.lookupEntity(anchorAttr, anchorVal)
      if found.isSome:
        resolved[tid] = found.get
      else:
        resolved[tid] = ops.allocateInPartition(PartUser)
    else:
      resolved[tid] = ops.allocateInPartition(PartUser)

  # 4. Apply data ops in order (schema group ops already consumed in step 2).
  for op in txdata:
    if isSchemaGroupOp(op): continue
    let kind = op.items[0].kwval
    case kind
    of "db/add":
      let eSlot = op.items[1]
      let attr = expectKwVal(op.items[2], "attribute")
      let vSlot = op.items[3]

      var eId: int64
      if isTempid(eSlot):
        eId = resolved[eSlot.ival]
      elif isDbCurrentTx(eSlot):
        eId = txEid
      elif isLookupRef(eSlot):
        let attr = expectKwVal(eSlot.items[0], "lookup ref attr")
        if not ops.isUniqueAttr(attr):
          raise txErr("tx: lookup ref attr not UNIQUE: " & attr)
        let found = ops.lookupEntity(attr, eSlot.items[1])
        if found.isNone:
          raise txErr("tx: lookup ref [:" & attr & " " & $eSlot.items[1] &
            "] did not match any entity")
        eId = found.get
      elif eSlot.kind == sInt and eSlot.ival >= 0:
        eId = eSlot.ival
      else:
        raise txErr("tx: cannot resolve e slot: " & $eSlot)

      var val = vSlot
      if isTempid(vSlot):
        if vSlot.ival notin resolved:
          raise txErr("tx: tempid " & $vSlot.ival &
            " referenced in v slot but never allocated")
        val = newInt(resolved[vSlot.ival])
      elif isLookupRef(vSlot):
        let rattr = expectKwVal(vSlot.items[0], "lookup ref attr")
        if not ops.isUniqueAttr(rattr):
          raise txErr("tx: lookup ref attr not UNIQUE: " & rattr)
        let found = ops.lookupEntity(rattr, vSlot.items[1])
        if found.isNone:
          raise txErr("tx: lookup ref [:" & rattr & " " & $vSlot.items[1] &
            "] did not match any entity")
        val = newInt(found.get)

      # Datomic semantics: :db/add of a datom that is already present is a
      # no-op — for :db.cardinality/one AND :db.cardinality/many.  Without
      # this, a re-assert of the same value under cardinality-one produces a
      # retract+reassert pair at the same t that shadows the datom (breaking
      # unique lookups), and under many it would duplicate the value in
      # every index scan.
      if ops.hasDatom(eId, attr, val):
        continue

      ops.saveWithT(eId, attr, val, t, 0)

    of "db/retract":
      let eSlot = op.items[1]
      if isDbCurrentTx(eSlot):
        raise txErr("tx: :db/retract on :db/current-tx is not allowed (§6)")
      let attr = expectKwVal(op.items[2], "attribute")
      let vSlot = op.items[3]
      if vSlot.kind == sKeyword or isLookupRef(vSlot) or isTempid(vSlot):
        raise txErr("tx: :db/retract requires a concrete scalar value (§4)")

      var eId: int64
      if isTempid(eSlot):
        raise txErr("tx: :db/retract does not take a tempid (§4)")
      elif isLookupRef(eSlot):
        let rattr = expectKwVal(eSlot.items[0], "lookup ref attr")
        if not ops.isUniqueAttr(rattr):
          raise txErr("tx: lookup ref attr not UNIQUE: " & rattr)
        let found = ops.lookupEntity(rattr, eSlot.items[1])
        if found.isNone:
          raise txErr("tx: lookup ref [:" & rattr & " " & $eSlot.items[1] &
            "] did not match any entity")
        eId = found.get
      elif eSlot.kind == sInt and eSlot.ival >= 0:
        eId = eSlot.ival
      else:
        raise txErr("tx: cannot resolve e slot: " & $eSlot)

      ops.retract(eId, attr, vSlot, t, 0)
    else:
      raise txErr("tx: unknown op keyword: :" & kind)

  result = TxReport(tempids: resolved, tx: t)