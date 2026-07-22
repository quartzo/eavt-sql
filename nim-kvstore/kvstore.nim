## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.
## Implements all KVStoreEngine operations via C-ABI vtable.

import std/[tables, strformat, strutils, times, monotimes, options, os]
import ./abi
import ./backend
import ./spinlock

import nim_memtable/backend as mt_be

# ═══════════════════════════════════════════════════════════════════════════════
# Simple min-heap for (seq[byte], int) using cmpSeq
# ═══════════════════════════════════════════════════════════════════════════════

import ./backend  # for cmpSeq (re-import for clarity)

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
    lock: SpinLock
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

proc kvPut(s: var S; cf: int; key: seq[byte]) =
  s.mtSize = s.mt.put(cf, key)

proc kvGet(s: var S; cf: int; key: seq[byte]): bool =
  if s.mt.contains(0, cf, key): return true
  if s.flushSnap != 0 and s.mt.contains(s.flushSnap, cf, key): return true
  return keyExists(s.ps[], cf, key)

proc buildScanSources(s: var S; cf: int;
                       prefix: seq[byte]): seq[MergeSource] =
  # 1. Page store source
  let psKeys = getKeysInPrefix(s.ps[], cf, prefix)
  if psKeys.len > 0:
    result.add MergeSource(kind: mskPageStore, keys: psKeys, idx: 0)

  # 2. Flush snapshot — eager materialize
  if s.flushSnap != 0:
    let snapKeys = s.mt.scanAll(s.flushSnap, cf, prefix, false)
    if snapKeys.len > 0:
      result.add MergeSource(kind: mskMemTable, keys: snapKeys, idx: 0)

  # 3. Live memtable — materialize eagerly
  let liveSnap = s.mt.snapshot()
  let liveKeys = s.mt.scanAll(liveSnap, cf, prefix, false)
  s.mt.snapshotFree(liveSnap)
  if liveKeys.len > 0:
    result.add MergeSource(kind: mskMemTable, keys: liveKeys, idx: 0)

