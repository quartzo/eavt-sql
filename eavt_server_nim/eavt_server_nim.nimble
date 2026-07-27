version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT UDS server (Unix Domain Socket + JSON)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run server tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r tests.nim"
