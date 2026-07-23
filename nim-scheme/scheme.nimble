version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Scheme IR evaluator"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run scheme tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r tests.nim"
