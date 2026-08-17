## `AsyncFile` lifecycle and positioning: open/wrap constructors, size/position
## queries, the readLine read-ahead helpers and the open/closed guards.

import std/[posix, syncio]
from std/os import FilePermission

import pkg/chronos
import pkg/chronos/[osutils, oserrno]

import uring_io, thread_pool_io, common, posix_backend

const seekSeamSuspends* = uringCompiled or threadPoolCompiled
  ## Single answer to "can a seekable op still be in flight after the seam
  ## returned?" — every consumer branches on this rather than naming a backend.
  ## A new suspending backend extends this expression.

{.push raises: [].}

proc checkOpen*(f: AsyncFile) {.raises: [AsyncFileError].} =
  ## Guards public operations against an uninitialized or closed handle: a
  ## default-constructed `AsyncFile()` owns no fd, and after `close` the
  ## descriptor may already have been reused by the OS, so touching it would
  ## hit an unrelated fd.
  if not f.opened:
    raise newAsyncFileError("operation on an uninitialized AsyncFile")
  if f.closed:
    raise newAsyncFileError("operation on a closed AsyncFile")
  if f.closing:
    raise newAsyncFileError("operation on an AsyncFile that is being closed")

proc usabilityError*(f: AsyncFile): ref AsyncFileError =
  ## Same guard as `checkOpen` for the raw-future procs, which must `fail` the
  ## future rather than `raise`: returns the error to fail with, or `nil` when
  ## the handle is usable.
  if not f.opened:
    newAsyncFileError("operation on an uninitialized AsyncFile")
  elif f.closed:
    newAsyncFileError("operation on a closed AsyncFile")
  elif f.closing:
    newAsyncFileError("operation on an AsyncFile that is being closed")
  else:
    nil

proc isOpen*(f: AsyncFile): bool =
  ## True while the handle is usable: a constructor (`openAsync`/`newAsyncFile`)
  ## opened it and neither `close` nor `closeWait` has been called (a
  ## `closeWait` that is still draining already counts as not open). This is
  ## the public query for handle state — the raw object fields are internal.
  f.opened and not f.closed and not f.closing

proc isClosed*(f: AsyncFile): bool =
  ## True once `close` has run or `closeWait` has started (including while it
  ## is still draining). A default-constructed `AsyncFile()` was never opened,
  ## so it is neither open nor closed: `isOpen` and `isClosed` are both false
  ## for it (it is merely inert).
  f.opened and (f.closed or f.closing)

proc reconcile*(f: AsyncFile) =
  ## Drops any seekable `readLine` read-ahead and rewinds `f.offset` to the
  ## logical read position, so a following `pread`/`pwrite` at `f.offset` lands
  ## where `getFilePos` reports. Preserves `getFilePos` (offset decreases by
  ## exactly the discarded buffered amount). The dropped bytes are re-pread by
  ## the next read — a one-time cost only at a readLine→other-op transition.
  ## No-op for non-seekable fds (which never populate `rbuf`).
  if f.seekable and f.rbuf.len > f.rpos:
    f.offset.dec(f.rbuf.len - f.rpos)

  f.rbuf.setLen(0)
  f.rpos = 0

proc checkOffsetIdle*(f: AsyncFile) {.raises: [AsyncFileBusyError].} =
  ## Reject an op that mutates the shared offset / read-ahead (a direct `offset`
  ## write or `reconcile`) while a seekable implicit-offset op holds the slot.
  ## Unlike `acquireOffsetGuard` it does *not* take the slot: positioning ops
  ## (`setFilePos`/`setFileSize`) and the positioned write (`writeBufferAt`) touch
  ## that state synchronously with no seam await, so they only need turning away,
  ## not to hold it. No-op for non-seekable fds; positioned reads
  ## (`readAt`/`readBufferAt`) never touch the state and skip this.
  if f.seekable and f.seekOpInFlight:
    raise newAsyncFileBusyError(
      "a seekable read/write/readLine is already in progress on this handle"
    )

