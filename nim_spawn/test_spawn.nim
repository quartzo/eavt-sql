## test_spawn.nim — unit tests for nim_spawn.

import std/[unittest, atomics, os, times]
import spawn

var done: Atomic[int]

proc waitFor(target: int; timeoutMs = 5000) =
  let deadline = epochTime() + float64(timeoutMs) / 1000.0
  while done.load(moRelaxed) < target:
    doAssert epochTime() < deadline, "timeout waiting for " & $target & " spawns"
    sleep(10)

proc reset() = done.store(0, moRelaxed)

proc inc() {.gcsafe.} = discard done.fetchAdd(1, moRelaxed)

suite "nim_spawn: basic":
  test "single spawn runs":
    initSpawn()
    reset()
    spawn(inc)
    waitFor(1)
    check done.load(moRelaxed) == 1

  test "spawn returns immediately (fire-and-forget)":
    initSpawn()
    reset()
    let n = 50
    for i in 0 ..< n: spawn(inc)
    waitFor(n)
    check done.load(moRelaxed) == n

suite "nim_spawn: unbounded concurrency":
  test "many concurrent spawns exceed pool size":
    initSpawn()
    reset()
    # Far above any plausible pool size (malebolgia default is 8). If we
    # were pool-bound, this would deadlock or queue; fire-and-forget
    # completes all of them.
    let n = 200
    for i in 0 ..< n: spawn(inc)
    waitFor(n, 15000)
    check done.load(moRelaxed) == n

suite "nim_spawn: reaper":
  test "finished handles are dropped":
    initSpawn()
    reset()
    for i in 0 ..< 100: spawn(inc)
    waitFor(100)
    # After the spawns finish, a subsequent spawn triggers reapLocked(),
    # which removes the 100 finished slots. Allow a few cycles for the
    # worker threads to actually mark themselves as not running.
    var stable = false
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      spawn(inc)
      waitFor(done.load(moRelaxed) + 1)
      sleep(20)
      if activeSlots() <= 1:
        stable = true
        break
    check stable

suite "nim_spawn: closure capture":
  test "fn captures and mutates ref":
    initSpawn()
    var v: Atomic[int]
    v.store(0, moRelaxed)
    spawn(proc() {.gcsafe.} = v.store(42, moRelaxed))
    var ok = false
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      if v.load(moRelaxed) == 42:
        ok = true
        break
      sleep(5)
    check ok
