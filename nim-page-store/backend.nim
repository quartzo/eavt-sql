## backend.nim — COW B-tree page store on top of Nim blobstore.
##
## Port of spier-kvstore/src/generic_page_store.rs (~1800 lines → ~900 lines Nim).

import std/[tables, sets, hashes, strformat, strutils, times, monotimes, sysrand, random, options]
import ./abi
import ./pages
import ./spinlock

# ── seq[byte] comparison helpers ──

proc cmpSeq(a, b: seq[byte]): int =
  let n = min(a.len, b.len)
  for i in 0..<n:
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  return 0

# Use cmpSeq directly — never overload < for seq[byte] globally.
# Overloading < interferes with Nim's runtime Table operations.

# ══════════════════════════════════════════════════════════════════════════════
# BlobStore extern symbols (compiled in libnim_blobstore_*.a)
# ══════════════════════════════════════════════════════════════════════════════

proc nim_blob_memory_open*(keys, vals: CStringArr; count: cint;
                           errOut: ptr cint): NimBlobVtablePtr
    {.importc: "nim_blob_memory_open", cdecl.}

proc nim_blob_file_open*(keys, vals: CStringArr; count: cint;
                         errOut: ptr cint): NimBlobVtablePtr
    {.importc: "nim_blob_file_open", cdecl.}

proc nim_blob_s3_open*(keys, vals: CStringArr; count: cint;
                       errOut: ptr cint): NimBlobVtablePtr
    {.importc: "nim_blob_s3_open", cdecl.}

proc nim_blob_memory_close*(vt: NimBlobVtablePtr)
    {.importc: "nim_blob_memory_close", cdecl.}

proc nim_blob_file_close*(vt: NimBlobVtablePtr)
    {.importc: "nim_blob_file_close", cdecl.}

proc nim_blob_s3_close*(vt: NimBlobVtablePtr)
    {.importc: "nim_blob_s3_close", cdecl.}

# Journal extern symbols
proc nim_journal_open*(keys, vals: CStringArr; count: cint;
                       errOut: ptr cint): NimJournalVtablePtr
    {.importc: "nim_journal_open", cdecl.}

proc nim_journal_close*(vt: NimJournalVtablePtr)
    {.importc: "nim_journal_close", cdecl.}

# ══════════════════════════════════════════════════════════════════════════════
# zstd FFI (libzstd)
# ══════════════════════════════════════════════════════════════════════════════

proc ZSTD_compress*(dst: pointer; dstCapacity: csize_t;
                     src: pointer; srcSize: csize_t;
                     compressionLevel: cint): csize_t
    {.importc: "ZSTD_compress", cdecl.}

proc ZSTD_decompress*(dst: pointer; dstCapacity: csize_t;
                       src: pointer; srcSize: csize_t): csize_t
    {.importc: "ZSTD_decompress", cdecl.}

proc ZSTD_compressBound*(srcSize: csize_t): csize_t
    {.importc: "ZSTD_compressBound", cdecl.}

proc ZSTD_isError*(code: csize_t): cuint
    {.importc: "ZSTD_isError", cdecl.}

proc compress(data: openArray[byte]): seq[byte] =
  let bound = ZSTD_compressBound(data.len.csize_t).int
  result = newSeq[byte](bound)
  let rc = ZSTD_compress(addr result[0], result.len.csize_t,
                          unsafeAddr data[0], data.len.csize_t, 1.cint)
  if ZSTD_isError(rc) != 0:
    raise newException(IOError, "zstd compress failed")
  result.setLen(rc.int)

proc decompress(data: openArray[byte]): seq[byte] =
  const ZstdMagic = [0x28'u8, 0xB5'u8, 0x2F'u8, 0xFD'u8]
  if data.len < 4 or data[0..3] != ZstdMagic:
    return @data

  let frameSize = ZSTD_compressBound(data.len.csize_t).int * 4
  result = newSeq[byte](max(frameSize, 262144))
  let rc = ZSTD_decompress(addr result[0], result.len.csize_t,
                            unsafeAddr data[0], data.len.csize_t)
  if ZSTD_isError(rc) != 0:
    raise newException(IOError, "zstd decompress failed")
  result.setLen(rc.int)

# ══════════════════════════════════════════════════════════════════════════════
# Constants
# ══════════════════════════════════════════════════════════════════════════════

const
  RootMagic = [0x45'u8, 0x56'u8, 0x54'u8, 0x31'u8]  # "EVT1"
  RootVersion = 2'u16
  IndexPageMaxSize = 256 * 1024

# ══════════════════════════════════════════════════════════════════════════════
# UUID helpers
# ══════════════════════════════════════════════════════════════════════════════

proc newUuidBytes(): array[16, byte] =
  proc random(dest: var array[16, byte]) =
    for i in 0..15: dest[i] = byte(rand(255))
  random(result)
  result[6] = (result[6] and 0x0F) or 0x40
  result[8] = (result[8] and 0x3F) or 0x80

proc fmtUuid(uuid: array[16, byte]): string =
  result = &"{uuid[0]:02x}{uuid[1]:02x}{uuid[2]:02x}{uuid[3]:02x}-"
  result.add &"{uuid[4]:02x}{uuid[5]:02x}-{uuid[6]:02x}{uuid[7]:02x}-"
  result.add &"{uuid[8]:02x}{uuid[9]:02x}-"
  for i in 10..15: result.add &"{uuid[i]:02x}"