proc acquireOffsetGuard*(f: AsyncFile) {.raises: [AsyncFileBusyError].} =
  ## Take the single in-flight `offset` slot for a seekable implicit-offset op,
  ## raising `AsyncFileBusyError` if one is already held (see `seekOpInFlight`).
  ## No-op for non-seekable fds, which use the `readFut`/`writeFut` guards.
  ## Prefer the `withOffsetGuard` template, which pairs this with
  ## `releaseOffsetGuard` correctly (acquire before the `try`, release in
  ## `finally`); these raw procs are exported only for the tests.
  checkOffsetIdle(f)
  if f.seekable:
    f.seekOpInFlight = true

proc releaseOffsetGuard*(f: AsyncFile) =
  ## Releases the slot taken by `acquireOffsetGuard`. No-op for non-seekable fds.
  if f.seekable:
    f.seekOpInFlight = false

template withOffsetGuard*(f: AsyncFile, alreadyGuarded: bool, body: untyped) =
  ## Run `body` (a seekable implicit-offset op) holding the single `offset` slot
  ## for its whole duration, releasing it on every exit (normal/`return`/raise).
  ## Acquire is *outside* the `try`, so a busy reject releases nothing — the one
  ## place the acquire-before-try pairing lives. See `acquireOffsetGuard`.
  ##
  ## `alreadyGuarded = true` neither takes nor releases the slot (the caller
  ## already holds it for the whole op, e.g. a multi-chunk read whose leaf chunks
  ## must not re-take it). A defaulted single template can't replace the two
  ## overloads: Nim won't bind a trailing colon-block past a defaulted parameter.
  if not alreadyGuarded:
    acquireOffsetGuard(f)
  try:
    body
  finally:
    if not alreadyGuarded:
      releaseOffsetGuard(f)

template withOffsetGuard*(f: AsyncFile, body: untyped) =
  ## The unconditional form of the three-argument template (`alreadyGuarded =
  ## false`): for a leaf/op that always owns the slot for its whole duration.
  ## See the three-argument overload for the acquire-before-try contract.
  withOffsetGuard(f, false, body)

when threadPoolCompiled:
  # Adapt the pool seams to `seekableSeam`'s uniform signature. The write seam
  # takes `f` for `f.appendMode`: a worker can issue the sequential `write(2)`
  # append needs.
  proc poolReadSeam(
      f: AsyncFile,
      p: ThreadPool,
      buf: pointer,
      size: int,
      offset: int64,
      context: string,
  ): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
    return tpReadSeam(p, cint(f.fd), buf, size, offset, context)

  proc poolWriteSeam(
      f: AsyncFile,
      p: ThreadPool,
      buf: pointer,
      size: int,
      offset: int64,
      context: string,
  ): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
    return tpWriteSeam(p, cint(f.fd), buf, size, offset, context, f.appendMode)

