version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "SQL parser for EAVT query language"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run SQL parser tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r test_sql_parse.nim"