proc fmtHex(data: openArray[byte]; maxLen: int): string =
  let n = min(data.len, maxLen)
  result = newStringOfCap(n * 2)
  for i in 0..<n: result.add &"{data[i]:02x}"
  if data.len > maxLen: result.add ".."

# ══════════════════════════════════════════════════════════════════════════════
# Root blob serialization
# ══════════════════════════════════════════════════════════════════════════════

type
  CfTree = object
    rootUuid: array[16, byte]
    height: uint8
    numLeaves: uint32

proc serializeRoot(trees: seq[CfTree]): seq[byte] =
  result = newSeqOfCap[byte](8 + trees.len * 21)
  result.add RootMagic
  result.add byte(RootVersion shr 8)
  result.add byte(RootVersion and 0xFF)
  let nc = trees.len.uint16
  result.add byte(nc shr 8)
  result.add byte(nc and 0xFF)
  for tree in trees:
    result.add tree.rootUuid
    result.add tree.height
    let nl = tree.numLeaves
    result.add byte(nl shr 24)
    result.add byte((nl shr 16) and 0xFF)
    result.add byte((nl shr 8) and 0xFF)
    result.add byte(nl and 0xFF)

proc deserializeRoot(data: openArray[byte]): seq[CfTree] =
  if data.len < 8 or data[0..3] != RootMagic:
    raise newException(ValueError, "invalid root magic")
  let version = uint16(data[4]) shl 8 or uint16(data[5])
  if version != RootVersion:
    raise newException(ValueError, &"unsupported root version {version}")
  let numCf = (uint16(data[6]) shl 8 or uint16(data[7])).int
  if data.len < 8 + numCf * 21:
    raise newException(ValueError, "truncated root")
  result = newSeqOfCap[CfTree](numCf)
  var off = 8
  for _ in 0..<numCf:
    var uuid: array[16, byte]
    for j in 0..15: uuid[j] = data[off + j]
    off += 16
    let height = data[off]; off += 1
    let nl = (uint32(data[off]) shl 24 or uint32(data[off+1]) shl 16 or
              uint32(data[off+2]) shl 8 or uint32(data[off+3]))
    off += 4
    result.add CfTree(rootUuid: uuid, height: height, numLeaves: nl)

proc emptyTree(): CfTree =
  CfTree(rootUuid: default(array[16, byte]), height: 0, numLeaves: 0)

# ══════════════════════════════════════════════════════════════════════════════
# Index page serialization (prefix-compressed varint, same as leaf pages)
# ══════════════════════════════════════════════════════════════════════════════

proc serializeIndexPage(entries: seq[(seq[byte], array[16, byte])]): seq[byte] =
  result = newSeqOfCap[byte](entries.len * 40)
  let count = entries.len.uint16
  result.add byte(count shr 8)
  result.add byte(count and 0xFF)
  var prev: seq[byte] = @[]
  for (key, uuid) in entries:
    let plen = commonPrefixLen(prev, key)
    let suffix = key[plen .. ^1]
    writeVarint(result, plen)
    writeVarint(result, suffix.len)
    result.add suffix
    result.add uuid
    prev = key

proc deserializeIndexPage(data: openArray[byte]): seq[(seq[byte], array[16, byte])] =
  if data.len < 2:
    raise newException(ValueError, "index page too short")
  let count = (uint16(data[0]) shl 8 or uint16(data[1])).int
  result = newSeqOfCap[(seq[byte], array[16, byte])](count)
  var offset = 2
  var prev: seq[byte] = @[]
  for _ in 0..<count:
    let (plenRaw, next1) = readVarint(data, offset); offset = next1
    let (slen, next2) = readVarint(data, offset); offset = next2
    if offset + slen + 16 > data.len:
      raise newException(ValueError, "truncated index entry")
    let plen = min(plenRaw, prev.len)
    var key = newSeqOfCap[byte](plen + slen)
    key.add prev[0..<plen]
    key.add data[offset..<offset+slen]
    offset += slen
    var uuid: array[16, byte]
    for j in 0..15: uuid[j] = data[offset + j]
    offset += 16
    prev = key
    result.add (key, uuid)

# ══════════════════════════════════════════════════════════════════════════════
# Root name helpers
# ══════════════════════════════════════════════════════════════════════════════

proc makeRootName(): string =
  let ts = getMonoTime().ticks
  let neg = (not ts) + 1
  &"root_{neg:016x}"

proc parseRootUs(name: string): int64 =
  if not name.startsWith("root_"): return 0
  try:
    let bits = parseHexInt(name[5..^1])
    let neg = cast[int64](bits)
    return -neg
  except:
    return 0

# ══════════════════════════════════════════════════════════════════════════════
# Binary search helpers
# ══════════════════════════════════════════════════════════════════════════════

proc partitionPoint[T](s: openArray[T]; pred: proc(x: T): bool): int =
  var lo = 0; var hi = s.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if pred(s[mid]): lo = mid + 1
    else: hi = mid
  return lo

proc prefixEnd(prefix: seq[byte]): Option[seq[byte]] =
  var e = @prefix
  while e.len > 0:
    let last = e[^1]
    if last < 0xFF:
      e[^1] = last + 1
      return some(e)
    e.setLen(e.len - 1)
  return none(seq[byte])

