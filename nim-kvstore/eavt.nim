## eavt.nim — EAVT engine (save, retract, bootstrap, lookup).
##
## Port of spier-transactor/src/eavt.rs (~1099 lines Rust → Nim).
## Coordinates Resolver + KVStore for entity-attribute-value-time operations.

import std/[tables, strutils, strformat, options, times, sets]
import ./resolver
import ./keys
import ./abi  # for NimKVStoreVtablePtr, MtVtablePtr, error codes
import ./spinlock

# ═══════════════════════════════════════════════════════════════════════════════
# Value type mapping
# ═══════════════════════════════════════════════════════════════════════════════

proc valueTypeToEncodeMode*(vt: uint32): EncodeMode =
  case vt:
  of DbTypeRef:       return emRef
  of DbTypeString:    return emVariable
  of DbTypeKeyword:   return emVariable
  of DbTypeBoolean:   return emFixed
  of DbTypeLong:      return emFixed
  of DbTypeInstant:   return emFixed
  of DbTypeFloat:     return emFixed
  of DbTypeBytes:     return emBlob
  of DbTypeBlob:      return emBlob
  else:               return emVariable

proc valueTypeFromName*(name: string): uint32 =
  case name.toLowerAscii():
  of "ref":     return DbTypeRef
  of "string":  return DbTypeString
  of "keyword": return DbTypeKeyword
  of "boolean": return DbTypeBoolean
  of "long":    return DbTypeLong
  of "instant": return DbTypeInstant
  of "float":   return DbTypeFloat
  of "bytes":   return DbTypeBytes
  of "blob":    return DbTypeBlob
  else:         return DbTypeString

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT Engine
# ═══════════════════════════════════════════════════════════════════════════════

type
  EavtEngine* = ref object
    kv*: NimKVStoreVtablePtr
    kvHandle*: pointer
    resolver*: Resolver
    lock: SpinLock

proc newEavtEngine*(kv: NimKVStoreVtablePtr): EavtEngine =
  result = EavtEngine(kv: kv, kvHandle: kv.handle, resolver: newResolver())
  initSpinLock(result.lock)
  # bootstrap called after construction (avoids forward ref)

# ── Batch write helper ──

proc batchWrite*(eng: EavtEngine; entries: seq[EavtEntry]) =
  if entries.len == 0: return
  var ops: seq[byte] = @[]
  for e in entries:
    ops.add e.cf
    let kl = e.key.len.uint32
    ops.add byte(kl shr 24); ops.add byte((kl shr 16) and 0xFF)
    ops.add byte((kl shr 8) and 0xFF); ops.add byte(kl and 0xFF)
    ops.add e.key
  var err: cint
  discard eng.kv.batchWrite(eng.kvHandle, addr ops[0], ops.len.csize_t, addr err)

# ── Scan helper ──

proc scan*(eng: EavtEngine; cf: uint32; prefix: seq[byte]): seq[seq[byte]] =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var err: cint
  let pf = if prefix.len > 0: addr prefix[0] else: nil
  let rc = eng.kv.scan(eng.kvHandle, cf, pf, prefix.len.csize_t,
                         addr outBuf, addr outLen, addr err)
  if rc != 0: return @[]
  var pos = 0
  while pos + 4 <= outLen.int:
    let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                 uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                 uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                 uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
    pos += 4
    if pos + klen > outLen.int: break
    var k = newSeq[byte](klen)
    copyMem(addr k[0], addr cast[ptr UncheckedArray[byte]](outBuf)[pos], klen)
    pos += klen
    result.add k
  if outBuf != nil: eng.kv.freeBuf(outBuf)

# ── Bootstrap: scan KV for existing schema ──

