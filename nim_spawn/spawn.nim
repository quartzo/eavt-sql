## spawn.nim — fire-and-forget spawn (pool-less, unbounded concurrency).
##
## Each `spawn(fn)` launches a fresh Nim thread that runs `fn` and exits.
## There is no thread pool, no fixed concurrency limit, and no join /
## awaitAll: the caller never waits for completion. Thread handles live in
## a fixed-size global array (stable addresses, avoiding the createThread-
## on-stack race documented in AGENTS.md); a reaper drops finished handles
## on each spawn, freeing slots for reuse.
##
## Built for `--mm:atomicArc`: worker threads are Nim-native (atomic ref
## counting — no cycle collector needed). Call `initSpawn()` once
## from the main thread before the first `spawn`.
##
## GC-safety note: `gThreads` holds `Thread[SpawnArg]` which contains
## GC'ed memory internally. The compiler cannot prove `gcsafe` for any
## access to it, even under a lock. The single `cast(gcsafe)` block in
## `spawn` covers all `gThreads` access (reap + create); every other
## global uses `Atomic[T]` and is auto-proven `gcsafe`. The lock
## serialises all access, so the cast is a real guarantee, not a
## suppression — see AGENTS.md for the carve-out covering this module.

import std/[atomics, locks, typedthreads]

const MaxConcurrent* {.intdefine.} = 65535

type
  SpawnArg* = ref object
    ## Heap-allocated closure carrier. Lives until the worker drops it.
    fn*: proc() {.gcsafe.}

var
  gThreads: array[MaxConcurrent, Thread[SpawnArg]]
  gActive {.align(64).}: array[MaxConcurrent, Atomic[bool]]
  gNextFree {.align(64).}: Atomic[int]
  gLock: Lock
  gInited: bool

proc initSpawn*() {.gcsafe.} =
  ## Initialise the spawn lock. Call once from the main thread before the
  ## first `spawn`. Idempotent.
  if not gInited:
    initLock(gLock)
    gInited = true

proc worker(arg: SpawnArg) {.thread.} =
  ## Thread trampoline: run the closure, then drop it (atomicArc releases
  ## `arg` when this frame unwinds).
  arg.fn()

proc spawn*(fn: proc() {.gcsafe.}) {.gcsafe.} =
  ## Fire-and-forget: launch a fresh thread running `fn`. Returns immedi-
  ## ately; the caller does not wait. `fn` must be `{.gcsafe.}`.
  assert gInited, "initSpawn() must be called before spawn()"
  let arg = SpawnArg(fn: fn)
  var idx: int
  gLock.withLock:
    {.cast(gcsafe).}:
      # Reap finished threads
      for i in 0 ..< MaxConcurrent:
        if gActive[i].load(moRelaxed) and not gThreads[i].running:
          gActive[i].store(false, moRelaxed)
          joinThread(gThreads[i])
      # Find free slot
      idx = gNextFree.load(moRelaxed)
      while gActive[idx].load(moRelaxed):
        idx = (idx + 1) mod MaxConcurrent
      gActive[idx].store(true, moRelaxed)
      gNextFree.store((idx + 1) mod MaxConcurrent, moRelaxed)
      createThread(gThreads[idx], worker, arg)

proc activeSlots*(): int {.gcsafe.} =
  ## Number of spawned threads still tracked (finished ones are reaped on
  ## each `spawn`). Mainly for tests/diagnostics.
  for i in 0 ..< MaxConcurrent:
    if gActive[i].load(moRelaxed): inc result