proc findPrefixRange(entries: seq[(seq[byte], array[16, byte])];
                      prefix: seq[byte]): (int, int) =
  if prefix.len == 0: return (0, entries.len)
  let pe = prefixEnd(prefix)
  let s = partitionPoint(entries, proc(x: auto): bool = cmpSeq(x[0], prefix) < 0)
  let startIdx = if s > 0: s - 1 else: 0
  let endIdx = if pe.isSome:
    partitionPoint(entries, proc(x: auto): bool = cmpSeq(x[0], pe.get) < 0)
  else:
    entries.len
  (min(startIdx, endIdx), endIdx)

# ══════════════════════════════════════════════════════════════════════════════
# PageCache — simple LRU via access-order counter
# ══════════════════════════════════════════════════════════════════════════════

type
  CacheEntry = object
    keys: seq[seq[byte]]
    accessOrder: int64

  PageCache = object
    map: Table[array[16, byte], CacheEntry]
    maxBytes: int
    currentBytes: int
    nextOrder: int64
    lock: SpinLock

proc keysSize(keys: seq[seq[byte]]): int =
  for k in keys: result += k.len + 8

proc initCache(maxBytes: int): PageCache =
  result = PageCache(maxBytes: maxBytes, currentBytes: 0, nextOrder: 1)
  initSpinLock(result.lock)

proc get(cc: var PageCache; uuid: array[16, byte]): Option[seq[seq[byte]]] =
  cc.lock.withLock:
    if uuid in cc.map:
      cc.map[uuid].accessOrder = cc.nextOrder
      inc cc.nextOrder
      return some(cc.map[uuid].keys)
    return none(seq[seq[byte]])

proc put(cc: var PageCache; uuid: array[16, byte]; keys: seq[seq[byte]]) =
  cc.lock.withLock:
    if uuid in cc.map: return
    let sz = keysSize(keys)
    while cc.currentBytes + sz > cc.maxBytes and cc.map.len > 0:
      var minKey: array[16, byte]
      var minOrder = high(int64)
      for k, v in cc.map:
        if v.accessOrder < minOrder:
          minOrder = v.accessOrder
          minKey = k
      cc.currentBytes -= keysSize(cc.map[minKey].keys)
      cc.map.del(minKey)
    if sz <= cc.maxBytes:
      cc.currentBytes += sz
      cc.map[uuid] = CacheEntry(keys: keys, accessOrder: cc.nextOrder)
      inc cc.nextOrder

# ══════════════════════════════════════════════════════════════════════════════
# PageStoreInner — the B-tree engine state
# ══════════════════════════════════════════════════════════════════════════════

type
  PageStoreInner = object
    blobs: NimBlobVtablePtr
    journal: NimJournalVtablePtr
    trees: seq[CfTree]
    numCf: int
    readOnly: bool
    currentRoot: string
    cache: PageCache
    lock: SpinLock
    backendType: string


# ══════════════════════════════════════════════════════════════════════════════
# BlobStore / Journal wrappers
# ══════════════════════════════════════════════════════════════════════════════

proc blobPut(blobs: NimBlobVtablePtr; data: openArray[byte]): array[16, byte] =
  let compressed = compress(data)
  var idOut: array[16, byte]
  var err: cint
  let rc = blobs.put(blobs.handle, cast[ptr Byte](unsafeAddr compressed[0]),
                      compressed.len.csize_t, cast[ptr Byte](addr idOut), addr err)
  if rc != 0:
    raise newException(IOError, &"blob put failed: err={err}")
  return idOut

proc blobGet(blobs: NimBlobVtablePtr; id: array[16, byte]): Option[seq[byte]] =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var present: cint = 0
  var err: cint
  let rc = blobs.get(blobs.handle, cast[ptr Byte](unsafeAddr id),
                      addr outBuf, addr outLen, addr present, addr err)
  if rc != 0:
    raise newException(IOError, &"blob get failed: err={err}")
  if present == 0: return none(seq[byte])
  let raw = newSeq[byte](outLen.int)
  copyMem(unsafeAddr raw[0], outBuf, outLen.int)
  blobs.freeBuf(outBuf)
  return some(decompress(raw))

proc blobPutRoot(blobs: NimBlobVtablePtr; name: string; data: openArray[byte]) =
  let compressed = compress(data)
  var err: cint
  let rc = blobs.putRoot(blobs.handle, name.cstring,
                          cast[ptr Byte](unsafeAddr compressed[0]),
                          compressed.len.csize_t, addr err)
  if rc != 0:
    raise newException(IOError, &"blob put_root failed: err={err}")

proc blobGetRoot(blobs: NimBlobVtablePtr; name: string): Option[seq[byte]] =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var present: cint = 0
  var err: cint
  let rc = blobs.getRoot(blobs.handle, name.cstring,
                          addr outBuf, addr outLen, addr present, addr err)
  if rc != 0:
    raise newException(IOError, &"blob get_root failed: err={err}")
  if present == 0: return none(seq[byte])
  let raw = newSeq[byte](outLen.int)
  copyMem(unsafeAddr raw[0], outBuf, outLen.int)
  blobs.freeBuf(outBuf)
  return some(decompress(raw))

proc blobListRoots(blobs: NimBlobVtablePtr): seq[string] =
  var outArr: pointer = nil
  var outCount: csize_t = 0
  var err: cint
  let rc = blobs.listRoots(blobs.handle, addr outArr, addr outCount, addr err)
  if rc != 0: return @[]
  let carr = cast[CStringArr](outArr)
  for i in 0..<outCount.int:
    result.add $carr[i]
  blobs.freeStrs(carr, outCount)

