version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Key-Value Store"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_kvstore.nim"
