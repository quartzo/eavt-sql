## transactor.nim — Nim Transactor (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.
## Implements all KVStoreEngine operations via C-ABI vtable.

import std/[tables, strformat, strutils, times, monotimes, options, os]
import ./abi
import ./backend
import ./spinlock

# MemTable functions — compiled into the same .a, accessed via importc
proc nim_memtable_open*(num_cf: cuint; errOut: ptr cint): pointer
    {.importc: "nim_memtable_open", cdecl.}
proc nim_memtable_close*(vt: pointer)
    {.importc: "nim_memtable_close", cdecl.}

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
# KVStoreInner — the transactor state
# ═══════════════════════════════════════════════════════════════════════════════

type
  KVStoreInner = object
    ps: ptr PageStoreInner        # page store (already opened)
    mt: MtVtablePtr      # memtable handle
    mtSize: uint64                # approximate memtable byte size
    flushSnap: uint64             # snapshot id during active flush (0 = none)
    lock: SpinLock                # guards all state
    config: Table[string, string] # parsed config
    path: string
    readOnly: bool
    numCf: int
    flushThreshold: uint64    # bytes
    gcMaxAgeSecs: uint64      # max root age before GC
    gcMaxRootCount: int       # max root count before GC

  MergeSourceKind = enum
    mskPageStore
    mskMemTable

  MergeSource = object
    case kind: MergeSourceKind
    of mskPageStore:
      keys: seq[seq[byte]]
      idx: int
    of mskMemTable:
      cursorId: uint64
      cursorVt: MtVtablePtr

# ═══════════════════════════════════════════════════════════════════════════════
# Merge — k-way heap merge of sorted sources
# ═══════════════════════════════════════════════════════════════════════════════

proc mergeSources(sources: var seq[MergeSource]; endBound: seq[byte];
                   limit: int = -1): seq[seq[byte]] =
  var heap: MinHeap
  # Prime: push first key from each valid source
  for i, src in sources.mpairs:
    case src.kind
    of mskPageStore:
      if src.idx < src.keys.len:
        heap.push((src.keys[src.idx], i))
    of mskMemTable:
      var keyPtr: pointer = nil
      var keyLen: csize_t = 0
      var valid: cint = 0
      var err: cint
      discard src.cursorVt.cursorNext(src.cursorVt.handle, src.cursorId,
                                       addr keyPtr, addr keyLen, addr valid, addr err)
      if valid != 0 and keyPtr != nil:
        var k = newSeq[byte](keyLen.int)
        copyMem(addr k[0], keyPtr, keyLen.int)
        src.cursorVt.freeBuf(keyPtr)
        heap.push((k, i))

  result = @[]
  var lastKey: seq[byte] = @[]
  while heap.len > 0 and (limit < 0 or result.len < limit):
    let (key, srcIdx) = heap.pop()
    # Check end bound (keys must be <= endBound)
    if cmpSeq(key, endBound) > 0:
      break
    # Deduplicate
    if key == lastKey:
      lastKey = key
      # Advance source and continue
      var src = addr sources[srcIdx]
      case src.kind
      of mskPageStore:
        inc src.idx
        if src.idx < src.keys.len:
          heap.push((src.keys[src.idx], srcIdx))
      of mskMemTable:
        var keyPtr: pointer = nil
        var keyLen: csize_t = 0
        var valid: cint = 0
        var err: cint
        discard src.cursorVt.cursorNext(src.cursorVt.handle, src.cursorId,
                                         addr keyPtr, addr keyLen, addr valid, addr err)
        if valid != 0 and keyPtr != nil:
          var nextK = newSeq[byte](keyLen.int)
          copyMem(addr nextK[0], keyPtr, keyLen.int)
          src.cursorVt.freeBuf(keyPtr)
          heap.push((nextK, srcIdx))
      continue
    lastKey = key
    result.add key
    # Advance source
    var src = addr sources[srcIdx]
    case src.kind
    of mskPageStore:
      inc src.idx
      if src.idx < src.keys.len:
        heap.push((src.keys[src.idx], srcIdx))
    of mskMemTable:
      var keyPtr: pointer = nil
      var keyLen: csize_t = 0
      var valid: cint = 0
      var err: cint
      discard src.cursorVt.cursorNext(src.cursorVt.handle, src.cursorId,
                                       addr keyPtr, addr keyLen, addr valid, addr err)
      if valid != 0 and keyPtr != nil:
        var nextK = newSeq[byte](keyLen.int)
        copyMem(addr nextK[0], keyPtr, keyLen.int)
        src.cursorVt.freeBuf(keyPtr)
        heap.push((nextK, srcIdx))

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

