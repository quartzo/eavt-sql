## blobstore_async.nim — Async facade over the synchronous BlobStore trait.
##
## A pool of 2-4 worker threads executes whole blob operations (zstd
## compress/decompress + backend put/get) off the event loop; completion
## crosses to the loop via ThreadSignalPtr (eventfd) and only the loop
## completes Futures.
##
## Memory discipline (the house rule — see AGENTS.md):
##   * Work items are manually allocated POD (allocShared0): the worker half
##     carries raw pointers/lengths only; a worker never touches GC memory.
##   * GC payloads (the seq[byte] pages, the result seqs) are owned by the
##     LOOP: the in-flight table keeps them alive until the future settles.
##     The worker reads/writes through raw pointers into loop-owned buffers.
##   * Cancelling a future abandons the *result* only — the operation runs to
##     completion (a worker syscall cannot be aborted), then the item is
##     freed. Nothing leaks, nothing is freed early.
##
## Both file and s3 backends are covered by the same bridge: the synchronous
## backend call (including s3's httpclient round-trip) runs inside the worker,
## where blocking is the job. No backend was rewritten.
##
## Blueprint: vendor/chronos_file_pkg/chronos_file/thread_pool_io.nim.

import std/[atomics, locks, os, options, sequtils, tables]
import std/typedthreads
import chronos
import chronos/threadsync
import blobstore
import common
import zstd_worker

when defined(nimdoc):
  type ThreadSignalPtr* = ptr object
    discard

const
  DefaultPoolSize = 4
    ## Workers for blob ops. Disk (or s3 latency) dominates; 4 covers a flush
    ## (hundreds of small pages) without oversubscribing.

type
  BlobOpKind = enum
    bokPut       ## compress + put        -> new blob id
    bokGet       ## get + decompress      -> page bytes
    bokPutRoot   ## compress + putRoot    -> ()
    bokGetRoot   ## getRoot + decompress  -> root bytes

  BlobJobObj = object
    ## Manually allocated POD. Fields above the divider are touched by the
    ## worker; below, loop-only.
    # --- worker-visible: POD only
    kind: BlobOpKind
    store: BlobStore          ## trait ref is a plain pointer for the worker;
                              ## backends are stateless/thread-safe (file: pure
                              ## syscalls; s3: per-request client under its lock)
    inPtr: pointer            ## payload to compress/write (bokPut/bokPutRoot)
    inLen: int
    namePtr: cstring          ## root name (bokPutRoot/bokGetRoot)
    outPtr: pointer           ## loop-owned output buffer (bokGet/bokGetRoot:
                              ## raw decompressed bytes land here)
    outCap: int
    outLen: int               ## bytes written by the worker
    compPtr: pointer          ## compress scratch (allocShared, worker writes,
                              ## loop frees) — the backend reads it via
                              ## toOpenArray; no GC object is ever created on
                              ## the worker side
    compCap: int
    compLen: int
    blobId: ByteArr16         ## in: id to fetch (bokGet); out: new id (bokPut)
    ok: bool                  ## worker success flag
    errBuf: array[96, char]   ## truncated error message, if any
    errLen: int
    next: ptr BlobJobObj      ## intrusive link (submit/completion/free lists)
    # --- loop-thread only
    payload: seq[byte]        ## keeps inPtr alive until settle
    nameStr: string           ## keeps namePtr alive
    resultBuf: seq[byte]      ## keeps outPtr alive (worker writes into it)
    resFut: FutureBase        ## the caller's future
    cancelRequested: bool

  BlobJob = ptr BlobJobObj

  BlobPoolObj = object
    workers: seq[Thread[ptr BlobPoolObj]]
    lock: Lock
    cond: Cond
    submitHead, submitTail: BlobJob
    completionLock: Lock
    completionHead, completionTail: BlobJob
    signal: ThreadSignalPtr
    signalPending: Atomic[bool]
    stopping: Atomic[bool]
    dispatcherFut: FutureBase
    freeHead: BlobJob
    freeCount: int
    inflight: int             ## loop-only
    closed: bool

  BlobPool* = ref object
    inner: ptr BlobPoolObj

const MaxFreeJobs = 32

