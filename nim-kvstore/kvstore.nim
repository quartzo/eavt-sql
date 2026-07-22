## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.
## Implements all KVStoreEngine operations via C-ABI vtable.

import std/[tables, strutils, os, options]
import ./abi
import ./backend
import std/locks

import nim_memtable/backend as mt_be
import nim_memtable/treap_cursor
import ./page_cursor
import query/scanner  # NimCursor type

type
  HeapEntry = tuple[key: seq[byte], srcIdx: int]
  MinHeap = object
    data: seq[HeapEntry]

proc parent(i: int): int = (i - 1) shr 1
proc leftChild(i: int): int = (i shl 1) + 1

proc push(h: var MinHeap; entry: HeapEntry) =
  h.data.add entry
  var i = h.data.len - 1
  while i > 0:
    let p = parent(i)
    if cmpSeq(h.data[i].key, h.data[p].key) < 0:
      swap(h.data[i], h.data[p])
      i = p
    else:
      break

proc pop(h: var MinHeap): HeapEntry =
  result = h.data[0]
  h.data[0] = h.data[^1]
  h.data.setLen(h.data.len - 1)
  var i = 0
  while true:
    let l = leftChild(i)
    if l >= h.data.len: break
    var smallest = i
    if cmpSeq(h.data[l].key, h.data[smallest].key) < 0:
      smallest = l
    let r = l + 1
    if r < h.data.len and cmpSeq(h.data[r].key, h.data[smallest].key) < 0:
      smallest = r
    if smallest != i:
      swap(h.data[i], h.data[smallest])
      i = smallest
    else:
      break

proc len*(h: MinHeap): int = h.data.len

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore — Nim-native ref type
# ═══════════════════════════════════════════════════════════════════════════════

type
  KVStore* = ref object
    ps*: ptr PageStoreInner        # page store
    mt*: mt_be.MemTable            # Nim ref — no vtable
    mtSize*: uint64
    flushSnap*: uint64
    lock: Lock
    config*: Table[string, string]
    path*: string
    readOnly*: bool
    numCf*: int
    flushThreshold*: uint64
    gcMaxAgeSecs*: uint64
    gcMaxRootCount*: int

# ── Internal alias (shared implementation) ──
type
  S* = KVStore  # short alias used throughout the file

  MergeSourceKind = enum
    mskPageStore
    mskMemTable

  MergeSource = object
    case kind: MergeSourceKind
    of mskPageStore, mskMemTable:
      keys: seq[seq[byte]]
      idx: int

# ═══════════════════════════════════════════════════════════════════════════════
# Merge — k-way heap merge of sorted sources
# ═══════════════════════════════════════════════════════════════════════════════

proc mergeSources(sources: var seq[MergeSource]; endBound: seq[byte];
                   limit: int = -1): seq[seq[byte]] =
  var heap: MinHeap
  for i, src in sources.mpairs:
    if src.idx < src.keys.len:
      heap.push((src.keys[src.idx], i))

  result = @[]
  var lastKey: seq[byte] = @[]
  while heap.len > 0 and (limit < 0 or result.len < limit):
    let (key, srcIdx) = heap.pop()
    if cmpSeq(key, endBound) > 0: break
    if key == lastKey:
      lastKey = key
      inc sources[srcIdx].idx
      if sources[srcIdx].idx < sources[srcIdx].keys.len:
        heap.push((sources[srcIdx].keys[sources[srcIdx].idx], srcIdx))
      continue
    lastKey = key
    result.add key
    inc sources[srcIdx].idx
    if sources[srcIdx].idx < sources[srcIdx].keys.len:
      heap.push((sources[srcIdx].keys[sources[srcIdx].idx], srcIdx))

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations
# ═══════════════════════════════════════════════════════════════════════════════

proc prefixEnd(prefix: seq[byte]): seq[byte] =
  if prefix.len == 0:
    result = newSeq[byte](64)
    for i in 0..<64: result[i] = 0xFF
  else:
    for i in 0..<32: result.add 0xFF
    result = prefix & result

