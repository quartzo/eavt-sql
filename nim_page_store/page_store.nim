## backend.nim — COW B-tree page store on top of Nim blobstore.
##
## Port of spier-kvstore/src/generic_page_store.rs (~1800 lines → ~900 lines Nim).

import std/[tables, sets, hashes, strformat, strutils, times, monotimes, options, os]
import pages
import std/locks

import blobstore
import file/file_backend as fil_be
import s3/s3_backend as s3_be
import journal/journal_backend as jou_be

# ── seq[byte] comparison helpers ──

proc cmpSeq*(a, b: seq[byte]): int =
  let n = min(a.len, b.len)
  for i in 0..<n:
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  return 0

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
# Root blob serialization
# ══════════════════════════════════════════════════════════════════════════════

type
  CfTree* = object
    rootUuid*: array[16, byte]
    height*: uint8
    numLeaves*: uint32

proc serializeRoot*(trees: seq[CfTree]): seq[byte] =
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

proc deserializeRoot*(data: openArray[byte]): seq[CfTree] =
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

proc deserializeIndexPage*(data: openArray[byte]): seq[(seq[byte], array[16, byte])] =
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

proc makeRootName*(): string =
  let ts = getTime().toUnix * 1_000_000_000 + getTime().nanosecond.int64
  let neg = cast[uint64]((not ts) + 1)
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

proc partitionPoint(entries: seq[(seq[byte], array[16, byte])]; target: seq[byte]): int =
  ## First index where entries[i][0] >= target.
  var lo = 0; var hi = entries.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpSeq(entries[mid][0], target) < 0: lo = mid + 1
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

proc findPrefixRange*(entries: seq[(seq[byte], array[16, byte])];
                       prefix: seq[byte]): (int, int) =
  if prefix.len == 0: return (0, entries.len)
  let pe = prefixEnd(prefix)
  let s = partitionPoint(entries, prefix)
  let startIdx = if s > 0: s - 1 else: 0
  let endIdx = if pe.isSome:
    partitionPoint(entries, pe.get)
  else:
    entries.len
  (min(startIdx, endIdx), endIdx)

# ══════════════════════════════════════════════════════════════════════════════
# PageCache — simple LRU via access-order counter.
# Stores zstd-compressed page bytes (as returned by blobstore).
# 3-5× smaller than decompressed → 3-5× more pages in cache → fewer I/Os.
# Decompression is paid on cache hit (~0.5ms) but I/O saving dominates.

type
  CacheEntry = object
    compressed: seq[byte]    ## zstd-compressed page (from blobstore)
    accessOrder: int64

  PageCache = object
    map: Table[array[16, byte], CacheEntry]
    maxBytes: int
    currentBytes: int
    nextOrder: int64
    lock: Lock

proc initCache(maxBytes: int): PageCache =
  result = PageCache(maxBytes: maxBytes, currentBytes: 0, nextOrder: 1)
  initLock(result.lock)

proc get(cc: var PageCache; uuid: array[16, byte]): Option[seq[byte]] =
  cc.lock.withLock:
    if uuid in cc.map:
      cc.map[uuid].accessOrder = cc.nextOrder
      inc cc.nextOrder
      return some(cc.map[uuid].compressed)
    return none(seq[byte])

proc put(cc: var PageCache; uuid: array[16, byte]; compressed: seq[byte]) =
  cc.lock.withLock:
    if uuid in cc.map: return
    let sz = compressed.len
    while cc.currentBytes + sz > cc.maxBytes and cc.map.len > 0:
      var minKey: array[16, byte]
      var minOrder = high(int64)
      for k, v in cc.map:
        if v.accessOrder < minOrder:
          minOrder = v.accessOrder
          minKey = k
      cc.currentBytes -= cc.map[minKey].compressed.len
      cc.map.del(minKey)
    if sz <= cc.maxBytes:
      cc.currentBytes += sz
      cc.map[uuid] = CacheEntry(compressed: compressed, accessOrder: cc.nextOrder)
      inc cc.nextOrder



