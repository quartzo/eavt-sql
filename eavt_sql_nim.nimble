# eavt-sql-nim.nimble
# Root nimble file — `nimble test` runs all Nim unit tests.

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT SQL engine (Nim storage stack)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run all Nim unit tests":
  exec "(cd nim-blobstore/memory  && nimble test)"
  exec "(cd nim-blobstore/file    && nimble test)"
  exec "(cd nim-blobstore/journal && nimble test)"
  exec "(cd nim_memtable          && nimble test)"
  exec "nim c --mm:arc --threads:on -d:release -r nim-page-store/tests.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim-scheme/tests.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim-kvstore/tests.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim-eavt/tests.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim-query/query/tests.nim"
  exec "(cd nim-sql-parse && nimble test)"
  exec "(cd nim-datalog && nimble test)"
