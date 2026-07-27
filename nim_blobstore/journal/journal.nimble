# journal.nimble
# Nimble definition for the Nim journal backend.
#
# Test:
#   cd nim_blobstore/journal && nimble test
#   nimble test -d:nimDebugDlOpen             # if DlOpenWithSelf fails

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Sequential append-only file journal"
license       = "MIT"
srcDir        = "."
backend       = "c"

# The journal uses std/os for file I/O and needs --mm:atomicArc + --threads:on
# (pthread mutex for the spinlock).

task test, "Run unit tests":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "-r -d:nimStrictDelete test_journal.nim"
