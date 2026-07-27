version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT engine"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run EAVT unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_eavt.nim"
