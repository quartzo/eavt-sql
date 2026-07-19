## pynim_kvstore.nim — nimpy bridge: KVStore + Resolver for Python.
##
## Exposes all low-level EAVT/KVStore operations via nimpy.
## Import in Python: `import pynim_kvstore`
##
## Build:
##   nim c --mm:arc --threads:on -d:release --noNimblePath \
##     --path:nim-page-store --path:<nimpy_dir> \
##     --app:lib -o:pynim_kvstore.so nim-page-store/pynim_kvstore.nim

import nimpy
import std/[options, strutils, strformat]

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all

import resolver
import transactor
import abi

# ═══════════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════════

proc getPartUser*(): uint64 {.exportpy.} = PartUser
proc getPartDb*(): uint64 {.exportpy.} = PartDb
proc getPartTx*(): uint64 {.exportpy.} = PartTx
proc getU64Max*(): uint64 {.exportpy.} = 0xFFFFFFFFFFFFFFFF'u64
proc getBootstrapFirstUserId*(): uint64 {.exportpy.} = BootstrapFirstUserId

# ═══════════════════════════════════════════════════════════════════════════════
# Resolver — standalone (no KVStore needed)
# ═══════════════════════════════════════════════════════════════════════════════

type
  PyResolver = ref object
    inner: Resolver

proc newResolver(): PyResolver {.exportpy.} =
  PyResolver(inner: resolver.newResolver())

proc lookupAttr(r: PyResolver; name: string): Option[uint32] {.exportpy.} =
  r.inner.lookupAttr(name)

proc internAttr(r: PyResolver; name: string): uint32 {.exportpy.} =
  r.inner.internAttr(name)

proc declareAttr(r: PyResolver; name: string; valueType: uint32; many: bool): tuple[aid: uint32, isNew: bool] {.exportpy.} =
  r.inner.declareAttr(name, valueType, many)

proc attrName(r: PyResolver; aid: uint32): string {.exportpy.} =
  r.inner.attrName(aid)

proc valueTypeFor(r: PyResolver; aid: uint32): Option[uint32] {.exportpy.} =
  r.inner.valueTypeFor(aid)

proc isDeclared(r: PyResolver; aid: uint32): bool {.exportpy.} =
  r.inner.isDeclared(aid)

proc allocateEntityId(r: PyResolver): uint64 {.exportpy.} =
  r.inner.allocateEntityId()

proc allocateInPartition(r: PyResolver; partitionId: uint64): uint64 {.exportpy.} =
  r.inner.allocateInPartition(partitionId)

proc allocateSchemaId(r: PyResolver): uint64 {.exportpy.} =
  r.inner.allocateSchemaId()

proc partitionIdFor(r: PyResolver; name: string): Option[uint64] {.exportpy.} =
  r.inner.partitionIdFor(name)

proc declarePartition(r: PyResolver; name: string): uint64 {.exportpy.} =
  r.inner.declarePartition(name)

proc isMany(r: PyResolver; aid: uint32): bool {.exportpy.} =
  r.inner.isMany(aid)

proc isUnique(r: PyResolver; aid: uint32): bool {.exportpy.} =
  r.inner.isUnique(aid)

proc setCardinality(r: PyResolver; aid: uint32; many: bool) {.exportpy.} =
  r.inner.setCardinality(aid, many)

# Entity ID helpers
proc makeEntityId(partitionId: uint64; seq: uint64): uint64 {.exportpy.} =
  resolver.makeEntityId(partitionId, seq)

proc partitionOf(eid: uint64): uint64 {.exportpy.} =
  resolver.partitionOf(eid)

proc seqOf(eid: uint64): uint64 {.exportpy.} =
  resolver.seqOf(eid)

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore engine — wraps NimKVStore (transactor)
# ═══════════════════════════════════════════════════════════════════════════════

type
  PyEngine = ref object
    vt: NimKVStoreVtablePtr
    handle: pointer

proc newEngine(config: openArray[(string, string)]): PyEngine {.exportpy.} =
  # Convert Python dict items to CStringArr
  let n = config.len
  var keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  for i, (k, v) in config:
    keys[i] = k.cstring
    vals[i] = v.cstring
  var err: cint
  let vt = openKvStore(keys, vals, n.cint, addr err)
  deallocShared(keys)
  deallocShared(vals)
  if vt == nil:
    raise newException(ValueError, "failed to open kvstore: err=" & $err)
  PyEngine(vt: vt, handle: vt.handle)

proc close(e: PyEngine) {.exportpy.} =
  if e.vt != nil:
    var err: cint
    discard e.vt.close(e.handle, addr err)
    freeKVVtable(e.vt)
    e.vt = nil

proc put(e: PyEngine; cf: uint32; key: seq[byte]) {.exportpy.} =
  var err: cint
  let rc = e.vt.put(e.handle, cf, addr key[0], key.len.csize_t, addr err)
  if rc != 0:
    raise newException(ValueError, "put failed: err=" & $err)

proc get(e: PyEngine; cf: uint32; key: seq[byte]): bool {.exportpy.} =
  var present: cint = 0
  var err: cint
  discard e.vt.get(e.handle, cf, addr key[0], key.len.csize_t, addr present, addr err)
  return present != 0

proc scan(e: PyEngine; cf: uint32; prefix: seq[byte]): seq[seq[byte]] {.exportpy.} =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var err: cint
  let pf = if prefix.len > 0: addr prefix[0] else: nil
  let rc = e.vt.scan(e.handle, cf, pf, prefix.len.csize_t, addr outBuf, addr outLen, addr err)
  if rc != 0: return @[]
  result = @[]
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
  if outBuf != nil: e.vt.freeBuf(outBuf)

proc flush(e: PyEngine) {.exportpy.} =
  var err: cint
  discard e.vt.flush(e.handle, addr err)

proc memtableSize(e: PyEngine): uint64 {.exportpy.} =
  var outSize: uint64 = 0
  var err: cint
  discard e.vt.memtableSize(e.handle, addr outSize, addr err)
  return outSize

proc gcFull(e: PyEngine; maxAgeSecs: uint64; maxRootCount: uint32; dryRun: bool): seq[byte] {.exportpy.} =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var err: cint
  discard e.vt.gcFull(e.handle, maxAgeSecs, maxRootCount.cuint,
                        (if dryRun: 1 else: 0).cint, addr outBuf, addr outLen, addr err)
  if outBuf != nil:
    result = newSeq[byte](outLen.int)
    copyMem(addr result[0], outBuf, outLen.int)
    e.vt.freeBuf(outBuf)

proc batchWrite(e: PyEngine; ops: seq[byte]) {.exportpy.} =
  var err: cint
  discard e.vt.batchWrite(e.handle, addr ops[0], ops.len.csize_t, addr err)
