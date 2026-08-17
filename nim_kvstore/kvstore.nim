## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.

import std/[tables, strutils, os, options, times, random]
import std/[osproc, exitprocs]
import page_store

import std/locks
import std/atomics

import nim_memtable/treap_backend as mt_be
import treap_cursor
import page_cursor
import query/cursor
import spawn
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
    ## When set, journal bytes (same format as the journal file) are handed
    ## to this sink instead of being written to the journal file inline —
    ## the async server buffers them on its event loop (group-commit) and
    ## writes/fsyncs via chronos_file. The sink is called under `kv.lock`.
    journalSink*: proc (data: seq[byte]) {.gcsafe, raises: [].}
    ## When true, close() removes the whole data directory (tests use it for
    ## their tempdir-per-store pattern).
    ownsPath*: bool
# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations

# ═══════════════════════════════════════════════════════════════════════════════

proc requestFlush*(kv: KVStore) {.gcsafe.}
proc flushSync*(kv: KVStore) {.gcsafe.}
proc runBackgroundFlush*(kv: KVStore) {.gcsafe.}

# ═══════════════════════════════════════════════════════════════════════════════

proc newKVStore*(config: Table[string, string]): KVStore =
  let readOnly = config.getOrDefault("read_only", "false") == "true"
  var cfg = config
  if not cfg.hasKey("num_cf"):
    cfg["num_cf"] = "64"  ## CFs 0-3: EAVT indexes (key-only). CFs 10+: key-value.
  if not cfg.hasKey("path") or cfg["path"].len == 0:
    return nil  # a local path is required (blob dir / journal / WAL)
  let ps = newPageStore(cfg)
  if ps == nil: return nil
  let numCf = parseInt(cfg["num_cf"])
  let mt = mt_be.newMemTable(numCf)
  if mt == nil: closePageStore(ps); return nil
  result = KVStore()
  result.ps = ps; result.mt = mt
  result.config = config
  result.path = cfg["path"]
  result.readOnly = readOnly
  result.numCf = numCf
  result.flushThreshold = parseUInt(config.getOrDefault("flush_threshold", "67108864")).uint64
  result.gcMaxAgeSecs = parseUInt(config.getOrDefault("gc_max_age_secs", "43200")).uint64
  result.gcMaxRootCount = parseInt(config.getOrDefault("gc_root_count", "10"))
  initLock(result.lock)
  initSpawn()
  # Replay journal
  block replay:
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
          # Journal record: [4B klen][cf + key][4B vlen][value]. Key-only CFs
          # (0-3, EAVT indexes): the op stream wants [cf][klen-1][key without
          # the cf byte]. The old code hard-coded cf=0 and kept the cf byte
          # inside the key, corrupting the replay for every CF but 0.
          if klen >= 1 and cf <= 3'u8:
            ops.add(cf); ops.add(byte(((klen-1) shr 24) and 0xFF))
            ops.add(byte(((klen-1) shr 16) and 0xFF)); ops.add(byte(((klen-1) shr 8) and 0xFF))
            ops.add(byte((klen-1) and 0xFF))
            for i in 1..<klen: ops.add(byte(data[pos - 4 - vlen - klen + i]))
        if ops.len > 0: result.mtSize = result.mt.batch(ops)
      except: discard

proc journalDeliver*(kv: KVStore; data: seq[byte]) {.gcsafe.} =
  ## Journal bytes (journal-file format) to the sink when installed, else
  ## best-effort append to the journal file. Called under `kv.lock`.
  if kv.journalSink != nil:
    kv.journalSink(data)
    return
  try:
    let journalPath = kv.path / "journal" / "journal"
    createDir(parentDir(journalPath))
    var f = open(journalPath, fmAppend)
    discard f.writeBytes(data, 0, data.len)
    f.close()
  except: discard

proc journaling(kv: KVStore): bool {.inline.} =
  kv.path.len > 0 and not kv.readOnly

# tempdirs handed out by newTempFileKVStore — swept at process exit so a
# test that forgets close() still does not leak its directory. threadvar:
# stores are created (and closed) on the main thread; a thread-local seq
# keeps the exit hook provably gcsafe.
var gTempDirsStr {.threadvar.}: seq[string]
addExitProc proc() {.gcsafe.} =
  for d in gTempDirsStr:
    try: removeDir(d) except CatchableError: discard