proc pushBack(head, tail: var BlobJob; job: BlobJob) =
  job.next = nil
  if tail.isNil: head = job
  else: tail.next = job
  tail = job

proc popFront(head, tail: var BlobJob): BlobJob =
  result = head
  if not result.isNil:
    head = result.next
    if head.isNil: tail = nil
    result.next = nil

proc popAll(head, tail: var BlobJob): BlobJob =
  result = head
  head = nil
  tail = nil

proc newJob(pool: ptr BlobPoolObj): BlobJob =
  if pool.freeHead.isNil:
    result = cast[BlobJob](allocShared0(sizeof(BlobJobObj)))
  else:
    result = pool.freeHead
    pool.freeHead = result.next
    dec pool.freeCount

proc freeJob(pool: ptr BlobPoolObj; job: BlobJob) =
  ## Loop thread only. `reset` runs GC-field destructors on the owning
  ## thread; plain deallocShared would leak them.
  reset(job.payload)
  reset(job.nameStr)
  reset(job.resultBuf)
  reset(job.resFut)
  if pool.closed or pool.freeCount >= MaxFreeJobs:
    deallocShared(job)
  else:
    zeroMem(addr job.errBuf[0], sizeof(job.errBuf))
    job.errLen = 0
    job.cancelRequested = false
    job.next = pool.freeHead
    pool.freeHead = job
    inc pool.freeCount

proc jobError(job: BlobJob): ref CatchableError =
  var msg = ""
  for i in 0..<job.errLen: msg.add(job.errBuf[i])
  newException(IOError, msg)

proc workerFail(job: BlobJob; msg: string) {.inline.} =
  job.ok = false
  let n = min(msg.len, job.errBuf.len - 1)
  if n > 0:
    copyMem(addr job.errBuf[0], unsafeAddr msg[0], n)
    job.errLen = n

proc runJob(job: BlobJob) {.gcsafe, raises: [].} =
  ## Worker thread. May touch ONLY the POD half of the job. The compress
  ## scratch and openArray wrapping keep every value POD — no GC object is
  ## created or destroyed here.
  try:
    case job.kind
    of bokPut:
      job.compLen = compressInto(job.inPtr, job.inLen, job.compPtr, job.compCap)
      if job.compLen < 0:
        workerFail(job, "zstd compress failed")
      else:
        job.blobId = job.store.put(
          toOpenArray(cast[ptr UncheckedArray[byte]](job.compPtr),
                      0, job.compLen - 1))
        job.ok = true
    of bokPutRoot:
      job.compLen = compressInto(job.inPtr, job.inLen, job.compPtr, job.compCap)
      if job.compLen < 0:
        workerFail(job, "zstd compress failed")
      else:
        job.store.putRoot($job.namePtr,
          toOpenArray(cast[ptr UncheckedArray[byte]](job.compPtr),
                      0, job.compLen - 1))
        job.ok = true
    of bokGet:
      let data = job.store.get(job.blobId)
      if data.isNone:
        workerFail(job, "blob not found")
      else:
        # `data` is a seq created by the backend ON THIS WORKER — safe: it is
        # a local GC value living and dying inside this frame (backend calls
        # are plain Nim procs on this thread); only its BYTES cross back via
        # the POD outPtr.
        let src = data.get
        if src.len > 0:
          let n = decompressInto(src[0].unsafeAddr, src.len, job.outPtr, job.outCap)
          if n < 0:
            workerFail(job, "zstd decompress failed")
          else:
            job.outLen = n
            job.ok = true
        else:
          job.outLen = 0
          job.ok = true
    of bokGetRoot:
      let data = job.store.getRoot($job.namePtr)
      if data.isNone:
        workerFail(job, "root not found")
      else:
        let src = data.get
        if src.len > 0:
          let n = decompressInto(src[0].unsafeAddr, src.len, job.outPtr, job.outCap)
          if n < 0:
            workerFail(job, "zstd decompress failed")
          else:
            job.outLen = n
            job.ok = true
        else:
          job.outLen = 0
          job.ok = true
  except Exception as e:
    # trait methods carry no raises pragma; their inference is Exception.
    # The worker reports the failure through POD — the caller's future fails.
    workerFail(job, if e.msg.len > 0: e.msg else: "blob op failed")

