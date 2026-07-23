version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Page Store (COW B-tree on blobstore)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run page store unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--path:../nim-blobstore " &
       "--path:../nim-kvstore " &
       "--path:.. " &
       "--passL:-lcrypto --passL:-lzstd " &
       "-r tests.nim"
