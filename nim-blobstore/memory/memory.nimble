# memory.nimble
# Nimble definition for the in-memory blobstore backend.
#
# Test:
#   cd nim-blobstore/memory && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "In-memory blobstore backend (HashMap)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r tests.nim"
