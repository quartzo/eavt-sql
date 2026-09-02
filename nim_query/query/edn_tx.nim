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

const SchemaAttrKws = ["db/ident", "db/valueType", "db/cardinality",
                       "db/unique"]

proc isSchemaGroupOp(op: TxWOp): bool =
  ## :db/add carrying a db/* SCHEMA declaration attribute — never applied
  ## as raw datoms (declareAttrFromSql persists them itself).
  not op.isRetract and op.attr in SchemaAttrKws

proc sameSlotEntity(a, b: TxWSlot): bool =
  ## Schema entities group by their raw e-slot literal (eid int or keyword).
  if a.kind != b.kind: return false
  case a.kind
  of tskInt: a.i == b.i
  of tskKw: a.s == b.s
  else: false

proc applySchemaGroupTx(ops: EngineOps; txops: seq[TxWOp]; seedOp: int;
                        t: int64) =
  ## Collect the schema datoms of the seed op's entity and declare the attr.
  var ident = ""
  var vtName = "string"
  var many = false
  var unique = false
  for j in 0 ..< txops.len:
    let op = txops[j]
    if op.isRetract: continue
    if not isSchemaGroupOp(op): continue
    if not sameSlotEntity(op.e, txops[seedOp].e): continue
    case op.attr
    of "db/ident":
      if op.v.kind != tskKw:
        raise txErr("tx: :db/ident value must be a keyword: " & op.v.s)
      ident = op.v.s
    of "db/valueType":
      vtName = vtFromKeyword(op.v.s)
    of "db/cardinality":
      if op.v.s == "db.cardinality/many": many = true
      elif op.v.s == "db.cardinality/one": many = false
      else: raise txErr("tx: unknown :db/cardinality keyword: :" & op.v.s)
    of "db/unique":
      if op.v.s == "db.unique/identity" or op.v.s == "db.unique/value":
        unique = true
      else:
        raise txErr("tx: unknown :db/unique keyword: :" & op.v.s)
    else: discard
  if ident.len == 0:
    raise txErr("tx: schema entity has no :db/ident")
  ops.declareAttrFromSql(ident, vtName, many, unique, t)

proc slotRepr(v: TxWSlot): string =
  case v.kind
  of tskInt: $v.i
  of tskFloat: $v.f
  of tskBool: $v.b
  of tskStr: "\"" & v.s & "\""
  of tskKw: ":" & v.s
  of tskBytes: "<bytes:" & $v.bin.len & ">"
  of tskLookupRef: "[:" & v.refAttr & " " & slotRepr(v.refVal[]) & "]"
  of tskMissing: "nil"

