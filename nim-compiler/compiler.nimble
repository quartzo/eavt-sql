version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Scheme IR compiler (SQL -> Scheme S-exprs)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run compiler tests":
  exec "nim c --mm:arc --threads:on -d:release -r tests.nim"