type
  PageStoreInner* = object
    blobs*: BlobStore           # trait dispatch — no vtable
    journal*: jou_be.Journal
    trees*: seq[CfTree]
    numCf*: int
    readOnly*: bool
    currentRoot*: string
    cache*: PageCache
    lock*: Lock
    backendType*: string
    ## Directory holding blobs/journal; closePageStore removes it when ownsPath
    ## is set (tests' tempdir-per-store pattern).
    dbPath*: string
    ownsPath*: bool


# ══════════════════════════════════════════════════════════════════════════════
# BlobStore / Journal wrappers
# ══════════════════════════════════════════════════════════════════════════════

proc blobPut(blobs: BlobStore; data: openArray[byte]): array[16, byte] =
  blobs.put(compress(data))

proc blobGet*(blobs: BlobStore; id: array[16, byte]): Option[seq[byte]] =
  let r = blobs.get(id)
  if r.isNone(): return none(seq[byte])
  result = some(decompress(r.get()))

proc blobPutRoot(blobs: BlobStore; name: string; data: openArray[byte]): bool =
  try:
    blobs.putRoot(name, compress(data))
    return true
  except:
    return false

proc blobGetRoot(blobs: BlobStore; name: string): Option[seq[byte]] =
  let r = blobs.getRoot(name)
  if r.isNone(): return none(seq[byte])
  result = some(decompress(r.get()))

proc blobListRoots(blobs: BlobStore): seq[string] =
  blobs.listRoots()

proc blobList(blobs: BlobStore): seq[array[16, byte]] =
  blobs.list()

proc journalTruncate(s: var PageStoreInner) =
  if s.journal == nil: return
  s.journal.truncate()

# ══════════════════════════════════════════════════════════════════════════════
# B-tree operations
# ══════════════════════════════════════════════════════════════════════════════

proc loadLeafRaw*(s: var PageStoreInner; uuid: array[16, byte]): seq[byte] =
  ## Return decompressed (prefix-compressed, NOT expanded) page bytes.
  ## Caches zstd-compressed bytes. Decompresses on every call —
  ## the cache exists to avoid I/O, not CPU.
  let cached = s.cache.get(uuid)
  if cached.isSome:
    return decompress(cached.get)       # decompress from cache
  let compressed = s.blobs.get(uuid)     # raw blobstore call (no zstd)
  if compressed.isNone:
    raise newException(IOError, "leaf blob not found")
  s.cache.put(uuid, compressed.get)     # cache zstd-compressed
  return decompress(compressed.get)

proc loadLeafKeys*(s: var PageStoreInner; uuid: array[16, byte]): seq[seq[byte]] =
  let raw = loadLeafRaw(s, uuid)
  deserializePage(raw)

proc loadLeafKeysNoput(s: var PageStoreInner; uuid: array[16, byte]): seq[seq[byte]] =
  ## Load leaf keys from blobstore without putting into cache (used by COW merge).
  let compressed = s.blobs.get(uuid)
  if compressed.isNone:
    raise newException(IOError, "leaf blob not found")
  deserializePage(decompress(compressed.get))

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

proc getKeysInPrefix*(s: var PageStoreInner; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  if cf >= s.numCf: return @[]
  var tree: CfTree
  s.lock.withLock: tree = s.trees[cf]
  if tree.rootUuid == default(array[16, byte]): return @[]
  if tree.height == 0:
    let keys = loadLeafKeys(s, tree.rootUuid)
    for k in keys:
      if k.len >= prefix.len and k[0..<prefix.len] == prefix:
        result.add k
  else:
    result = collectKeysFromIndex(s, tree.rootUuid, tree.height, prefix)

proc keyExists*(s: var PageStoreInner; cf: int; key: seq[byte]): bool =
  let keys = getKeysInPrefix(s, cf, key)
  for k in keys:
    if k == key: return true
  return false

# ══════════════════════════════════════════════════════════════════════════════
# Key-value leaf operations (CFs >= 10)
# ══════════════════════════════════════════════════════════════════════════════

proc loadLeafPairs*(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], seq[byte])] =
  let raw = loadLeafRaw(s, uuid)
  deserializePageKv(raw)

