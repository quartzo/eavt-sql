version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT UDS server (Unix Domain Socket + JSON)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run server tests":
  exec "nim c --mm:orc --threads:on -d:release -r tests.nim"
