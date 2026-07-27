version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Scheme IR compiler (SQL -> Scheme S-exprs)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run compiler tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_compiler.nim"
