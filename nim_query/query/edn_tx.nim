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
import scheme, symtab
import keys
import resolver
import eavt
import engine
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
    sym: uint32               ## interned attr keyword (0 = empty slot)
    name: string              ## payload (one copy per distinct attr)
    attrId: uint32            ## 0 = unresolved / undeclared
    unique: bool
    declared: bool
    vt: uint32                ## value type (prefix encoding for batch lookups)
    mode: EncodeMode

proc sameSlotEntity(a, b: TxWSlot): bool =
  ## Schema entities group by their raw e-slot literal (eid int or keyword).
  if a.kind != b.kind: return false
  case a.kind
  of tskInt: a.i == b.i
  of tskKw: a.sym == b.sym
  else: false

proc isSchemaGroupOp(tab: SymTab; op: TxWOp): bool =
  ## :db/add carrying a db/* SCHEMA declaration attribute (by interned id).
  not op.isRetract and
  (op.attrSym == uint32(tab.dbIdent) or op.attrSym == uint32(tab.dbType) or
   op.attrSym == uint32(tab.dbCardinality) or op.attrSym == uint32(tab.dbUnique))

proc applySchemaGroupTx(ops: EngineOps; tab: SymTab; txops: seq[TxWOp]; seedOp: int;
                        t: int64) =
  ## Collect the schema datoms of the seed op's entity and declare the attr.
  ## Rare path: values are read back through symName().
  var ident = ""
  var vtName = "string"
  var many = false
  var unique = false
  for j in 0 ..< txops.len:
    let op = txops[j]
    if op.isRetract: continue
    if not isSchemaGroupOp(tab, op): continue
    if not sameSlotEntity(op.e, txops[seedOp].e): continue
    let a = op.attrSym
    if a == uint32(tab.dbIdent):
      if op.v.kind != tskKw:
        raise txErr("tx: :db/ident value must be a keyword: " &
          tab.symName(SymId(op.v.sym)))
      ident = tab.symName(SymId(op.v.sym))
    elif a == uint32(tab.dbType):
      vtName = vtFromKeyword(tab.symName(SymId(op.v.sym)))
    elif a == uint32(tab.dbCardinality):
      let v = tab.symName(SymId(op.v.sym))
      if v == "db.cardinality/many": many = true
      elif v == "db.cardinality/one": many = false
      else: raise txErr("tx: unknown :db/cardinality keyword: :" & v)
    elif a == uint32(tab.dbUnique):
      let v = tab.symName(SymId(op.v.sym))
      if v == "db.unique/identity" or v == "db.unique/value": unique = true
      else: raise txErr("tx: unknown :db/unique keyword: :" & v)
  if ident.len == 0:
    raise txErr("tx: schema entity has no :db/ident")
  ops.declareAttrFromSql(ident, vtName, many, unique, t)

proc slotRepr(tab: SymTab; v: TxWSlot): string =
  case v.kind
  of tskInt: $v.i
  of tskFloat: $v.f
  of tskBool: $v.b
  of tskStr: "\"" & v.s & "\""
  of tskKw: ":" & tab.symName(SymId(v.sym))
  of tskBytes: "<bytes:" & $v.bin.len & ">"
  of tskLookupRef: "[:" & tab.symName(SymId(v.sym)) & " " & slotRepr(tab, v.refVal[]) & "]"
  of tskMissing: "nil"

