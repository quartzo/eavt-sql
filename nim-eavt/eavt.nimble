version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT engine"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run EAVT unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--path:../nim-blobstore " &
       "--path:../nim-page-store " &
       "--path:../nim-kvstore " &
       "--path:../nim-scheme " &
       "--path:.. " &
       "--passL:-lcrypto --passL:-lzstd " &
       "-r tests.nim"
