## query/engine.nim — QueryEngine: ties kvstore + scheme + scanner + hostfns.
##
## Port of spier-eavt-query/src/engine/query_engine_inner.rs + lib.rs (~1293 lines Rust → Nim).

import std/[options, tables, strutils, sequtils]
import scheme
import kvstore
import eavt
import keys
import resolver
import types
import scanner
import hostfns

# ═══════════════════════════════════════════════════════════════════════════════
# QueryStore — concrete EngineOps implementation over the kvstore
# ═══════════════════════════════════════════════════════════════════════════════

type
  QueryStore* = ref object of EngineOps
    eavt*: EavtEngine
    kv*: KVStore             # Nim ref — no C-ABI

proc newQueryStore*(kv: KVStore): QueryStore =
  let eng = newEavtEngine(kv)
  eng.bootstrapResolver()
  QueryStore(eavt: eng, kv: kv)

# ── SExpr → storage value ──

proc sexprToPackedValue(val: SExpr): string =
  case val.kind:
  of sVoid: result = ""
  of sInt: result = $val.ival
  of sFloat: result = $val.fval
  of sStr: result = val.sval
  of sBool: result = (if val.bval: "true" else: "false")
  of sBytes:
    result = newString(val.bytesval.len)
    for i, b in val.bytesval: result[i] = char(b)
  else: result = ""

proc sexprToValueForType(val: SExpr; vt: uint32): string =
  if vt == scanner.DbTypeBoolean:
    result = if val.kind == sBool: (if val.bval: "1" else: "0") else: "0"
  elif vt == scanner.DbTypeBytes or vt == scanner.DbTypeBlob:
    if val.kind == sBytes:
      result = newString(val.bytesval.len)
      for i, b in val.bytesval: result[i] = char(b)
    else:
      result = "0"
  else:
    result = sexprToPackedValue(val)

# ── EngineOps implementation ──

method openCursor(q: QueryStore; cfId: uint32; prefix: seq[byte]): Cursor =
  let mc = q.kv.openScanCursor(cfId.int)
  mergedCursor(mc)

method saveWithT(q: QueryStore; eid: int64; attr: string; val: SExpr;
                  t: int64; asOf: int64) =
  let attrIdOpt = q.eavt.lookupAttr(attr)
  if attrIdOpt.isNone:
    raise newException(EvalError, "save to undeclared attr: " & attr)
  let attrId = attrIdOpt.get
  let vt = q.eavt.valueTypeFor(attrId).get(scanner.DbTypeString)
  let many = q.eavt.isMany(attrId)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(sexprToValueForType(val, vt), mode, eid)
  let indexed = q.eavt.resolver.isIndexed(attrId)
  if not many:
    var ePrefix = keys.encodeEid(eid)
    ePrefix.add byte(attrId shr 24); ePrefix.add byte((attrId shr 16) and 0xFF)
    ePrefix.add byte((attrId shr 8) and 0xFF); ePrefix.add byte(attrId and 0xFF)
    for ek in q.eavt.scanPrefix(0, ePrefix):
      if ek.len < 20: continue
      let esf = beUint64(ek, ek.len - 8)
      if (esf and 1) != 0: continue
      var retEntries = buildEavtEntries(eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
      q.eavt.batchWrite(retEntries)
  var entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, indexed)
  q.eavt.batchWrite(entries)