template seekableSeam(
    f: AsyncFile,
    buf: pointer,
    size: int,
    offset: int64,
    context: string,
    opName: string,
    pinAppend: static bool,
    ringEligible: untyped,
    uringSeam: untyped,
    poolSeam: untyped,
    syncBody: untyped,
) =
  ## Shared body of the seekable seams, spliced in as each proc's whole body so
  ## its `return`s leave the seam. Steps: reject a negative offset; try each
  ## suspending backend in order (io_uring → pool) via `dispatchTo`; otherwise
  ## complete inline from `syncBody`.
  ##
  ## Seams share one body and backends share `dispatchTo`, so the close-drain
  ## guard that `closeWait` relies on lives in one place. Non-`untyped` params
  ## expand at each use site, so pass side-effect-free expressions.
  #
  # Derived from the literal `opName` so the two seams cannot disagree; a `const`
  # so it satisfies `newFuture`'s `static string`.
  const futId = "chronos_file." & opName & "Seekable"
  #
  # A negative offset has no positioned meaning — reject it here, the single
  # guard for all backends, before the io_uring `uint64(offset)` cast (io_uring
  # reads `(u64)-1` as "current file position", diverging from `pread`/`pwrite`
  # which EINVAL). Also catches a per-chunk `offset + written` that wrapped
  # negative. The implicit-offset path feeds `f.offset` (kept >= 0), so it never
  # fires there.
  if offset < 0:
    return failedFuture(
      futId, newAsyncFileError("negative " & opName & " offset: " & $offset)
    )
  #
  template dispatchTo(instance: untyped, seamCall: untyped) =
    ## When `instance` is usable, re-check the handle per chunk, submit, and
    ## register the future for `closeWait`'s drain. The per-chunk re-check is
    ## load-bearing: refill/partial-write loops re-enter, and a chunk slipping
    ## in after `closeWait` snapshotted `seekFuts` would leak the fd. On
    ## `f.closing` a chunk of an already-tracked op is owed `CancelledError`
    ## (chronos forbids `fail`-ing with it, hence `cancelAndSchedule`); a
    ## brand-new op is rejected with an error by the entry guards.
    if not instance.isNil:
      if f.closing:
        return cancelledFuture(futId)
      let uerr = usabilityError(f)
      if not uerr.isNil:
        return failedFuture(futId, uerr)
      let fut = seamCall
      trackSeekFut(f, fut) # let close/closeWait drain it if still in flight
      return fut

  when uringCompiled:
    # Ring-eligible fds only: a non-seekable fd needs ESPIPE from the sync tail
    # (an io_uring op on a pipe would block instead), and append has no
    # write-at-end mode.
    when pinAppend:
      # Debug tripwire against routing append through the ring without wiring
      # `trackSeekFut`.
      assert not (ringEligible and f.appendMode)
    let u =
      if ringEligible:
        uringInstance()
      else:
        nil
    dispatchTo(u, uringSeam(u, cint(f.fd), buf, size, offset, context))
  when threadPoolCompiled:
    # Eligibility is `f.seekable` alone — a worker runs a plain sequential
    # `write(2)` for append. Non-seekable fds still fall through so a
    # misdirected `*At` gets its ESPIPE from the sync tail.
    let p =
      if f.seekable:
        threadPoolInstance()
      else:
        nil
    dispatchTo(p, poolSeam(f, p, buf, size, offset, context))
  let syncFut = newFuture[int](futId)
  try:
    syncFut.complete(syncBody)
  except AsyncFileError as e:
    syncFut.fail(e)
  return syncFut

proc readSeekable*(
    f: AsyncFile, buf: pointer, size: int, offset: int64, context = ""
): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
  ## The single async seam for a *seekable* read: one read of up to `size` bytes
  ## into `buf` at the absolute `offset`, returning the bytes read (0 = EOF).
  ##
  ## Offset-agnostic — it never touches `f.offset`; the caller owns all offset
  ## bookkeeping. Every seekable read in the library funnels through here
  ## (`readBuffer`/`readBufferAt` and `readLine`'s read-ahead refill), so this is
  ## the one place the backend is chosen.
  ##
  ## Backend order: io_uring → thread pool → synchronous. The suspending
  ## backends yield until the op completes and are cancellable (draining the
  ## in-flight op first); the synchronous fallback completes inline and never
  ## yields to the dispatcher.
  seekableSeam(
    f,
    buf,
    size,
    offset,
    context,
    opName = "read",
    pinAppend = false,
    ringEligible = f.seekable,
    uringSeam = uringReadSeam,
    poolSeam = poolReadSeam,
    syncBody = doPread(cint(f.fd), buf, size, offset, context),
  )

