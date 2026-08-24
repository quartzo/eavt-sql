## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.
##
## Threading: NONE. This module is single-threaded (the server runs it on its
## chronos loop; tests run it on the main thread). `lock` only exists to keep
## the loop's critical sections explicit and to pair with PageStore tree
## swaps. The async twin (flush/GC via the blob pool, chunked treap drain)
## lives in async/kvstore_async.nim.

import std/[tables, strutils, os, options, times, random, algorithm, monotimes]
import std/[osproc, exitprocs]
import std/syncio
import page_store
import logutil

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
    config*: Table[string, string]
    path*: string
    readOnly*: bool
    numCf*: int
    flushThreshold*: uint64
    gcMaxAgeSecs*: uint64
    gcMaxRootCount*: int
    ## Flush arming hook: called when a write crosses flushThreshold and by
    ## requestFlush(). The async server installs a proc that schedules
    ## flushAsync on its event loop; nil (tests, sync callers) means "no
    ## background flusher" — call flush()/flushSync() explicitly.
    onFlushRequest*: proc () {.gcsafe.}
    ## Sinaliza CAPTURA de flush na réplica: fronteira de geração — todo wal
    ## entregue depois pertence à geração nova. Deve sair ANTES do root.
    onFlushSeal*: proc () {.gcsafe, raises: [].}
    ## When set, journal entries are handed to this sink instead of being
    ## written to the journal file inline — the sink serializes them directly
    ## into the WAL buffer.
    journalSink*: proc (entries: seq[mt_be.CfKey]) {.gcsafe, raises: [].}
    ## When true, close() removes the whole data directory (tests use it for
    ## their tempdir-per-store pattern).
    ownsPath*: bool
    ## WAL rotation hooks (server with journalSink installed).
    ## journalSeal is called by flush() at capture time: it seals the current
    ## WAL segment at the logical byte boundary of the capture — writes
    ## arriving after the seal land in the NEXT segment. Returns the boundary.
    journalSeal*: proc (): int64 {.gcsafe, raises: [].}
    ## Set by flush() after commitMerge published the new root: every record
    ## with logical position < walDurableUpTo is durable in the PageStore, so
    ## the sealed segment covering it may be deleted. The WAL writer polls
    ## this on its cycle.
    walDurableUpTo*: Atomic[int64]
    ## Called after flush publishes a new root (i.e., the root name just
    ## committed to PageStore). The replication hub uses it to broadcast the
    ## new root to replicas. Only memcpy work in the callback.
    onFlushPublish*: proc (rootName: string) {.gcsafe, raises: [].}
    # perf counters for batchWrite
    bwCount*: int64
    bwJournalNs*: int64
    bwTreapNs*: int64
    bwTotalNs*: int64
# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations

# ═══════════════════════════════════════════════════════════════════════════════

proc requestFlush*(kv: KVStore) {.gcsafe.}
proc flushSync*(kv: KVStore) {.gcsafe.}


proc readFileBytes*(path: string): seq[byte] =
  ## Read raw bytes from a file — returns seq[byte] instead of readFile's
  ## string.  Used only at startup (before the chronos loop starts);
  ## runtime reads use chronos-file's readFileBytesAsync (seq[byte], async).
  let f = syncio.open(path, fmRead)
  defer: f.close()
  let sz = getFileSize(f)
  if sz == 0: return @[]
  result = newSeq[byte](sz)
  discard f.readBuffer(addr result[0], sz)

proc parseJournalRecords*(data: openArray[byte]): seq[mt_be.CfKey] =
  ## Parse journal records from raw bytes into CfKey entries for memtable batch apply.
  ## Journal format: [4B klen][cf+key][4B vlen][value].
  ## Key-only CFs 0-3: the cf byte is part of the key in the journal, but we
  ## extract it as the CfKey.cf and store the remaining bytes as CfKey.key.
  ## A torn tail (truncated record) stops parsing at the last complete record.
  result = @[]
  var pos = 0
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
    if klen >= 1 and cf <= 3'u8:
      var key = newSeq[byte](klen - 1)
      let keyStart = pos - 4 - vlen - klen + 1
      for i in 0 ..< klen - 1:
        key[i] = byte(data[keyStart + i])
      result.add(mt_be.CfKey(cf: cf, key: key))

proc parseJournalFile*(path: string): seq[mt_be.CfKey] =
  ## Parse a single journal file (used by replay at open).
  try:
    parseJournalRecords(readFileBytes(path))
  except CatchableError:
    @[]


