## flush_worker.nim — a dedicated thread runs the flush's hot path (key-only
## drain + commitMergeCore) off the event loop.
##
## Follows the blob pool's cross-thread pattern: the worker touches only the
## POD half of the job (raw roots, raw CfTree buffer, the BlobStore trait as a
## plain pointer). Every GC value the worker creates (drained keys, merged
## pages, backend seqs) lives and dies inside its own frame — only POD crosses
## the boundary. The loop keeps the GC owners (rootsSeq, treesSeq, arena) alive
## until the worker signals done.
##
## KV CFs (>= 10) stay on the loop: the caller only routes a flush here when
## it is pure key-only (no live KV roots), so the worker's single root write is
## the only one for that generation.

import std/atomics
import std/locks
import std/algorithm
import chronos
import blobstore
import nim_memtable/memtypes
import nim_memtable/runs
import page_store

type
  FlushWorkerObj = object
    lock: Lock
    cond: Cond
    stopping: Atomic[bool]
    requested: Atomic[bool]
    done: Atomic[bool]
    # job input (POD + frozen GC refs; loop writes before request, worker
    # reads — os draining runs são imutáveis e o loop os mantém vivos)
    numCf: int
    trees: ptr UncheckedArray[CfTree]   ## worker writes new trees here
    blobs: BlobStore                    ## sync trait, plain pointer for worker
    runsByCf: seq[seq[Run]]             ## runs congelados por CF (M8)
    # result (POD; worker writes)
    rootNameBuf: array[128, char]
    rootNameLen: int
    maxT: int64             ## max datom t across the flushed keys (M6: the
                            ## commit watermark for write-through mirrors)
    ok: bool
    errBuf: array[96, char]
    errLen: int
    # loop-only (keep the GC owners alive + the thread handle)
    runsByCfOwner: seq[seq[Run]]
    treesSeq: seq[CfTree]
    thread: Thread[ptr FlushWorkerObj]

  FlushWorker* = ref object
    inner: ptr FlushWorkerObj

proc flushWorkerMain(w: ptr FlushWorkerObj) {.thread.} =
  while true:
    acquire(w.lock)
    while not w.requested.load(moAcquire) and not w.stopping.load(moAcquire):
      wait(w.cond, w.lock)
    let doWork = w.requested.load(moAcquire) and not w.stopping.load(moAcquire)
    w.requested.store(false, moRelease)
    release(w.lock)
    if not doWork:
      break
    try:
      var keysByCf: seq[(int, seq[seq[byte]])] = @[]
      for cf in 0 ..< w.numCf:
        if cf >= 10: break  # key-only CFs only
        # runs congelados já ordenados — k-way merge (newest-wins)
        let keys = drainSorted(w.runsByCf[cf])
        if keys.len > 0: keysByCf.add (cf, keys)
      var maxT: int64 = -1
      for (cf, keys) in keysByCf:
        for k in keys:
          if k.len < 8: continue
          var sf = 0'u64
          for b in k[k.len - 8 ..< k.len]: sf = (sf shl 8) or uint64(b)
          let kt = (sf shr 1).int64
          if kt > maxT: maxT = kt
      w.maxT = maxT
      let rootName = commitMergeCore(w.blobs, w.trees, w.numCf, keysByCf)
      let n = min(rootName.len, w.rootNameBuf.len)
      if n > 0: copyMem(addr w.rootNameBuf[0], unsafeAddr rootName[0], n)
      w.rootNameLen = n
      w.ok = true
    except CatchableError as e:
      let msg = e.msg
      let n = min(msg.len, w.errBuf.len - 1)
      if n > 0: copyMem(addr w.errBuf[0], unsafeAddr msg[0], n)
      w.errLen = n
      w.maxT = -1
      w.ok = false
    w.done.store(true, moRelease)

proc startFlushWorker*(): FlushWorker =
  result = FlushWorker(inner:
    cast[ptr FlushWorkerObj](allocShared0(sizeof(FlushWorkerObj))))
  let w = result.inner
  initLock(w.lock)
  initCond(w.cond)
  createThread(w.thread, flushWorkerMain, w)

proc closeFlushWorker*(fw: FlushWorker) {.async.} =
  ## Stop the worker and release its resources. Must run on the loop, after
  ## the flusher drained (no in-flight flush).
  let w = fw.inner
  w.stopping.store(true, moRelease)
  acquire(w.lock)
  w.cond.broadcast()
  release(w.lock)
  joinThread(w.thread)
  deinitCond(w.cond)
  deinitLock(w.lock)
  deallocShared(w)

proc runFlush*(fw: FlushWorker; numCf: int; runsByCf: seq[seq[Run]];
               trees: seq[CfTree]; blobs: BlobStore):
    Future[tuple[rootName: string, trees: seq[CfTree], maxT: int64, ok: bool]] {.async.} =
  ## Submit a pure key-only flush, wait for completion, return the result.
  ## The loop owns `runsByCf`/`trees` for the whole call (the draining runs
  ## são imutáveis e mantidos vivos pelo chamador até o done).
  let w = fw.inner
  w.runsByCfOwner = runsByCf
  w.treesSeq = newSeq[CfTree](trees.len)
  if trees.len > 0:
    copyMem(addr w.treesSeq[0], unsafeAddr trees[0],
            trees.len * sizeof(CfTree))
  w.numCf = numCf
  w.runsByCf = runsByCf
  w.trees = (if w.treesSeq.len > 0:
    cast[ptr UncheckedArray[CfTree]](addr w.treesSeq[0]) else: nil)
  w.blobs = blobs
  w.done.store(false, moRelease)
  w.requested.store(true, moRelease)
  acquire(w.lock)
  w.cond.signal()
  release(w.lock)
  while not w.done.load(moAcquire):
    await sleepAsync(1.milliseconds)
  if w.ok:
    # NOTA: `$` sobre slice de array[char] produz o REPR (@['r', ...]) —
    # foi exatamente o bug que corrompia o rootName broadcastado à réplica
    # (publishRoot falhava, réplica presa na geração 0, db.* perdidos no
    # seal seguinte → "attribute resolution failed" em todo SQL). Construir
    # string explicitamente.
    var rn = newString(w.rootNameLen)
    if w.rootNameLen > 0:
      copyMem(addr rn[0], addr w.rootNameBuf[0], w.rootNameLen)
    result = (rootName: rn, trees: w.treesSeq, maxT: w.maxT, ok: true)
  else:
    result = (rootName: "", trees: @[], maxT: -1, ok: false)