proc writeSeekable*(
    f: AsyncFile, buf: pointer, size: int, offset: int64, context = ""
): Future[int] {.async: (raw: true, raises: [AsyncFileError, CancelledError]).} =
  ## The single async seam for a *seekable* write: one write of up to `size`
  ## bytes from `buf`, returning the bytes written (> 0).
  ##
  ## Append-aware — under `fmAppend` it uses a sequential `write` (the kernel
  ## appends atomically, so `offset` is ignored; `pwrite` would honour `offset`
  ## and overwrite on POSIX-conforming platforms), otherwise a `pwrite` at the
  ## absolute `offset`. Offset-agnostic: it never touches `f.offset`, so the
  ## caller drives the partial-write loop and offset bookkeeping. The companion
  ## of `readSeekable`.
  ##
  ## Backend order: io_uring → thread pool → synchronous. The suspending
  ## backends yield until the op completes and are cancellable (draining the
  ## in-flight op first); the synchronous fallback completes inline and never
  ## yields to the dispatcher.
  ##
  ## Append is io_uring's one carve-out: it needs a sequential `write(2)`
  ## (io_uring has no write-at-end mode) and falls through to the sync tail, so
  ## it is neither suspended nor tracked — a large append can still block the
  ## loop. The thread-pool backend has no such carve-out: a worker issues the
  ## `write(2)` itself, so pool builds suspend and drain append writes like any
  ## other chunk.
  seekableSeam(
    f,
    buf,
    size,
    offset,
    context,
    opName = "write",
    pinAppend = true,
    ringEligible = f.seekable and not f.appendMode,
    uringSeam = uringWriteSeam,
    poolSeam = poolWriteSeam,
    syncBody = (
      if f.appendMode:
        doWrite(cint(f.fd), buf, size, context)
      else:
        doPwrite(cint(f.fd), buf, size, offset, context)
    ),
  )

proc refillReadBuf*(
    f: AsyncFile, chunkSize: int, alreadyGuarded: bool
): Future[bool] {.async: (raises: [AsyncFileError, CancelledError]).} =
  ## Refills `f.rbuf` in place with a fresh chunk read at `f.offset` (rpos = 0)
  ## through the `readSeekable` seam, advancing `f.offset` by the bytes read.
  ## Returns false at EOF (rbuf left empty). Seekable `readLine` helper; only
  ## called once the previous buffer is exhausted (rpos == rbuf.len), so
  ## overwriting `rbuf` drops no unconsumed bytes. Reuses the existing `rbuf`
  ## allocation across refills.
  ##
  ## Single-in-flight guard: `readLine` holds the `offset` slot once for the
  ## whole line and calls this with `alreadyGuarded = true`; standalone (false)
  ## it takes the slot.
  ##
  ## Cancellation / error safety: the buffer grows to `chunkSize` before the
  ## seam read (the sole suspension point). If that read aborts before
  ## committing — an I/O error or a cancellation — the `finally` drops the
  ## grown buffer back to empty with `f.offset` untouched. Since refill is only
  ## entered with the previous buffer consumed, that restores the exact
  ## pre-refill position: no phantom zeros, no drift.
  withOffsetGuard(f, alreadyGuarded):
    # Precondition the rollback depends on: refill is entered with the previous
    # buffer fully consumed and `f.offset` not yet advanced, so leaving
    # `f.offset` untouched restores the exact pre-refill position.
    assert f.rpos == f.rbuf.len
    f.rbuf.setLen(chunkSize)

    var n = 0
    var committed = false
    try:
      n = await readSeekable(f, addr f.rbuf[0], chunkSize, f.offset, "readLine")
      committed = true
    finally:
      if not committed:
        f.rbuf.setLen(0)
        f.rpos = 0

    f.offset.inc(n)
    f.rbuf.setLen(n)
    f.rpos = 0
    return n > 0

