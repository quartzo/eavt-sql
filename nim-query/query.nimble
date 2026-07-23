version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Query engine"
license       = "MIT"
srcDir        = "query"
backend       = "c"

task test, "Run query engine unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--path:../../nim-blobstore " &
       "--path:../../nim-page-store " &
       "--path:../../nim-kvstore " &
       "--path:../../nim-eavt " &
       "--path:../../nim-scheme " &
       "--path:../.. " &
       "--passL:-lcrypto --passL:-lzstd " &
       "-r tests.nim"