proc loadLeafPairsNoput(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], seq[byte])] =
  let compressed = s.blobs.get(uuid)
  if compressed.isNone:
    raise newException(IOError, "leaf blob not found")
  deserializePageKv(decompress(compressed.get))

proc getPairsInPrefix*(s: var PageStoreInner; cf: int; prefix: seq[byte]): seq[(seq[byte], seq[byte])] =
  if cf >= s.numCf: return @[]
  var tree: CfTree
  s.lock.withLock: tree = s.trees[cf]
  if tree.rootUuid == default(array[16, byte]): return @[]
  if tree.height == 0:
    let pairs = loadLeafPairs(s, tree.rootUuid)
    for (k, v) in pairs:
      if k.len >= prefix.len and k[0..<prefix.len] == prefix:
        result.add (k, v)
  else:
    let data = blobGet(s.blobs, tree.rootUuid)
    if data.isNone: return @[]
    let entries = deserializeIndexPage(data.get)
    let (start, endIdx) = findPrefixRange(entries, prefix)
    for i in start..<endIdx:
      let (_, childUuid) = entries[i]
      if tree.height == 1:
        let pairs = loadLeafPairs(s, childUuid)
        for (k, v) in pairs:
          if k.len >= prefix.len and k[0..<prefix.len] == prefix:
            result.add (k, v)
      else:
        # recurse through index levels
        var stack: seq[(array[16, byte], uint8)] = @[(childUuid, tree.height - 1)]
        while stack.len > 0:
          let (uuid, h) = stack.pop()
          let d = blobGet(s.blobs, uuid)
          if d.isNone: continue
          let ents = deserializeIndexPage(d.get)
          let (s2, e2) = findPrefixRange(ents, prefix)
          for j in s2..<e2:
            let (_, cu) = ents[j]
            if h == 1:
              let pairs = loadLeafPairs(s, cu)
              for (k, v) in pairs:
                if k.len >= prefix.len and k[0..<prefix.len] == prefix:
                  result.add (k, v)
            else:
              stack.add (cu, h - 1)

proc keyExistsKv*(s: var PageStoreInner; cf: int; key: seq[byte]): Option[seq[byte]] =
  let pairs = getPairsInPrefix(s, cf, key)
  for (k, v) in pairs:
    if k == key: return some(v)
  return none(seq[byte])

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

proc commitMerge*(s: var PageStoreInner; keysByCf: seq[(int, seq[seq[byte]])];
                  clearJournal: bool) =
  if s.readOnly:
    raise newException(IOError, "read-only")
  for (cf, sortedKeysIn) in keysByCf:
    if cf >= s.numCf or sortedKeysIn.len == 0: continue
    var sortedKeys = sortedKeysIn
    let tree = s.trees[cf]
    var idx = 0
    let newTree: CfTree =
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
    s.lock.withLock:
      s.trees[cf] = newTree
  let newRoot = makeRootName()
  discard blobPutRoot(s.blobs, newRoot, serializeRoot(s.trees))
  s.lock.withLock:
    s.currentRoot = newRoot
  if clearJournal:
    journalTruncate(s)