proc getFileSize*(f: AsyncFile): int64 {.raises: [AsyncFileError].} =
  ## Returns the size of the file in bytes. The file position is not touched
  ## (uses `fstat`, so it is safe to call mid-stream).
  ##
  ## For block devices `fstat` reports `st_size == 0`, so the real capacity is
  ## queried via `ioctl` (Linux `BLKGETSIZE64`; macOS `DKIOCGETBLOCKSIZE` *
  ## `DKIOCGETBLOCKCOUNT`). On platforms providing neither, block devices still
  ## report 0 (and `fmAppend` would seed `offset = 0` there — append on a block
  ## device is not meaningful regardless).
  checkOpen(f)

  var st: Stat
  if handleEintr(fstat(cint(f.fd), st)) == -1:
    raise newAsyncFileOsError(osLastError(), "getFileSize")
  if S_ISBLK(st.st_mode):
    blockDeviceSize(cint(f.fd))
  else:
    int64(st.st_size)

proc getFilePos*(f: AsyncFile): int64 {.raises: [AsyncFileError].} =
  ## Returns the current (logical) file position, accounting for any bytes that
  ## `readLine` pushed back but `read` has not yet re-served.
  checkOpen(f)
  f.offset - int64(f.rbuf.len - f.rpos) - int64(f.pushback.len)

proc setFilePos*(f: AsyncFile, pos: int64) {.raises: [AsyncFileError].} =
  ## Sets the current file position. Any pending `readLine` pushback is dropped,
  ## since the new position invalidates it.
  ##
  ## On a seekable handle this rewrites the shared `offset` and drops the
  ## read-ahead, so it raises `AsyncFileBusyError` while a seekable implicit-offset
  ## op is in flight (repositioning under it would corrupt its bookkeeping). The
  ## `pos` validation runs before that busy check, so an invalid position always
  ## reports the deterministic argument error, never a transient busy error.
  checkOpen(f)

  if pos < 0:
    raise newAsyncFileError("negative file position: " & $pos)
  checkOffsetIdle(f)
  if not f.seekable:
    # Non-seekable fds (pipe/FIFO/tty) use the kernel position; let `lseek`
    # report the real error (typically ESPIPE). This path never blocks, so
    # `lseek` is not retried on EINTR (unlike the file I/O syscalls); it also
    # returns `Off`, which the int-typed `handleEintr` would not accept.
    if lseek(cint(f.fd), Off(pos), SEEK_SET) == -1:
      raise newAsyncFileOsError(osLastError(), "setFilePos")

  # Seekable fds read/write via pread/pwrite at `offset`, so no lseek is needed.
  f.offset = pos
  f.pushback.setLen(0)
  f.rbuf.setLen(0)
  f.rpos = 0

proc setFileSize*(f: AsyncFile, length: int64) {.raises: [AsyncFileError].} =
  ## Truncates or extends the file to `length` bytes.
  ##
  ## Invalidates the `readLine` read-ahead (via `reconcile`), which touches the
  ## shared `offset`, so it raises `AsyncFileBusyError` while a seekable implicit-
  ## offset op is in flight (same reason as `setFilePos`).
  checkOpen(f)
  checkOffsetIdle(f)
  reconcile(f) # truncation/extension invalidates any readLine read-ahead

  if handleEintr(ftruncate(cint(f.fd), Off(length))) == -1:
    raise newAsyncFileOsError(osLastError(), "setFileSize")

