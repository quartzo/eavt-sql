## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.

import std/[tables, strutils, os, options]
import page_store

import std/locks
import std/atomics

import nim_memtable/treap_backend as mt_be
import treap_cursor
import page_cursor
import query/cursor
export cursor

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore

type
  KVStore* = ref object
    ps*: ptr PageStoreInner
    mt*: mt_be.MemTable
    mtSize*: uint64
    flushRoots*: seq[mt_be.TreapNode]
    lock: Lock
    config*: Table[string, string]
    path*: string
    readOnly*: bool
    numCf*: int
    flushThreshold*: uint64
    gcMaxAgeSecs*: uint64
    gcMaxRootCount*: int
    # ── Background-flush coordination ──
    # Monotonic counters: bumped under `lock`. "In flight" ≡ start > end.
    flushStart: Atomic[uint64]
    flushEnd: Atomic[uint64]
    # Set by requestFlush while a flush is running; the running flush
    # clears it and re-iterates, so a request made mid-flush is honoured.
    flushPending: Atomic[bool]
    # Spawned by requestFlush when no flush is in flight. nil = async
    # requests are no-ops (background not wired up — e.g. unit tests).
    onFlushRequest*: proc() {.gcsafe.}
# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations

# ═══════════════════════════════════════════════════════════════════════════════

proc requestFlush*(kv: KVStore) {.gcsafe.}
proc flushSync*(kv: KVStore) {.gcsafe.}
proc runBackgroundFlush*(kv: KVStore) {.gcsafe.}

# ═══════════════════════════════════════════════════════════════════════════════

proc newKVStore*(config: Table[string, string]): KVStore =
  let readOnly = config.getOrDefault("read_only", "false") == "true"
  let ps = newPageStore(config)
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
          let cf = byte(data[pos])
          pos += klen
          let vlen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + vlen > data.len: break
          pos += vlen
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

proc close*(kv: KVStore) {.gcsafe.} =
  if kv != nil:
    kv.lock.withLock:
      if kv.ps != nil: closePageStore(kv.ps); kv.ps = nil

