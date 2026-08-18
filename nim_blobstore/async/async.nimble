# Package

version       = "0.1.0"
author        = "fabio"
description   = "Async blobstore facade: pool bridge over the sync BlobStore trait (chronos)"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.16"
requires "chronos >= 4.2.0"

task test, "Run the async blobstore tests (orc; not part of all_tests)":
  exec "nim c --mm:orc --threads:on -d:release -d:useMalloc -r test_blobstore_async.nim"