proc newAsyncFile*(fd: AsyncFD): AsyncFile {.raises: [AsyncFileError].} =
  ## Wraps an already open file descriptor. For non-seekable descriptors
  ## (pipe/FIFO/tty) `O_NONBLOCK` is set automatically so that read/write take
  ## the EAGAIN -> `addReader2` path instead of blocking the event loop; if the
  ## flag cannot be set this proc raises (a blocking non-seekable fd would stall
  ## the whole loop, so the failure is fatal, not ignored). Regular files bypass
  ## the dispatcher and are unaffected by the flag.
  ##
  ## Ownership: on success the returned `AsyncFile` takes over `fd`, and a later
  ## `close()` will close it (so do not also close `fd` yourself). If this proc
  ## raises instead (e.g. making the fd non-blocking, registration or `fstat`
  ## fails), `fd` is left open and ownership stays with the caller. Note,
  ## however, that the flag changes below (`O_NONBLOCK` on non-seekable fds,
  ## `FD_CLOEXEC`) are applied to `fd` *before* the operations that can raise,
  ## and are **not** rolled back on failure — a fd handed back to the caller
  ## after a raise may already carry them.
  ##
  ## `O_APPEND` is detected via `fcntl`, so positioned writes (`writeAt`/
  ## `writeBufferAt`) are rejected on append-mode descriptors exactly as for a
  ## file opened with `openAsync(fmAppend)`.
  ##
  ## The wrapped fd is also made close-on-exec (`FD_CLOEXEC`, best-effort: only
  ## if `fcntl(F_GETFD)` succeeded), mirroring `openAsync`'s `O_CLOEXEC`, so the
  ## descriptor does not leak across `exec`.
  ##
  ## **Double-wrap warning:** for a non-seekable fd this registers it with the
  ## chronos dispatcher. Wrapping the same fd twice (or wrapping an fd already
  ## registered with the dispatcher) hits the selector's duplicate-registration
  ## assertion, which aborts the process (a `Defect`, not a catchable
  ## `AsyncFileError`). Wrap each descriptor at most once.
  let seekable = isSeekable(cint(fd))

  # fcntl(F_GETFL) failure is non-fatal: fall back to treating the fd as
  # non-append rather than refusing to wrap an otherwise valid descriptor.
  let flags = handleEintr(fcntl(cint(fd), F_GETFL))
  let appendMode = flags != -1 and (flags and O_APPEND) == O_APPEND

  # Make the descriptor close-on-exec to match openAsync (which opens with
  # O_CLOEXEC), reusing chronos' helper. Best-effort and non-fatal.
  discard setDescriptorInheritance(cint(fd), false)

  # Seekable fds bypass the dispatcher, so only register non-seekable ones
  # (close mirrors this and only unregisters non-seekable fds).
  if not seekable:
    # Non-seekable fds MUST be non-blocking, otherwise read/write would block
    # the whole event loop instead of returning EAGAIN and taking the
    # addReader2/addWriter2 path. Unlike openAsync (which sets O_NONBLOCK
    # atomically in the open() flags), here the flag is toggled on an existing
    # fd, so it can fail — and a failure is fatal: registering a still-blocking
    # fd would silently produce a handle that stalls the loop. Done before
    # register2, so raising here needs no unregister, and `result` is still nil
    # (no half-built handle for the destructor to touch); the caller keeps fd
    # ownership. On F_GETFL/F_SETFL failure the helper leaves the fd flags
    # unchanged, so no O_NONBLOCK rollback is owed.
    let nonblock = setDescriptorBlocking(cint(fd), false)
    if nonblock.isErr:
      raise newAsyncFileOsError(nonblock.error, "newAsyncFile")
    let res = register2(fd)
    if res.isErr:
      raise newAsyncFileOsError(res.error, "newAsyncFile")
  result = AsyncFile(
    fd: fd, offset: 0, seekable: seekable, appendMode: appendMode, opened: true
  )

  if appendMode:
    # Seed the tracked offset with the current size, matching openAsync. The
    # caller keeps fd ownership, so on failure we only undo our registration
    # (and only if we actually registered, i.e. for non-seekable fds).
    result.offset =
      try:
        getFileSize(result)
      except AsyncFileError as e:
        if not seekable:
          discard unregister2(fd)
        # The caller keeps fd ownership on failure, so mark closed to stop the
        # destructor of the half-built `result` from closing the caller's fd.
        result.closed = true
        raise e

