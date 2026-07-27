version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Datalog IR builder for EAVT query language"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run datalog tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_datalog.nim"