proc bootstrapResolver*(eng: EavtEngine) =
  ## Load user attribute schema from db.* datoms (Rust bootstrap_resolver).
  ## aevt key: [attr 4B BE][eid 8B BE][val][sf 8B BE]
  var identMap = initTable[uint64, string]()
  var vtMap = initTable[uint64, uint32]()
  var cardMap = initTable[uint64, bool]()
  var uniqueSet = initHashSet[uint64]()

  for k in eng.scan(1'u32, @[0'u8, 0'u8, 0'u8, byte(DbIdentAid)]):
    if k.len < 24: continue
    if beUint32(k, 0) != DbIdentAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = beUint64(k, 4)
    if e < BootstrapFirstUserId: continue
    let name = decodeVariableStr(k, 12)
    if name.len > 0: identMap[e] = name

  for k in eng.scan(1'u32, @[0'u8, 0'u8, 0'u8, byte(DbValueTypeAid)]):
    if k.len < 28: continue
    if beUint32(k, 0) != DbValueTypeAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = beUint64(k, 4)
    vtMap[e] = cast[uint32](decodeInt64(beUint64(k, 12)))

  for k in eng.scan(1'u32, @[0'u8, 0'u8, 0'u8, byte(DbCardinalityAid)]):
    if k.len < 28: continue
    if beUint32(k, 0) != DbCardinalityAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = beUint64(k, 4)
    cardMap[e] = cast[uint32](decodeInt64(beUint64(k, 12))) == DbCardinalityManyAid

  for k in eng.scan(1'u32, @[0'u8, 0'u8, 0'u8, byte(DbUniqueAid)]):
    if k.len < 20: continue
    if beUint32(k, 0) != DbUniqueAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    uniqueSet.incl beUint64(k, 4)

  for e, name in identMap:
    let vt = vtMap.getOrDefault(e, DbTypeString)
    let many = cardMap.getOrDefault(e, false)
    let unique = e in uniqueSet
    eng.resolver.loadUserAttr(name, e, vt, many, unique, false)

# ── Save a datom ──