proc applyJournalRecords*(kv: KVStore; data: openArray[byte]) {.gcsafe.} =
  ## Apply journal-format records directly to the memtable (batch apply).
  ## Used by the replication replica: the WAL stream arrives as journal-format
  ## bytes and is applied to the live treap without re-journaling.
  if data.len == 0: return
  let entries = parseJournalRecords(data)
  if entries.len > 0:
    kv.mtSize = kv.mt.batch(entries)

proc sealLiveToFlush*(kv: KVStore) {.gcsafe.} =
  ## Seal the live memtable into flushRoots (the first half of kv.flush).
  ## Used by the replication replica when the server signals a seal event:
  ## the current live treap becomes the "pending" treap (will be discarded
  ## when the next root publish arrives) and a fresh live treap takes over.
  kv.flushRoots = kv.mt.hnd.live
  kv.mt.clear()
  kv.mtSize = 0


proc publishRoot*(kv: KVStore; rootName: string) {.gcsafe.} =
  ## Publish a new root (the second half of kv.flush, minus the blob writes).
  ## The server already committed the root to disk; this loads it into
  ## ps.trees and discards the pending treap.
  let loaded = loadRoot(kv.ps[], rootName)
  block diag:
    var snap = ""
    for cf in 0..<min(4, kv.ps[].trees.len):
      let t = kv.ps[].trees[cf]
      var hex = ""
      for b in t.rootUuid: hex.add toHex(b)
      snap.add " cf" & $cf & "=h" & $t.height & "/" & hex[0 ..< 8]
    if loaded:
      logInfo("replica-root", rootName & snap)
    else:
      logWarn("replica-root", rootName & " LOAD FAILED")
  if loaded:
    kv.flushRoots = @[]
    kv.mtSize = 0


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
  result.walDurableUpTo.store(-1'i64, moRelaxed)
  # Replay journal: legacy single file first (pre-rotation format), then
  # segments in numeric order (later segments win — newer records overwrite
  # older ones during batch apply). A torn tail (crash mid-write) ends that
  # file's replay at its last complete record.
  block replay:
    var files: seq[string] = @[]
    let jdir = result.path / "journal"
    let legacy = jdir / "journal"
    if fileExists(legacy): files.add(legacy)
    var segs: seq[tuple[idx: int, path: string]] = @[]
    if dirExists(jdir):
      for kind, name in walkDir(jdir):
        # walkDir yields full paths; splitFile would eat ".00001" as the
        # extension — use lastPathPart for the whole base name.
        let base = lastPathPart(name)
        if kind == pcFile and base.startsWith("journal."):
          try:
            segs.add((parseInt(base[8..^1]), name))
          except ValueError:
            # Non-numeric entry in journal dir — filter, not an error.
            logDebug("kvstore", "skipping non-segment file " & base)
    segs.sort(proc(a, b: tuple[idx: int, path: string]): int = cmp(a.idx, b.idx))
    for s in segs: files.add(s.path)
    var entries: seq[mt_be.CfKey] = @[]
    for jf in files:
      try:
        let data = readFile(jf)
        if data.len > 0:
          entries.add parseJournalRecords(cast[seq[byte]](data))
      except CatchableError as e:
        # Tolerant replay (decided): keep opening, but the skipped segment
        # is durability-relevant and MUST be visible.
        logError("kvstore", "journal replay skipped " & jf & " (" &
          excMsg(e) & "); data in this segment may be missing")
    if entries.len > 0: result.mtSize = result.mt.batch(entries)

proc journalDeliver*(kv: KVStore; entries: seq[mt_be.CfKey]) {.gcsafe.} =
  ## Journal entries to the sink when installed, else best-effort append
  ## to the journal file (legacy fallback, serializes here).
  if kv.journalSink != nil:
    kv.journalSink(entries)
    return
  # Legacy fallback: serialize to file directly
  try:
    let journalPath = kv.path / "journal" / "journal"
    createDir(parentDir(journalPath))
    var f = open(journalPath, fmAppend)
    for e in entries:
      let klen = e.key.len
      let totKlen = 1 + klen
      var hdr = newSeq[byte](4 + totKlen + 4 + 1)
      hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
      hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
      hdr[4] = e.cf
      if klen > 0: copyMem(addr hdr[5], unsafeAddr e.key[0], klen)
      hdr[5+klen] = 0; hdr[6+klen] = 0; hdr[7+klen] = 0; hdr[8+klen] = 1; hdr[9+klen] = 0
      discard f.writeBytes(hdr, 0, hdr.len)
    f.close()
  except CatchableError as e:
    # Durability path: a failed journal append means those entries are NOT
    # crash-safe — this must never be silent.
    logError("kvstore", "legacy journal append failed (" & excMsg(e) &
      "); " & $entries.len & " entries not durable")

proc journaling(kv: KVStore): bool {.inline.} =
  kv.path.len > 0 and not kv.readOnly

# tempdirs handed out by newTempFileKVStore — swept at process exit so a
# test that forgets close() still does not leak its directory. threadvar:
# stores are created (and closed) on the main thread; a thread-local seq
# keeps the exit hook provably gcsafe.
var gTempDirsStr {.threadvar.}: seq[string]
addExitProc proc() {.gcsafe.} =
  for d in gTempDirsStr:
    try: removeDir(d)
    except CatchableError as e:
      logWarn("kvstore", "temp dir sweep failed for " & d & " (" &
        excMsg(e) & ")")

proc close*(kv: KVStore) {.gcsafe.} =
  if kv != nil:
    if kv.ps != nil: closePageStore(kv.ps); kv.ps = nil
    if kv.ownsPath and kv.path.len > 0:
      let idx = gTempDirsStr.find(kv.path)
      if idx >= 0: gTempDirsStr.delete(idx)
      try:
        removeDir(kv.path)
      except CatchableError as e:
        logWarn("kvstore", "temp dir removal failed for " & kv.path & " (" &
          excMsg(e) & ")")

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
  kv.mtSize = kv.mt.put(cf, k)
  if kv.mtSize >= kv.flushThreshold: needsFlush = true
  if journaling(kv):
    kv.journalDeliver(@[mt_be.CfKey(cf: cf.uint8, key: k)])
  if needsFlush: kv.requestFlush()

proc get*(kv: KVStore; cf: int; key: openArray[byte]): bool {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var liveRoot = kv.mt.hnd.live[cf]
  var flushRoot: mt_be.TreapNode
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
  kv.mtSize = kv.mt.putKv(cf, k, v)
  if kv.mtSize >= kv.flushThreshold: needsFlush = true
  if journaling(kv):
    # Key-value journal format: [totKlen:4B][cf+key][vlen:4B][value]
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
    if kv.journalSink == nil:
      try:
        let journalPath = kv.path / "journal" / "journal"
        createDir(parentDir(journalPath))
        var f = open(journalPath, fmAppend)
        discard f.writeBytes(hdr, 0, hdr.len)
        f.close()
      except CatchableError as e:
        # Durability path: this put is NOT crash-safe — never silent.
        logError("kvstore", "legacy journal append failed on put (" &
          excMsg(e) & ")")
  if needsFlush: kv.requestFlush()

proc getKv*(kv: KVStore; cf: int; key: openArray[byte]): Option[seq[byte]] {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var liveRoot = kv.mt.hnd.live[cf]
  var flushRoot: mt_be.TreapNode
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
    # Legacy: write directly to journal file (CfKey doesn't support delete format)
    if kv.journalSink == nil:
      try:
        let journalPath = kv.path / "journal" / "journal"
        createDir(parentDir(journalPath))
        var f = open(journalPath, fmAppend)
        discard f.writeBytes(hdr, 0, hdr.len)
        f.close()
      except CatchableError as e:
        # Durability path: this tombstone is NOT crash-safe — never silent.
        logError("kvstore", "legacy journal append failed on delete (" &
          excMsg(e) & ")")

proc flush*(kv: KVStore) {.gcsafe.} =
  if kv.readOnly: return
  var roots: seq[mt_be.TreapNode]
  var sealBoundary: int64 = -1
  # Single-threaded: capture runs atomically before next await.
  if kv.flushRoots.len > 0: return
  roots = kv.mt.hnd.live
  kv.mt.clear(); kv.mtSize = 0
  kv.flushRoots = roots
  # Seal the WAL segment at the capture boundary: records applied after
  # this point land in the NEXT segment and survive until their own flush
  # publishes.
  if kv.journalSeal != nil:
    sealBoundary = kv.journalSeal()
    if kv.onFlushSeal != nil: kv.onFlushSeal()
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
  # Single-threaded publish — runs atomically before next await.
  kv.flushRoots = @[]; kv.mtSize = 0
  # Publish done: everything before the seal boundary is durable in the
  # PageStore — the sealed WAL segment may be deleted on the next WAL cycle.
  if sealBoundary >= 0:
    kv.walDurableUpTo.store(sealBoundary, moRelease)
  # Notify the replication hub (if installed) of the newly published root.
  if kv.onFlushPublish != nil:
    kv.onFlushPublish(kv.ps[].currentRoot)

# ── Flush arming ──
#
# requestFlush() dispatches to the onFlushRequest hook (installed by the
# server; nil in tests). The heavy work lives in one of two places:
#   flush()/flushSync()  — inline, synchronous (tests, tooling);
#   async/kvstore_async.nim flushAsync() — chunked, blob-pool backed
#     (the server's event loop).
# Both use the same capture/publish steps as flush(), so WAL sealing and
# walDurableUpTo publication behave identically.

proc requestFlush*(kv: KVStore) {.gcsafe.} =
  ## Ask the installed hook to schedule a flush. Idempotent by contract
  ## (the async flusher collapses concurrent requests). No hook: no-op.
  if kv.onFlushRequest != nil:
    kv.onFlushRequest()

proc flushSync*(kv: KVStore) {.gcsafe.} =
  ## Synchronous flush — with no background flusher thread, this is simply
  ## an inline flush() (kept as a separate name for call-site clarity).
  ## On return, every write prior to the call is durable.
  kv.flush()

proc batchWrite*(kv: KVStore; entries: seq[mt_be.CfKey]) {.gcsafe.} =
  kv.bwCount += 1
  let t0 = getMonoTime()
  var needsFlush = false
  if journaling(kv) and entries.len > 0:
    kv.journalDeliver(entries)
  kv.bwJournalNs += (getMonoTime().ticks - t0.ticks)
  let t1 = getMonoTime()
  kv.mtSize = kv.mt.batch(entries)
  kv.bwTreapNs += (getMonoTime().ticks - t1.ticks)
  if kv.mtSize >= kv.flushThreshold: needsFlush = true
  kv.bwTotalNs += (getMonoTime().ticks - t0.ticks)
  if needsFlush: kv.requestFlush()

proc memtableSize*(kv: KVStore): uint64 {.gcsafe.} = kv.mtSize

proc resetBwCounters*(kv: KVStore) =
  kv.bwCount = 0
  kv.bwJournalNs = 0
  kv.bwTreapNs = 0
  kv.bwTotalNs = 0

proc printBwPerf*(kv: KVStore) =
  if kv.bwCount == 0: return
  let total = kv.bwTotalNs
  template pct(ns: int64): string = formatFloat(ns.float / total.float * 100, ffDecimal, 1)
  template ms(ns: int64): string = formatFloat(ns.float / 1_000_000, ffDecimal, 1)
  echo "=== batchWrite perf (", kv.bwCount, " calls) ==="
  echo "  journal:        ", ms(kv.bwJournalNs), " ms  (", pct(kv.bwJournalNs), "%)"
  echo "  treap:          ", ms(kv.bwTreapNs), " ms  (", pct(kv.bwTreapNs), "%)"
  echo "  total:          ", ms(total), " ms"
  echo "  avg per batch:  ", formatFloat(total.float / kv.bwCount.float / 1_000_000, ffDecimal, 3), " ms"

# ── Streaming scan entry point ──

proc openScanCursor*(kv: KVStore; cf: int): MergedCursor {.gcsafe.} =
  ## Create MergedCursor with fixed layout: 0=PageStore, 1=flush, 2=live.
  ## update() assumes this layout for in-place source updates.
  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: mt_be.TreapNode

  var tree = kv.ps[].trees[cf]
  psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
  if kv.flushRoots.len > 0:
    flushRoot = kv.flushRoots[cf]
  liveRoot = kv.mt.hnd.live[cf]

  # Always create all 3 sources — update() assumes fixed indices
  var sources: seq[Cursor] = @[]
  sources.add pageStoreCursor(PageStoreCursor(
    s: kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
    isKv: cf >= 10))
  sources.add treapCursor(newTreapCursor(flushRoot))
  sources.add treapCursor(newTreapCursor(liveRoot))

  result = newMergedCursor(sources)
  result.cf = cf
  result.psRootUuid = psSnap.rootUuid
  result.psHeight = psSnap.height
  result.flushRoot = flushRoot
  result.liveRoot = liveRoot

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

  var tree = kv.ps[].trees[cf]
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
