# s3.nimble
# Nimble definition for the S3 blobstore backend.
#
# Prerequisites: `rustfs` binary on PATH.
#
# Test:
#   cd nim_blobstore/s3 && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "S3 blobstore backend (SigV4 + HTTP)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests (requires rustfs)":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r test_s3.nim"
