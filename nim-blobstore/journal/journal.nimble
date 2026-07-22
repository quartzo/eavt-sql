# journal.nimble
# Nimble definition for the Nim journal backend.
#
# Test:
#   cd nim-blobstore/journal && nimble test
#   nimble test -d:nimDebugDlOpen             # if DlOpenWithSelf fails

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Sequential append-only file journal"
license       = "MIT"
srcDir        = "."
backend       = "c"

# The journal uses std/os for file I/O and needs --mm:arc + --threads:on
# (pthread mutex for the spinlock).

task test, "Run unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r -d:nimStrictDelete tests.nim"