proc completionEnqueue(pool: ptr BlobPoolObj; job: BlobJob) =
  acquire(pool.completionLock)
  pushBack(pool.completionHead, pool.completionTail, job)
  release(pool.completionLock)
  if not pool.signalPending.exchange(true, moAcquireRelease):
    discard pool.signal.fireSync()

proc workerMain(pool: ptr BlobPoolObj) {.thread, raises: [].} =
  {.gcsafe.}:
    while true:
      acquire(pool.lock)
      while pool.submitHead.isNil and not pool.stopping.load(moAcquire):
        wait(pool.cond, pool.lock)
      if pool.stopping.load(moAcquire):
        release(pool.lock)
        break
      let job = popFront(pool.submitHead, pool.submitTail)
      release(pool.lock)
      runJob(job)
      completionEnqueue(pool, job)

proc dispatchCompletion(pool: ptr BlobPoolObj; job: BlobJob) =
  ## Loop thread. Settles the future (unless cancelled), then frees the job —
  ## the payload/result buffers are released here, on the owning thread.
  dec pool.inflight
  template fut[T](): Future[T] = cast[Future[T]](job.resFut)
  if not job.resFut.finished():
    if job.cancelRequested:
      job.resFut.cancelAndSchedule()
    elif not job.ok:
      let err = jobError(job)
      cast[Future[void]](job.resFut).fail(err)
    else:
      case job.kind
      of bokPut: fut[ByteArr16]().complete(job.blobId)
      of bokPutRoot: fut[void]().complete()
      of bokGet, bokGetRoot:
        var outSeq = newSeq[byte](job.outLen)
        if job.outLen > 0:
          copyMem(addr outSeq[0], job.outPtr, job.outLen)
        fut[seq[byte]]().complete(outSeq)
  if job.compPtr != nil:
    deallocShared(job.compPtr)
    job.compPtr = nil
    job.compCap = 0
    job.compLen = 0
  freeJob(pool, job)

proc drainCompletions(pool: ptr BlobPoolObj) =
  pool.signalPending.store(false, moRelease)
  acquire(pool.completionLock)
  var localHead = popAll(pool.completionHead, pool.completionTail)
  release(pool.completionLock)
  while not localHead.isNil:
    let job = localHead
    localHead = job.next
    job.next = nil
    dispatchCompletion(pool, job)

const completionBackstop = 50.milliseconds

proc completionDispatcher(pool: ptr BlobPoolObj) {.async: (raises: []).} =
  while not pool.stopping.load(moAcquire):
    try:
      try:
        await pool.signal.wait().wait(completionBackstop)
      except AsyncTimeoutError:
        discard # backstop tick: drain anyway
      except CancelledError:
        return
      except CatchableError:
        if pool.stopping.load(moAcquire): return
        drainCompletions(pool)
        try: await sleepAsync(1.milliseconds) except CatchableError: discard
        continue
      if pool.stopping.load(moAcquire): return
      drainCompletions(pool)
    except CatchableError:
      return

# ═══════════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════════

proc startBlobPool*(numWorkers = DefaultPoolSize): BlobPool =
  ## Create the pool and start its dispatcher on the current event loop.
  ## Call closeBlobPool at shutdown.
  result = BlobPool(inner: cast[ptr BlobPoolObj](allocShared0(sizeof(BlobPoolObj))))
  let p = result.inner
  initLock(p.lock)
  initCond(p.cond)
  initLock(p.completionLock)
  let sig = ThreadSignalPtr.new().expect("eventfd for blob pool")
  p.signal = sig
  p.workers = newSeq[Thread[ptr BlobPoolObj]](numWorkers)
  for i in 0..<numWorkers:
    createThread(p.workers[i], workerMain, p)
  p.dispatcherFut = completionDispatcher(p)

