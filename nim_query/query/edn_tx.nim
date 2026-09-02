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

const MaxTxAttrs = 128        ## distinct attr keywords per tx (stack cache)

type
  AttrE = object
    h: uint32                 ## FNV-1a of name; 0 = empty slot
    name: string              ## kwval (one copy per distinct attr)
    attrId: uint32            ## 0 = unresolved / undeclared
    unique: bool
    declared: bool

proc fnv1a(s: string): uint32 =
  var h = 2166136261'u32
  for c in s:
    h = (h xor uint32(c)) * 16777619'u32
  if h == 0: h = 1
  h

proc transactEdn*(ops: EngineOps; txdata: seq[SExpr]): TxReport =
  ## Execute one EDN transaction; returns the tx-report (§3.2).
  ## One allocateTx per transaction — every datom shares its t.
  ##
  ## Flat interpreter: ONE classification pass produces TxOpInfo records in
  ## the EngineOps scratch (buffers reused across txs — no steady-state
  ## allocation); the schema, anchor and apply passes read the flat records
  ## only.  All resolution happens before the first write issues, so any
  ## failure aborts the tx with zero datoms applied.
  if txdata.len == 0:
    raise txErr("tx: empty txdata")

  # Per-tx stack cache: distinct attr keywords → name/attrId/unique.
  # 128 open-addressed slots; overflow (-2) falls back to per-op lookups.
  var cache: array[MaxTxAttrs, AttrE]

  proc intern(name: string): int32 =
    ## Slot of `name` in the stack cache; inserts on first sight. -2 = full.
    let h = fnv1a(name)
    let start = int(h mod MaxTxAttrs)
    for k in 0 ..< MaxTxAttrs:
      let j = (start + k) mod MaxTxAttrs
      if cache[j].h == 0:
        cache[j].h = h
        cache[j].name = name
        return int32(j)
      if cache[j].h == h and cache[j].name == name:
        return int32(j)
    -2

  # ── 1. Classification pass ─────────────────────────────────────────────────
  ops.txInfos.setLen(0)
  var minTid = 0'i64
  var maxTid = -1'i64
  var haveTids = false

  for op in txdata:
    if op.kind != sList or op.items.len != 4:
      raise txErr("tx: op must be a 4-element vector: " & $op)
    if op.items[0].kind != sKeyword:
      raise txErr("tx: op must start with a keyword: " & $op)

    var info: TxOpInfo
    info.aRef = op.items[2]
    info.eRef = op.items[1]
    info.vRef = op.items[3]

    case op.items[0].kwval
    of "db/add": info.kind = tokAdd
    of "db/retract": info.kind = tokRetract
    else:
      raise txErr("tx: unknown op keyword: :" & op.items[0].kwval)

    if op.items[2].kind == sKeyword:
      info.attrSlot = intern(op.items[2].kwval)
    else:
      info.attrSlot = -1

    let e = op.items[1]
    if isTempid(e):
      info.ekind = teTempid
      info.eid = e.ival
      if not haveTids or e.ival < minTid: minTid = e.ival
      if not haveTids or e.ival > maxTid: maxTid = e.ival
      haveTids = true
    elif isDbCurrentTx(e): info.ekind = teCurrentTx
    elif isLookupRef(e): info.ekind = teLookupRef
    elif e.kind == sInt and e.ival >= 0:
      info.ekind = teEid
      info.eid = e.ival
    elif e.kind == sKeyword: info.ekind = teKeyword  # schema entity name
    else: info.ekind = teInvalid

    let v = op.items[3]
    if isTempid(v): info.vkind = tvTempid
    elif isLookupRef(v): info.vkind = tvLookupRef
    else: info.vkind = tvScalar

    if info.kind == tokAdd:
      info.schema = info.aRef.kind == sKeyword and
        info.aRef.kwval.isSchemaAttrKw

    ops.txInfos.add(info)

  # ── 2. Allocate the tx entity + txInstant.  Its eid is this tx's t. ───────
  let txEid = ops.allocateTx()
  let t = txEid

  # ── 3. Schema ops first (same-tx declaration usable by data ops). ─────────
  for i in 0 ..< ops.txInfos.len:
    let info = ops.txInfos[i]
    if info.kind == tokAdd and info.schema and
       info.aRef.kwval == "db/ident":
      ops.applySchemaGroup(txdata, info.eRef, t)

  # Refresh the attr cache: attrs declared above (or in earlier txs) resolve
  # here — one resolver call per DISTINCT attr, never per op.
  for j in 0 ..< MaxTxAttrs:
    if cache[j].h != 0 and not cache[j].declared:
      let aidOpt = ops.lookupAttr(cache[j].name)
      if aidOpt.isSome:
        cache[j].attrId = aidOpt.get
        cache[j].unique = ops.isUniqueAttr(cache[j].name)
        cache[j].declared = true

  # ── 4. Resolve all tempids before any write: upsert anchors (first
  #    :db/add of the tempid with a unique attr) look up or allocate;
  #    bare tempids allocate fresh.  Failure aborts with zero datoms. ────────
  var resolved = initTable[int64, int64]()
  if haveTids:
    let span = int(maxTid - minTid + 1)
    if span > 1_000_000:
      raise txErr("tx: tempid span too large (max 1000000): " & $span)
    ops.txAnchorOp.setLen(span)
    ops.txAnchorEid.setLen(span)
    for idx in 0 ..< span:
      ops.txAnchorOp[idx] = 0
      ops.txAnchorEid[idx] = 0

    # anchor detection: first :db/add of each tempid with a UNIQUE attr
    for i in 0 ..< ops.txInfos.len:
      let info = ops.txInfos[i]
      if info.kind != tokAdd or info.ekind != teTempid: continue
      var isUnique = false
      if info.attrSlot >= 0: isUnique = cache[info.attrSlot].unique
      elif info.attrSlot == -2: isUnique = ops.isUniqueAttr(info.aRef.kwval)
      if isUnique:
        let idx = int(info.eid - minTid)
        if ops.txAnchorOp[idx] == 0: ops.txAnchorOp[idx] = int32(i + 1)

    # resolution in first-occurrence order (deterministic eid allocation)
    for i in 0 ..< ops.txInfos.len:
      let info = ops.txInfos[i]
      if info.ekind != teTempid: continue
      let tid = info.eid
      let idx = int(tid - minTid)
      if ops.txAnchorEid[idx] != 0: continue
      var eid: int64
      let aop = ops.txAnchorOp[idx]
      if aop != 0:
        let ao = ops.txInfos[aop - 1]
        let anchorName = if ao.attrSlot >= 0: cache[ao.attrSlot].name
                         else: ao.aRef.kwval
        let found = ops.lookupEntity(anchorName, ao.vRef)
        eid = if found.isSome: found.get
              else: ops.allocateInPartition(PartUser)
      else:
        eid = ops.allocateInPartition(PartUser)
      ops.txAnchorEid[idx] = eid
      resolved[tid] = eid

  # ── 5. Apply pass: resolve e/v slots in place, then two batchWrites
  #    (saves, retracts).  No intermediate op seqs. ──────────────────────────
  for i in 0 ..< ops.txInfos.len:
    var info = ops.txInfos[i]
    if info.kind == tokAdd and info.schema: continue

    if info.kind == tokRetract:
      if info.ekind == teCurrentTx:
        raise txErr("tx: :db/retract on :db/current-tx is not allowed (§6)")
      if info.attrSlot == -1:
        raise txErr("tx: expected keyword for attribute, got " & $info.aRef)
      if info.vRef.kind == sKeyword or info.vkind != tvScalar:
        raise txErr("tx: :db/retract requires a concrete scalar value (§4)")
      if info.ekind == teTempid:
        raise txErr("tx: :db/retract does not take a tempid (§4)")

    # attr: name + attrId (attrId 0 = undeclared; retract no-ops on it)
    var attrName: string
    if info.attrSlot >= 0:
      attrName = cache[info.attrSlot].name
      if not cache[info.attrSlot].declared and info.kind == tokAdd:
        raise newException(EvalError, "save to undeclared attr: " & attrName)
      ops.txInfos[i].attrId = cache[info.attrSlot].attrId
    else:  # -2 overflow: per-op slow path; -1 handled above
      attrName = info.aRef.kwval
      let aidOpt = ops.lookupAttr(attrName)
      ops.txInfos[i].attrId = if aidOpt.isSome: aidOpt.get else: 0
      if aidOpt.isNone and info.kind == tokAdd:
        raise newException(EvalError, "save to undeclared attr: " & attrName)

    # e slot
    case info.ekind
    of teTempid:
      ops.txInfos[i].eid = ops.txAnchorEid[int(info.eid - minTid)]
    of teCurrentTx:
      ops.txInfos[i].eid = txEid
    of teLookupRef:
      let lattr = expectKwVal(info.eRef.items[0], "lookup ref attr")
      if not ops.isUniqueAttr(lattr):
        raise txErr("tx: lookup ref attr not UNIQUE: " & lattr)
      let found = ops.lookupEntity(lattr, info.eRef.items[1])
      if found.isNone:
        raise txErr("tx: lookup ref [:" & lattr & " " & $info.eRef.items[1] &
          "] did not match any entity")
      ops.txInfos[i].eid = found.get
    of teEid: discard
    of teKeyword, teInvalid:
      raise txErr("tx: cannot resolve e slot: " & $info.eRef)

    # v slot
    case info.vkind
    of tvTempid:
      let tid = info.vRef.ival
      if tid < minTid or tid > maxTid or
         ops.txAnchorEid[int(tid - minTid)] == 0:
        raise txErr("tx: tempid " & $tid &
          " referenced in v slot but never allocated")
      ops.txInfos[i].vresolved = ops.txAnchorEid[int(tid - minTid)]
    of tvLookupRef:
      let rattr = expectKwVal(info.vRef.items[0], "lookup ref attr")
      if not ops.isUniqueAttr(rattr):
        raise txErr("tx: lookup ref attr not UNIQUE: " & rattr)
      let found = ops.lookupEntity(rattr, info.vRef.items[1])
      if found.isNone:
        raise txErr("tx: lookup ref [:" & rattr & " " & $info.vRef.items[1] &
          "] did not match any entity")
      ops.txInfos[i].vresolved = found.get
    of tvScalar: discard

    # Datomic semantics: :db/add of a datom that is already present is a
    # no-op — for :db.cardinality/one AND :db.cardinality/many.  Without
    # this, a re-assert of the same value under cardinality-one produces a
    # retract+reassert pair at the same t that shadows the datom (breaking
    # unique lookups), and under many it would duplicate the value in
    # every index scan.
    if info.kind == tokAdd:
      let val = if info.vkind == tvScalar: info.vRef
                else: newInt(ops.txInfos[i].vresolved)
      if ops.hasDatom(ops.txInfos[i].eid, attrName, val):
        ops.txInfos[i].attrId = 0  # mark no-op: engine skips it

  # 6. Emit one batchWrite for saves and one for retracts.
  ops.saveBatchEdn(ops.txInfos, t, 0)
  ops.retractBatch(ops.txInfos, t, 0)

  result = TxReport(tempids: resolved, tx: t)