proc transactTx*(ops: EngineOps; txops: seq[TxWOp]): TxReport =
  ## Execute one flat tx (decoded straight from the wire — no SExpr).
  ## Same semantics as transactEdn (docs/tx-protocol.md): tempid upsert
  ## anchors, lookup refs, schema-as-data, one t per tx, fail-loud before
  ## any write.  Scratch buffers on EngineOps are reused across txs.
  if txops.len == 0:
    raise txErr("tx: empty txdata")

  # Per-tx stack cache: distinct attr keywords → name/attrId/unique.
  # 128 open-addressed slots; overflow (-2) falls back to per-op lookups.
  var cache: array[MaxTxAttrs, AttrE]

  proc intern(name: string): int32 =
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

  # ── 1. Classification pass — slots are already typed; only the attr cache
  #    slot (parallel scratch) and the tempid range are computed here. ───────
  ops.txSlot.setLen(txops.len)
  var minTid = 0'i64
  var maxTid = -1'i64
  var haveTids = false

  for i in 0 ..< txops.len:
    let op = addr txops[i]
    if op.attr.len == 0:
      ops.txSlot[i] = -1            # malformed attr → apply raises
    else:
      ops.txSlot[i] = intern(op.attr)
    if op.e.kind == tskInt and op.e.i < 0:
      if not haveTids or op.e.i < minTid: minTid = op.e.i
      if not haveTids or op.e.i > maxTid: maxTid = op.e.i
      haveTids = true
    if op.v.kind == tskInt and op.v.i < 0:
      if not haveTids or op.v.i < minTid: minTid = op.v.i
      if not haveTids or op.v.i > maxTid: maxTid = op.v.i
      haveTids = true

  # ── 2. Allocate the tx entity + txInstant.  Its eid is this tx's t. ───────
  let txEid = ops.allocateTx()
  let t = txEid

  # ── 3. Schema ops first (same-tx declaration usable by data ops). ─────────
  for i in 0 ..< txops.len:
    if txops[i].attr == "db/ident" and not txops[i].isRetract:
      ops.applySchemaGroupTx(txops, i, t)

  # Refresh the attr cache: one resolver call per DISTINCT attr, never per op.
  for j in 0 ..< MaxTxAttrs:
    if cache[j].h != 0 and not cache[j].declared:
      let aidOpt = ops.lookupAttr(cache[j].name)
      if aidOpt.isSome:
        cache[j].attrId = aidOpt.get
        cache[j].unique = ops.isUniqueAttr(cache[j].name)
        cache[j].declared = true

  # ── 4. Resolve all tempids before any write (upsert anchors first). ───────
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
    for i in 0 ..< txops.len:
      let op = txops[i]
      if op.isRetract or op.e.kind != tskInt or op.e.i >= 0: continue
      let aSlot = ops.txSlot[i]
      var isUnique = false
      if aSlot >= 0: isUnique = cache[aSlot].unique
      elif aSlot == -2: isUnique = ops.isUniqueAttr(op.attr)
      if isUnique:
        let idx = int(op.e.i - minTid)
        if ops.txAnchorOp[idx] == 0: ops.txAnchorOp[idx] = int32(i + 1)

    # resolution in first-occurrence order (deterministic eid allocation)
    for i in 0 ..< txops.len:
      let op = txops[i]
      if op.e.kind != tskInt or op.e.i >= 0: continue
      let tid = op.e.i
      let idx = int(tid - minTid)
      if ops.txAnchorEid[idx] != 0: continue
      var eid: int64
      let aop = ops.txAnchorOp[idx]
      if aop != 0:
        let ao = txops[aop - 1]
        let anchorName = if ops.txSlot[aop - 1] >= 0:
                           cache[ops.txSlot[aop - 1]].name
                         else: ao.attr
        let found = ops.lookupEntityW(anchorName, ao.v)
        eid = if found.isSome: found.get
              else: ops.allocateInPartition(PartUser)
      else:
        eid = ops.allocateInPartition(PartUser)
      ops.txAnchorEid[idx] = eid
      resolved[tid] = eid

  # ── 5. Apply pass: resolve e/v slots in place, then two batchWrites. ──────
  for i in 0 ..< txops.len:
    let op = addr txops[i]
    let aSlot = ops.txSlot[i]

    if isSchemaGroupOp(op[]):
      continue

    if op.isRetract:
      if op.e.kind == tskKw and op.e.s == "db/current-tx":
        raise txErr("tx: :db/retract on :db/current-tx is not allowed (§6)")
      if op.attr.len == 0:
        raise txErr("tx: expected keyword for attribute")
      if op.v.kind == tskKw or op.v.kind == tskLookupRef or
         (op.v.kind == tskInt and op.v.i < 0):
        raise txErr("tx: :db/retract requires a concrete scalar value (§4)")
      if op.e.kind == tskInt and op.e.i < 0:
        raise txErr("tx: :db/retract does not take a tempid (§4)")

    # attrId (0 = undeclared; adds raise, retract no-ops in the engine)
    if aSlot >= 0:
      if not cache[aSlot].declared and not op.isRetract:
        raise newException(EvalError,
          "save to undeclared attr: " & cache[aSlot].name)
      op.attrId = cache[aSlot].attrId
    elif aSlot == -2:
      let aidOpt = ops.lookupAttr(op.attr)
      op.attrId = if aidOpt.isSome: aidOpt.get else: 0
      if aidOpt.isNone and not op.isRetract:
        raise newException(EvalError, "save to undeclared attr: " & op.attr)

    # e slot → resolved eid (mutated in place)
    case op.e.kind
    of tskInt:
      if op.e.i < 0:
        op.e.i = ops.txAnchorEid[int(op.e.i - minTid)]
    of tskKw:
      if op.e.s == "db/current-tx":
        op.e = TxWSlot(kind: tskInt, i: txEid)
      else:
        raise txErr("tx: cannot resolve e slot: :" & op.e.s)
    of tskLookupRef:
      let lattr = op.e.refAttr
      if not ops.isUniqueAttr(lattr):
        raise txErr("tx: lookup ref attr not UNIQUE: " & lattr)
      let found = ops.lookupEntityW(lattr, op.e.refVal[])
      if found.isNone:
        raise txErr("tx: lookup ref [:" & lattr & " " &
          slotRepr(op.e.refVal[]) & "] did not match any entity")
      op.e = TxWSlot(kind: tskInt, i: found.get)
    else:
      raise txErr("tx: cannot resolve e slot: " & slotRepr(op.e))

    # v slot → vresolved for tempids / lookup refs
    if op.v.kind == tskInt and op.v.i < 0:
      let tid = op.v.i
      if tid < minTid or tid > maxTid or
         ops.txAnchorEid[int(tid - minTid)] == 0:
        raise txErr("tx: tempid " & $tid &
          " referenced in v slot but never allocated")
      op.vresolved = ops.txAnchorEid[int(tid - minTid)]
    elif op.v.kind == tskLookupRef:
      let rattr = op.v.refAttr
      if not ops.isUniqueAttr(rattr):
        raise txErr("tx: lookup ref attr not UNIQUE: " & rattr)
      let found = ops.lookupEntityW(rattr, op.v.refVal[])
      if found.isNone:
        raise txErr("tx: lookup ref [:" & rattr & " " &
          slotRepr(op.v.refVal[]) & "] did not match any entity")
      op.vresolved = found.get

    # Datomic semantics: :db/add of a present datom is a no-op (both
    # cardinalities) — re-assert under card-one would retract+reassert at
    # the same t, shadowing the datom and breaking unique lookups.
    if not op.isRetract and op.attrId != 0:
      let vEff = if op.v.kind == tskInt and op.v.i < 0:
                   TxWSlot(kind: tskInt, i: op.vresolved)
                 elif op.v.kind == tskLookupRef:
                   TxWSlot(kind: tskInt, i: op.vresolved)
                 else: op.v
      if ops.hasDatomW(op.e.i, op.attrId, vEff):
        op.attrId = 0               # engine skips it

  # 6. Emit one batchWrite for saves and one for retracts.
  ops.saveBatchEdn(txops, t, 0)
  ops.retractBatch(txops, t, 0)

  result = TxReport(tempids: resolved, tx: t)

