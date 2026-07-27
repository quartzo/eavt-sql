version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Query engine"
license       = "MIT"
srcDir        = "query"
backend       = "c"

task test, "Run query engine unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r query/test_query.nim"
