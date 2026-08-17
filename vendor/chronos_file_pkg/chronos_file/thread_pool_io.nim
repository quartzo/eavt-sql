## Thread-pool backend for seekable file I/O. On by default on POSIX;
## `-d:chronosFileNoThreadPool` opts out, `-d:chronosFileThreadPool` forces it in.
## Priority: io_uring → thread pool → synchronous.
##
## A worker syscall cannot be aborted, so on cancel the future stays pending
## until it returns; the caller blocks in `cancelAndWait`, which keeps its
## buffer alive — zero-copy, no use-after-free.

import uring_io # the gate below defers to the ring

const uringWins {.used.} = uringCompiled
  ## Alias keeping `uring_io` referenced so `UnusedImport` never fires.

const threadPoolCompiled* =
  when defined(chronosFileNoThreadPool):
    # Opt-out wins over opt-in. `flush` still spawns a per-call worker thread.
    false
  elif defined(chronosFileThreadPool):
    true
  elif not defined(posix):
    false
  elif uringWins:
    # io_uring covers the same ops without threads; `-d:chronosFileThreadPool`
    # opts back in.
    false
  else:
    true

when threadPoolCompiled:
  import std/[atomics, locks, posix, typedthreads]

  import pkg/chronos
  import pkg/chronos/[osutils, oserrno]

  # `ThreadSignalPtr` (and its nimdoc stub) comes from `common`.
  import common

  {.push raises: [].}

  type
    TpOpKind = enum
      tpoRead
      tpoWrite
      tpoWriteAppend
      tpoFsync
      tpoFdatasync

    TpJobObj = object
      ## Manually allocated (`allocShared0`) rather than a `ref`: ORC refcounts
      ## are per-thread and non-atomic, so a worker writing into a `ref` would
      ## corrupt the loop thread's heap. Fields above the divider are POD the
      ## worker may touch; fields below belong to the loop thread only.
      #
      # --- worker-visible: POD only.
      kind: TpOpKind
      fd: cint
      buf: pointer ## nil for fsync/fdatasync
      size: int
      offset: int64 ## 0 and unused for fsync/fdatasync and append writes
      resCode: int ## syscall retval, or 0 on failure
      errCode: int32 ## errno on failure, else 0
      next: TpJob ## intrusive link, shared by submit/completion/free lists
      #
      # --- loop-thread only.
      cancelRequested: bool
      context: string ## Caller-supplied literal ("read", "write", …)
      resFut: Future[int] ## OwnCancelSchedule; drives caller

    TpJob = ptr TpJobObj

    ThreadPoolObj = object
      workers: seq[Thread[ptr ThreadPoolObj]]
      lock: Lock
      cond: Cond
      submitHead: TpJob
      submitTail: TpJob
      completionLock: Lock
      completionHead: TpJob
      completionTail: TpJob
      signal: ThreadSignalPtr ## loop-side wakeup (shared eventfd)
      signalPending: Atomic[bool] ## `fireSync` coalescing flag
      stopping: Atomic[bool]
      dispatcherFut: FutureBase
        ## Captured so `closePool` can `cancelSoon` before closing the signal /
        ## deinit-ing locks. No wait needed: the closure holds an ORC ref to the
        ## pool, keeping it alive past teardown.
      freeHead: TpJob
        ## Recycle list of spent job blocks; loop-thread only, so reuse needs no
        ## lock and skips the allocator on the hot path.
      freeCount: int
      inflight: int ## Loop-thread only; jobs submitted but not yet dispatched
      closed: bool
      ownerThreadId: int
        ## Only the owning thread may `closePool`: it clears its own `gPool`
        ## threadvar, and a cross-thread call would leave it pointing at freed
        ## memory.

    ThreadPool* = ref ThreadPoolObj

  const configuredPoolSize {.intdefine: "chronosFileThreadPoolSize".} = 0
    ## `-d:chronosFileThreadPoolSize=N` pins the worker count (uncapped); 0 keeps
    ## the `max(4, ncpu)` heuristic. Cost is per event-loop thread (`gPool` is a
    ## threadvar).

  when configuredPoolSize <= 0:
    import std/cpuinfo

  proc poolSize(): int =
    when configuredPoolSize > 0:
      configuredPoolSize
    else:
      min(max(4, countProcessors()), 32)

  const maxFreeJobs = 64 ## Cap on the recycle list; beyond it `freeJob` deallocates.

  proc pushBack(head, tail: var TpJob, job: TpJob) =
    ## Callers hold the queue's lock; shared by submit/completion.
    job.next = nil
    if tail.isNil:
      head = job
    else:
      tail.next = job
    tail = job

  proc popFront(head, tail: var TpJob): TpJob =
    result = head
    if not result.isNil:
      head = result.next
      if head.isNil:
        tail = nil
      result.next = nil

  proc popAll(head, tail: var TpJob): TpJob =
    result = head
    head = nil
    tail = nil

  proc newJob(
      pool: ThreadPool,
      kind: TpOpKind,
      fd: cint,
      buf: pointer,
      size: int,
      offset: int64,
      context: string,
      resFut: Future[int],
  ): TpJob =
    ## Loop thread only. Every field is rewritten: recycled blocks are not
    ## re-zeroed, so a stale `cancelRequested` would cancel a fresh future.
    if pool.freeHead.isNil:
      result = cast[TpJob](allocShared0(sizeof(TpJobObj)))
    else:
      result = pool.freeHead
      pool.freeHead = result.next
      dec pool.freeCount
    result.kind = kind
    result.fd = fd
    result.buf = buf
    result.size = size
    result.offset = offset
    result.resCode = 0
    result.errCode = 0
    result.next = nil
    result.cancelRequested = false
    result.context = context
    result.resFut = resFut

  proc freeJob(pool: ThreadPool, job: TpJob) =
    ## Loop thread only, after the worker released the job. `reset` runs the GC
    ## fields' destructors on their owning thread; `deallocShared` alone would
    ## leak them.
    reset(job.context)
    reset(job.resFut)
    if pool.isNil or pool.closed or pool.freeCount >= maxFreeJobs:
      deallocShared(job)
    else:
      job.next = pool.freeHead
      pool.freeHead = job
      inc pool.freeCount

  proc runJob(job: TpJob) {.gcsafe, raises: [].} =
    ## Worker thread. Records the outcome in POD fields only — must not touch
    ## the GC-managed half of `job` (see `TpJobObj`).
    template settle(call: untyped) =
      let res = handleEintr(call)
      if res < 0:
        job.resCode = 0
        job.errCode = int32(osLastError())
      else:
        job.resCode = int(res)
        job.errCode = 0

    case job.kind
    of tpoRead:
      settle(posix.pread(job.fd, job.buf, job.size, Off(job.offset)))
    of tpoWrite:
      settle(posix.pwrite(job.fd, job.buf, job.size, Off(job.offset)))
    of tpoWriteAppend:
      # Sequential `write(2)` — kernel picks the position (atomic append).
      settle(posix.write(job.fd, job.buf, job.size))
    of tpoFsync:
      settle(fsync(job.fd))
    of tpoFdatasync:
      when hasFdatasync:
        settle(fdatasync(job.fd))
      else:
        settle(fsync(job.fd))

  proc completionEnqueue(pool: ptr ThreadPoolObj, job: TpJob) =
    ## Append `job` to the completion queue and (coalesced) wake the loop. The
    ## lock's release/acquire also publishes the worker's `resCode`/`errCode`.
    acquire(pool.completionLock)
    pushBack(pool.completionHead, pool.completionTail, job)
    release(pool.completionLock)
    if not pool.signalPending.exchange(true, moAcquireRelease):
      var fired = false
      for _ in 0 ..< 3:
        if pool.signal.fireSync().isOk():
          fired = true
          break
      if not fired:
        # Latch ours but no fire got through: leaving it set would suppress every
        # future wake. Drop and re-fire; an extra fire is harmless.
        pool.signalPending.store(false, moRelease)
        discard pool.signal.fireSync()

  proc enqueue(pool: ThreadPool, job: TpJob) =
    ## Loop thread only — hence `inflight` is a plain int.
    if pool.closed:
      # Stale ref after `closePool`; the lock is deinit-ed, so fail the future
      # and drop the job instead of touching it.
      if not job.resFut.finished():
        job.resFut.fail(newAsyncFileError("thread_pool: pool is closed"))
      freeJob(pool, job)
      return
    inc pool.inflight
    acquire(pool.lock)
    pushBack(pool.submitHead, pool.submitTail, job)
    release(pool.lock)
    pool.cond.signal()

  proc workerMain(pool: ptr ThreadPoolObj) {.thread, raises: [].} =
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

  proc settleJob(job: TpJob) =
    if job.resFut.finished():
      return
    if job.cancelRequested:
      # Syscall returned, so the kernel is done with the buffer — only now safe
      # to deliver `CancelledError`. fsync callers await under `noCancel`, which
      # Defects on a Cancelled inner future, so fail instead (as `closePool`'s
      # sweep does).
      if job.kind in {tpoFsync, tpoFdatasync}:
        job.resFut.fail(newAsyncFileError(job.context & ": cancelled"))
      else:
        job.resFut.cancelAndSchedule()
      return
    case job.kind
    of tpoRead, tpoFsync, tpoFdatasync:
      if job.errCode != 0:
        job.resFut.fail(newAsyncFileOsError(OSErrorCode(job.errCode), job.context))
      else:
        job.resFut.complete(job.resCode)
    of tpoWrite, tpoWriteAppend:
      if job.errCode != 0:
        job.resFut.fail(newAsyncFileOsError(OSErrorCode(job.errCode), job.context))
      elif job.resCode == 0:
        # 0-byte write with no error → EIO, so a partial-write loop cannot spin
        # on no progress.
        job.resFut.fail(newAsyncFileOsError(oserrno.EIO, job.context))
      else:
        job.resFut.complete(job.resCode)

  proc dispatchCompletion(pool: ThreadPool, job: TpJob) =
    ## Safe to free: worker done and future settled, so the cancel callback can
    ## no longer reach this pointer.
    settleJob(job)
    freeJob(pool, job)
    dec pool.inflight

  proc drainCompletions(pool: ThreadPool) =
    pool.signalPending.store(false, moRelease)
    acquire(pool.completionLock)
    var localHead = popAll(pool.completionHead, pool.completionTail)
    release(pool.completionLock)
    while not localHead.isNil:
      let job = localHead
      localHead = job.next
      job.next = nil
      dispatchCompletion(pool, job)

  const
    minRetryDelayMs = 1
    maxRetryDelayMs = 50
    completionBackstopInterval = 50.milliseconds
      ## Always-armed backstop in case `fireSync` fails while `signal.wait()`
      ## keeps blocking; without it in-flight futures would hang. An idle tick
      ## costs one empty drain.

  proc completionDispatcher(pool: ThreadPool) {.async: (raises: []).} =
    var retryDelayMs = minRetryDelayMs
    while not pool.stopping.load(moAcquire):
      try:
        try:
          await pool.signal.wait().wait(completionBackstopInterval)
        except AsyncTimeoutError:
          # Backstop tick — fall through to the drain below.
          discard
      except CancelledError:
        return
      except CatchableError:
        if pool.stopping.load(moAcquire):
          return
        # Signal broken while the pool is live: drain here or the latched
        # `signalPending` would suppress every wake and hang in-flight ops.
        drainCompletions(pool)
        try:
          await sleepAsync(retryDelayMs.milliseconds)
        except CancelledError:
          return
        except CatchableError:
          discard
        retryDelayMs = min(retryDelayMs * 2, maxRetryDelayMs)
        continue
      retryDelayMs = minRetryDelayMs
      if pool.stopping.load(moAcquire):
        return
      drainCompletions(pool)

  proc newThreadPool(): ThreadPool {.raises: [CatchableError].} =
    result = ThreadPool()
    result.ownerThreadId = getThreadId()
    initLock(result.lock)
    initCond(result.cond)
    initLock(result.completionLock)
    result.signal = ThreadSignalPtr.new().valueOr:
      deinitLock(result.lock)
      deinitCond(result.cond)
      deinitLock(result.completionLock)
      raise newAsyncFileError("thread_pool: cannot create completion signal: " & error)
    let n = poolSize()
    result.workers = newSeq[Thread[ptr ThreadPoolObj]](n)
    # Unwind partial thread creation, else survivors keep a dangling pool ptr.
    var created = 0
    var failure: ref CatchableError = nil
    while created < n:
      try:
        createThread(
          result.workers[created], workerMain, cast[ptr ThreadPoolObj](result)
        )
      except CatchableError as e:
        failure = e
        break
      inc created
    if not failure.isNil:
      acquire(result.lock)
      result.stopping.store(true, moRelease)
      broadcast(result.cond)
      release(result.lock)
      for i in 0 ..< created:
        joinThread(result.workers[i])
      result.workers.setLen(0)
      discard result.signal.close()
      deinitLock(result.lock)
      deinitCond(result.cond)
      deinitLock(result.completionLock)
      raise newAsyncFileError("thread_pool: initialization failed: " & failure.msg)
    # Spawned after workers exist; neither call can raise.
    let dispFut = completionDispatcher(result)
    result.dispatcherFut = dispFut
    asyncSpawn dispFut

  var gPool {.threadvar.}: ThreadPool
  var gPoolProbed {.threadvar.}: bool
  var gPoolFailure {.threadvar.}: string

  proc closePool*(p: ThreadPool) {.raises: [].} =
    ## Stop workers, drain completions, release OS resources. Idempotent.
    ## Test-only teardown; normal operation keeps the pool for process lifetime.
    ##
    ## The event loop must keep running afterwards: `cancelSoon` settles the
    ## dispatcher on a later tick, and its closure holds the last pool reference
    ## until then.
    if p.isNil or p.closed:
      return
    # A cross-thread call would leave the owner's `gPool` dangling.
    doAssert getThreadId() == p.ownerThreadId,
      "thread_pool: closePool must run on the pool's owner thread"
    # Broadcast under the lock so a worker between checking `stopping` and
    # waiting cannot miss the wakeup.
    acquire(p.lock)
    p.stopping.store(true, moRelease)
    broadcast(p.cond)
    release(p.lock)

    for i in 0 ..< p.workers.len:
      joinThread(p.workers[i])
    p.workers.setLen(0)

    # Workers exit on `stopping` with jobs still queued; settle those futures.
    acquire(p.lock)
    var pending = popAll(p.submitHead, p.submitTail)
    release(p.lock)
    while not pending.isNil:
      let job = pending
      pending = job.next
      job.next = nil
      if not job.resFut.finished():
        if job.kind in {tpoFsync, tpoFdatasync}:
          # `flush` awaits under `noCancel`, which Defects on a Cancelled inner
          # future — fail instead.
          job.resFut.fail(
            newAsyncFileError("flush: thread pool closed before the sync could run")
          )
        else:
          job.resFut.cancelAndSchedule()
      freeJob(p, job)
      dec p.inflight

    drainCompletions(p)
    doAssert p.inflight == 0, "thread_pool: inflight jobs remain after closePool drain"

    # Drain the recycle list; after `closed = true` `freeJob` deallocates directly.
    var recycled = p.freeHead
    p.freeHead = nil
    p.freeCount = 0
    while not recycled.isNil:
      let job = recycled
      recycled = job.next
      deallocShared(job)

    if not p.dispatcherFut.isNil and not p.dispatcherFut.finished():
      p.dispatcherFut.cancelSoon()

    discard p.signal.close()
    p.signal = nil
    deinitLock(p.lock)
    deinitCond(p.cond)
    deinitLock(p.completionLock)
    p.closed = true

    if gPool == p:
      gPool = nil
      gPoolProbed = false
      gPoolFailure = ""

  proc workerCount*(p: ThreadPool): int {.raises: [].} =
    ## Number of worker threads. Test-only: saturation walls must size off the
    ## live pool since `-d:chronosFileThreadPoolSize=N` pins the count uncapped.
    p.workers.len

  proc inflightJobs*(p: ThreadPool): int {.raises: [].} =
    ## Loop-thread count of jobs submitted but not yet settled. Test-only: pins
    ## that an op really entered the pool (other backends leave this at 0).
    p.inflight

  proc threadPoolInstance*(): ThreadPool {.raises: [].} =
    ## The calling thread's pool, or `nil` when unusable. First call lazily
    ## creates it, latching any failure so the probe runs once.
    ##
    ## The owning thread must live until process exit or call `closePool` first:
    ## workers hold a raw `ptr` and would dereference freed memory otherwise.
    if not gPoolProbed:
      gPoolProbed = true
      gPool =
        try:
          newThreadPool()
        except CatchableError as e:
          # Latch the message so an app can detect the fallback to the blocking
          # inline path via `threadPoolFailure`.
          gPoolFailure = e.msg
          nil
    gPool

  proc threadPoolAvailable*(): bool {.raises: [].} =
    ## True when the backend is compiled in and usable on this thread.
    ##
    ## **Not a passive query**: the first call lazily constructs the pool
    ## (spawning workers and the completion signal, held until `closePool` or
    ## process exit). Call from an event-loop thread.
    not threadPoolInstance().isNil

  proc threadPoolFailure*(): string {.raises: [].} =
    ## `newThreadPool` failure message latched by the first probe, or "" while
    ## usable / not yet probed. Detects degradation to the synchronous path.
    gPoolFailure

  proc wireTpCancel(retFut: Future[int], job: TpJob) =
    ## On cancel, mark `cancelRequested`; `settleJob` delivers `CancelledError`
    ## once the worker finishes. Idempotent (chronos re-invokes it each tick).
    proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
      job.cancelRequested = true

    retFut.cancelCallback = onCancel

  proc tpReadSeam*(
      p: ThreadPool, fd: cint, buf: pointer, size: int, offset: int64, context: string
  ): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
    ## Submit one read; `buf` is caller-owned (zero-copy).
    let retFut = newFuture[int]("chronos_file.tpRead", {FutureFlag.OwnCancelSchedule})
    let job = newJob(p, tpoRead, fd, buf, size, offset, context, retFut)
    wireTpCancel(retFut, job)
    enqueue(p, job)
    return retFut

  proc tpWriteSeam*(
      p: ThreadPool,
      fd: cint,
      buf: pointer,
      size: int,
      offset: int64,
      context: string,
      appendMode: bool,
  ): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
    ## Submit one write; `buf` is caller-owned. `appendMode` selects sequential
    ## `write` instead of `pwrite`.
    let retFut = newFuture[int]("chronos_file.tpWrite", {FutureFlag.OwnCancelSchedule})
    let job =
      if appendMode:
        newJob(p, tpoWriteAppend, fd, buf, size, 0, context, retFut)
      else:
        newJob(p, tpoWrite, fd, buf, size, offset, context, retFut)
    wireTpCancel(retFut, job)
    enqueue(p, job)
    return retFut

  proc tpFsyncSeam*(
      p: ThreadPool, fd: cint, dataOnly: bool, context: string
  ): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
    ## Submit an fsync/fdatasync. No buffer, so no drain-on-cancel; `flush` wraps
    ## this in `noCancel`. Cancellation settles with `AsyncFileError`, not
    ## `CancelledError`: `noCancel` Defects on a Cancelled inner future, so
    ## `settleJob`/`closePool` fail fsync jobs instead.
    let kind = if dataOnly: tpoFdatasync else: tpoFsync
    let retFut = newFuture[int]("chronos_file.tpFsync", {FutureFlag.OwnCancelSchedule})
    let job = newJob(p, kind, fd, nil, 0, 0, context, retFut)
    wireTpCancel(retFut, job)
    enqueue(p, job)
    return retFut

  {.pop.}
else:
  proc threadPoolAvailable*(): bool {.raises: [].} =
    false

  proc threadPoolFailure*(): string {.raises: [].} =
    ""
