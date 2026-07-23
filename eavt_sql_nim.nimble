# eavt-sql-nim.nimble
# Root nimble file — `nimble test` runs all Nim unit tests.

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT SQL engine (Nim storage stack)"
license       = "MIT"
srcDir        = "."
backend       = "c"

const SharedPaths = "--path:nim-blobstore --path:nim-page-store " &
                    "--path:nim-kvstore --path:nim-scheme " &
                    "--path:nim-eavt --path:nim-query " &
                    "--path:nim_memtable --path:. "

const Flags = "--mm:arc --threads:on -d:release --passL:-lcrypto --passL:-lzstd "

task test, "Run all Nim unit tests":
  exec "(cd nim-blobstore/memory  && nimble test)"
  exec "(cd nim-blobstore/file    && nimble test)"
  exec "(cd nim-blobstore/journal && nimble test)"
  exec "(cd nim_memtable          && nimble test)"
  exec "nim c " & Flags & SharedPaths & "-r nim-page-store/tests.nim"
  exec "nim c " & Flags & SharedPaths & "-r nim-scheme/tests.nim"
  exec "nim c " & Flags & SharedPaths & "-r nim-kvstore/tests.nim"
  exec "nim c " & Flags & SharedPaths & "-r nim-eavt/tests.nim"
  exec "nim c " & Flags & SharedPaths & "-r nim-query/query/tests.nim"