proc kvScan(s: var S; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  var sources = buildScanSources(s, cf, prefix)
  let endB = prefixEnd(prefix)
  return mergeSources(sources, endB)

proc kvScanReverse(s: var S; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  var result = kvScan(s, cf, prefix)
  var i = 0; var j = result.len - 1
  while i < j:
    swap(result[i], result[j])
    inc i; dec j
  return result

proc kvFlush(s: var S): bool =
  if s.readOnly: return false
  if s.flushSnap != 0: return false
  let numCf = s.numCf
  s.flushSnap = s.mt.snapshot()
  s.mt.clear()
  s.mtSize = 0
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<numCf:
    let keys = s.mt.scanAll(s.flushSnap, cf, @[], false)
    if keys.len > 0: keysByCf.add (cf, keys)
  if keysByCf.len > 0:
    commitMerge(s.ps[], keysByCf, true)
  s.flushSnap = 0
  s.mtSize = 0
  return true

proc kvGCFull(s: var S; maxAgeSecs: uint64; maxRootCount: int;
               dryRun: bool): seq[byte] =
  return gcFull(s.ps[], maxAgeSecs, maxRootCount, dryRun)

# ── Forward declarations ──
proc kvJournalAppendC*(h: pointer; key: ptr Byte; klen: csize_t;
    `val`: ptr Byte; vlen: csize_t; errOut: ptr cint): cint {.exportc, cdecl.}

# ═══════════════════════════════════════════════════════════════════════════════
# C-ABI wrappers
# ═══════════════════════════════════════════════════════════════════════════════

proc kvPutC(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
             errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  if s.readOnly: setErr(errOut, ErrReadOnly); return -1
  s.lock.withLock:
    try:
      var k = newSeq[byte](klen.int)
      if klen.int > 0: copyMem(addr k[0], key, klen.int)
      kvPut(s[], cf.int, k)
      # Journal for crash recovery
      if s.path.len > 0 and s.path != ":memory:" and not s.readOnly:
        var jk = newSeq[byte](1 + klen.int)
        jk[0] = byte(cf)
        if klen.int > 0:
          copyMem(cast[pointer](cast[int](addr jk[0]) + 1), key, klen.int)
        var flag: byte = 0
        discard kvJournalAppendC(h, addr jk[0], jk.len.csize_t, addr flag, 1, errOut)
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvBatchWrite(h: pointer; ops: ptr Byte; olen: csize_t;
                   errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      # Journal for crash recovery (TODO: also persist AEVT entries correctly)
      if s.path.len > 0 and s.path != ":memory:" and not s.readOnly:
        var journalPath = s.path / "journal" / "journal"
        try:
          createDir(parentDir(journalPath))
          var f = open(journalPath, fmAppend)
          let raw = cast[ptr UncheckedArray[byte]](ops)
          var pos: int = 0
          while pos + 5 <= olen.int:
            let cf = raw[pos]
            let klenU32 = uint32(raw[pos+1]) shl 24 or uint32(raw[pos+2]) shl 16 or
                          uint32(raw[pos+3]) shl 8 or uint32(raw[pos+4])
            let klen = klenU32.int
            var hdr = newSeq[byte](4 + 1 + klen + 4 + 1)
            let totKlen = 1 + klen
            hdr[0] = byte(totKlen shr 24); hdr[1] = byte((totKlen shr 16) and 0xFF)
            hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
            hdr[4] = cf
            if klen > 0:
              copyMem(addr hdr[5], addr raw[pos+5], klen)
            hdr[5+klen] = 0; hdr[6+klen] = 0; hdr[7+klen] = 0; hdr[8+klen] = 1
            hdr[9+klen] = 0  # flag byte
            discard f.writeBytes(hdr, 0, hdr.len)
            pos += 5 + klen
          close(f)
        except: discard
      # Write to memtable
      var o: seq[byte] = newSeq[byte](olen)
      if olen > 0: copyMem(addr o[0], ops, olen)
      s.mtSize = s.mt.batch(o)
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvGetC(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
             outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      var k = newSeq[byte](klen.int)
      if klen.int > 0: copyMem(addr k[0], key, klen.int)
      outPresent[] = if kvGet(s[], cf.int, k): 1 else: 0
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvScanReverseC(h: pointer; cf: cuint; prefix: ptr Byte; plen: csize_t;
                     outBuf: ptr pointer; outLen: ptr csize_t;
                     errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      var pfx = newSeq[byte](plen.int)
      if plen.int > 0: copyMem(addr pfx[0], prefix, plen.int)
      let keys = kvScanReverse(s[], cf.int, pfx)
      var packed: seq[byte] = @[]
      for k in keys:
        let kl = k.len.uint32
        packed.add byte(kl shr 24)
        packed.add byte((kl shr 16) and 0xFF)
        packed.add byte((kl shr 8) and 0xFF)
        packed.add byte(kl and 0xFF)
        packed.add k
      let buf = allocByteBuf(packed.len)
      if packed.len > 0: copyMem(buf, addr packed[0], packed.len)
      outBuf[] = buf; outLen[] = packed.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvScanC(h: pointer; cf: cuint; prefix: ptr Byte; plen: csize_t;
              outBuf: ptr pointer; outLen: ptr csize_t;
              errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      var pfx = newSeq[byte](plen.int)
      if plen.int > 0: copyMem(addr pfx[0], prefix, plen.int)
      let keys = kvScan(s[], cf.int, pfx)
      # Pack into [u32 klen][key] format
      var packed: seq[byte] = @[]
      for k in keys:
        let kl = k.len.uint32
        packed.add byte(kl shr 24)
        packed.add byte((kl shr 16) and 0xFF)
        packed.add byte((kl shr 8) and 0xFF)
        packed.add byte(kl and 0xFF)
        packed.add k
      let buf = allocByteBuf(packed.len)
      if packed.len > 0: copyMem(buf, addr packed[0], packed.len)
      outBuf[] = buf; outLen[] = packed.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvFlushC(h: pointer; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  if s.readOnly: setErr(errOut, ErrReadOnly); return -1
  s.lock.withLock:
    try:
      if not kvFlush(s[]): setErr(errOut, ErrReadOnly); return -1
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvGCFullC(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
                dryRun: cint; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      let result = kvGCFull(s[], maxAgeSecs, maxRootCount.int, dryRun != 0)
      let buf = allocByteBuf(result.len)
      if result.len > 0: copyMem(buf, addr result[0], result.len)
      outBuf[] = buf; outLen[] = result.len.csize_t
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvMemtableSizeC(h: pointer; outSize: ptr uint64;
                      errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      outSize[] = s.mtSize
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvJournalAppendC*(h: pointer; key: ptr Byte; klen: csize_t;
    `val`: ptr Byte; vlen: csize_t;
    errOut: ptr cint): cint {.exportc: "kvJournalAppendC", cdecl.} =
  var s = cast[ptr S](h)
  if s.path in ["", ":memory:"] or s.config.getOrDefault("backend", "") == "memory":
    setErr(errOut, ErrConfig); return -1
  let journalPath = s.path / "journal" / "journal"
  try:
    createDir(parentDir(journalPath))
    var f: File
    if open(f, journalPath, fmAppend):
      var hdr = newSeq[byte](4 + klen.int + 4 + vlen.int)
      let ku = klen.uint32
      hdr[0] = byte(ku shr 24); hdr[1] = byte((ku shr 16) and 0xFF)
      hdr[2] = byte((ku shr 8) and 0xFF); hdr[3] = byte(ku and 0xFF)
      copyMem(addr hdr[4], key, klen.int)
      let vu = vlen.uint32; let voff = 4 + klen.int
      hdr[voff] = byte(vu shr 24); hdr[voff+1] = byte((vu shr 16) and 0xFF)
      hdr[voff+2] = byte((vu shr 8) and 0xFF); hdr[voff+3] = byte(vu and 0xFF)
      if vlen.int > 0:
        copyMem(cast[pointer](cast[int](addr hdr[0]) + voff + 4), `val`, vlen.int)
      discard f.writeBytes(hdr, 0, hdr.len); close(f)
    setErr(errOut, ErrOk); return 0
  except: setErr(errOut, ErrIo); return -1

proc kvJournalReadC*(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
    errOut: ptr cint): cint {.exportc: "kvJournalReadC", cdecl.} =
  var s = cast[ptr S](h)
  if s.path in ["", ":memory:"] or s.config.getOrDefault("backend", "") == "memory":
    setErr(errOut, ErrConfig); return -1
  let journalPath = s.path / "journal" / "journal"
  try:
    if not fileExists(journalPath):
      outBuf[] = nil; outLen[] = 0; setErr(errOut, ErrOk); return 0
    let data = readFile(journalPath)
    let buf = allocByteBuf(data.len)
    if data.len > 0: copyMem(buf, addr data[0], data.len)
    outBuf[] = buf; outLen[] = data.len.csize_t
    setErr(errOut, ErrOk); return 0
  except: setErr(errOut, ErrIo); return -1

proc kvJournalTruncateC*(h: pointer; errOut: ptr cint): cint
    {.exportc: "kvJournalTruncateC", cdecl.} =
  var s = cast[ptr S](h)
  if s.path.len == 0: setErr(errOut, ErrConfig); return -1
  let journalPath = s.path / "journal" / "journal"
  try:
    if fileExists(journalPath): removeFile(journalPath)
    setErr(errOut, ErrOk); return 0
  except: setErr(errOut, ErrIo); return -1

proc kvCloseC(h: pointer; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr S](h)
  s.lock.withLock:
    try:
      # Close memtable
      if s.mt != nil:
        s.mt.close()
        s.mt = nil
      # Close page store
      closePageStore(s.ps)
      # ARC cleanup before raw free
      s.config = initTable[string, string]()
      s.path = ""
      GC_unref(cast[KVStore](s))
      setErr(errOut, ErrOk)
    except:
      setErr(errOut, ErrIo)
  return 0

# ═══════════════════════════════════════════════════════════════════════════════
# openKvStore — create and initialize
# ═══════════════════════════════════════════════════════════════════════════════

proc openKvStore*(keys, vals: CStringArr; count: cint;
                   errOut: ptr cint): NimKVStoreVtablePtr =
  let config = parseConfig(keys, vals, count.csize_t)
  let readOnly = config.getOrDefault("read_only", "false") == "true"

  # Open page store
  let ps = newPageStore(keys, vals, count, errOut)
  if ps == nil:
    return nil

  # Open memtable
  let mt = mt_be.newMemTable(4)
  if mt == nil:
    closePageStore(ps)
    setErr(errOut, ErrIo)
    return nil

  let s = KVStore()
  GC_ref(s)  # keep alive past openKvStore return (handle is raw pointer)
  s.ps = ps
  s.mt = mt
  s.mtSize = 0
  s.flushSnap = 0
  s.config = config
  s.path = config.getOrDefault("path", ":memory:")
  s.readOnly = readOnly
  s.numCf = 4
  s.flushThreshold = parseUInt(config.getOrDefault("flush_threshold", "67108864")).uint64
  s.gcMaxAgeSecs = parseUInt(config.getOrDefault("gc_max_age_secs", "43200")).uint64
  s.gcMaxRootCount = parseInt(config.getOrDefault("gc_max_root_count", "10"))
  initSpinLock(s.lock)

  # Replay journal into memtable (crash recovery)
  if s.path.len > 0 and s.path != ":memory:" and s.path != "":
    let journalPath = s.path / "journal" / "journal"
    if fileExists(journalPath):
      try:
        let data = readFile(journalPath)
        var pos = 0
        while pos + 4 <= data.len:
          let klen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + klen + 4 > data.len: discard
          let jkey = data[pos..<pos + klen]
          pos += klen
          let vlen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + vlen > data.len: discard
          pos += vlen  # skip flag byte
          # Replay: if EAVT key (20+ bytes), replay as CF 0
          # If short key (cf-prefixed), extract cf from first byte
          if klen >= 20:
            var ops = newSeq[byte](1 + 4 + klen)
            ops[0] = 0  # CF 0
            ops[1] = byte((klen shr 24) and 0xFF)
            ops[2] = byte((klen shr 16) and 0xFF)
            ops[3] = byte((klen shr 8) and 0xFF)
            ops[4] = byte(klen and 0xFF)
            copyMem(addr ops[5], addr jkey[0], klen)
            s.mtSize = s.mt.batch(ops)
          elif klen >= 1:
            let cf = byte(jkey[0])
            if cf <= 3:
              var ops = newSeq[byte](1 + 4 + (klen - 1))
              ops[0] = cf
              ops[1] = byte(((klen - 1) shr 24) and 0xFF)
              ops[2] = byte(((klen - 1) shr 16) and 0xFF)
              ops[3] = byte(((klen - 1) shr 8) and 0xFF)
              ops[4] = byte((klen - 1) and 0xFF)
              copyMem(addr ops[5], addr jkey[1], klen - 1)
              s.mtSize = s.mt.batch(ops)
      except: discard

  let vt = newKVVtable()
  vt.handle = cast[pointer](s)
  vt.put = kvPutC
  vt.batchWrite = kvBatchWrite
  vt.replay = kvBatchWrite  # same format for replay
  vt.get = kvGetC
  vt.scan = kvScanC
  vt.scanReverse = kvScanReverseC
  vt.flush = kvFlushC
  vt.gcFull = kvGCFullC
  vt.memtableSize = kvMemtableSizeC
  vt.close = kvCloseC
  vt.freeBuf = freeShared
  setErr(errOut, ErrOk)
  return vt

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native API (constructs + methods on KVStore ref)
# ══════════════════════════════════════════════════════════════════════════════


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
  initSpinLock(result.lock)
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
    let snapKeys = kv.mt.scanAll(kv.flushSnap, cf, pfx, false)
    if snapKeys.len > 0: sources.add MergeSource(kind: mskMemTable, keys: snapKeys, idx: 0)
  let liveSnap = kv.mt.snapshot()
  let liveKeys = kv.mt.scanAll(liveSnap, cf, pfx, false)
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
    let keys = kv.mt.scanAll(kv.flushSnap, cf, @[], false)
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

