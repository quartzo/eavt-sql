# spawn.nimble
# Nimble definition for nim_spawn — fire-and-forget spawn (pool-less).
#
# Test:
#   cd nim_spawn && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Fire-and-forget spawn: unbounded concurrency, no join"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "-r test_spawn.nim"
