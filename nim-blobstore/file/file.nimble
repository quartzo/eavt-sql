# file.nimble
# Nimble definition for the file-backed blobstore backend.
#
# Test:
#   cd nim-blobstore/file && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "File-backed blobstore backend (hex-sharded directory)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r tests.nim"
