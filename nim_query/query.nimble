version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Query engine"
license       = "MIT"
srcDir        = "query"
backend       = "c"

task test, "Run query engine unit tests":
  exec "nim c --mm:arc --threads:on -d:release -r query/test_query.nim"
