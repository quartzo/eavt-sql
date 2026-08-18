## wal.nim — Segmented WAL on the chronos event loop (chronos_file).
##
## Group-commit writer with SEGMENT ROTATION at flush-capture boundaries:
##
##   write path (loop, under kv.lock)        WAL cycle (loop, 100 ms)
##   ┌────────────────────────────┐          ┌──────────────────────────────┐
##   │ sink: buf.add(data)        │          │ drain: split buf at seal     │
##   │ logicalEnd += data.len     │          │   pre-seal → segment N       │
##   └────────────────────────────┘          │   post-seal → segment N+1    │
##                                           │ fsync current segment        │
##   flush thread                            │ delete sealed segs ≤         │
##   capture (kv.lock): journalSeal() ──────▶│   kv.walDurableUpTo          │
##   publish  (kv.lock): walDurableUpTo ─────┘
##
## Why rotation instead of truncating one file: records written DURING a
## flush tail the same file after the captured ones — truncating (at 0 or at
## the capture offset) either loses those records or rewrites live bytes with
## torn-crash regressions. Segments are append-only and deleted only after
## their records are durable in the PageStore. A crash mid-flush leaves all
## segments; restart replays them in numeric order (later wins; pre-capture
## re-applies are idempotent puts).
##
## Segment files: <db>/journal/journal.NNNNN (5 digits). A legacy single
## <db>/journal/journal (pre-rotation format) is replayed first if present.
##
## Durability: interval fsync (100 ms) on the current segment — process crash
## always safe, machine crash loses at most ~100 ms of writes.

import std/[os, strutils, algorithm, atomics]
import chronos
import chronos_file
import kvstore

const
  FsyncIntervalMs = 100
  SegPrefix = "journal."
  SegDigits = 5

type
  WalWriter* = ref object
    kv: KVStore                  # polls walDurableUpTo for segment deletion
    dir: string                  # <db>/journal
    segIdx: int                  # current segment number
    f: AsyncFile                 # current segment (append; never truncated)
    offset: int64                # write position within the current segment
    buf: seq[byte]               # pending bytes; buf[0] is logical pos bufPos
    bufPos: int64                # logical stream position of buf[0]
    ## logicalEnd is mutated by the sink under kv.lock and read by seal()
    ## under kv.lock — the lock provides the needed visibility.
    logicalEnd: int64
    sealBoundary: Atomic[int64]  # set by seal() (flush thread); -1 = none
    sealed: seq[tuple[idx: int, path: string, boundary: int64]]
    draining: bool
    stopped: bool

proc segPath(dir: string; idx: int): string =
  dir / (SegPrefix & align($idx, SegDigits, '0'))

proc openSeg(w: WalWriter; idx: int): AsyncFile {.raises: [AsyncFileError].} =
  let p = segPath(w.dir, idx)
  try:
    if not fileExists(p):
      writeFile(p, "")
  except CatchableError:
    discard  # openAsync below surfaces a real error
  result = openAsync(p, fmReadWriteExisting)  # never O_TRUNC

proc sink(w: WalWriter; data: seq[byte]) {.gcsafe, raises: [].} =
  ## Called under kv.lock on the loop thread — cheap work only.
  if w.stopped: return
  w.buf.add(data)
  w.logicalEnd.inc(int64(data.len))

proc seal(w: WalWriter): int64 =
  ## Called by flush() at capture time, under kv.lock (flush thread). Returns
  ## the logical boundary; the drain splits the buffer there and rotates the
  ## segment. Single-flight flushes guarantee at most one pending seal.
  result = w.logicalEnd
  w.sealBoundary.store(result, moRelease)

proc drain(w: WalWriter) {.async.} =
  ## Chained single-writer drain. Splits at the seal boundary when one is
  ## pending: pre-boundary bytes finish the current segment, then the segment
  ## rotates (even if the pending tail is empty — the boundary itself ends
  ## the segment) and later bytes go to the new one.
  if w.draining: return
  w.draining = true
  while not w.stopped:
    let seal = w.sealBoundary.load(moAcquire)
    if seal >= 0:
      # Pending bytes strictly before the boundary belong to the current
      # segment. seal == bufPos (buffer already drained up to the boundary)
      # still rotates — that is exactly the flush-idle case.
      let split = if seal > w.bufPos: min(int(seal - w.bufPos), w.buf.len) else: 0
      if split > 0:
        let at = w.offset
        let chunk = w.buf[0..<split]
        w.offset.inc(int64(split))
        w.bufPos.inc(int64(split))
        await w.f.writeAt(at, chunk)
        w.buf = w.buf[split..^1]
      if w.bufPos >= seal:
        # Boundary reached: finish this segment, rotate.
        await w.f.closeWait()
        w.sealed.add((w.segIdx, segPath(w.dir, w.segIdx), seal))
        inc w.segIdx
        w.f = openSeg(w, w.segIdx)
        w.offset = 0
        w.sealBoundary.store(-1'i64, moRelease)
      if w.buf.len == 0:
        break
    else:
      if w.buf.len == 0:
        break
      let at = w.offset
      let chunk = w.buf
      w.offset.inc(int64(chunk.len))
      w.bufPos.inc(int64(chunk.len))
      await w.f.writeAt(at, chunk)
      w.buf = @[]
  w.draining = false

proc deleteDurable(w: WalWriter) =
  ## Delete sealed segments whose records are durable in the PageStore.
  let durable = w.kv.walDurableUpTo.load(moAcquire)
  while w.sealed.len > 0 and w.sealed[0].boundary <= durable:
    try:
      removeFile(w.sealed[0].path)
    except CatchableError:
      break  # retry next cycle
    w.sealed = w.sealed[1..^1]

proc walCycle(w: WalWriter) {.async.} =
  while not w.stopped:
    await sleepAsync(chronos.milliseconds(FsyncIntervalMs))
    await w.drain()
    await w.f.flush()
    w.deleteDurable()

proc attachWal*(kv: KVStore; dbPath: string): Future[WalWriter] {.async.} =
  ## Open (or continue) the segmented WAL and install the sink + seal hooks
  ## on the KVStore. Segment numbering continues after the highest existing
  ## segment (a crash mid-flush leaves old segments; replay handles them).
  let dir = dbPath / "journal"
  createDir(dir)
  let w = WalWriter()
  w.kv = kv
  w.dir = dir
  w.sealBoundary.store(-1'i64, moRelaxed)
  # find max segment index (walkDir yields full paths; splitFile would eat
  # ".00001" as an extension — use lastPathPart)
  var maxIdx = -1
  for kind, name in walkDir(dir):
    let base = lastPathPart(name)
    if kind == pcFile and base.startsWith(SegPrefix):
      try:
        let idx = parseInt(base[SegPrefix.len..^1])
        if idx > maxIdx: maxIdx = idx
      except ValueError: discard
  w.segIdx = maxIdx + 1
  w.f = openSeg(w, w.segIdx)
  w.offset = int64(getFileSize(segPath(w.dir, w.segIdx)))
  # Capture the heap refs (never the async FutureVar) — hooks run on the
  # write path / flush thread outside this frame.
  kv.journalSink = proc(data: seq[byte]) {.gcsafe, raises: [].} =
    sink(w, data)
  kv.journalSeal = proc(): int64 {.gcsafe, raises: [].} =
    seal(w)
  asyncSpawn w.walCycle()
  return w

proc stop*(w: WalWriter) {.async.} =
  ## Final drain + fsync + close. Sealed segments pending deletion are left
  ## in place (harmless: restart replays then re-flushes them).
  w.stopped = true
  await w.drain()
  await w.f.flush()
  await w.f.closeWait()
