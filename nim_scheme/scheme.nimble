version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Scheme IR evaluator"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run scheme tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "-r test_scheme.nim"