proc kvPut(s: var KVStoreInner; cf: int; key: seq[byte]) =
  var outSize: uint64 = 0
  var err: cint
  discard s.mt.put(s.mt.handle, cf.cuint, cast[ptr Byte](addr key[0]),
                    key.len.csize_t, addr outSize, addr err)
  s.mtSize = outSize

proc kvGet(s: var KVStoreInner; cf: int; key: seq[byte]): bool =
  # Check live memtable
  var snap: uint64 = 0
  var err: cint
  discard s.mt.snapshot(s.mt.handle, addr snap, addr err)
  var present: cint = 0
  discard s.mt.contains(s.mt.handle, snap, cf.cuint,
                         cast[ptr Byte](addr key[0]), key.len.csize_t,
                         addr present, addr err)
  s.mt.snapshotFree(s.mt.handle, snap)
  if present != 0: return true

  # Check flush snap
  if s.flushSnap != 0:
    discard s.mt.contains(s.mt.handle, s.flushSnap, cf.cuint,
                           cast[ptr Byte](addr key[0]), key.len.csize_t,
                           addr present, addr err)
    if present != 0: return true

  # Check page store
  return keyExists(s.ps[], cf, key)

proc buildScanSources(s: var KVStoreInner; cf: int;
                       prefix: seq[byte]): seq[MergeSource] =
  var err: cint
  # 1. Page store source
  let psKeys = getKeysInPrefix(s.ps[], cf, prefix)
  if psKeys.len > 0:
    result.add MergeSource(kind: mskPageStore, keys: psKeys, idx: 0)

  # 2. Flush snapshot
  if s.flushSnap != 0:
    var cursorId: uint64 = 0
    let rc = s.mt.scan(s.mt.handle, s.flushSnap, cf.cuint,
                        if prefix.len > 0: cast[ptr Byte](addr prefix[0]) else: nil,
                        prefix.len.csize_t, 0.cint, addr cursorId, addr err)
    if rc == 0:
      result.add MergeSource(kind: mskMemTable, cursorId: cursorId,
                              cursorVt: s.mt)

  # 3. Live memtable
  var liveSnap: uint64 = 0
  var liveErr: cint = 0
  discard s.mt.snapshot(s.mt.handle, addr liveSnap, addr liveErr)
  var cursorId: uint64 = 0
  let rc = s.mt.scan(s.mt.handle, liveSnap, cf.cuint,
                      if prefix.len > 0: cast[ptr Byte](addr prefix[0]) else: nil,
                      prefix.len.csize_t, 0.cint, addr cursorId, addr err)
  if rc == 0:
    result.add MergeSource(kind: mskMemTable, cursorId: cursorId,
                            cursorVt: s.mt)

