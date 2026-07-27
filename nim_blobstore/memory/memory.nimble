# memory.nimble
# Nimble definition for the in-memory blobstore backend.
#
# Test:
#   cd nim_blobstore/memory && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "In-memory blobstore backend (HashMap)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "-r test_memory.nim"