proc slotFromSExpr(e: SExpr): TxWSlot =
  ## SExpr value slot → flat TxWSlot (EDN/test path).
  case e.kind
  of sInt: TxWSlot(kind: tskInt, i: e.ival)
  of sFloat: TxWSlot(kind: tskFloat, f: e.fval)
  of sStr: TxWSlot(kind: tskStr, s: e.sval)
  of sKeyword: TxWSlot(kind: tskKw, s: e.kwval)
  of sSymbol: TxWSlot(kind: tskStr, s: e.symval)
  of sBool: TxWSlot(kind: tskBool, b: e.bval)
  of sBytes: TxWSlot(kind: tskBytes, bin: e.bytesval)
  of sList:
    if e.items.len == 2 and e.items[0].kind == sKeyword:
      var s = TxWSlot(kind: tskLookupRef, refAttr: e.items[0].kwval)
      new(s.refVal)
      s.refVal[] = slotFromSExpr(e.items[1])
      s
    else:
      TxWSlot(kind: tskMissing)
  of sVoid, sResource: TxWSlot(kind: tskMissing)

proc toTxWOp(op: SExpr): TxWOp =
  ## SExpr op vector → flat TxWOp (EDN/test path).
  if op.kind != sList or op.items.len != 4:
    raise txErr("tx: op must be a 4-element vector: " & $op)
  if op.items[0].kind != sKeyword:
    raise txErr("tx: op must start with a keyword: " & $op)
  result.isRetract = op.items[0].kwval == "db/retract"
  if not result.isRetract and op.items[0].kwval != "db/add":
    raise txErr("tx: unknown op keyword: :" & op.items[0].kwval)
  result.e = slotFromSExpr(op.items[1])
  if op.items[2].kind == sKeyword:
    result.attr = op.items[2].kwval
  result.v = slotFromSExpr(op.items[3])

proc transactEdn*(ops: EngineOps; txdata: seq[SExpr]): TxReport =
  ## EDN/SExpr entry — converts to flat ops and runs transactTx
  ## (tests, REPL and any SExpr producer).
  if txdata.len == 0:
    raise txErr("tx: empty txdata")
  var flat = newSeq[TxWOp](txdata.len)
  for i in 0 ..< txdata.len:
    flat[i] = toTxWOp(txdata[i])
  transactTx(ops, flat)
