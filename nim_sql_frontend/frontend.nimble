version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "SQL frontend: parse → datalog → plan → compile"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run frontend tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_sql_frontend.nim"
