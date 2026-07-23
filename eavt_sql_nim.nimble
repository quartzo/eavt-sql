# eavt-sql-nim.nimble
# Root nimble file — `nimble test` runs all Nim unit tests.

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT SQL engine (Nim storage stack)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run all Nim unit tests (single binary)":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--out:build/all_tests all_tests.nim && build/all_tests"

task dist, "Build server and REPL to build/":
  exec "nim c --mm:orc --threads:on -d:release " &
       "--out:build/eavt-server eavt_server_nim/server.nim"
  exec "(cd eavt-repl-nim && nimble release)"

task test_local, "Run each module's tests separately (for debugging)":
  exec "(cd nim_blobstore/memory  && nimble test)"
  exec "(cd nim_blobstore/file    && nimble test)"
  exec "(cd nim_blobstore/journal && nimble test)"
  exec "(cd nim_memtable          && nimble test)"
  exec "nim c --mm:arc --threads:on -d:release -r nim_page_store/test_page_store.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim_scheme/test_scheme.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim_kvstore/test_kvstore.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim_eavt/test_eavt.nim"
  exec "nim c --mm:arc --threads:on -d:release -r nim_query/query/test_query.nim"
  exec "(cd nim_sql_parse && nimble test)"
  exec "(cd nim_datalog && nimble test)"
  exec "(cd nim_planner && nimble test)"
  exec "nim c --mm:arc --threads:on -d:release -r nim_compiler/test_compiler.nim"
  exec "(cd nim_sql_frontend && nimble test)"