proc blobList(blobs: NimBlobVtablePtr): seq[array[16, byte]] =
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var err: cint
  let rc = blobs.list(blobs.handle, addr outBuf, addr outLen, addr err)
  if rc != 0: return @[]
  let data = cast[ptr UncheckedArray[byte]](outBuf)
  var pos = 0
  while pos + 16 <= outLen.int:
    var id: array[16, byte]
    for j in 0..15: id[j] = data[pos + j]
    pos += 16
    result.add id
  blobs.freeBuf(outBuf)

proc journalAppend(s: var PageStoreInner; key, val: openArray[byte]) =
  if s.journal == nil: return
  var err: cint
  discard s.journal.append(s.journal.handle,
    cast[ptr Byte](unsafeAddr key[0]), key.len.csize_t,
    cast[ptr Byte](unsafeAddr val[0]), val.len.csize_t, addr err)

proc journalRead(s: var PageStoreInner): seq[byte] =
  if s.journal == nil: return @[]
  var outBuf: pointer = nil
  var outLen: csize_t = 0
  var err: cint
  let rc = s.journal.read(s.journal.handle, addr outBuf, addr outLen, addr err)
  if rc != 0: return @[]
  result = newSeq[byte](outLen.int)
  copyMem(unsafeAddr result[0], outBuf, outLen.int)
  s.journal.freeBuf(outBuf)

proc journalSize(s: var PageStoreInner): uint64 =
  if s.journal == nil: return 0
  var outSize: uint64 = 0
  var err: cint
  discard s.journal.size(s.journal.handle, addr outSize, addr err)
  return outSize

proc journalTruncate(s: var PageStoreInner) =
  if s.journal == nil: return
  var err: cint
  discard s.journal.truncate(s.journal.handle, addr err)

# ══════════════════════════════════════════════════════════════════════════════
# B-tree operations
# ══════════════════════════════════════════════════════════════════════════════

proc loadLeafKeys(s: var PageStoreInner; uuid: array[16, byte]): seq[seq[byte]] =
  let cached = s.cache.get(uuid)
  if cached.isSome: return cached.get
  let data = blobGet(s.blobs, uuid)
  if data.isNone:
    raise newException(IOError, "leaf blob not found")
  result = deserializePage(data.get)
  s.cache.put(uuid, result)

proc loadLeafKeysNoput(s: var PageStoreInner; uuid: array[16, byte]): seq[seq[byte]] =
  let cached = s.cache.get(uuid)
  if cached.isSome: return cached.get
  let data = blobGet(s.blobs, uuid)
  if data.isNone:
    raise newException(IOError, "leaf blob not found")
  return deserializePage(data.get)

proc loadRootEntries(s: var PageStoreInner; tree: CfTree): seq[(seq[byte], array[16, byte])] =
  if tree.rootUuid == default(array[16, byte]) or tree.height == 0:
    return @[]
  let data = blobGet(s.blobs, tree.rootUuid)
  if data.isNone: return @[]
  return deserializeIndexPage(data.get)

proc collectKeysFromIndex(s: var PageStoreInner; pageUuid: array[16, byte];
                           height: uint8; prefix: seq[byte]): seq[seq[byte]] =
  let data = blobGet(s.blobs, pageUuid)
  if data.isNone: return @[]
  let entries = deserializeIndexPage(data.get)
  let (start, endIdx) = findPrefixRange(entries, prefix)
  for i in start..<endIdx:
    let (_, childUuid) = entries[i]
    if height == 1:
      let keys = loadLeafKeys(s, childUuid)
      for k in keys:
        if k.len >= prefix.len and k[0..<prefix.len] == prefix:
          result.add k
    else:
      result.add collectKeysFromIndex(s, childUuid, height - 1, prefix)