proc close*(kv: KVStore) {.gcsafe.} =
  if kv != nil:
    kv.lock.withLock:
      if kv.ps != nil: closePageStore(kv.ps); kv.ps = nil
    if kv.ownsPath and kv.path.len > 0:
      let idx = gTempDirsStr.find(kv.path)
      if idx >= 0: gTempDirsStr.delete(idx)
      try:
        removeDir(kv.path)
      except CatchableError:
        discard

proc newTempFileKVStore*(extra: Table[string, string] = initTable[string, string]()): KVStore =
  ## KVStore on a fresh temp directory (mkdtemp-style), removed on close()
  ## (or at process exit). The test-suite replacement for the removed
  ## :memory: backend — exercises the real journal/replay/blob paths.
  var cfg = {"backend": "file"}.toTable
  for k, v in extra: cfg[k] = v
  cfg["path"] = getTempDir() / "eavt_test_" & $getCurrentProcessId() & "_" &
                $epochTime().uint64 & "_" & $rand(high(int))
  createDir(cfg["path"])
  result = newKVStore(cfg)
  if result != nil:
    result.ownsPath = true
    gTempDirsStr.add(cfg["path"])

proc put*(kv: KVStore; cf: int; key: openArray[byte]) {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var needsFlush = false
  kv.lock.withLock:
    kv.mtSize = kv.mt.put(cf, k)
    if kv.mtSize >= kv.flushThreshold: needsFlush = true
    if journaling(kv):
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
      kv.journalDeliver(hdr)
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

proc putKv*(kv: KVStore; cf: int; key, value: openArray[byte]) {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var v = newSeq[byte](value.len)
  if value.len > 0: copyMem(addr v[0], unsafeAddr value[0], value.len)
  var needsFlush = false
  kv.lock.withLock:
    kv.mtSize = kv.mt.putKv(cf, k, v)
    if kv.mtSize >= kv.flushThreshold: needsFlush = true
    if journaling(kv):
      var jk = newSeq[byte](1 + key.len)
      jk[0] = byte(cf)
      if key.len > 0: copyMem(addr jk[1], unsafeAddr key[0], key.len)
      let totKlen = 1 + key.len
      var hdr = newSeq[byte](4 + totKlen + 4 + value.len + 1)
      hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
      hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
      copyMem(addr hdr[4], addr jk[0], totKlen)
      let vlen = value.len
      hdr[4 + totKlen] = byte((vlen shr 24) and 0xFF)
      hdr[5 + totKlen] = byte((vlen shr 16) and 0xFF)
      hdr[6 + totKlen] = byte((vlen shr 8) and 0xFF)
      hdr[7 + totKlen] = byte(vlen and 0xFF)
      if value.len > 0: copyMem(addr hdr[8 + totKlen], addr v[0], value.len)
      hdr[8 + totKlen + value.len] = 0
      kv.journalDeliver(hdr)
  if needsFlush: kv.requestFlush()

proc getKv*(kv: KVStore; cf: int; key: openArray[byte]): Option[seq[byte]] {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var liveRoot, flushRoot: mt_be.TreapNode
  kv.lock.withLock:
    liveRoot = kv.mt.hnd.live[cf]
    if kv.flushRoots.len > 0:
      flushRoot = kv.flushRoots[cf]
  if liveRoot != nil:
    let v = mt_be.getValue(liveRoot, k)
    if v.isSome: return v
    # Check if key exists but is a tombstone
    if mt_be.containsKey(liveRoot, k): return none(seq[byte])
  if flushRoot != nil:
    let v = mt_be.getValue(flushRoot, k)
    if v.isSome: return v
    if mt_be.containsKey(flushRoot, k): return none(seq[byte])
  keyExistsKv(kv.ps[], cf, k)

proc deleteKv*(kv: KVStore; cf: int; key: openArray[byte]) {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  kv.lock.withLock:
    mt_be.deleteKv(kv.mt, cf, k)
    if journaling(kv):
      var jk = newSeq[byte](1 + key.len)
      jk[0] = byte(cf)
      if key.len > 0: copyMem(addr jk[1], unsafeAddr key[0], key.len)
      let totKlen = 1 + key.len
      # vlen = 0xFFFFFFFF marks a delete
      var hdr = newSeq[byte](4 + totKlen + 4 + 1)
      hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
      hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
      copyMem(addr hdr[4], addr jk[0], totKlen)
      hdr[4 + totKlen] = 0xFF; hdr[5 + totKlen] = 0xFF
      hdr[6 + totKlen] = 0xFF; hdr[7 + totKlen] = 0xFF
      hdr[8 + totKlen] = 0
      kv.journalDeliver(hdr)

proc flush*(kv: KVStore) {.gcsafe.} =
  if kv.readOnly: return
  var roots: seq[mt_be.TreapNode]
  kv.lock.withLock:
    if kv.flushRoots.len > 0: return
    roots = kv.mt.hnd.live
    kv.mt.clear(); kv.mtSize = 0
    kv.flushRoots = roots
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  var pairsByCf: seq[(int, seq[(seq[byte], seq[byte])])] = @[]
  var deletedByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<kv.numCf:
    if roots[cf] != nil:
      if cf >= 10:
        var pairs: seq[(seq[byte], seq[byte])] = @[]
        var deleted: seq[seq[byte]] = @[]
        let tc = newTreapCursor(roots[cf])
        while not tc.atEnd:
          let kvp = tc.nextKv()
          if kvp.isSome:
            let (key, val) = kvp.get
            pairs.add (key, val)
        # Collect tombstones from the same treap
        let tc2 = newTreapCursor(roots[cf])
        while not tc2.atEnd:
          let dk = tc2.nextDeleted()
          if dk.isSome: deleted.add(dk.get)
        if pairs.len > 0: pairsByCf.add (cf, pairs)
        if deleted.len > 0: deletedByCf.add (cf, deleted)
      else:
        var keys: seq[seq[byte]] = @[]
        let tc = newTreapCursor(roots[cf])
        while not tc.atEnd:
          let k = tc.next()
          if k.isSome: keys.add(k.get)
        if keys.len > 0: keysByCf.add (cf, keys)
  if keysByCf.len > 0: commitMerge(kv.ps[], keysByCf, true)
  if pairsByCf.len > 0 or deletedByCf.len > 0:
    commitMergeKv(kv.ps[], pairsByCf, deletedByCf, true)
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

proc flushStartSeq*(kv: KVStore): uint64 {.gcsafe.} =
  kv.flushStart.load(moRelaxed)

proc flushEndSeq*(kv: KVStore): uint64 {.gcsafe.} =
  kv.flushEnd.load(moRelaxed)

proc requestFlush*(kv: KVStore) {.gcsafe.} =
  ## Ask for a background flush. Idempotent. If a flush is already running,
  ## marks flushPending so the runner re-iterates; otherwise arms a fresh
  ## flush (flushStart++) and spawns runBackgroundFlush. The storage is
  ## self-contained — no external wiring needed.
  kv.flushPending.store(true, moRelaxed)
  var fire = false
  kv.lock.withLock:
    if kv.flushStart.load(moRelaxed) == kv.flushEnd.load(moRelaxed):
      discard kv.flushStart.fetchAdd(1, moRelaxed)
      fire = true
  if fire:
    spawn(proc() {.gcsafe.} = runBackgroundFlush(kv))

proc runBackgroundFlush*(kv: KVStore) {.gcsafe.} =
  ## Background flush loop. Spawned by requestFlush. Drains the MemTable
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
    if journaling(kv) and ops.len > 0:
      let raw = cast[ptr UncheckedArray[byte]](unsafeAddr ops[0]); var pos = 0
      var journal: seq[byte] = @[]
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
        journal.add(hdr)
        pos += 5 + klen
      if journal.len > 0: kv.journalDeliver(journal)
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
    var psc = PageStoreCursor(
      s: kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
      isKv: cf >= 10)
    sources.add pageStoreCursor(psc)

  if flushRoot != nil:
    let tc = newTreapCursor(flushRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  if liveRoot != nil:
    let tc = newTreapCursor(liveRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  result = newMergedCursor(sources)

proc openScanCursorKv*(kv: KVStore; cf: int): MergedCursor {.gcsafe.} =
  ## Open a scan cursor for key-value CFs (>= 10). Returns a MergedCursor
  ## with isKv=true; use peekKv/nextKv to read (key, value) pairs.
  ##
  ## Implementation: manually merges PageStore + flushRoot + liveRoot,
  ## skipping tombstones from Treap sources. The PageStore is assumed to
  ## have no tombstones (they are removed during flush).
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
    var psc = PageStoreCursor(
      s: kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
      isKv: true)
    sources.add pageStoreCursor(psc)

  if flushRoot != nil:
    let tc = newTreapCursor(flushRoot)
    if not tc.atEnd:
      # Wrap in a cursor that filters tombstones via peekKv/nextKv
      sources.add treapKvCursor(tc)

  if liveRoot != nil:
    let tc = newTreapCursor(liveRoot)
    if not tc.atEnd:
      sources.add treapKvCursor(tc)

  result = newMergedCursor(sources)
  result.isKv = true