proc transactTx*(ops: EngineOps; txops: seq[TxWOp]): TxReport =
  ## Execute one flat tx (decoded straight from the wire — no SExpr).
  ## Same semantics as transactEdn (docs/tx-protocol.md): tempid upsert
  ## anchors, lookup refs, schema-as-data, one t per tx, fail-loud before
  ## any write.  Scratch buffers on EngineOps are reused across txs.
  ## Keywords are interned at transport capture (symtab.nim) — identity is
  ## uint32; strings only on rare paths (errors, attr declaration).
  if txops.len == 0:
    raise txErr("tx: empty txdata")

  # Per-tx stack cache: distinct attr keywords → name/attrId/unique/vt/mode.
  # 128 open-addressed slots keyed by the interned symId (no hashing of
  # strings on the hot path); overflow (-2) falls back to per-op lookups.
  var cache: array[MaxTxAttrs, AttrE]

  proc intern(sym: uint32, name: string): int32 =
    let start = int(sym mod MaxTxAttrs)
    for k in 0 ..< MaxTxAttrs:
      let j = (start + k) mod MaxTxAttrs
      if cache[j].sym == 0:
        cache[j].sym = sym
        cache[j].name = name
        return int32(j)
      if cache[j].sym == sym:
        return int32(j)
    -2

  # ── 1. Classification pass — only the attr cache slot and the tempid
  #    range are computed here (slots are typed by the decoder). ────────────
  ops.txSlot.setLen(txops.len)
  var minTid = 0'i64
  var maxTid = -1'i64
  var haveTids = false

  for i in 0 ..< txops.len:
    let op = addr txops[i]
    if op.attrSym == 0:
      ops.txSlot[i] = -1            # malformed attr → apply raises
    else:
      ops.txSlot[i] = intern(op.attrSym, ops.symtab.symName(SymId(op.attrSym)))
    if op.e.kind == tskInt and op.e.i < 0:
      if not haveTids or op.e.i < minTid: minTid = op.e.i
      if not haveTids or op.e.i > maxTid: maxTid = op.e.i
      haveTids = true
    if op.v.kind == tskInt and op.v.i < 0:
      if not haveTids or op.v.i < minTid: minTid = op.v.i
      if not haveTids or op.v.i > maxTid: maxTid = op.v.i
      haveTids = true

  # ── 2. Allocate the tx entity.  Its db.txInstant datom is appended to the
  #    main batchWrite by the engine (one storage cycle per tx). ─────────────
  let txEid = ops.allocateTxDeferred()
  let t = txEid

  # ── 3. Schema ops first (same-tx declaration usable by data ops). ─────────
  for i in 0 ..< txops.len:
    if not txops[i].isRetract and
       txops[i].attrSym == uint32(ops.symtab.dbIdent):
      ops.applySchemaGroupTx(ops.symtab, txops, i, t)

  # Refresh the attr cache: one resolver call per DISTINCT attr, never per op.
  for j in 0 ..< MaxTxAttrs:
    if cache[j].sym != 0 and not cache[j].declared:
      let aidOpt = ops.lookupAttr(cache[j].name)
      if aidOpt.isSome:
        cache[j].attrId = aidOpt.get
        cache[j].unique = ops.isUniqueById(cache[j].attrId)
        let vtOpt = ops.valueTypeFor(cache[j].attrId)
        cache[j].vt = vtOpt.get(resolver.DbTypeString)
        cache[j].mode = valueTypeToEncodeMode(cache[j].vt)
        cache[j].declared = true

  # ── 4. Collect every unique-index lookup of the tx (anchors + lookup refs)
  #    and resolve them in ONE batched pass (sorted, deduped). ───────────────
  var lookupKeys: seq[seq[byte]]
  var lookupOwner: seq[int]        # op index → key index (-1 = none)
  for i in 0 ..< txops.len:
    lookupOwner.add(-1)

  proc keyFor(aid: uint32, vt: uint32, mode: EncodeMode, v: TxWSlot): seq[byte] =
    result = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
              byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    result.add encodeValue(slotToValueForType(v, vt), mode, 0)

  proc slotOf(sym: uint32, name: string): int32 =
    ## Cache slot for any attr keyword (anchors may reference attrs not in
    ## the op-attr set); interns + resolves on first sight.
    let existing = intern(sym, name)
    if existing == -2: return -2
    if not cache[existing].declared:
      let aidOpt = ops.lookupAttr(name)
      if aidOpt.isSome:
        cache[existing].attrId = aidOpt.get
        cache[existing].unique = ops.isUniqueById(cache[existing].attrId)
        let vtOpt = ops.valueTypeFor(cache[existing].attrId)
        cache[existing].vt = vtOpt.get(resolver.DbTypeString)
        cache[existing].mode = valueTypeToEncodeMode(cache[existing].vt)
        cache[existing].declared = true
    existing

  for i in 0 ..< txops.len:
    let op = txops[i]
    # upsert anchor: :db/add of a tempid with a UNIQUE attr
    if not op.isRetract and op.e.kind == tskInt and op.e.i < 0 and
       op.attrSym != 0:
      let aSlot = ops.txSlot[i]
      var cSlot: int32
      if aSlot >= 0: cSlot = aSlot
      elif aSlot == -2: cSlot = -2
      else: cSlot = -1
      var isUnique = false
      if cSlot >= 0: isUnique = cache[cSlot].unique
      elif cSlot == -2: isUnique = ops.isUniqueAttr(ops.symtab.symName(SymId(op.attrSym)))
      if isUnique and cSlot >= 0:
        lookupKeys.add keyFor(cache[cSlot].attrId, cache[cSlot].vt,
                              cache[cSlot].mode, op.v)
        lookupOwner[i] = lookupKeys.len - 1
    # e-slot lookup ref: [uniqueAttr value]
    if op.e.kind == tskLookupRef:
      let name = ops.symtab.symName(SymId(op.e.sym))
      let cSlot = slotOf(op.e.sym, name)
      if cSlot >= 0 and cache[cSlot].declared and cache[cSlot].unique:
        lookupKeys.add keyFor(cache[cSlot].attrId, cache[cSlot].vt,
                              cache[cSlot].mode, op.e.refVal[])
        lookupOwner[i] = lookupKeys.len - 1
    # v-slot lookup ref
    if op.v.kind == tskLookupRef:
      let name = ops.symtab.symName(SymId(op.v.sym))
      let cSlot = slotOf(op.v.sym, name)
      if cSlot >= 0 and cache[cSlot].declared and cache[cSlot].unique:
        lookupKeys.add keyFor(cache[cSlot].attrId, cache[cSlot].vt,
                              cache[cSlot].mode, op.v.refVal[])
        lookupOwner[i] = lookupKeys.len - 1

  let lookupResults = batchLookupAvet(ops, lookupKeys)

  # ── 5. Resolve tempids before any write (anchors first, allocation order
  #    preserved by first-occurrence).  Allocated eids are marked FRESH:
  #    their CF-0 set was empty at birth, so idempotency is trivially false
  #    and hasDatom is skipped. ──────────────────────────────────────────────
  var resolved = initTable[int64, int64]()
  if haveTids:
    let span = int(maxTid - minTid + 1)
    if span > 1_000_000:
      raise txErr("tx: tempid span too large (max 1000000): " & $span)
    ops.txAnchorOp.setLen(span)
    ops.txAnchorEid.setLen(span)
    ops.txFresh.setLen(span)
    for idx in 0 ..< span:
      ops.txAnchorOp[idx] = 0
      ops.txAnchorEid[idx] = 0
      ops.txFresh[idx] = false

    # anchor op per tempid: first :db/add with a UNIQUE attr
    for i in 0 ..< txops.len:
      let op = txops[i]
      if op.isRetract or op.e.kind != tskInt or op.e.i >= 0: continue
      if lookupOwner[i] < 0: continue    # anchor-less tempid → fresh
      let tid = op.e.i
      let idx = int(tid - minTid)
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
      if aop != 0 and lookupOwner[aop - 1] >= 0:
        eid = if lookupResults[lookupOwner[aop - 1]].isSome:
                lookupResults[lookupOwner[aop - 1]].get
              else: ops.allocateInPartition(PartUser)
      else:
        eid = ops.allocateInPartition(PartUser)
      ops.txAnchorEid[idx] = eid
      ops.txFresh[idx] = true
      resolved[tid] = eid

  # ── 6. Apply pass: resolve e/v slots in place, then one batchWrite
  #    (data + the deferred db.txInstant) and one for retracts. ──────────────
  for i in 0 ..< txops.len:
    let op = addr txops[i]
    let aSlot = ops.txSlot[i]

    if isSchemaGroupOp(ops.symtab, op[]):
      continue

    if op.isRetract:
      if op.e.kind == tskKw and op.e.sym == uint32(ops.symtab.dbCurrentTx):
        raise txErr("tx: :db/retract on :db/current-tx is not allowed (§6)")
      if op.attrSym == 0:
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
      let aidOpt = ops.lookupAttr(ops.symtab.symName(SymId(op.attrSym)))
      op.attrId = if aidOpt.isSome: aidOpt.get else: 0
      if aidOpt.isNone and not op.isRetract:
        raise newException(EvalError,
          "save to undeclared attr: " & ops.symtab.symName(SymId(op.attrSym)))

    # e slot → resolved eid (mutated in place)
    case op.e.kind
    of tskInt:
      if op.e.i < 0:
        op.e.i = ops.txAnchorEid[int(op.e.i - minTid)]
    of tskKw:
      if op.e.sym == uint32(ops.symtab.dbCurrentTx):
        op.e = TxWSlot(kind: tskInt, i: txEid)
      else:
        raise txErr("tx: cannot resolve e slot: :" &
          ops.symtab.symName(SymId(op.e.sym)))
    of tskLookupRef:
      let ki = lookupOwner[i]
      var found = none[int64]()
      if ki >= 0: found = lookupResults[ki]
      if found.isNone:
        raise txErr("tx: lookup ref [:" &
          ops.symtab.symName(SymId(op.e.sym)) & " " &
          ops.symtab.slotRepr(op.e.refVal[]) & "] did not match any entity")
      op.e = TxWSlot(kind: tskInt, i: found.get)
    else:
      raise txErr("tx: cannot resolve e slot: " & ops.symtab.slotRepr(op.e))

    # v slot → vresolved for tempids / lookup refs
    if op.v.kind == tskInt and op.v.i < 0:
      let tid = op.v.i
      if tid < minTid or tid > maxTid or
         ops.txAnchorEid[int(tid - minTid)] == 0:
        raise txErr("tx: tempid " & $tid &
          " referenced in v slot but never allocated")
      op.vresolved = ops.txAnchorEid[int(tid - minTid)]
    elif op.v.kind == tskLookupRef:
      let ki = lookupOwner[i]
      var found = none[int64]()
      if ki >= 0: found = lookupResults[ki]
      if found.isNone:
        raise txErr("tx: lookup ref [:" &
          ops.symtab.symName(SymId(op.v.sym)) & " " &
          ops.symtab.slotRepr(op.v.refVal[]) & "] did not match any entity")
      op.vresolved = found.get

    # Datomic semantics: :db/add of a present datom is a no-op.  Fresh
    # entities (allocated in this tx) are skipped by construction.
    if not op.isRetract and op.attrId != 0:
      var isFresh = false
      if op.e.i >= 0 and haveTids:
        let fi = op.e.i - minTid
        if fi >= 0 and fi < ops.txFresh.len and ops.txFresh[int(fi)]:
          isFresh = true
      if not isFresh:
        let vEff = if op.v.kind == tskInt and op.v.i < 0:
                     TxWSlot(kind: tskInt, i: op.vresolved)
                   elif op.v.kind == tskLookupRef:
                     TxWSlot(kind: tskInt, i: op.vresolved)
                   else: op.v
        if ops.hasDatomW(op.e.i, op.attrId, vEff):
          op.attrId = 0               # engine skips it

  # 7. Emit one batchWrite (data + deferred txInstant) and one for retracts.
  ops.saveBatchEdn(txops, t, 0)
  ops.retractBatch(txops, t, 0)

  result = TxReport(tempids: resolved, tx: t)