proc eavtSave*(eng: EavtEngine; eid: uint64; attrName: string;
                value: string; t: uint64): uint64 {.discardable.} =
  eng.lock.withLock:
    let attrId = eng.resolver.internAttr(attrName)
    let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
    let many = eng.resolver.isMany(attrId)
    let mode = valueTypeToEncodeMode(vt)
    let encoded = encodeValue(value, mode, 0)
    let indexed = eng.resolver.isIndexed(attrId)
    if not many:
      # Retract any existing active datoms for this eid+attr.
      var ePrefix = encodeRef(eid)
      ePrefix.add byte(attrId shr 24); ePrefix.add byte((attrId shr 16) and 0xFF)
      ePrefix.add byte((attrId shr 8) and 0xFF); ePrefix.add byte(attrId and 0xFF)
      for ek in eng.scan(0'u32, ePrefix):
        if ek.len < 20: continue
        let esf = beUint64(ek, ek.len - 8)
        if (esf and 1) != 0: continue
        var retEntries = buildEavtEntries(eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
        eng.batchWrite(retEntries)
    let entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, indexed)
    eng.batchWrite(entries)
    return eid

proc eavtRetract*(eng: EavtEngine; eid: uint64; attrName: string;
                   value: string; t: uint64) =
  eng.lock.withLock:
    let attrId = eng.resolver.internAttr(attrName)
    let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
    let mode = valueTypeToEncodeMode(vt)
    let encoded = encodeValue(value, mode, 0)
    let indexed = eng.resolver.isIndexed(attrId)
    let entries = buildEavtEntries(eid, attrId, encoded, t, true, mode, indexed)
    eng.batchWrite(entries)

# ── Tx allocation + as-of resolution ──

proc nowMicros(): uint64 =
  let t = getTime()
  t.toUnix.uint64 * 1_000_000 + (t.nanosecond div 1000).uint64

proc allocateTAndWriteTx*(eng: EavtEngine): uint64 =
  ## Allocate a fresh tx entity and write its db.txInstant datom.
  ## Port of Rust EavtEngine::allocate_t_and_write_tx.
  eng.lock.withLock:
    let txEid = eng.resolver.allocateInPartition(PartTx)
    let encoded = encodeValue($nowMicros(), emFixed, 0)
    let entries = buildEavtEntries(txEid, DbTxInstantAid, encoded, txEid,
                                    false, emFixed, false)
    eng.batchWrite(entries)
    return txEid

proc resolveAsOfTx*(eng: EavtEngine; asOfUs: uint64): Option[uint64] =
  ## Resolve an as-of timestamp (micros) to the newest tx entity whose
  ## db.txInstant is <= it. Port of Rust EavtEngine::resolve_as_of_tx.
  if asOfUs == uint64.high: return none[uint64]()
  if (asOfUs shr 44) == PartTx: return some(asOfUs)  # already a tx eid
  # aevt key: [attr 4B BE][eid 8B BE][val][sf 8B BE]
  var prefix = @[0'u8, 0'u8, 0'u8, byte(DbTxInstantAid)]
  var bestTx = 0'u64
  var bestInst = 0'u64
  var found = false
  for k in eng.scan(1'u32, prefix):
    if k.len < 28: continue  # 4 + 8 + 8 + 8
    if beUint32(k, 0) != DbTxInstantAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue  # retracted
    let us = decodeInt64(beUint64(k, 12))
    if us < 0: continue
    let usU = cast[uint64](us)
    if usU <= asOfUs and (not found or usU > bestInst):
      bestTx = beUint64(k, 4)
      bestInst = usU
      found = true
  if found: some(bestTx) else: none[uint64]()

proc eavtDeclareAttr*(eng: EavtEngine; name: string; valueType: uint32;
                       many: bool; unique: bool = false): (uint32, bool) =
  eng.lock.withLock:
    let (aid, isNew) = eng.resolver.declareAttr(name, valueType, many)
    if unique: eng.resolver.setUnique(aid, true)
    if isNew:
      # Persist schema as db.* datoms (Rust declare_attr_with_t).
      let t = eng.resolver.allocateInPartition(PartTx)
      let e = aid.uint64
      eng.batchWrite(buildEavtEntries(e, DbIdentAid,
        encodeValue(name, emVariable, 0), t, false, emVariable, true))
      eng.batchWrite(buildEavtEntries(e, DbValueTypeAid,
        encodeValue($valueType, emFixed, 0), t, false, emFixed, true))
      let cardId = if many: DbCardinalityManyAid else: DbCardinalityOneAid
      eng.batchWrite(buildEavtEntries(e, DbCardinalityAid,
        encodeValue($cardId, emFixed, 0), t, false, emFixed, true))
      if unique:
        eng.batchWrite(buildEavtEntries(e, DbUniqueAid,
          encodeValue($DbUniqueIdentityAid, emFixed, 0), t, false, emFixed, true))
    return (aid, isNew)

# ── Resolver accessors ──

proc lookupAttr*(eng: EavtEngine; name: string): Option[uint32] =
  eng.lock.withLock: return eng.resolver.lookupAttr(name)

proc attrName*(eng: EavtEngine; aid: uint32): string =
  eng.lock.withLock: return eng.resolver.attrName(aid)

proc allocateEntityId*(eng: EavtEngine): uint64 =
  eng.lock.withLock: return eng.resolver.allocateEntityId()

proc isDeclared*(eng: EavtEngine; aid: uint32): bool =
  eng.lock.withLock: return eng.resolver.isDeclared(aid)

proc isMany*(eng: EavtEngine; aid: uint32): bool =
  eng.lock.withLock: return eng.resolver.isMany(aid)

proc isUnique*(eng: EavtEngine; aid: uint32): bool =
  eng.lock.withLock: return eng.resolver.isUnique(aid)

proc valueTypeFor*(eng: EavtEngine; aid: uint32): Option[uint32] =
  eng.lock.withLock: return eng.resolver.valueTypeFor(aid)

proc allocateInPartition*(eng: EavtEngine; pid: uint64): uint64 =
  eng.lock.withLock: return eng.resolver.allocateInPartition(pid)

proc declarePartition*(eng: EavtEngine; name: string): uint64 =
  eng.lock.withLock: return eng.resolver.declarePartition(name)

proc partitionIdFor*(eng: EavtEngine; name: string): Option[uint64] =
  eng.lock.withLock: return eng.resolver.partitionIdFor(name)

proc defaultUserPartition*(eng: EavtEngine): uint64 =
  PartUser