proc openAsyncImpl(
    filename: string, mode: FileMode, posixPerm: cint
): AsyncFile {.raises: [AsyncFileError].} =
  ## Shared body of the `openAsync` overloads; `posixPerm` is the raw POSIX
  ## creation mode passed to `open(2)`.
  let flags = toPosixFlags(mode) or O_NONBLOCK or O_CLOEXEC

  # `open` can be interrupted by a signal and return EINTR; retry like the
  # other file syscalls. `handleEintr` yields an int, so convert back to cint
  # to keep the downstream `closeFd`/`AsyncFD` calls unchanged.
  let fd = cint(handleEintr(open(cstring(filename), flags, posixPerm)))
  if fd == -1:
    raise newAsyncFileOsError(osLastError(), "openAsync '" & filename & "'")

  let afd = AsyncFD(fd)
  let seekable =
    try:
      isSeekable(fd)
    except AsyncFileError as e:
      discard closeFd(fd)
      raise e

  if not seekable:
    # Only non-seekable fds (pipe/FIFO/tty) ever use the dispatcher, via
    # addReader2/addWriter2 on EAGAIN. Seekable files go through pread/pwrite and
    # never touch the selector, so skip registration for them. `close` mirrors
    # this and only unregisters non-seekable fds.
    let res = register2(afd)
    if res.isErr:
      discard closeFd(fd)
      raise newAsyncFileOsError(res.error, "openAsync '" & filename & "'")

  result = AsyncFile(fd: afd, offset: 0, seekable: seekable, opened: true)
  if mode == fmAppend:
    result.appendMode = true
    result.offset =
      try:
        getFileSize(result)
      except AsyncFileError as e:
        # Roll back the open+register so the fd / selector entry cannot leak
        # if fstat fails after the file was already opened and registered.
        # Only non-seekable fds were registered (mirrors the guard above).
        if not seekable:
          discard unregister2(afd)
        discard closeFd(fd)
        # Mark closed so the destructor of the half-built `result` does not
        # close the (already closed) fd a second time.
        result.closed = true
        raise e

proc openAsync*(
    filename: string,
    mode = fmRead,
    perm: set[FilePermission] = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead},
): AsyncFile {.raises: [AsyncFileError].} =
  ## Opens a file for asynchronous I/O. `O_NONBLOCK` is always set so that
  ## pipe/FIFO/tty descriptors take the truly asynchronous path; it has no effect
  ## on regular files. `O_CLOEXEC` is always set as well, so the descriptor does
  ## not leak into child processes across `exec`. `perm` is the creation mode
  ## applied (subject to umask) when the file is created; it is ignored for
  ## existing files. The default is `0o644`.
  ##
  ## **FIFO note:** opening a FIFO write-only (`fmWrite`/`fmAppend`) with no
  ## reader present fails with `ENXIO`, because `O_NONBLOCK` is set (POSIX
  ## semantics). Open the read end first.
  ##
  ## **`fmAppend` note:** `O_APPEND` makes every write go to the end of the file
  ## regardless of the current position. The tracked `offset` is seeded with the
  ## file size on open, but if you `setFilePos` elsewhere and then write, the
  ## kernel still appends — so `getFilePos` can diverge from where the bytes
  ## actually land. This matches `std/asyncfile`.
  openAsyncImpl(filename, mode, toPosixMode(perm))

proc openAsync*(
    filename: string, mode: FileMode, perm: int
): AsyncFile {.raises: [AsyncFileError].} =
  ## Overload taking the creation mode as a plain octal number (e.g. `0o644`),
  ## passed to `open(2)` as-is — more convenient than spelling out a
  ## `set[FilePermission]`. `perm` must be within `0 .. 0o7777` (permission
  ## bits plus setuid/setgid/sticky). See the `set[FilePermission]` overload
  ## for the full semantics; `perm` has no default here so that
  ## `openAsync(path, mode)` keeps resolving to that overload.
  if perm < 0 or perm > 0o7777:
    raise newAsyncFileError("invalid permission mode: " & $perm)
  openAsyncImpl(filename, mode, cint(perm))
