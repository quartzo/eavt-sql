# kvstore.nimble
# Nimble definition for the Nim KVStore.
#
# Test:
#   cd nim-kvstore && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Key-Value Store (MemTable + PageStore + Journal)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--path:../nim-blobstore --path:.. " &
       "--passL:-lcrypto --passL:-lzstd " &
       "-r tests.nim"
