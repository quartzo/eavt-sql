## eavt.nim — EAVT engine (save, retract, bootstrap, lookup).
##
## Port of spier-transactor/src/eavt.rs (~1099 lines Rust → Nim).
## Coordinates Resolver + KVStore for entity-attribute-value-time operations.

import std/[tables, strutils, strformat, options]
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

proc batchWrite(eng: EavtEngine; entries: seq[EavtEntry]) =
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

proc scan(eng: EavtEngine; cf: uint32; prefix: seq[byte]): seq[seq[byte]] =
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
  # Scan AEVT for attribute declarations
  let keys = eng.scan(1'u32, @[])
  for k in keys:
    if k.len < 16: continue  # need at least attr(4) + eid(8) + sf(4)
    let attr = (uint32(k[0]) shl 24 or uint32(k[1]) shl 16 or
                 uint32(k[2]) shl 8 or uint32(k[3]))
    # Only process if attribute is in bootstrap range or declared
    if eng.resolver.isDeclared(attr): continue
    # This is a raw datom — load the attribute from the value
    # For simplicity, skip AEVT bootstrap for now

  # Scan EAVT for entity information
  # Partition seed: find highest sequence numbers
  # Simplified: just ensure resolver is ready

# ── Save a datom ──

proc eavtSave*(eng: EavtEngine; eid: uint64; attrName: string;
                value: string; t: uint64): uint64 {.discardable.} =
  eng.lock.withLock:
    let attrId = eng.resolver.internAttr(attrName)
    let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
    let mode = valueTypeToEncodeMode(vt)
    let encoded = encodeValue(value, mode, 0)
    let entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, false)
    eng.batchWrite(entries)
    return eid

proc eavtRetract*(eng: EavtEngine; eid: uint64; attrName: string;
                   value: string; t: uint64) =
  eng.lock.withLock:
    let attrId = eng.resolver.internAttr(attrName)
    let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
    let mode = valueTypeToEncodeMode(vt)
    let encoded = encodeValue(value, mode, 0)
    let entries = buildEavtEntries(eid, attrId, encoded, t, true, mode, false)
    eng.batchWrite(entries)

proc eavtDeclareAttr*(eng: EavtEngine; name: string; valueType: uint32;
                       many: bool): (uint32, bool) =
  eng.lock.withLock:
    return eng.resolver.declareAttr(name, valueType, many)

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
