# eavt-sql-nim.nimble
# Root nimble file — `nimble test` runs all Nim unit tests.

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "EAVT SQL engine (Nim storage stack)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run all Nim unit tests (single binary)":
  exec "nim c --mm:orc --threads:on -d:release " &
       "--out:build/all_tests all_tests.nim && build/all_tests"

task dist, "Build transactor, query server and REPL to build/":
  exec "(cd eavt_transactor_nim && nimble release)"
  exec "(cd eavt_query_nim && nimble release)"
  exec "(cd eavt-repl-nim && nimble release)"
  exec "sh -c 'if command -v go >/dev/null 2>&1; then (cd go && go build -o ../build/eavt-sql-cli-go ./cmd/eavt-repl && go build -o ../build/eavt-sql-query-front-go ./cmd/eavt-query-front && go build -o ../build/eavt-sql-query-go ./cmd/eavt-query && go build -o ../build/eavt-sql-transactor-go ./cmd/eavt-transactor && go build -o ../build/eavt-sql-load-go ./cmd/eavt-load); fi'"

task go_test, "Run Go tests (gofmt check + vet + go test)":
  exec "sh -c 'cd go && test -z \"$(gofmt -l .)\" && go vet ./... && go test ./...'"

task dev, "Run transactor + query server in the foreground (Ctrl-C stops both)":
  exec "scripts/dev.sh"

task test_local, "Run each module's tests separately (for debugging)":
  exec "(cd nim_blobstore/file    && nimble test)"
  exec "(cd nim_blobstore/journal && nimble test)"
  exec "(cd nim_memtable          && nimble test)"
  exec "nim c --mm:orc --threads:on -d:release -r nim_page_store/test_page_store.nim"
  exec "nim c --mm:orc --threads:on -d:release -r nim_scheme/test_scheme.nim"
  exec "nim c --mm:orc --threads:on -d:release -r nim_kvstore/test_kvstore.nim"
  exec "nim c --mm:orc --threads:on -d:release -r nim_eavt/test_eavt.nim"
  exec "nim c --mm:orc --threads:on -d:release -r nim_query/query/test_query.nim"
  exec "(cd nim_sql_parse && nimble test)"
  exec "(cd nim_datalog && nimble test)"
  exec "(cd nim_planner && nimble test)"
  exec "nim c --mm:orc --threads:on -d:release -r nim_compiler/test_compiler.nim"
  exec "(cd nim_sql_frontend && nimble test)"
