version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Page Store (COW B-tree on blobstore)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run page store unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_page_store.nim"
