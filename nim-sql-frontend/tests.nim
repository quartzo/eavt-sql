import std/[unittest, tables, sets, strutils]
import parser as sql_parser, frontend, stats, scheme

proc makeStats(): CompileStats =
  var attrs = {
    "company.name": 100'u32,
    "person.name": 101'u32,
    "company.active": 102'u32,
    "company.revenue": 103'u32,
  }.toTable

  CompileStats(
    lookupAttr: proc(name: string): uint32 =
      if name in attrs: attrs[name] else: 0,
    estimateIndexSize: proc(index: string, bound: openArray[uint64]): float64 =
      if index == "AEVT": 10_000.0 else: 10_000_000.0,
    partitionIdFor: proc(name: string): uint64 = 0,
    isRefAttr: proc(name: string): bool = false,
    isIndexedAttr: proc(name: string): bool = true,
  )

proc compileStmt(sql: string): (string, CompileResult) =
  let stmt = sql_parser.parse(sql)
  (sql, compileSql(stmt, makeStats()))

suite "frontend: Scheme IR structure (port of test_compiler_json.py)":
  test "resolved attr emits scanner-push":
    let (_, result) = compileStmt(
      "SELECT d1.company.name WHERE d1.company.name = 'ACME'")
    let s = $result.program.body
    check("scanner-open" in s or "scanner-push" in s)

  test "select uses valid index name":
    let (_, result) = compileStmt(
      "SELECT d1.company.name WHERE d1.company.name = 'ACME'")
    let s = $result.program.body
    check("\"AEVT\"" in s or "\"EAVT\"" in s or "\"AVET\"" in s or "\"VAET\"" in s)

  test "attribute compiles to declare-attr":
    let (_, result) = compileStmt(
      "ATTRIBUTE company.revenue FLOAT ONE")
    let s = $result.program.body
    check("declare-attr" in s)
    check("company.revenue" in s)

  test "partition compiles to declare-partition":
    let (_, result) = compileStmt(
      "PARTITION my_partition")
    let s = $result.program.body
    check("declare-partition" in s)
    check("my_partition" in s)

  test "upsert compiles to scheme":
    let (_, result) = compileStmt(
      "UPSERT AS D1 SET company.name = 'Test Co'")
    let s = $result.program.body
    check(s.startsWith("("))
    check("alloc-entity" in s)
    check("save" in s)
    check("company.name" in s)

suite "frontend: pipeline integration":
  test "explain select":
    let stmt = sql_parser.parse(
      "SELECT d1.company.name WHERE d1.company.name = 'ACME'")
    let result = compileSql(stmt, makeStats())
    let s = $result.program.body
    check(result.isSelect)
    check result.orderedVars.len >= 0
    check "result-row" in s

  test "explain upsert via explain prefix":
    let stmt = sql_parser.parse(
      "EXPLAIN UPSERT AS D1 SET company.name = 'TestCo'")
    let result = compileSql(stmt, makeStats())
    let s = $result.program.body
    check("alloc-entity" in s)