method retract(q: QueryStore; eid: int64; attr: string; val: SExpr;
                t: int64; asOf: int64) =
  let attrIdOpt = q.eavt.lookupAttr(attr)
  if attrIdOpt.isNone: return  # retract on undeclared attr is a no-op
  let attrId = attrIdOpt.get
  let vt = q.eavt.valueTypeFor(attrId).get(scanner.DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(sexprToValueForType(val, vt), mode, eid)
  let indexed = q.eavt.resolver.isIndexed(attrId)
  let entries = buildEavtEntries(eid, attrId, encoded, t, true, mode, indexed)
  q.eavt.batchWrite(entries)

method lookupAttr(q: QueryStore; name: string): Option[uint32] =
  q.eavt.lookupAttr(name)

method attrName(q: QueryStore; aid: uint32): string =
  q.eavt.attrName(aid)

method declareAttrFromSql(q: QueryStore; attr, typeName: string;
    many, unique: bool; t: int64) =
  let vt = valueTypeFromName(typeName)
  discard q.eavt.eavtDeclareAttr(attr, vt, many, unique)

method declarePartition(q: QueryStore; name: string; t: int64): uint64 =
  q.eavt.declarePartition(name)

method allocateInPartition(q: QueryStore; partitionId: uint64): int64 =
  q.eavt.allocateInPartition(partitionId)

method allocateTx(q: QueryStore): int64 =
  q.eavt.allocateTAndWriteTx()

method valueTypeFor(q: QueryStore; aid: uint32): Option[uint32] =
  q.eavt.valueTypeFor(aid)

method isUniqueAttr(q: QueryStore; name: string): bool =
  let aid = q.eavt.lookupAttr(name)
  aid.isSome and q.eavt.isUnique(aid.get)

method lookupEntity(q: QueryStore; attrName: string; value: SExpr): Option[int64] =
  ## Unique-attr lookup: scan avet [attr 4B][val][eid 8B][sf 8B] by prefix.
  let aidOpt = q.eavt.lookupAttr(attrName)
  if aidOpt.isNone: return none[int64]()
  let aid = aidOpt.get
  let vt = q.eavt.valueTypeFor(aid).get(resolver.DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(sexprToValueForType(value, vt), mode, 0)
  var prefix = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
                byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  prefix.add encoded
  let scanRes = q.eavt.scanPrefix(2, prefix)
  if scanRes.len == 0: return none[int64]()
  let k = scanRes[0]
  if k.len < 20: return none[int64]()
  let sf = beUint64(k, k.len - 8)
  if (sf and 1) == 1: return none[int64]()  # retracted
  some(decodeEid(beUint64(k, k.len - 16)))

method lookupValue(q: QueryStore; eid: int64; attrName: string): Option[SExpr] =
  let aidOpt = q.eavt.lookupAttr(attrName)
  if aidOpt.isNone: return none[SExpr]()
  let aid = aidOpt.get
  # eavt key: [eid 8B BE][attr 4B BE][val][sf 8B BE]
  var prefix = keys.encodeEid(eid)
  prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
  prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
  let scanRes = q.eavt.scanPrefix(0, prefix)
  # Key order: by (prefix, sf). sf = (t<<1)|retracted. Within the same
  # [eid][attr][val] group, a retraction (sf=odd) sorts right after its
  # original (sf=even). Walk backwards: if the newest entry in a group is
  # retracted the whole group is dead.  Otherwise the newest active wins.
  var retractedGroup: seq[byte] = @[]
  for j in countdown(scanRes.len - 1, 0):
    let k = scanRes[j]
    if k.len < 20: continue
    let sf = beUint64(k, k.len - 8)
    let group = k[0 ..< k.len - 8]
    if (sf and 1) == 1:
      retractedGroup = group
      continue
    if group == retractedGroup:
      continue   # group was killed by a later retraction
    let vt = q.eavt.valueTypeFor(aid).get(resolver.DbTypeString)
    return some(keys.decodeStoredValue(k[12 ..< k.len - 8], vt))
  none[SExpr]()

# ═══════════════════════════════════════════════════════════════════════════════
# QuerySession — runs compiled Scheme programs
# ═══════════════════════════════════════════════════════════════════════════════

type
  QuerySession* = ref object
    store*: QueryStore
    host*: SchemeHostFns
    program*: SchemeProgram

proc newQuerySession*(store: QueryStore; program: SchemeProgram;
                       params: seq[SExpr]; tx: int64;
                       asOfTx: Option[int64]): QuerySession =
  let host = SchemeHostFns(
    engine: store,
    params: params,
    tx: tx,
    asOfTx: asOfTx,
    scanners: @[],
    leapIters: initTable[int, LeapIterator](),
  )
  QuerySession(store: store, host: host, program: program)

# ── Execute program (batch, non-streaming) ──

proc executeProgram*(session: QuerySession): SExpr =
  var env = newEnvironment()
  eval(session.program, env, session.host)

# ── Streaming cursor (yield/resume) ──

type
  StreamingSession* = ref object
    vm*: VmSession
    host*: SchemeHostFns

proc newStreamingSession*(proto: QuerySession): StreamingSession =
  StreamingSession(
    vm: newVmSession(proto.program),
    host: proto.host,
  )

proc nextBatch*(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) =
  sess.vm.nextBatch(sess.host, maxRows)
