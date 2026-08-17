# chronos_file

Asynchronous file I/O for [chronos](https://github.com/status-im/nim-chronos).

> **POSIX only for now.** Windows (IOCP) is not implemented and fails at compile time.

## Behavior and caveats

- **Regular files are asynchronous by default**, via the
  [thread-pool backend](#thread-pool-backend-default-on): epoll/kqueue cannot watch
  a seekable file, so `pread`/`pwrite` run on a pool of worker threads and the event
  loop keeps serving other tasks. On Linux the [io_uring
  backend](#io_uring-backend-opt-in) can take their place. With both compiled out
  (`-d:chronosFileNoThreadPool`) reads/writes fall back to blocking `pread`/`pwrite`
  that **block the event loop**, mirroring `std/asyncfile`.
- **Non-seekable fds (pipe / FIFO / tty)** take the truly async `read`/`write` +
  `EAGAIN` path. An fd that is neither seekable nor pollable opens fine, but the
  **first read/write** fails (e.g. `EPERM`), surfacing as `AsyncFileOsError`.
- **One implicit-offset op at a time per handle.** `read`/`write`/`readLine` (and
  the low-level `readBuffer`/`writeBuffer`) share the file position, so a second
  one issued while another is in flight raises `AsyncFileBusyError`. For concurrent
  reads use the positioned `readAt`/`readBufferAt` family: offset-independent and
  never rejected. The positioned writes (`writeAt`/`writeBufferAt`) and positioning
  ops (`setFilePos`/`setFileSize`) must drop the `readLine` read-ahead, so they too
  raise `AsyncFileBusyError` while an implicit-offset op is in flight.
- **Close explicitly** with `close()` (sync) or `closeWait()` (async). A destructor
  releases the fd as a last-resort safety net but does not cancel pending ops.
  `closeWait()` cancels and drains the in-flight op so the awaiter sees
  `CancelledError` rather than `EBADF`; synchronous `close()` cannot, so prefer
  `closeWait()` (or await the op first) when a read/write may still be outstanding.
  With a suspending backend (the default) `close()` **raises `AsyncFileError`** when
  a seekable op is still in flight rather than closing the fd underneath it.
- **Zero-copy buffers must outlive the future.** The low-level `readBuffer` /
  `writeBuffer` / `readBufferAt` / `writeBufferAt` hand your pointer straight to the
  backend, so keep the buffer valid until the future *settles* — cancel with
  `cancelAndWait()`, never `cancelSoon()` followed by a free. Only the
  compiled-out-backend build completes these inline; on every default build a freed
  buffer is a use-after-free. Use the high-level `read`/`write`/`readAt`/`writeAt`
  for library-owned buffers with no lifetime rule.

## Usage

```nim
import pkg/chronos_file

proc main() {.async.} =
  # One-shot helpers: open, transfer and close in a single call.
  await writeFileAsync("/tmp/foo.txt", "test")
  doAssert (await readFileAsync("/tmp/foo.txt")) == "test"        # string
  doAssert (await readFileBytesAsync("/tmp/foo.txt")).len == 4    # seq[byte]

  # Handle API with a guaranteed close (also on error/cancellation).
  # fmReadWriteExisting opens without truncating, so "test" survives.
  withAsyncFile(f, "/tmp/foo.txt", fmReadWriteExisting):
    doAssert (await f.readAllString()) == "test"   # readAll() returns seq[byte]
    f.setFilePos(0)
    await f.write("done")

waitFor main()
```

## io_uring backend (opt-in)

On Linux, regular-file I/O can be routed through **io_uring** — a threadless
kernel-ring backend — instead of the thread-pool backend. Several reads/writes
(and `flush`) can be in flight at once, with completions delivered by the ring
rather than a dispatcher draining a result queue.
Append-mode writes are the one exception (see below).

Build with `-d:chronosFileUring` — **opt-in** (off by default) and **Linux 5.6+**
only; without it the thread-pool backend below is what runs on every POSIX target.

```sh
nim c -d:chronosFileUring -d:asyncBackend=chronos yourapp.nim
```

- **Dependency:** needs [`iori`](https://github.com/fox0430/iori) >= 0.2.0
  (`nimble install iori`) with chronos selected as its async backend
  (`-d:asyncBackend=chronos`, as above). Both come from **your** build — a library
  cannot force an async backend on its consumers. `iori` is intentionally not a
  hard dependency (Linux-only, opt-in), so the default build pulls in nothing extra.
- **Graceful fallback:** if io_uring is unavailable at runtime (kernel too old, ring
  setup fails), the library transparently falls back to the synchronous path — the
  define enables the backend, it does not force it.
- **Same public API and contracts.** The single-in-flight rule, positioned `*At`
  concurrency, buffer ownership and cancellation all hold; seekable ops just
  actually suspend now, so cancellation drains the in-flight kernel op before
  settling.
- **Append writes stay synchronous.** io_uring's write takes an explicit offset
  with no "append" mode, and faking `offset = -1` would let `pwrite` ignore
  `O_APPEND` and overwrite. So `fmAppend` writes keep the blocking sequential
  `write` and are never tracked as in-flight for `closeWait` to drain; a large
  append can still stall the loop. Every other seekable write is async. (The
  thread-pool backend has no such carve-out — see below.)
- **Trade-off:** each op makes a submit → completion round-trip, so a single
  uncontended read/write has *higher* latency than an inline `pread`; the win is
  non-blocking behavior and throughput under concurrency/contention.

## Thread-pool backend (default on)

Seekable I/O — reads, writes and `flush` — is dispatched to a pool of worker
threads that run the ordinary `pread`/`pwrite`/`write`/`fsync` syscalls. The
calling task suspends, the event loop keeps running, and several ops can be in
flight at once. This is **on by default on every POSIX target** and needs no
dependency beyond the standard library and chronos.

```sh
nim c yourapp.nim                          # pool is already in
nim c -d:chronosFileNoThreadPool yourapp.nim   # opt out: inline pread/pwrite
```

- **Backend order:** io_uring → thread pool → synchronous. The pool is compiled
  out by default on a build that enables io_uring (`-d:chronosFileUring`), since
  the ring covers the same ops without threads; pass `-d:chronosFileThreadPool`
  as well to get both, and the pool then catches the case where the ring's
  runtime probe fails.
- **Graceful fallback:** if the pool cannot start (thread creation fails), the
  library transparently falls back to the synchronous path, the same way the
  io_uring backend does.
- **Pool size:** `max(4, ncpu)` worker threads, capped at 32, created lazily on
  first use and kept for the lifetime of the process. The pool is **per event-loop
  thread**, so an app running four dispatcher threads that each touch a file ends
  up with four pools — up to 4 × 32 workers and four eventfds. Pin the count with
  `-d:chronosFileThreadPoolSize=N` when that matters:

  ```sh
  nim c -d:chronosFileThreadPoolSize=2 yourapp.nim
  ```

  The 32 cap applies to the `max(4, ncpu)` heuristic only — an explicit
  `-d:chronosFileThreadPoolSize=N` is taken verbatim, so it can also be used to
  ask for *more* than 32. The number is per event-loop thread, not a
  process-wide budget.
- **Same public API and contracts.** The single-in-flight rule, positioned `*At`
  concurrency, buffer ownership and cancellation all hold. Since a syscall in
  progress on a worker cannot be aborted, cancelling a seekable op waits for that
  syscall to return before settling `CancelledError` — which is precisely what
  keeps a caller-owned buffer valid for the whole op (zero-copy, no copy in/out).
- **Append writes are async here.** Unlike io_uring, a worker can issue the same
  sequential `write(2)` the synchronous path would, so `fmAppend` writes suspend,
  are tracked, and are drained by `closeWait` like any other write. The io_uring
  carve-out above does not apply to this backend.
- **Trade-off:** each op costs a queue hand-off and a completion wake-up, so a
  single uncontended read/write has *higher* latency than an inline `pread`; the
  win is non-blocking behavior and throughput under concurrency/contention. Opt
  out with `-d:chronosFileNoThreadPool` if the worker threads themselves are the
  problem (a hard thread budget, or a process that forks). Note that the opt-out
  covers seekable read/write only: `flush` has no non-blocking inline form, so on
  such a build it spawns (and joins) one dedicated thread per call instead. A
  build that must not create threads at all has to avoid `flush`.

## Roadmap

- Windows (IOCP) support

## License

MIT
