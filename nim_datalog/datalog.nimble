version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Datalog IR builder for EAVT query language"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run datalog tests":
  exec "nim c --mm:arc --threads:on -d:release -r test_datalog.nim"
