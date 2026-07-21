## query/engine.nim — QueryEngine: ties transactor + scheme + scanner + hostfns.
##
## Port of spier-eavt-query/src/engine/query_engine_inner.rs + lib.rs (~1293 lines Rust → Nim).

import std/[options, tables, strutils, sequtils]
import ../scheme
import ../transactor
import ../eavt
import ../keys
import ../resolver
import ../abi
import query/types
import query/scanner
import query/hostfns

# ═══════════════════════════════════════════════════════════════════════════════
# QueryStore — concrete EngineOps implementation over the transactor
# ═══════════════════════════════════════════════════════════════════════════════

type
  QueryStore* = ref object of EngineOps
    eavt*: EavtEngine
    kv*: NimKVStoreVtablePtr
    mt*: MtVtablePtr

proc newQueryStore*(kvHandle: NimKVStoreVtablePtr; mtHandle: MtVtablePtr): QueryStore =
  let eng = newEavtEngine(kvHandle)
  eng.bootstrapResolver()
  QueryStore(eavt: eng, kv: kvHandle, mt: mtHandle)

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

method openCursor(q: QueryStore; cfId: uint32; prefix: seq[byte]): NimCursor =
  let pf = if prefix.len > 0: addr prefix[0] else: nil
  var cursorId: uint64 = 0
  var err: cint

  # Use memtable scan to create cursor
  let mtPrefix = if cfId == 0'u32: prefix else: prefix

  # For now, create a simple cursor from the KVStore scan
  var keys: seq[seq[byte]] = @[]
  var pos = 0

  proc isValid(): bool = pos < keys.len
  proc currentKey(): Option[seq[byte]] =
    if pos < keys.len: some(keys[pos]) else: none[seq[byte]]()
  proc step() = inc pos
  proc skipGroup(ge: int) = inc pos
  proc seek(target: seq[byte]) =
    while pos < keys.len:
      var gt = true
      let k = keys[pos]
      if k.len < target.len: gt = false
      else:
        for i in 0..<target.len:
          if k[i] < target[i]: gt = false; break
          if k[i] > target[i]: break
      if gt: return
      inc pos
  proc invalidate() = pos = keys.len

  let ci = NimCursor(
    isValidCb: isValid,
    currentKeyCb: currentKey,
    stepCb: step,
    skipGroupCb: skipGroup,
    seekCb: seek,
    invalidateCb: invalidate,
  )

  # Load keys via scan
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  let rc = q.kv.scan(q.kv.handle, cfId, pf, prefix.len.csize_t,
                      addr outBuf, addr outLen, addr err)
  if rc != 0: return ci

  var rp = 0
  while rp + 4 <= outLen.int:
    let raw = cast[ptr UncheckedArray[byte]](outBuf)
    let klen = int(uint32(raw[rp]) shl 24 or uint32(raw[rp+1]) shl 16 or
                     uint32(raw[rp+2]) shl 8 or uint32(raw[rp+3]))
    rp += 4
    if rp + klen > outLen.int: break
    var k = newSeq[byte](klen)
    copyMem(addr k[0], addr cast[ptr UncheckedArray[byte]](outBuf)[rp], klen)
    rp += klen
    keys.add k
  if outBuf != nil: q.kv.freeBuf(outBuf)
  ci

method saveWithT(q: QueryStore; eid: uint64; attr: string; val: SExpr;
                  t: uint64; asOf: uint64) =
  let attrId = q.eavt.lookupAttr(attr).get(0'u32)
  if attrId == 0:
    # need to declare attr first
    discard
  let vt = q.eavt.valueTypeFor(attrId).get(scanner.DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(sexprToValueForType(val, vt), mode, eid)
  let entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, false)
  q.eavt.batchWrite(entries)

method retract(q: QueryStore; eid: uint64; attr: string; val: SExpr;
                t: uint64; asOf: uint64) =
  let attrId = q.eavt.lookupAttr(attr).get(0'u32)
  let vt = q.eavt.valueTypeFor(attrId).get(scanner.DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(sexprToValueForType(val, vt), mode, eid)
  let entries = buildEavtEntries(eid, attrId, encoded, t, true, mode, false)
  q.eavt.batchWrite(entries)

method lookupAttr(q: QueryStore; name: string): Option[uint32] =
  q.eavt.lookupAttr(name)

method attrName(q: QueryStore; aid: uint32): string =
  q.eavt.attrName(aid)

method declareAttrFromSql(q: QueryStore; attr, typeName: string;
    many, unique: bool; t: uint64) =
  let vt = valueTypeFromName(typeName)
  discard q.eavt.eavtDeclareAttr(attr, vt, many)

method declarePartition(q: QueryStore; name: string; t: uint64): uint64 =
  q.eavt.declarePartition(name)

method allocateInPartition(q: QueryStore; partitionId: uint64): uint64 =
  q.eavt.allocateInPartition(partitionId)

method allocateTx(q: QueryStore): uint64 = 0  # TODO

method valueTypeFor(q: QueryStore; aid: uint32): Option[uint32] =
  q.eavt.valueTypeFor(aid)

method isUniqueAttr(q: QueryStore; name: string): bool = false  # TODO

method lookupEntity(q: QueryStore; attrName: string; value: SExpr): Option[uint64] =
  # TODO: not yet implemented
  none[uint64]()

method lookupValue(q: QueryStore; eid: uint64; attrName: string): Option[SExpr] =
  let aid = q.eavt.lookupAttr(attrName)
  if aid.isNone: return none[SExpr]()
  var prefix = keys.encodeInt(int64(eid))
  let aidVal = aid.get
  prefix.add byte(aidVal shr 24); prefix.add byte((aidVal shr 16) and 0xFF)
  prefix.add byte((aidVal shr 8) and 0xFF); prefix.add byte(aidVal and 0xFF)
  let scanRes = q.eavt.scan(0'u32, prefix)
  if scanRes.len > 0:
    let k = scanRes[0]
    if k.len >= 20:
      let raw = beUint64(k, 12)
      return some(SExpr(kind: sInt, ival: keys.decodeInt64(raw)))
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
                       params: seq[SExpr]; tx: uint64;
                       asOfTx: Option[uint64]): QuerySession =
  let host = SchemeHostFns(
    engine: store,
    params: params,
    tx: tx,
    asOfTx: asOfTx,
    scanners: @[],
  )
  QuerySession(store: store, host: host, program: program)

# ── Execute program (batch, non-streaming) ──

proc executeProgram*(session: QuerySession): SExpr =
  var env = newEnvironment()
  eval(session.program, env, session.host)

# ── Open streaming cursor (yield/resume) ──

type
  StreamingSession* = ref object
    program*: SchemeProgram
    env*: Environment
    host*: SchemeHostFns
    state*: YieldState
    done*: bool

proc newStreamingSession*(proto: QuerySession): StreamingSession =
  StreamingSession(
    program: proto.program,
    env: newEnvironment(),
    host: proto.host,
    state: YieldState(),
    done: false,
  )

proc nextBatch*(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) =
  ## Returns (rows, more_available).
  if sess.done or maxRows == 0:
    return (@[], false)

  var rows: seq[seq[SExpr]] = @[]
  var more = false

  while rows.len < maxRows:
    let step = evalWithYield(sess.program, sess.env, sess.host, sess.state)
    case step.kind:
    of esYield:
      if step.result.kind == sList:
        rows.add step.result.items
      more = rows.len >= maxRows
      if more: return (rows, true)
    of esDone:
      sess.done = true
      return (rows, false)

  (rows, true)
