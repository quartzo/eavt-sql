# Package

version       = "0.1.0"
author        = "fabio"
description   = "Async KVStore twin: flush + GC on the event loop (chronos)"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.16"
requires "chronos >= 4.2.0"

task test, "Run the async kvstore tests (orc; not part of all_tests)":
  exec "nim c --mm:orc --threads:on -d:release -d:useMalloc -r test_kvstore_async.nim"