proc commitMergeKv*(s: var PageStoreInner; pairsByCf: seq[(int, seq[(seq[byte], seq[byte])])];
                    deletedByCf: seq[(int, seq[seq[byte]])] = @[];
                    clearJournal: bool = true) =
  ## Like commitMerge but for key-value CFs (>= 10). Builds leaf pages with
  ## serializePageKv. Index pages are identical (boundary keys only, no values).
  ## deletedByCf lists keys to remove from the PageStore.
  if s.readOnly:
    raise newException(IOError, "read-only")

  # Build a lookup of deleted keys per CF
  var deletedKeys: Table[int, HashSet[seq[byte]]]
  for (cf, keys) in deletedByCf:
    deletedKeys[cf] = initHashSet[seq[byte]]()
    for k in keys: deletedKeys[cf].incl(k)

  # Also build a set of CFs that appear in pairsByCf
  var pairCfs: HashSet[int]
  for (cf, _) in pairsByCf: pairCfs.incl(cf)

  # Process CFs that have only deletions (no new pairs)
  for (cf, delKeys) in deletedByCf:
    if cf in pairCfs: continue  # handled in the main loop below
    if cf >= s.numCf: continue
    let tree = s.trees[cf]
    if tree.rootUuid == default(array[16, byte]): continue  # nothing to delete
    var allPairs = getPairsInPrefix(s, cf, @[])
    var livePairs: seq[(seq[byte], seq[byte])] = @[]
    let delSet = deletedKeys.getOrDefault(cf, initHashSet[seq[byte]]())
    for (k, v) in allPairs:
      if k notin delSet: livePairs.add((k, v))
    if livePairs.len == 0:
      s.lock.withLock:
        s.trees[cf] = CfTree(rootUuid: default(array[16, byte]), height: 0, numLeaves: 0)
      continue
    let pageList = buildPagesKv(livePairs)
    var entries: seq[(seq[byte], array[16, byte])] = @[]
    for (boundary, pageData) in pageList:
      discard deserializePageKv(pageData)
      let uuid = blobPut(s.blobs, pageData)
      entries.add (boundary, uuid)
    let numLeaves = entries.len.uint32
    var (root, height) = buildIndexTree(s, entries, 0)
    if height == 0:
      s.lock.withLock:
        s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
    else:
      s.lock.withLock:
        s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: numLeaves)

  for (cf, sortedPairs) in pairsByCf:
    if cf >= s.numCf or sortedPairs.len == 0: continue
    let tree = s.trees[cf]
    let delSet = deletedKeys.getOrDefault(cf, initHashSet[seq[byte]]())

    if tree.rootUuid == default(array[16, byte]):
      # No existing data — just filter out deleted keys from new pairs
      var filtered: seq[(seq[byte], seq[byte])] = @[]
      for (k, v) in sortedPairs:
        if k notin delSet: filtered.add((k, v))
      if filtered.len == 0: continue
      let pageList = buildPagesKv(filtered)
      var entries: seq[(seq[byte], array[16, byte])] = @[]
      for (boundary, pageData) in pageList:
        discard deserializePageKv(pageData)
        let uuid = blobPut(s.blobs, pageData)
        entries.add (boundary, uuid)
      let numLeaves = entries.len.uint32
      var (root, height) = buildIndexTree(s, entries, 0)
      if height == 0:
        s.lock.withLock:
          s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
      else:
        s.lock.withLock:
          s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
    else:
      # Merge into existing tree: collect all existing pairs, merge-sort with new,
      # rebuild pages. Remove keys present in delSet.
      var allPairs = getPairsInPrefix(s, cf, @[])
      # Filter out deleted keys from existing pairs
      var livePairs: seq[(seq[byte], seq[byte])] = @[]
      for (k, v) in allPairs:
        if k notin delSet: livePairs.add((k, v))
      # Merge-sort: both are sorted, combine deduplicating by key (newer wins)
      var merged: seq[(seq[byte], seq[byte])] = @[]
      var ai = 0; var bi = 0
      while ai < livePairs.len and bi < sortedPairs.len:
        let c = cmpSeq(livePairs[ai][0], sortedPairs[bi][0])
        if c < 0:
          if livePairs[ai][0] notin delSet: merged.add livePairs[ai]
          inc ai
        elif c > 0:
          if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
          inc bi
        else:
          if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
          inc ai; inc bi
      while ai < livePairs.len:
        if livePairs[ai][0] notin delSet: merged.add livePairs[ai]
        inc ai
      while bi < sortedPairs.len:
        if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
        inc bi
      if merged.len == 0:
        s.lock.withLock:
          s.trees[cf] = CfTree(rootUuid: default(array[16, byte]), height: 0, numLeaves: 0)
        continue
      let pageList = buildPagesKv(merged)
      var entries: seq[(seq[byte], array[16, byte])] = @[]
      for (boundary, pageData) in pageList:
        discard deserializePageKv(pageData)
        let uuid = blobPut(s.blobs, pageData)
        entries.add (boundary, uuid)
      let numLeaves = entries.len.uint32
      var (root, height) = buildIndexTree(s, entries, 0)
      if height == 0:
        s.lock.withLock:
          s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
      else:
        s.lock.withLock:
          s.trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
  let newRoot = makeRootName()
  discard blobPutRoot(s.blobs, newRoot, serializeRoot(s.trees))
  s.lock.withLock:
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

