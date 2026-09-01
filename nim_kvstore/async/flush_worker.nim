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
import chronos
import blobstore
import nim_memtable/treap_backend as mt_be
import page_store

type
  FlushWorkerObj = object
    lock: Lock
    cond: Cond
    stopping: Atomic[bool]
    requested: Atomic[bool]
    done: Atomic[bool]
    # job input (POD; loop writes before request, worker reads)
    numCf: int
    roots: ptr UncheckedArray[mt_be.TreapNode]
    trees: ptr UncheckedArray[CfTree]   ## worker writes new trees here
    blobs: BlobStore                    ## sync trait, plain pointer for worker
    # result (POD; worker writes)
    rootNameBuf: array[128, char]
    rootNameLen: int
    ok: bool
    errBuf: array[96, char]
    errLen: int
    # loop-only (keep the POD owners alive + the thread handle)
    rootsSeq: seq[mt_be.TreapNode]
    treesSeq: seq[CfTree]
    arena: mt_be.Arena
    thread: Thread[ptr FlushWorkerObj]

  FlushWorker* = ref object
    inner: ptr FlushWorkerObj

proc drainKeys(n: mt_be.TreapNode; keys: var seq[seq[byte]]) =
  ## In-order key materialisation (raw-pointer traversal — no cursor, no
  ## readerCount). Runs on the worker; every seq dies on the worker frame.
  if n == nil: return
  drainKeys(n.left, keys)
  keys.add(mt_be.toSeq(mt_be.KeyRef(p: n.keyPtr, len: n.keyLen.int)))
  drainKeys(n.right, keys)

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
        if w.roots[cf] == nil: continue
        var keys: seq[seq[byte]] = @[]
        drainKeys(w.roots[cf], keys)
        if keys.len > 0: keysByCf.add (cf, keys)
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

proc runFlush*(fw: FlushWorker; numCf: int; roots: seq[mt_be.TreapNode];
               trees: seq[CfTree]; blobs: BlobStore; arena: mt_be.Arena):
    Future[tuple[rootName: string, trees: seq[CfTree], ok: bool]] {.async.} =
  ## Submit a pure key-only flush, wait for completion, return the result.
  ## The loop owns `roots`/`trees`/`arena` for the whole call (the caller keeps
  ## them alive — e.g. via kv.flushRoots / kv.flushArena).
  let w = fw.inner
  w.rootsSeq = roots
  w.treesSeq = newSeq[CfTree](trees.len)
  if trees.len > 0:
    copyMem(addr w.treesSeq[0], unsafeAddr trees[0],
            trees.len * sizeof(CfTree))
  w.arena = arena
  w.numCf = numCf
  w.roots = (if roots.len > 0:
    cast[ptr UncheckedArray[mt_be.TreapNode]](unsafeAddr w.rootsSeq[0]) else: nil)
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
    result = (rootName: rn, trees: w.treesSeq, ok: true)
  else:
    result = (rootName: "", trees: @[], ok: false)