proc closeBlobPool*(pool: BlobPool) {.async.} =
  ## Drain in-flight jobs, stop workers, free the pool. Must run on the loop.
  let p = pool.inner
  # Wait for inflight to hit zero (jobs already submitted run to completion).
  while p.inflight > 0:
    drainCompletions(p)
    if p.inflight > 0:
      await sleepAsync(1.milliseconds)
  p.stopping.store(true, moRelease)
  acquire(p.lock)
  p.cond.broadcast()
  release(p.lock)
  for i in 0..<p.workers.len:
    joinThread(p.workers[i])
  cast[Future[void]](p.dispatcherFut).cancelSoon()
  discard p.signal.close()
  # Free any recycled blocks then the pool itself.
  while p.freeHead != nil:
    let j = p.freeHead
    p.freeHead = j.next
    deallocShared(j)
  while p.submitHead != nil:
    let j = p.submitHead
    p.submitHead = j.next
    deallocShared(j)
  deinitLock(p.completionLock)
  deinitCond(p.cond)
  deinitLock(p.lock)
  deallocShared(p)

proc submit(pool: BlobPool; store: BlobStore; kind: BlobOpKind): BlobJob =
  let p = pool.inner
  result = newJob(p)
  result.kind = kind
  result.store = store
  result.resFut = nil # set by the specific op

proc enqueueJob(pool: BlobPool; job: BlobJob) =
  let p = pool.inner
  if p.closed:
    freeJob(p, job)
    raise newException(IOError, "blob pool is closed")
  inc p.inflight
  acquire(p.lock)
  pushBack(p.submitHead, p.submitTail, job)
  release(p.lock)
  p.cond.signal()

proc armCancel(job: BlobJob; fut: FutureBase) =
  template cb(jobParam: BlobJob): proc (udata: pointer) {.gcsafe, raises: [].} =
    proc (udata: pointer) {.gcsafe, raises: [].} =
      jobParam.cancelRequested = true
  fut.cancelCallback = cb(job)

proc putPageAsync*(pool: BlobPool; store: BlobStore;
                   data: sink seq[byte]): Future[ByteArr16] =
  ## Compress (zstd level 1) and put a page blob. `data` ownership moves to
  ## the pool until the future settles.
  let job = submit(pool, store, bokPut)
  job.payload = data            # loop-owned; keeps inPtr alive
  if job.payload.len > 0:
    job.inPtr = addr job.payload[0]
  job.inLen = job.payload.len
  job.compCap = compressBound(job.inLen) + 16
  job.compPtr = allocShared0(job.compCap)
  let fut = newFuture[ByteArr16]("blob.putPage")
  job.resFut = fut
  armCancel(job, fut)   # op still runs; result is dropped at settle
  enqueueJob(pool, job)
  fut

proc getPageAsync*(pool: BlobPool; store: BlobStore;
                   id: ByteArr16): Future[seq[byte]] =
  ## Get a blob and decompress it. Returns the page bytes.
  let job = submit(pool, store, bokGet)
  job.blobId = id
  job.outCap = zstdDecompressBound()
  job.resultBuf = newSeq[byte](job.outCap)
  job.outPtr = addr job.resultBuf[0]
  let fut = newFuture[seq[byte]]("blob.getPage")
  job.resFut = fut
  armCancel(job, fut)
  enqueueJob(pool, job)
  fut

proc putRootAsync*(pool: BlobPool; store: BlobStore; name: string;
                   data: sink seq[byte]): Future[void] =
  let job = submit(pool, store, bokPutRoot)
  job.payload = data
  if job.payload.len > 0:
    job.inPtr = addr job.payload[0]
  job.inLen = job.payload.len
  job.compCap = compressBound(job.inLen) + 16
  job.compPtr = allocShared0(job.compCap)
  job.nameStr = name
  job.namePtr = cast[cstring](job.nameStr.cstring)
  let fut = newFuture[void]("blob.putRoot")
  job.resFut = fut
  armCancel(job, fut)
  enqueueJob(pool, job)
  fut

proc getRootAsync*(pool: BlobPool; store: BlobStore;
                   name: string): Future[seq[byte]] =
  let job = submit(pool, store, bokGetRoot)
  job.nameStr = name
  job.namePtr = cast[cstring](job.nameStr.cstring)
  job.outCap = zstdDecompressBound()
  job.resultBuf = newSeq[byte](job.outCap)
  job.outPtr = addr job.resultBuf[0]
  let fut = newFuture[seq[byte]]("blob.getRoot")
  job.resFut = fut
  armCancel(job, fut)
  enqueueJob(pool, job)
  fut