proc gcFull*(s: var PageStoreInner; maxAgeSecs: uint64; maxRootCount: int;
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
      try: s.blobs.deleteRoot(name)
      except: discard
  let allBlobs = blobList(s.blobs)
  let blobsScanned = allBlobs.len
  var blobsRemoved = 0
  for id in allBlobs:
    if id notin liveUuids:
      if not dryRun:
        try: s.blobs.delete(id)
        except: discard
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

proc newPageStore*(config: Table[string, string]): ptr PageStoreInner =
  let backend = config.getOrDefault("backend", "file")
  let readOnly = config.getOrDefault("read_only", "false") == "true"
  let path = config.getOrDefault("path", "")
  let pageCacheSize = parseInt(config.getOrDefault("page_cache_size", "67108864"))
  let numCf = parseInt(config.getOrDefault("num_cf", "64"))

  if path.len == 0:
    return nil  # a local path is required (blob dir / journal / WAL)

  let blobs: BlobStore =
    case backend:
    of "file": fil_be.newFileBlobStore(path, readOnly)
    of "s3": s3_be.newS3BlobStore(config)
    else: nil

  if blobs == nil:
    return nil

  let journal =
    try:
      jou_be.newJournal(path)
    except:
      nil

  result = cast[ptr PageStoreInner](allocShared0(sizeof(PageStoreInner)))
  result.blobs = blobs
  result.journal = journal
  result.numCf = numCf
  result.readOnly = readOnly
  result.cache = initCache(pageCacheSize)
  result.backendType = backend
  result.dbPath = path
  result.ownsPath = config.getOrDefault("owns_path", "false") == "true"
  initLock(result.lock)

  let roots = blobListRoots(blobs)
  if roots.len > 0:
    let latest = roots[0]
    let rootData = blobGetRoot(blobs, latest)
    if rootData.isSome():
      result.trees = deserializeRoot(rootData.get())
      var i = result.trees.len
      while i < numCf:
        result.trees.add emptyTree(); inc i
      result.currentRoot = latest
    else:
      deallocShared(result)
      return nil
  else:
    result.trees = @[]
    for _ in 0..<numCf: result.trees.add emptyTree()
    let name = makeRootName()
    if not blobPutRoot(blobs, name, serializeRoot(result.trees)):
      deallocShared(result)
      return nil
    result.currentRoot = name

proc closePageStore*(ps: ptr PageStoreInner) =
  if ps == nil: return
  if ps.journal != nil: ps.journal.close()
  let path = ps.dbPath
  let owns = ps.ownsPath
  deinitLock(ps.lock)
  deallocShared(ps)
  if owns and path.len > 0:
    try:
      removeDir(path)
    except CatchableError:
      discard

