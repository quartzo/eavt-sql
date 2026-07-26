## spawn.nim — fire-and-forget spawn (pool-less, unbounded concurrency).
##
## Each `spawn(fn)` launches a fresh Nim thread that runs `fn` and exits.
## There is no thread pool, no fixed concurrency limit, and no join /
## awaitAll: the caller never waits for completion. Thread handles live in
## a fixed-size global array (stable addresses, avoiding the createThread-
## on-stack race documented in AGENTS.md); a reaper drops finished handles
## on each spawn, freeing slots for reuse.
##
## Built for `--mm:orc`: worker threads are Nim-native (full ORC setup,
## including the thread-local cycle collector). Call `initSpawn()` once
## from the main thread before the first `spawn`.
##
## GC-safety note: the global handle table is GC'ed (it holds `ref`
## closure carriers), so the procs that touch it cannot be auto-proven
## `{.gcsafe.}`. Every access is serialised by `gLock`, so the casts below
## are a real guarantee, not a suppression — see AGENTS.md for the
## carve-out covering this module.

import std/[locks, typedthreads]

const MaxConcurrent* {.intdefine.} = 65535

type
  SpawnArg* = ref object
    ## Heap-allocated closure carrier. Lives until the worker drops it.
    fn*: proc() {.gcsafe.}

var
  gThreads: array[MaxConcurrent, Thread[SpawnArg]]
  gActive: array[MaxConcurrent, bool]
  gNextFree: int
  gLock: Lock
  gInited: bool

proc initSpawn*() {.gcsafe.} =
  ## Initialise the spawn lock. Call once from the main thread before the
  ## first `spawn`. Idempotent.
  if not gInited:
    initLock(gLock)
    gInited = true

proc worker(arg: SpawnArg) {.thread.} =
  ## Thread trampoline: run the closure, then drop it (ORC releases `arg`
  ## when this frame unwinds).
  arg.fn()

proc reapLocked() =
  ## Free slots whose threads have exited. Caller holds `gLock`.
  for i in 0 ..< MaxConcurrent:
    if gActive[i] and not gThreads[i].running:
      gActive[i] = false
      joinThread(gThreads[i])

proc spawn*(fn: proc() {.gcsafe.}) =
  ## Fire-and-forget: launch a fresh thread running `fn`. Returns immedi-
  ## ately; the caller does not wait. `fn` must be `{.gcsafe.}`.
  assert gInited, "initSpawn() must be called before spawn()"
  let arg = SpawnArg(fn: fn)
  var idx: int
  gLock.withLock:
    {.cast(gcsafe).}:
      reapLocked()
      while gActive[gNextFree]:
        gNextFree = (gNextFree + 1) mod MaxConcurrent
      idx = gNextFree
      gActive[idx] = true
      gNextFree = (gNextFree + 1) mod MaxConcurrent
      createThread(gThreads[idx], worker, arg)

proc activeSlots*(): int =
  ## Number of spawned threads still tracked (finished ones are reaped on
  ## each `spawn`). Mainly for tests/diagnostics.
  gLock.withLock:
    {.cast(gcsafe).}:
      result = 0
      for i in 0 ..< MaxConcurrent:
        if gActive[i]: inc result
