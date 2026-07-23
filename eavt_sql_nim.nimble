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
  exec "(cd nim-kvstore           && nimble test)"
  exec "(cd nim-eavt              && nimble test)"
  exec "(cd nim-query             && nimble test)"
  # nim-page-store tests are part of nim-kvstore/tests.nim (to be split)
  # nim-scheme tests are part of nim-kvstore/tests.nim (to be split)
