version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Query planner (join ordering + index selection)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run planner tests":
  exec "nim c --mm:arc --threads:on -d:release -r tests.nim"