proc kvScan(s: var KVStoreInner; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  var sources = buildScanSources(s, cf, prefix)
  let endB = prefixEnd(prefix)
  return mergeSources(sources, endB)

proc kvScanReverse(s: var KVStoreInner; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  var result = kvScan(s, cf, prefix)
  var i = 0; var j = result.len - 1
  while i < j:
    swap(result[i], result[j])
    inc i; dec j
  return result

proc kvFlush(s: var KVStoreInner): bool =
  if s.readOnly: return false
  if s.flushSnap != 0: return false  # flush already in progress

  let numCf = s.numCf

  # Snapshot + clear memtable ONCE (not per CF)
  var err: cint
  discard s.mt.snapshot(s.mt.handle, addr s.flushSnap, addr err)
  discard s.mt.clear(s.mt.handle, addr err)
  s.mtSize = 0

  # Scan snapshot for each CF
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<numCf:

    # Scan the snapshot to get all keys for this CF
    var outBuf: pointer = nil
    var outLen: csize_t = 0
    let rc = s.mt.scanPrefix(s.mt.handle, s.flushSnap, cf.cuint, nil, 0.csize_t,
                              0.cint, addr outBuf, addr outLen, addr err)
    if rc != 0 or outBuf == nil: continue

    var keys: seq[seq[byte]] = @[]
    var pos = 0
    while pos + 4 <= outLen.int:
      let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                   uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                   uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                   uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
      pos += 4
      if pos + klen > outLen.int: break
      keys.add newSeq[byte](klen)
      copyMem(addr keys[^1][0], addr cast[ptr UncheckedArray[byte]](outBuf)[pos], klen)
      pos += klen
    s.mt.freeBuf(outBuf)
    if keys.len > 0:
      keysByCf.add (cf, keys)

  if keysByCf.len > 0:
    commitMerge(s.ps[], keysByCf, true)
    # Truncate journal after successful flush (data now in page store)
    if s.path.len > 0:
      let journalPath = s.path / "journal" / "journal"
      if fileExists(journalPath):
        try: removeFile(journalPath)
        except: discard
  s.flushSnap = 0
  s.mtSize = 0
  return true

proc kvGCFull(s: var KVStoreInner; maxAgeSecs: uint64; maxRootCount: int;
               dryRun: bool): seq[byte] =
  return gcFull(s.ps[], maxAgeSecs, maxRootCount, dryRun)

# ═══════════════════════════════════════════════════════════════════════════════
# C-ABI wrappers
# ═══════════════════════════════════════════════════════════════════════════════

proc kvPutC(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
             errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr KVStoreInner](h)
  s.lock.withLock:
    try:
      var k = newSeq[byte](klen.int)
      if klen.int > 0: copyMem(addr k[0], key, klen.int)
      kvPut(s[], cf.int, k)
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvBatchWrite(h: pointer; ops: ptr Byte; olen: csize_t;
                   errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr KVStoreInner](h)
  s.lock.withLock:
    try:
      # Write to memtable
      var outSize: uint64 = 0
      var merr: cint
      let rc = s.mt.batch(s.mt.handle, ops, olen, addr outSize, addr merr)
      if rc != 0:
        setErr(errOut, merr); return -1
      s.mtSize = outSize
      # Journal each key-value entry for crash recovery
      if s.path.len > 0 and not s.readOnly:
        let journalPath = s.path / "journal" / "journal"
        try:
          createDir(parentDir(journalPath))
          var f: File
          if open(f, journalPath, fmAppend):
            var pos = 0
            while pos + 1 <= olen.int:
              let cf = cast[ptr UncheckedArray[byte]](ops)[pos]
              inc pos
              if pos + 4 > olen.int: break
              let klen = int(uint32(cast[ptr UncheckedArray[byte]](ops)[pos]) shl 24 or
                             uint32(cast[ptr UncheckedArray[byte]](ops)[pos+1]) shl 16 or
                             uint32(cast[ptr UncheckedArray[byte]](ops)[pos+2]) shl 8 or
                             uint32(cast[ptr UncheckedArray[byte]](ops)[pos+3]))
              pos += 4
              if pos + klen > olen.int: break
              let keyStart = pos
              pos += klen
              # Write journal entry: [u32 klen][cf+key][u32 1][flag=0]
              var jentry = newSeq[byte](4 + 1 + klen + 4 + 1)
              jentry[0] = byte((1 + klen) shr 24); jentry[1] = byte(((1 + klen) shr 16) and 0xFF)
              jentry[2] = byte(((1 + klen) shr 8) and 0xFF); jentry[3] = byte((1 + klen) and 0xFF)
              jentry[4] = cf
              copyMem(addr jentry[5], addr cast[ptr UncheckedArray[byte]](ops)[keyStart], klen)
              jentry[5 + klen + 0] = 0; jentry[5 + klen + 1] = 0
              jentry[5 + klen + 2] = 0; jentry[5 + klen + 3] = 1 # vlen = 1
              jentry[5 + klen + 4] = 0 # flag = 0
              discard f.writeBytes(jentry, 0, jentry.len)
            close(f)
        except: discard
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvGetC(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
             outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr KVStoreInner](h)
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
  var s = cast[ptr KVStoreInner](h)
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
  var s = cast[ptr KVStoreInner](h)
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
  var s = cast[ptr KVStoreInner](h)
  s.lock.withLock:
    try:
      discard kvFlush(s[])
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvGCFullC(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
                dryRun: cint; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr KVStoreInner](h)
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
  var s = cast[ptr KVStoreInner](h)
  s.lock.withLock:
    try:
      outSize[] = s.mtSize
      setErr(errOut, ErrOk); return 0
    except:
      setErr(errOut, ErrIo); return -1

proc kvCloseC(h: pointer; errOut: ptr cint): cint {.cdecl.} =
  var s = cast[ptr KVStoreInner](h)
  s.lock.withLock:
    try:
      # Close memtable
      if s.mt != nil:
        nim_memtable_close(cast[pointer](s.mt))
        s.mt = nil
      # Close page store
      psClose(s.ps)
      # ARC cleanup before raw free
      s.config = initTable[string, string]()
      s.path = ""
      setErr(errOut, ErrOk)
    except:
      setErr(errOut, ErrIo)
  deallocShared(h)
  return 0

# ═══════════════════════════════════════════════════════════════════════════════
# openKvStore — create and initialize
# ═══════════════════════════════════════════════════════════════════════════════

proc openKvStore*(keys, vals: CStringArr; count: cint;
                   errOut: ptr cint): NimKVStoreVtablePtr =
  let config = parseConfig(keys, vals, count.csize_t)
  let readOnly = config.getOrDefault("read_only", "false") == "true"

  # Open page store
  let ps = openPageStore(keys, vals, count, errOut)
  if ps == nil:
    return nil

  # Open memtable
  var mtErr: cint
  let mt = cast[MtVtablePtr](nim_memtable_open(4.cuint, addr mtErr))
  if mt == nil:
    psClose(cast[ptr PageStoreInner](ps.handle))
    freeVtable(ps)
    setErr(errOut, ErrIo)
    return nil

  let s = cast[ptr KVStoreInner](allocShared0(sizeof(KVStoreInner)))
  s.ps = cast[ptr PageStoreInner](ps.handle)
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
  if s.path.len > 0 and not readOnly:
    let journalPath = s.path / "journal" / "journal"
    if fileExists(journalPath):
      try:
        let data = readFile(journalPath)
        var pos = 0
        while pos + 4 <= data.len:
          let klen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + klen + 4 > data.len: break
          let jkey = data[pos..<pos + klen]
          pos += klen
          let vlen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + vlen > data.len: break
          pos += vlen  # skip value (flag byte)
          # Replay: batch write to memtable. Format: [cf][u32 klen][key]
          var ops = newSeq[byte](1 + 4 + (klen - 1))
          ops[0] = byte(jkey[0])  # cf byte
          ops[1] = byte(((klen - 1) shr 24) and 0xFF)
          ops[2] = byte(((klen - 1) shr 16) and 0xFF)
          ops[3] = byte(((klen - 1) shr 8) and 0xFF)
          ops[4] = byte((klen - 1) and 0xFF)
          copyMem(addr ops[5], addr jkey[1], klen - 1)
          var outSz: uint64 = 0; var merr: cint
          discard s.mt.batch(s.mt.handle, addr ops[0], ops.len.csize_t, addr outSz, addr merr)
          s.mtSize = outSz
      except: discard

  let vt = newKVVtable()
  vt.handle = s
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