proc put*(kv: KVStore; cf: int; key: openArray[byte]) {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var needsFlush = false
  kv.lock.withLock:
    kv.mtSize = kv.mt.put(cf, k)
    if kv.mtSize >= kv.flushThreshold: needsFlush = true
    if kv.path.len > 0 and kv.path != ":memory:" and not kv.readOnly:
      try:
        let journalPath = kv.path / "journal" / "journal"
        createDir(parentDir(journalPath))
        var f = open(journalPath, fmAppend)
        var jk = newSeq[byte](1 + key.len)
        jk[0] = byte(cf)
        if key.len > 0: copyMem(addr jk[1], unsafeAddr key[0], key.len)
        let totKlen = 1 + key.len
        var hdr = newSeq[byte](4 + totKlen + 4 + 1)
        hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
        hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
        copyMem(addr hdr[4], addr jk[0], totKlen)
        hdr[4 + totKlen] = 0; hdr[5 + totKlen] = 0; hdr[6 + totKlen] = 0; hdr[7 + totKlen] = 1
        hdr[8 + totKlen] = 0
        discard f.writeBytes(hdr, 0, hdr.len)
        f.close()
      except: discard
  if needsFlush: kv.requestFlush()

proc get*(kv: KVStore; cf: int; key: openArray[byte]): bool {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var liveRoot, flushRoot: mt_be.TreapNode
  kv.lock.withLock:
    liveRoot = kv.mt.hnd.live[cf]
    if kv.flushRoots.len > 0:
      flushRoot = kv.flushRoots[cf]
  if liveRoot != nil and mt_be.containsKey(liveRoot, k): return true
  if flushRoot != nil and mt_be.containsKey(flushRoot, k): return true
  keyExists(kv.ps[], cf, k)

proc flush*(kv: KVStore) {.gcsafe.} =
  if kv.readOnly: return
  var roots: seq[mt_be.TreapNode]
  kv.lock.withLock:
    if kv.flushRoots.len > 0: return
    roots = kv.mt.hnd.live
    kv.mt.clear(); kv.mtSize = 0
    kv.flushRoots = roots
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<kv.numCf:
    if roots[cf] != nil:
      var keys: seq[seq[byte]] = @[]
      let tc = newTreapCursor(roots[cf])
      while not tc.atEnd:
        let k = tc.next()
        if k.isSome: keys.add(k.get)
      if keys.len > 0: keysByCf.add (cf, keys)
  if keysByCf.len > 0: commitMerge(kv.ps[], keysByCf, true)
  kv.lock.withLock:
    kv.flushRoots = @[]; kv.mtSize = 0

# ── Background-flush API ──
#
# Two flavours:
#   requestFlush()       — async, fire-and-forget. Arms a background flush
#                          (bumps flushStart) and invokes onFlushRequest.
#   flushSync()          — synchronous. Waits for any in-flight flush via
#                          100ms polling (no Cond), then runs one inline,
#                          re-iterating if flushPending was set meanwhile.
# runBackgroundFlush() is the loop spawned by onFlushRequest: it drains the
# MemTable and re-iterates as long as flushPending is set on completion.
#
# Invariant: only one flush runs at a time. Background and sync mutually
# exclude via "flushStart > flushEnd" (the in-flight slot); each takes the
# slot by bumping flushStart before doing any work.

proc requestFlush*(kv: KVStore) {.gcsafe.} =
  ## Ask for a background flush. Idempotent. If a flush is already running,
  ## marks flushPending so the runner re-iterates; otherwise arms a fresh
  ## flush (flushStart++) and invokes onFlushRequest. No-op when
  ## onFlushRequest is nil (e.g. unit tests).
  kv.flushPending.store(true, moRelaxed)
  var cb: proc() {.gcsafe.} = nil
  kv.lock.withLock:
    if kv.flushStart.load(moRelaxed) == kv.flushEnd.load(moRelaxed) and
       kv.onFlushRequest != nil:
      discard kv.flushStart.fetchAdd(1, moRelaxed)
      cb = kv.onFlushRequest
  if cb != nil: cb()

proc runBackgroundFlush*(kv: KVStore) {.gcsafe.} =
  ## Background flush loop. Spawned by onFlushRequest. Drains the MemTable
  ## and, if flushPending was set while running, re-iterates so concurrent
  ## writes are not lost. Caller must NOT hold `kv.lock`.
  while true:
    kv.flush()
    var cont = false
    kv.lock.withLock:
      discard kv.flushEnd.fetchAdd(1, moRelaxed)
      if kv.flushPending.load(moRelaxed):
        kv.flushPending.store(false, moRelaxed)
        discard kv.flushStart.fetchAdd(1, moRelaxed)
        cont = true
    if not cont: break

proc flushSync*(kv: KVStore) {.gcsafe.} =
  ## Synchronous flush. Waits for any in-flight flush (100ms polling), then
  ## runs one inline, re-iterating if flushPending was set meanwhile. On
  ## return, every write prior to the call is durable.
  while true:
    var inFlight = false
    kv.lock.withLock:
      inFlight = kv.flushStart.load(moRelaxed) > kv.flushEnd.load(moRelaxed)
    if not inFlight: break
    sleep(100)
  kv.lock.withLock:
    discard kv.flushStart.fetchAdd(1, moRelaxed)
    kv.flushPending.store(false, moRelaxed)
  while true:
    kv.flush()
    var cont = false
    kv.lock.withLock:
      discard kv.flushEnd.fetchAdd(1, moRelaxed)
      if kv.flushPending.load(moRelaxed):
        kv.flushPending.store(false, moRelaxed)
        discard kv.flushStart.fetchAdd(1, moRelaxed)
        cont = true
    if not cont: break

proc batchWrite*(kv: KVStore; ops: openArray[byte]) {.gcsafe.} =
  var needsFlush = false
  kv.lock.withLock:
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
    if kv.mtSize >= kv.flushThreshold: needsFlush = true
  if needsFlush: kv.requestFlush()

proc memtableSize*(kv: KVStore): uint64 {.gcsafe.} = kv.mtSize

# ── Streaming scan entry point ──

proc openScanCursor*(kv: KVStore; cf: int): MergedCursor {.gcsafe.} =
  var sources: seq[Cursor] = @[]

  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: mt_be.TreapNode

  kv.lock.withLock:
    let tree = kv.ps[].trees[cf]
    psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
    if kv.flushRoots.len > 0:
      flushRoot = kv.flushRoots[cf]
    liveRoot = kv.mt.hnd.live[cf]

  if psSnap.rootUuid != default(array[16, byte]):
    sources.add pageStoreCursor(PageStoreCursor(
      s: kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height))

  if flushRoot != nil:
    let tc = newTreapCursor(flushRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  if liveRoot != nil:
    let tc = newTreapCursor(liveRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  result = newMergedCursor(sources)
