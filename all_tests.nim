## all_tests.nim — Centralized test runner.
##
## Imports every module's test file into a single binary, so the whole
## suite compiles and runs in one pass instead of 14 separate nim c
## invocations. Each module's local `nimble test` still works for
## isolated debugging.
##
## Run:  nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r all_tests.nim

# Storage stack
import nim_blobstore/file/test_file
import nim_blobstore/journal/test_journal
import nim_memtable/test_memtable
import nim_page_store/test_page_store
import nim_kvstore/test_kvstore
import nim_eavt/test_eavt

# Query engine
import nim_scheme/test_scheme
import nim_scheme/test_wire
import nim_scheme/test_msgpack_scan
import nim_query/query/test_query

# SQL pipeline
import nim_sql_parse/test_sql_parse
import nim_planner/test_planner
import nim_query/query/test_edn_tx
import nim_query/query/test_golden_tx
import nim_edn/test_edn
import nim_datalog/test_query_edn
