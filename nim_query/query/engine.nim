## query/engine.nim — QueryEngine: ties kvstore + scheme + scanner + hostfns.
##
## Port of spier-eavt-query/src/engine/query_engine_inner.rs + lib.rs (~1293 lines Rust → Nim).

import std/[options, tables, strutils, sequtils, monotimes]
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
    # perf counters for saveWithT
    saveCount*: int64
    saveLookupAttrNs*: int64    # nanoseconds
    saveTypeCheckNs*: int64
    saveEncodeNs*: int64
    saveRetractScanNs*: int64
    saveBuildEntriesNs*: int64
    saveBatchWriteNs*: int64
    # retractScan breakdown
    saveRetractPrefixNs*: int64  # prefix build time
    saveRetractSeekNs*: int64    # scanPrefix (cursor seek + iteration)
    saveRetractApplyNs*: int64   # filter + buildEavtEntries + batchWrite
    saveRetractCount*: int64     # datoms actually retracted
    saveRetractScans*: int64     # number of retractScan calls

proc newQueryStore*(kv: KVStore): QueryStore =
  let eng = newEavtEngine(kv)
  eng.bootstrapResolver()
  QueryStore(eavt: eng, kv: kv)

proc resetSaveCounters*(q: QueryStore) =
  q.saveCount = 0
  q.saveLookupAttrNs = 0
  q.saveTypeCheckNs = 0
  q.saveEncodeNs = 0
  q.saveRetractScanNs = 0
  q.saveBuildEntriesNs = 0
  q.saveBatchWriteNs = 0
  q.saveRetractPrefixNs = 0
  q.saveRetractSeekNs = 0
  q.saveRetractApplyNs = 0
  q.saveRetractCount = 0
  q.saveRetractScans = 0

proc printSavePerf*(q: QueryStore) =
  if q.saveCount == 0: return
  let total = q.saveLookupAttrNs + q.saveTypeCheckNs + q.saveEncodeNs +
              q.saveRetractScanNs + q.saveBuildEntriesNs + q.saveBatchWriteNs
  template pct(ns: int64): string = formatFloat(ns.float / total.float * 100, ffDecimal, 1)
  template ms(ns: int64): string = formatFloat(ns.float / 1_000_000, ffDecimal, 1)
  echo "=== saveWithT perf (", q.saveCount, " calls) ==="
  echo "  lookupAttr:     ", ms(q.saveLookupAttrNs), " ms  (", pct(q.saveLookupAttrNs), "%)"
  echo "  typeCheck:      ", ms(q.saveTypeCheckNs), " ms  (", pct(q.saveTypeCheckNs), "%)"
  echo "  encode:         ", ms(q.saveEncodeNs), " ms  (", pct(q.saveEncodeNs), "%)"
  echo "  retractScan:    ", ms(q.saveRetractScanNs), " ms  (", pct(q.saveRetractScanNs), "%)"
  echo "    prefix:       ", ms(q.saveRetractPrefixNs), " ms"
  echo "    seek:         ", ms(q.saveRetractSeekNs), " ms"
  echo "    apply:        ", ms(q.saveRetractApplyNs), " ms"
  echo "    retracted:    ", q.saveRetractCount, " datoms in ", q.saveRetractScans, " scans"
  echo "  buildEntries:   ", ms(q.saveBuildEntriesNs), " ms  (", pct(q.saveBuildEntriesNs), "%)"
  echo "  batchWrite:     ", ms(q.saveBatchWriteNs), " ms  (", pct(q.saveBatchWriteNs), "%)"
  echo "  total:          ", ms(total), " ms"
  echo "  avg per save:   ", formatFloat(total.float / q.saveCount.float / 1_000_000, ffDecimal, 3), " ms"

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
  q.saveCount += 1
  var t0 = getMonoTime()

  let attrIdOpt = q.eavt.lookupAttr(attr)
  if attrIdOpt.isNone:
    raise newException(EvalError, "save to undeclared attr: " & attr)
  let attrId = attrIdOpt.get

  q.saveLookupAttrNs += (getMonoTime().ticks - t0.ticks)
  t0 = getMonoTime()

  let vt = q.eavt.valueTypeFor(attrId).get(scanner.DbTypeString)
  let many = q.eavt.isMany(attrId)
  let mode = valueTypeToEncodeMode(vt)

  q.saveTypeCheckNs += (getMonoTime().ticks - t0.ticks)
  t0 = getMonoTime()

  let encoded = encodeValue(sexprToValueForType(val, vt), mode, eid)
  let indexed = q.eavt.resolver.isIndexed(attrId)

  q.saveEncodeNs += (getMonoTime().ticks - t0.ticks)
  t0 = getMonoTime()

  if not many:
    var tPrefix = getMonoTime()
    var ePrefix = keys.encodeEid(eid)
    ePrefix.add byte(attrId shr 24); ePrefix.add byte((attrId shr 16) and 0xFF)
    ePrefix.add byte((attrId shr 8) and 0xFF); ePrefix.add byte(attrId and 0xFF)
    q.saveRetractPrefixNs += (getMonoTime().ticks - tPrefix.ticks)

    var tScan = getMonoTime()
    var foundKeys: seq[seq[byte]] = @[]
    for ek in q.eavt.scanPrefixNoMerge(0, ePrefix):
      foundKeys.add(ek)
    q.saveRetractSeekNs += (getMonoTime().ticks - tScan.ticks)

    tScan = getMonoTime()
    var retracted = 0
    for ek in foundKeys:
      if ek.len < 20: continue
      let esf = beUint64(ek, ek.len - 8)
      if (esf and 1) != 0: continue
      var retEntries = buildEavtEntries(eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
      q.eavt.batchWrite(retEntries)
      retracted += 1
    q.saveRetractApplyNs += (getMonoTime().ticks - tScan.ticks)
    q.saveRetractCount += retracted
    q.saveRetractScans += 1

  q.saveRetractScanNs += (getMonoTime().ticks - t0.ticks)
  t0 = getMonoTime()

  var entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, indexed)

  q.saveBuildEntriesNs += (getMonoTime().ticks - t0.ticks)
  t0 = getMonoTime()

  q.eavt.batchWrite(entries)

  q.saveBatchWriteNs += (getMonoTime().ticks - t0.ticks)

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