proc getKeysInPrefix(s: var PageStoreInner; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  if cf >= s.numCf: return @[]
  let tree = s.trees[cf]
  if tree.rootUuid == default(array[16, byte]): return @[]
  if tree.height == 0:
    let keys = loadLeafKeys(s, tree.rootUuid)
    for k in keys:
      if k.len >= prefix.len and k[0..<prefix.len] == prefix:
        result.add k
  else:
    result = collectKeysFromIndex(s, tree.rootUuid, tree.height, prefix)

proc keyExists(s: var PageStoreInner; cf: int; key: seq[byte]): bool =
  let keys = getKeysInPrefix(s, cf, key)
  for k in keys:
    if k == key: return true
  return false

# ══════════════════════════════════════════════════════════════════════════════
# COW recursive merge
# ══════════════════════════════════════════════════════════════════════════════

proc splitIndexEntries(s: var PageStoreInner;
                        entries: openArray[(seq[byte], array[16, byte])]): seq[seq[byte]] =
  if entries.len == 0: return @[]
  let total = serializeIndexPage(@entries)
  if total.len <= IndexPageMaxSize or entries.len == 1:
    return @[serializeIndexPage(@entries)]
  let mid = entries.len div 2
  result = splitIndexEntries(s, entries[0..<mid])
  result.add splitIndexEntries(s, entries[mid..^1])

proc writeIndexLevel(s: var PageStoreInner;
                      entries: openArray[(seq[byte], array[16, byte])]): seq[(seq[byte], array[16, byte])] =
  let ser = serializeIndexPage(@entries)
  if ser.len <= IndexPageMaxSize or entries.len <= 1:
    let uuid = blobPut(s.blobs, ser)
    return @[(entries[0][0], uuid)]
  let pages = splitIndexEntries(s, entries)
  for pageData in pages:
    let pageEntries = deserializeIndexPage(pageData)
    if pageEntries.len > 0:
      let uuid = blobPut(s.blobs, pageData)
      result.add (pageEntries[0][0], uuid)

proc buildIndexTree(s: var PageStoreInner;
                     entries: seq[(seq[byte], array[16, byte])];
                     childHeight: uint8): (array[16, byte], uint8) =
  if entries.len == 0: return (default(array[16, byte]), 0'u8)
  let ser = serializeIndexPage(entries)
  if ser.len <= IndexPageMaxSize:
    let uuid = blobPut(s.blobs, ser)
    return (uuid, childHeight + 1)
  let pages = splitIndexEntries(s, entries)
  if pages.len == 1:
    let uuid = blobPut(s.blobs, pages[0])
    return (uuid, childHeight + 1)
  var levelEntries: seq[(seq[byte], array[16, byte])] = @[]
  for pageData in pages:
    let pageEntries = deserializeIndexPage(pageData)
    if pageEntries.len > 0:
      let uuid = blobPut(s.blobs, pageData)
      levelEntries.add (pageEntries[0][0], uuid)
  var height = childHeight + 2
  while true:
    let ser2 = serializeIndexPage(levelEntries)
    if ser2.len <= IndexPageMaxSize:
      let uuid = blobPut(s.blobs, ser2)
      return (uuid, height)
    let pages2 = splitIndexEntries(s, levelEntries)
    if pages2.len == levelEntries.len:
      let uuid = blobPut(s.blobs, ser2)
      return (uuid, height)
    var nextLevel: seq[(seq[byte], array[16, byte])] = @[]
    for pageData in pages2:
      let pageEntries = deserializeIndexPage(pageData)
      if pageEntries.len > 0:
        let uuid = blobPut(s.blobs, pageData)
        nextLevel.add (pageEntries[0][0], uuid)
    levelEntries = nextLevel
    inc height

proc countSubtreeLeaves(s: var PageStoreInner; uuid: array[16, byte];
                         height: uint8): uint32 =
  if height == 0: return 1
  let data = blobGet(s.blobs, uuid)
  if data.isNone: return 0
  let entries = deserializeIndexPage(data.get)
  for (_, childUuid) in entries:
    result += countSubtreeLeaves(s, childUuid, height - 1)

proc mergeLeaf(s: var PageStoreInner; leafUuid: array[16, byte];
                rangeEnd: Option[seq[byte]];
                newKeys: var seq[seq[byte]]; idx: var int): Option[seq[(seq[byte], array[16, byte])]] =
  let existing = loadLeafKeysNoput(s, leafUuid)
  var toMerge: seq[seq[byte]] = @[]
  while idx < newKeys.len:
    if rangeEnd.isSome and cmpSeq(newKeys[idx], rangeEnd.get) >= 0:
      break
    toMerge.add newKeys[idx]
    inc idx
  if toMerge.len == 0: return none(seq[(seq[byte], array[16, byte])])
  var merged: seq[seq[byte]]
  var ei, mi = 0
  while ei < existing.len or mi < toMerge.len:
    if ei >= existing.len:
      merged.add toMerge[mi]; inc mi
    elif mi >= toMerge.len:
      merged.add existing[ei]; inc ei
    elif cmpSeq(existing[ei], toMerge[mi]) < 0:
      merged.add existing[ei]; inc ei
    elif cmpSeq(toMerge[mi], existing[ei]) < 0:
      merged.add toMerge[mi]; inc mi
    else:
      merged.add existing[ei]; inc ei; inc mi
  let pageList = buildPages(merged)
  var entries: seq[(seq[byte], array[16, byte])] = @[]
  for (boundary, pageData) in pageList:
    discard deserializePage(pageData)  # round-trip validation
    let uuid = blobPut(s.blobs, pageData)
    entries.add (boundary, uuid)
  return some(entries)

proc mergeSubtree(s: var PageStoreInner; nodeUuid: array[16, byte];
                   height: uint8; rangeEnd: Option[seq[byte]];
                   newKeys: var seq[seq[byte]]; idx: var int): Option[seq[(seq[byte], array[16, byte])]] =
  if height == 0:
    return mergeLeaf(s, nodeUuid, rangeEnd, newKeys, idx)
  let data = blobGet(s.blobs, nodeUuid)
  if data.isNone: return none(seq[(seq[byte], array[16, byte])])
  let entries = deserializeIndexPage(data.get)
  var newEntries: seq[(seq[byte], array[16, byte])] = @[]
  var changed = false
  for i, (boundary, childUuid) in entries:
    let childEnd = if i + 1 < entries.len: some(entries[i+1][0]) else: rangeEnd
    let hasKeys = idx < newKeys.len and
                  (if childEnd.isSome: cmpSeq(newKeys[idx], childEnd.get) < 0 else: true)
    if not hasKeys:
      newEntries.add (boundary, childUuid)
      continue
    let childResult = mergeSubtree(s, childUuid, height - 1, childEnd, newKeys, idx)
    if childResult.isNone:
      newEntries.add (boundary, childUuid)
    else:
      changed = true
      newEntries.add childResult.get
  if not changed: return none(seq[(seq[byte], array[16, byte])])
  return some(writeIndexLevel(s, newEntries))

proc commitMerge(s: var PageStoreInner; keysByCf: seq[(int, seq[seq[byte]])];
                  clearJournal: bool) =
  if s.readOnly:
    raise newException(IOError, "read-only")
  for (cf, sortedKeysIn) in keysByCf:
    if cf >= s.numCf or sortedKeysIn.len == 0: continue
    var sortedKeys = sortedKeysIn
    let tree = s.trees[cf]
    var idx = 0
    s.trees[cf] =
      if tree.rootUuid == default(array[16, byte]):
        let pageList = buildPages(sortedKeys)
        var entries: seq[(seq[byte], array[16, byte])] = @[]
        for (boundary, pageData) in pageList:
          discard deserializePage(pageData)
          let uuid = blobPut(s.blobs, pageData)
          entries.add (boundary, uuid)
        let numLeaves = entries.len.uint32
        var (root, height) = buildIndexTree(s, entries, 0)
        if height == 0:
          CfTree(rootUuid: root, height: height, numLeaves: 0)
        else:
          CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
      else:
        let result = mergeSubtree(s, tree.rootUuid, tree.height,
                                   none(seq[byte]), sortedKeys, idx)
        if result.isNone:
          tree
        elif result.get.len == 1:
          let newUuid = result.get[0][1]
          let numLeaves = if tree.height == 0: 1'u32
                          else: countSubtreeLeaves(s, newUuid, tree.height)
          CfTree(rootUuid: newUuid, height: tree.height, numLeaves: numLeaves)
        else:
          var (root, height) = buildIndexTree(s, result.get, tree.height)
          let numLeaves = countSubtreeLeaves(s, root, height)
          CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
  let newRoot = makeRootName()
  blobPutRoot(s.blobs, newRoot, serializeRoot(s.trees))
  s.currentRoot = newRoot
  if clearJournal:
    journalTruncate(s)

# ══════════════════════════════════════════════════════════════════════════════
# GC
# ══════════════════════════════════════════════════════════════════════════════

proc collectTreeUuids(s: var PageStoreInner; tree: CfTree;
                       live: var HashSet[array[16, byte]]) =
  if tree.rootUuid == default(array[16, byte]): return
  live.incl tree.rootUuid
  if tree.height == 0: return
  let data = blobGet(s.blobs, tree.rootUuid)
  if data.isNone: return
  let entries = deserializeIndexPage(data.get)
  for (_, childUuid) in entries:
    live.incl childUuid
    if tree.height > 1:
      collectTreeUuids(s, CfTree(rootUuid: childUuid, height: tree.height - 1,
                                  numLeaves: 0), live)

proc hasOldRoots(s: var PageStoreInner; maxAgeSecs: uint64; maxRootCount: int): bool =
  let roots = blobListRoots(s.blobs)
  if roots.len <= 1: return false
  if maxRootCount > 0 and roots.len > maxRootCount: return true
  let latestUs = parseRootUs(roots[0])
  let maxAgeUs = cast[int64](maxAgeSecs) * 1_000_000
  for i in 1..<roots.len:
    let us = parseRootUs(roots[i])
    if latestUs - us > maxAgeUs: return true
  return false

proc gcFull(s: var PageStoreInner; maxAgeSecs: uint64; maxRootCount: int;
             dryRun: bool): seq[byte] =
  if s.readOnly:
    raise newException(IOError, "read-only")
  let roots = blobListRoots(s.blobs)
  if roots.len == 0: return @[]
  let rootsScanned = roots.len
  let latestUs = parseRootUs(roots[0])
  let maxAgeUs = cast[int64](maxAgeSecs) * 1_000_000
  var rootsToKeep: seq[string] = @[]
  var rootsToRemove: seq[string] = @[]
  for i, name in roots:
    let us = parseRootUs(name)
    let tooOld = latestUs - us > maxAgeUs
    let beyondCount = maxRootCount > 0 and i >= maxRootCount
    if tooOld or beyondCount:
      rootsToRemove.add name
    else:
      rootsToKeep.add name
  var liveUuids: HashSet[array[16, byte]]
  for name in rootsToKeep:
    let data = blobGetRoot(s.blobs, name)
    if data.isNone: continue
    let trees = deserializeRoot(data.get)
    for tree in trees:
      collectTreeUuids(s, tree, liveUuids)
  let rootsRemoved = rootsToRemove.len
  if not dryRun:
    for name in rootsToRemove:
      var err: cint
      discard s.blobs.deleteRoot(s.blobs.handle, name.cstring, addr err)
  let allBlobs = blobList(s.blobs)
  let blobsScanned = allBlobs.len
  var blobsRemoved = 0
  for id in allBlobs:
    if id notin liveUuids:
      if not dryRun:
        var err: cint
        discard s.blobs.delete(s.blobs.handle, cast[ptr Byte](unsafeAddr id), addr err)
      inc blobsRemoved
  let liveCount = liveUuids.len
  result = newSeqOfCap[byte](41)
  let rs = cast[uint64](rootsScanned)
  let rr = cast[uint64](rootsRemoved)
  let bs = cast[uint64](blobsScanned)
  let br = cast[uint64](blobsRemoved)
  let lc = cast[uint64](liveCount)
  for i in 0..7: result.add byte((rs shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((rr shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((bs shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((br shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((lc shr (i*8)) and 0xFF)
  result.add byte(if dryRun: 1 else: 0)

# ══════════════════════════════════════════════════════════════════════════════
# Stats
# ══════════════════════════════════════════════════════════════════════════════

proc collectBlobSizes(s: var PageStoreInner; tree: CfTree;
                       total, count: var uint64) =
  if tree.rootUuid == default(array[16, byte]): return
  let data = blobGet(s.blobs, tree.rootUuid)
  if data.isNone: return
  total += data.get.len.uint64
  inc count
  if tree.height == 0: return
  let entries = deserializeIndexPage(data.get)
  for (_, childUuid) in entries:
    collectBlobSizes(s, CfTree(rootUuid: childUuid, height: tree.height - 1,
                                numLeaves: 0), total, count)

proc cfStats(s: var PageStoreInner; cf: int): seq[byte] =
  let tree = s.trees[cf]
  var sstSize = 0'u64; var numSst = 0'u64
  if tree.rootUuid != default(array[16, byte]):
    collectBlobSizes(s, tree, sstSize, numSst)
  result = newSeqOfCap[byte](40)
  for i in 0..7: result.add byte((tree.numLeaves.uint64 shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((sstSize shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((sstSize shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((numSst shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte(0)

proc dbStats(s: var PageStoreInner): seq[byte] =
  var totalSst = 0'u64; var totalLive = 0'u64
  for tree in s.trees:
    var sz = 0'u64; var cnt = 0'u64
    collectBlobSizes(s, tree, sz, cnt)
    totalSst += sz
    totalLive += sz
  result = newSeqOfCap[byte](16)
  for i in 0..7: result.add byte((totalSst shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((totalLive shr (i*8)) and 0xFF)

proc pageCountInRange(s: var PageStoreInner; cf: int;
                       start, endp: seq[byte]): uint64 =
  if cf >= s.numCf: return 0
  let tree = s.trees[cf]
  if tree.rootUuid == default(array[16, byte]) or tree.numLeaves == 0:
    return 0
  let entries = loadRootEntries(s, tree)
  if entries.len == 0: return (if start.len == 0: 1 else: 0)
  let p = partitionPoint(entries, proc(x: auto): bool = cmpSeq(x[0], start) < 0)
  let lo = if p > 0: p - 1 else: 0
  let hi = partitionPoint(entries, proc(x: auto): bool = cmpSeq(x[0], endp) < 0)
  max(hi - lo, 1).uint64

# ══════════════════════════════════════════════════════════════════════════════
# VTable dispatch — C-ABI wrappers
# ══════════════════════════════════════════════════════════════════════════════

proc psGetKeysInPrefix(h: pointer; cf: cuint; prefix: ptr Byte; plen: csize_t;
                        outBuf: ptr pointer; outLen: ptr csize_t;
                        errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var s = cast[ptr PageStoreInner](h)
  if cf.int >= s.numCf:
    setErr(errOut, ErrInvalidArg)
    return -1
  s.lock.withLock:
    try:
      let pfx = if plen > 0: newSeq[byte](plen.int) else: newSeq[byte](0)
      if plen > 0: copyMem(unsafeAddr pfx[0], prefix, plen.int)
      let keys = getKeysInPrefix(s[], cf.int, pfx)
      var packed = newSeqOfCap[byte](keys.len * 12)
      for k in keys:
        let kl = k.len.uint32
        packed.add byte(kl shr 24)
        packed.add byte((kl shr 16) and 0xFF)
        packed.add byte((kl shr 8) and 0xFF)
        packed.add byte(kl and 0xFF)
        packed.add k
      let buf = allocByteBuf(packed.len)
      copyMem(buf, unsafeAddr packed[0], packed.len)
      outBuf[] = buf
      outLen[] = packed.len.csize_t
      setErr(errOut, ErrOk)
      return 0
    except:
      setErr(errOut, ErrIo)
      return -1

proc psKeyExists(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
                  outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      var k = newSeq[byte](klen.int)
      copyMem(unsafeAddr k[0], key, klen.int)
      let present = keyExists(s[], cf.int, k)
      outPresent[] = if present: 1 else: 0
      setErr(errOut, ErrOk)
      return 0
    except:
      setErr(errOut, ErrIo)
      return -1

proc psPageCount(h: pointer; cf: cuint; outCount: ptr uint64;
                  errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      if cf.int < s[].numCf:
        outCount[] = s[].trees[cf.int].numLeaves.uint64
      else:
        outCount[] = 0
      setErr(errOut, ErrOk)
      return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psPageCountInRange(h: pointer; cf: cuint; start: ptr Byte; slen: csize_t;
                         endp: ptr Byte; elen: csize_t;
                         outCount: ptr uint64; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      var st = newSeq[byte](slen.int)
      var en = newSeq[byte](elen.int)
      copyMem(unsafeAddr st[0], start, slen.int)
      copyMem(unsafeAddr en[0], endp, elen.int)
      outCount[] = pageCountInRange(s[], cf.int, st, en)
      setErr(errOut, ErrOk)
      return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psCommitMerge*(h: pointer; data: ptr Byte; dlen: csize_t;
           clearJournal: cint; errOut: ptr cint): cint {.cdecl.} =
  # This should NOT be called during open. Trace backtrace.
  if dlen > 100_000:
    setErr(errOut, ErrInvalidArg)
    return -1
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      var buf = newSeq[byte](dlen.int)
      copyMem(unsafeAddr buf[0], data, dlen.int)
      var keysByCf: seq[(int, seq[seq[byte]])] = @[]
      var pos = 0
      while pos + 5 <= buf.len:
        let cf = buf[pos].int; inc pos
        let nkeys = (uint32(buf[pos]) shl 24 or uint32(buf[pos+1]) shl 16 or
                      uint32(buf[pos+2]) shl 8 or uint32(buf[pos+3])).int
        pos += 4
        var keys: seq[seq[byte]] = @[]
        for ki in 0..<nkeys:
          if pos + 4 > buf.len: break
          let klen = (uint32(buf[pos]) shl 24 or uint32(buf[pos+1]) shl 16 or
                       uint32(buf[pos+2]) shl 8 or uint32(buf[pos+3])).int
          pos += 4
          if pos + klen > buf.len: break
          let key = buf[pos..<pos+klen]
          pos += klen
          keys.add @key
        keysByCf.add (cf, keys)
      commitMerge(s[], keysByCf, clearJournal != 0)
      setErr(errOut, ErrOk)
      return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psJournalPut(h: pointer; key: ptr Byte; klen: csize_t;
                   val: ptr Byte; vlen: csize_t;
                   errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      var k = newSeq[byte](klen.int)
      var v = newSeq[byte](vlen.int)
      copyMem(unsafeAddr k[0], key, klen.int)
      copyMem(unsafeAddr v[0], val, vlen.int)
      journalAppend(s[], k, v)
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psJournalScan(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                    errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      let data = journalRead(s[])
      let buf = allocByteBuf(data.len)
      copyMem(buf, unsafeAddr data[0], data.len)
      outBuf[] = buf; outLen[] = data.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psJournalSize(h: pointer; outSize: ptr uint64;
                    errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      outSize[] = journalSize(s[])
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psGcFull(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
               dryRun: cint; outBuf: ptr pointer; outLen: ptr csize_t;
               errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      let result = gcFull(s[], maxAgeSecs, maxRootCount.int, dryRun != 0)
      let buf = allocByteBuf(result.len)
      copyMem(buf, unsafeAddr result[0], result.len)
      outBuf[] = buf; outLen[] = result.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psCfStats(h: pointer; cf: cuint; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      let data = cfStats(s[], cf.int)
      let buf = allocByteBuf(data.len)
      copyMem(buf, unsafeAddr data[0], data.len)
      outBuf[] = buf; outLen[] = data.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psDbStats(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      let data = dbStats(s[])
      let buf = allocByteBuf(data.len)
      copyMem(buf, unsafeAddr data[0], data.len)
      outBuf[] = buf; outLen[] = data.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psHasOldRoots(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
                    outResult: ptr cint; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      outResult[] = if hasOldRoots(s[], maxAgeSecs, maxRootCount.int): 1 else: 0
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psRootCount(h: pointer; outCount: ptr uint64;
                  errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  s.lock.withLock:
    try:
      outCount[] = blobListRoots(s.blobs).len.uint64
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc psClose(h: pointer) {.cdecl.} =
  var s = cast[ptr PageStoreInner](h)
  if s.journal != nil: nim_journal_close(s.journal)
  if s.blobs != nil:
    case s.backendType:
    of "memory": nim_blob_memory_close(s.blobs)
    of "file": nim_blob_file_close(s.blobs)
    of "s3": nim_blob_s3_close(s.blobs)
    else: discard
  deallocShared(h)

proc initVtable(vt: NimPageStoreVtablePtr; s: ptr PageStoreInner) =
  vt.handle = s
  vt.getKeysInPrefix = psGetKeysInPrefix
  vt.keyExists = psKeyExists
  vt.pageCount = psPageCount
  vt.pageCountInRange = psPageCountInRange
  vt.journalPut = psJournalPut
  vt.journalScan = psJournalScan
  vt.journalSize = psJournalSize
  vt.gcFull = psGcFull
  vt.cfStats = psCfStats
  vt.dbStats = psDbStats
  vt.hasOldRoots = psHasOldRoots
  vt.rootCount = psRootCount
  vt.close = psClose
  vt.freeBuf = freeShared

# ══════════════════════════════════════════════════════════════════════════════
# openPageStore — create and initialize the page store
# ══════════════════════════════════════════════════════════════════════════════

proc openPageStore*(keys, vals: CStringArr; count: cint;
                     errOut: ptr cint): NimPageStoreVtablePtr =
  let backend = "memory"
  let numCf = 4

  let blobs = nim_blob_memory_open(keys, vals, count, errOut)
  if blobs == nil:
    setErr(errOut, ErrConfig)
    return nil

  let s = cast[ptr PageStoreInner](allocShared0(sizeof(PageStoreInner)))
  s.blobs = blobs
  s.journal = nil
  s.numCf = numCf
  s.readOnly = false
  s.cache = initCache(64 * 1024 * 1024)
  s.backendType = backend
  initSpinLock(s.lock)

  let roots = blobListRoots(blobs)
  if roots.len > 0:
    let latest = roots[0]
    let rootData = blobGetRoot(blobs, latest)
    if rootData.isSome:
      s.trees = deserializeRoot(rootData.get)
      var i = s.trees.len
      while i < numCf:
        s.trees.add emptyTree(); inc i
      s.currentRoot = latest
    else:
      setErr(errOut, ErrIo); deallocShared(s); return nil
  else:
    s.trees = newSeq[CfTree](numCf)
    for _ in 0..<numCf: s.trees.add emptyTree()
    let name = makeRootName()
    blobPutRoot(blobs, name, serializeRoot(s.trees))
    s.currentRoot = name
  let vt = newVtable()
  initVtable(vt, s)
  setErr(errOut, ErrOk)
  return vt
