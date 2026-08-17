## wal.nim — Group-commit WAL on the chronos event loop (chronos_file).
##
## The KVStore hands journal bytes to the sink (under kv.lock — cheap memcpy
## into a buffer). One chained writeAt drains the buffer via the chronos_file
## thread-pool; a 100ms timer fsyncs (interval durability: process crash is
## always safe, machine crash loses at most the last ~100ms of writes).
## Journal-file format is unchanged, so replay on startup is the existing
## KVStore path.

import std/[os, sequtils]
import chronos
import chronos_file
import kvstore

const
  FsyncIntervalMs = 100

type
  WalWriter* = ref object
    f: AsyncFile
    offset: int64        # next writeAt position (single writer, loop thread)
    buf: seq[byte]       # pending group
    draining: bool       # a writeAt chain is in flight
    stopped: bool
    syncedUpTo*: int64

proc journalPath(dbPath: string): string =
  dbPath / "journal" / "journal"

proc sink(w: WalWriter; data: seq[byte]) {.gcsafe, raises: [].} =
  ## Called under kv.lock from the KVStore write path — only cheap work here.
  if w.stopped: return
  w.buf.add(data)

proc drain(w: WalWriter) {.async.} =
  ## Chained single-writer drain: one writeAt per accumulated group.
  if w.draining: return
  w.draining = true
  while w.buf.len > 0 and not w.stopped:
    let group = w.buf
    w.buf = @[]
    let at = w.offset
    w.offset.inc(int64(group.len))
    await w.f.writeAt(at, group)
  w.draining = false

proc fsyncLoop(w: WalWriter) {.async.} =
  while not w.stopped:
    await sleepAsync(FsyncIntervalMs.milliseconds)
    await w.drain()
    await w.f.flush()
    w.syncedUpTo = w.offset

proc attachWal*(kv: KVStore; dbPath: string): Future[WalWriter] {.async.} =
  ## Open (or create) the journal file and install the sink on the KVStore.
  ## Existing journal content is preserved — offset continues after it.
  let path = journalPath(dbPath)
  createDir(parentDir(path))
  # fmReadWriteExisting = O_RDWR without O_TRUNC: the journal must survive
  # across restarts (replayed at KVStore open). Create it if absent —
  # fmReadWriteExisting alone would fail on a fresh database.
  if not fileExists(path):
    writeFile(path, "")
  let w = WalWriter()
  w.f = openAsync(path, fmReadWriteExisting)
  w.offset = int64(getFileSize(path))
  w.f.setFilePos(w.offset)
  # Capture the heap ref (NOT the FutureVar `result`) — the sink runs on the
  # write path under kv.lock, outside this async frame.
  kv.journalSink = proc(data: seq[byte]) {.gcsafe, raises: [].} =
    sink(w, data)
  asyncSpawn w.fsyncLoop()
  return w

proc stop*(w: WalWriter) {.async.} =
  ## Final drain + fsync + close. Call once at shutdown.
  w.stopped = true
  await w.drain()
  await w.f.flush()
  w.syncedUpTo = w.offset
  await w.f.closeWait()