proc newKVStore*(keys, vals: CStringArr; count: cint;
                  errOut: ptr cint): KVStore =
  let config = parseConfig(keys, vals, count.csize_t)
  let readOnly = config.getOrDefault("read_only", "false") == "true"
  let ps = newPageStore(keys, vals, count, errOut)
  if ps == nil: return nil
  let mt = mt_be.newMemTable(4)
  if mt == nil: closePageStore(ps); return nil
  result = KVStore()
  result.ps = ps; result.mt = mt
  result.config = config
  result.path = config.getOrDefault("path", ":memory:")
  result.readOnly = readOnly
  result.numCf = 4
  result.flushThreshold = parseUInt(config.getOrDefault("flush_threshold", "67108864")).uint64
  result.gcMaxAgeSecs = parseUInt(config.getOrDefault("gc_max_age_secs", "43200")).uint64
  result.gcMaxRootCount = parseInt(config.getOrDefault("gc_max_root_count", "10"))
  initLock(result.lock)
  # Replay journal
  if result.path.len > 0 and result.path != ":memory:" and result.path != "":
    let journalPath = result.path / "journal" / "journal"
    if fileExists(journalPath):
      try:
        let data = readFile(journalPath)
        var pos = 0; var ops = newSeq[byte](0)
        while pos + 4 <= data.len:
          let klen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + klen + 4 > data.len: break
          # Read jkey as raw bytes
          let cf = byte(data[pos])
          pos += klen
          let vlen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + vlen > data.len: break
          pos += vlen  # skip flag byte
          if klen >= 20:
            ops.add(0'u8); ops.add(byte((klen shr 24) and 0xFF))
            ops.add(byte((klen shr 16) and 0xFF)); ops.add(byte((klen shr 8) and 0xFF))
            ops.add(byte(klen and 0xFF))
            for i in 0..<klen: ops.add(byte(data[pos - 4 - vlen - klen + i]))
          elif klen >= 1 and cf <= 3:
            ops.add(cf); ops.add(byte(((klen-1) shr 24) and 0xFF))
            ops.add(byte(((klen-1) shr 16) and 0xFF)); ops.add(byte(((klen-1) shr 8) and 0xFF))
            ops.add(byte((klen-1) and 0xFF))
            for i in 1..<klen: ops.add(byte(data[pos - 4 - vlen - klen + i]))
        if ops.len > 0: result.mtSize = result.mt.batch(ops)
      except: discard

proc close*(kv: KVStore) =
  if kv != nil:
    if kv.mt != nil: kv.mt.close(); kv.mt = nil
    if kv.ps != nil: closePageStore(kv.ps); kv.ps = nil

proc put*(kv: KVStore; cf: int; key: openArray[byte]) =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  kv.lock.withLock:
    kv.mtSize = kv.mt.put(cf, k)
    # Journal for crash recovery
    if kv.path.len > 0 and kv.path != ":memory:" and not kv.readOnly:
      try:
        let journalPath = kv.path / "journal" / "journal"
        createDir(parentDir(journalPath))
        var f = open(journalPath, fmAppend)
        var jk = newSeq[byte](1 + key.len)
        jk[0] = byte(cf)
        if key.len > 0: copyMem(addr jk[1], unsafeAddr key[0], key.len)
        # Frame: [u32 klen][key][u32 vlen=1][flag=0]
        let totKlen = 1 + key.len
        var hdr = newSeq[byte](4 + totKlen + 4 + 1)
        hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
        hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
        copyMem(addr hdr[4], addr jk[0], totKlen)
        hdr[4 + totKlen] = 0; hdr[5 + totKlen] = 0; hdr[6 + totKlen] = 0; hdr[7 + totKlen] = 1
        hdr[8 + totKlen] = 0  # flag byte
        discard f.writeBytes(hdr, 0, hdr.len)
        f.close()
      except: discard

proc get*(kv: KVStore; cf: int; key: openArray[byte]): bool =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  if kv.mt.contains(0, cf, k): return true
  if kv.flushSnap != 0 and kv.mt.contains(kv.flushSnap, cf, k): return true
  keyExists(kv.ps[], cf, k)

proc scan*(kv: KVStore; cf: int; prefix: openArray[byte]): seq[seq[byte]] =
  var pfx: seq[byte] = @[]
  for b in prefix: pfx.add(b)
  # Build sources exactly like the internal kvScan
  var sources: seq[MergeSource] = @[]
  let psKeys = getKeysInPrefix(kv.ps[], cf, pfx)
  if psKeys.len > 0: sources.add MergeSource(kind: mskPageStore, keys: psKeys, idx: 0)
  if kv.flushSnap != 0:
    let snapKeys = kv.mt.scanAll(kv.flushSnap, cf, pfx)
    if snapKeys.len > 0: sources.add MergeSource(kind: mskMemTable, keys: snapKeys, idx: 0)
  let liveSnap = kv.mt.snapshot()
  let liveKeys = kv.mt.scanAll(liveSnap, cf, pfx)
  kv.mt.snapshotFree(liveSnap)
  if liveKeys.len > 0: sources.add MergeSource(kind: mskMemTable, keys: liveKeys, idx: 0)
  let endB = prefixEnd(pfx)
  mergeSources(sources, endB)

proc scanReverse*(kv: KVStore; cf: int; prefix: openArray[byte]): seq[seq[byte]] =
  var r = kv.scan(cf, prefix)
  var i = 0; var j = r.len - 1
  while i < j: swap(r[i], r[j]); inc i; dec j
  r

proc flush*(kv: KVStore) =
  if kv.readOnly: return
  if kv.flushSnap != 0: return
  kv.flushSnap = kv.mt.snapshot()
  kv.mt.clear(); kv.mtSize = 0
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<kv.numCf:
    let keys = kv.mt.scanAll(kv.flushSnap, cf, @[])
    if keys.len > 0: keysByCf.add (cf, keys)
  if keysByCf.len > 0: commitMerge(kv.ps[], keysByCf, true)
  kv.flushSnap = 0; kv.mtSize = 0

proc batchWrite*(kv: KVStore; ops: openArray[byte]) =
  if kv.path.len > 0 and kv.path != ":memory:" and not kv.readOnly:
    var journalPath = kv.path / "journal" / "journal"
    try:
      createDir(parentDir(journalPath)); var f = open(journalPath, fmAppend)
      let raw = cast[ptr UncheckedArray[byte]](unsafeAddr ops[0]); var pos = 0
      while pos + 5 <= ops.len:
        let cf = raw[pos]
        let klen = int(uint32(raw[pos+1]) shl 24 or uint32(raw[pos+2]) shl 16 or
                      uint32(raw[pos+3]) shl 8 or uint32(raw[pos+4]))
        let totKlen = 1 + klen
        var hdr = newSeq[byte](4 + totKlen + 4 + 1)
        hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
        hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
        hdr[4] = cf
        if klen > 0: copyMem(addr hdr[5], addr raw[pos+5], klen)
        hdr[5+klen] = 0; hdr[6+klen] = 0; hdr[7+klen] = 0; hdr[8+klen] = 1; hdr[9+klen] = 0
        discard f.writeBytes(hdr, 0, hdr.len); pos += 5 + klen
      f.close()
    except: discard
  kv.mtSize = kv.mt.batch(ops)

proc memtableSize*(kv: KVStore): uint64 = kv.mtSize


# ═══════════════════════════════════════════════════════════════════════════════
# MergedCursor — heap merge of N NimCursor sources (streaming, no materialization)
# ═══════════════════════════════════════════════════════════════════════════════

type
  MergedCursor* = ref object
    sources: seq[NimCursor]
    heap: MinHeap
    lastKey: seq[byte]
    atEnd*: bool
    curKey: Option[seq[byte]]

proc advance(mc: MergedCursor) =
  if mc.atEnd: return
  while mc.heap.len > 0:
    let (key, srcIdx) = mc.heap.pop()
    if mc.lastKey.len > 0 and key == mc.lastKey:
      var src = mc.sources[srcIdx]
      if src.isValidCb():
        src.stepCb()
        if src.isValidCb():
          let nk = src.currentKeyCb()
          if nk.isSome: mc.heap.push((nk.get, srcIdx))
      continue
    mc.lastKey = key
    mc.curKey = some(key)
    var src = mc.sources[srcIdx]
    src.stepCb()
    if src.isValidCb():
      let nk = src.currentKeyCb()
      if nk.isSome: mc.heap.push((nk.get, srcIdx))
    return
  mc.atEnd = true
  mc.curKey = none(seq[byte])

proc newMergedCursor*(sources: seq[NimCursor]): MergedCursor =
  result = MergedCursor(sources: sources, atEnd: false)
  var heap: MinHeap
  for i, src in sources:
    if src.isValidCb():
      let k = src.currentKeyCb()
      if k.isSome:
        heap.push((k.get, i))
  result.heap = heap
  # Lazy — first peek/next/seek will call ensure() → advance()

proc ensure(mc: MergedCursor) =
  if mc.curKey.isNone and not mc.atEnd:
    mc.advance()

proc peek*(mc: MergedCursor): Option[seq[byte]] =
  mc.ensure()
  if mc.atEnd: none(seq[byte]) else: mc.curKey

proc next*(mc: MergedCursor): Option[seq[byte]] =
  mc.ensure()
  result = mc.curKey
  mc.curKey = none(seq[byte])
  mc.advance()

proc seek*(mc: MergedCursor; target: seq[byte]) =
  for src in mc.sources:
    src.seekCb(target)
  mc.heap.data = @[]
  for i, src in mc.sources:
    if src.isValidCb():
      let k = src.currentKeyCb()
      if k.isSome: mc.heap.push((k.get, i))
  mc.lastKey = @[]
  mc.atEnd = false
  mc.curKey = none(seq[byte])
  mc.advance()

# ── Adapters: wrap page store and treap cursors as NimCursor ──

proc pageStoreToNimCursor*(psc: PageStoreCursor): NimCursor =
  NimCursor(
    isValidCb: proc(): bool = not psc.atEnd,
    currentKeyCb: proc(): Option[seq[byte]] = psc.peek(),
    stepCb: proc() = discard psc.next(),
    seekCb: proc(target: seq[byte]) = psc.seek(target),
    skipGroupCb: proc(ge: int) = discard psc.next(),
    invalidateCb: proc() = psc.atEnd = true,
  )

proc treapToNimCursor*(tc: TreapCursor): NimCursor =
  NimCursor(
    isValidCb: proc(): bool = not tc.atEnd,
    currentKeyCb: proc(): Option[seq[byte]] = tc.peek(),
    stepCb: proc() = discard tc.next(),
    seekCb: proc(target: seq[byte]) = tc.seek(target),
    skipGroupCb: proc(ge: int) = discard tc.next(),
    invalidateCb: proc() = tc.atEnd = true,
  )

# ── New streaming scan entry point ──

proc openScanCursor*(kv: KVStore; cf: int): MergedCursor =
  ## Open a lazy merged cursor over PageStore + flush snapshot + live memtable.
  ## No prefix — iterates all keys in the CF.
  var sources: seq[NimCursor] = @[]

  let psCursor = newPageStoreCursor(kv.ps, cf)
  if not psCursor.atEnd:
    sources.add pageStoreToNimCursor(psCursor)

  if kv.flushSnap != 0:
    let flushRoot =
      if kv.flushSnap.int <= kv.mt.hnd.snaps.len and kv.mt.hnd.snaps[kv.flushSnap.int - 1].inUse:
        kv.mt.hnd.snaps[kv.flushSnap.int - 1].roots[cf]
      else: nil
    if flushRoot != nil:
      let tc = newTreapCursor(flushRoot)
      if not tc.atEnd:
        sources.add treapToNimCursor(tc)

  let liveSnap = kv.mt.snapshot()
  let liveRoot =
    if liveSnap == 0: kv.mt.hnd.live[cf]
    elif liveSnap.int <= kv.mt.hnd.snaps.len and kv.mt.hnd.snaps[liveSnap.int - 1].inUse:
      kv.mt.hnd.snaps[liveSnap.int - 1].roots[cf]
    else: nil
  if liveRoot != nil:
    let tc = newTreapCursor(liveRoot)
    if not tc.atEnd:
      sources.add treapToNimCursor(tc)

  result = newMergedCursor(sources)