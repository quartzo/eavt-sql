## Asynchronous file I/O for chronos.
##
## Provides an `AsyncFile` type with a `std/asyncfile`-inspired (but not
## compatible) API that runs on the chronos event loop / `Future`. Notable
## differences: reads return `seq[byte]`, `readLine` returns `Opt[string]`
## (so an empty line is distinguishable from EOF), and one-shot helpers
## (`readFileAsync`/`writeFileAsync`/`withAsyncFile`) are provided.
##
## POSIX backend: pipes/FIFOs/ttys issue the syscall immediately and fall back to
## `addReader2`/`addWriter2` on `EAGAIN`/`EWOULDBLOCK`, so they are truly
## asynchronous. Regular files never return `EAGAIN` (epoll cannot watch them) and
## instead go through a *seekable backend*, chosen in this order:
##
## 1. **io_uring** (`uring_io`) — opt-in via `-d:chronosFileUring`, Linux 5.6+.
## 2. **thread pool** (`thread_pool_io`) — on by default on POSIX; the syscall
##    runs on a worker thread. `-d:chronosFileNoThreadPool` opts out.
## 3. **synchronous** — the inline `pread`/`pwrite` fallback, used when neither
##    of the above is compiled in or usable.
##
## Under (1) and (2) a seekable op suspends and the event loop keeps running.
## Under (3) the syscall blocks the whole event loop — on slow storage that
## stalls every other async task, as `std/asyncfile` does. The backend is chosen
## behind the `readSeekable`/`writeSeekable` seam; the public API, contracts and
## error types are identical either way.
##
## This module is POSIX-only for now. Windows (IOCP overlapped I/O) is not
## implemented yet; see the `when defined(windows)` block below for a sketch of
## the planned design.
##
## The implementation is split across `chronos_file/`: `common`
## (types/errors/destructor), `posix_backend` (raw-fd syscall wrappers),
## `posix_handle` (open/positioning/lifecycle), `posix_io` (the read/write
## surface), `posix_flush_close` (flush, close, one-shot helpers) and the two
## seekable backends `uring_io` / `thread_pool_io`. This module re-exports the
## public API of those submodules; the backends are internal, apart from their
## availability probes (`uringAvailable`, `threadPoolAvailable`,
## `threadPoolFailure`), which let an application detect a backend degrading to
## the synchronous fallback at runtime.

when defined(windows):
  # The Windows backend (IOCP overlapped I/O) is not implemented in this phase.
  # Planned design:
  #   - openAsync via createFile(FILE_FLAG_OVERLAPPED), register2 (= IOCP attach).
  #   - read/write issue overlapped readFile/writeFile with a RefCustomOverlapped
  #     whose offset/offsetHigh carry f.offset; GC_ref until the completion cb.
  #   - completion dispatched by poll() -> cb advances f.offset and completes;
  #     GC_unref unconditionally (chronos poll() does not GC_unref overlapped).
  #   - cancellation uses CancelIoEx (safe side) so pending I/O aborts before the
  #     caller-owned buffer of readBuffer/writeBuffer can be freed.
  {.
    error:
      "chronos_file: Windows (IOCP) backend not implemented yet; " &
      "POSIX only in this phase"
  .}
else:
  import std/syncio
  from std/os import FilePermission
  import pkg/chronos
  import pkg/chronos/oserrno

  import chronos_file/[common, posix_handle, posix_io, posix_flush_close]
  import chronos_file/[uring_io, thread_pool_io]

  export chronos
  export oserrno
  export syncio.FileMode
  export os.FilePermission

  export
    common.AsyncFile, common.AsyncFileObj, common.AsyncFileError,
    common.AsyncFileOsError, common.AsyncFileBusyError, common.AsyncFileIncompleteError,
    common.AsyncFileLimitError, common.FlushKind

  export
    posix_handle.getFileSize, posix_handle.getFilePos, posix_handle.setFilePos,
    posix_handle.setFileSize, posix_handle.newAsyncFile, posix_handle.openAsync,
    posix_handle.isOpen, posix_handle.isClosed
  export posix_io
  export posix_flush_close

  # The backends stay internal, but their runtime probes are public: both are
  # best-effort (old kernel, sandbox, thread-spawn failure degrade seekable I/O
  # to the blocking inline path), and these let an application detect that.
  # `threadPoolFailure` carries the construction error ("" while usable).
  export uring_io.uringAvailable
  export thread_pool_io.threadPoolAvailable, thread_pool_io.threadPoolFailure
