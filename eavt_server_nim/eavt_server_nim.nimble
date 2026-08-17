version       = "0.2.0"
author        = "eavt-sql-nim"
description   = "EAVT data server: pure Scheme execution engine (chronos, single-loop)"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.14"
requires "chronos >= 4.2.0"

task test, "Run server tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r tests.nim"

task release, "Build the data server":
  exec "nim c --mm:orc --threads:on -d:release -d:useMalloc " &
       "--out:../build/eavt-sql-server server.nim"