proc slotFromSExpr(tab: SymTab; e: SExpr): TxWSlot =
  ## SExpr value slot → flat TxWSlot (EDN/test path).
  case e.kind
  of sInt: TxWSlot(kind: tskInt, i: e.ival)
  of sFloat: TxWSlot(kind: tskFloat, f: e.fval)
  of sStr: TxWSlot(kind: tskStr, s: e.sval)
  of sKeyword: TxWSlot(kind: tskKw, sym: uint32(tab.internSym(e.kwval)))
  of sSymbol: TxWSlot(kind: tskStr, s: e.symval)
  of sBool: TxWSlot(kind: tskBool, b: e.bval)
  of sBytes: TxWSlot(kind: tskBytes, bin: e.bytesval)
  of sList:
    if e.items.len == 2 and e.items[0].kind == sKeyword:
      var s = TxWSlot(kind: tskLookupRef,
                      sym: uint32(tab.internSym(e.items[0].kwval)))
      new(s.refVal)
      s.refVal[] = tab.slotFromSExpr(e.items[1])
      s
    else:
      TxWSlot(kind: tskMissing)
  of sVoid, sResource: TxWSlot(kind: tskMissing)

proc toTxWOp(tab: SymTab; op: SExpr): TxWOp =
  ## SExpr op vector → flat TxWOp (EDN/test path).
  if op.kind != sList or op.items.len != 4:
    raise txErr("tx: op must be a 4-element vector: " & $op)
  if op.items[0].kind != sKeyword:
    raise txErr("tx: op must start with a keyword: " & $op)
  result.isRetract = op.items[0].kwval == "db/retract"
  if not result.isRetract and op.items[0].kwval != "db/add":
    raise txErr("tx: unknown op keyword: :" & op.items[0].kwval)
  result.e = tab.slotFromSExpr(op.items[1])
  if op.items[2].kind == sKeyword:
    result.attrSym = uint32(tab.internSym(op.items[2].kwval))
  result.v = tab.slotFromSExpr(op.items[3])

proc transactEdn*(ops: EngineOps; txdata: seq[SExpr]): TxReport =
  ## EDN/SExpr entry — converts to flat ops and runs transactTx
  ## (tests, REPL and any SExpr producer).
  if txdata.len == 0:
    raise txErr("tx: empty txdata")
  var flat = newSeq[TxWOp](txdata.len)
  for i in 0 ..< txdata.len:
    flat[i] = ops.symtab.toTxWOp(txdata[i])
  transactTx(ops, flat)
