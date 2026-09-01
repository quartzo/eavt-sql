import std/[unittest, tables, sets, strutils]
import edn
import parser as sql_parser, frontend, stats, scheme

proc makeStats(): CompileStats =
  var attrs = {
    "company.name": 100'u32,
    "person.name": 101'u32,
    "company.active": 102'u32,
    "company.revenue": 103'u32,
  }.toTable

  result.attrIds = attrs
  result.indexEstimates["EAVT:"] = 10_000_000.0
  result.indexEstimates["AEVT:"] = 10_000.0
  result.indexEstimates["AVET:"] = 10_000_000.0
  result.indexEstimates["VAET:"] = 10_000_000.0
  result.partitionIds = initTable[string, uint64]()
  result.refAttrs = initHashSet[string]()

proc compileStmt(sql: string): (string, CompileResult) =
  let stmt = sql_parser.parse(sql)
  (sql, compileSql(stmt, makeStats()))

suite "frontend: expression projection (no triejoin)":
  test "SELECT arithmetic compiles to result-row without scanner":
    let (_, r) = compileStmt("SELECT 20+20")
    check r.isSelect
    let body = $(r.program.body)
    check body == "[:result-row [:+ 20 20]]"

  test "SELECT parenthesised compiles with precedence":
    let (_, r) = compileStmt("SELECT (1+2)*3")
    check $(r.program.body) == "[:result-row [:* [:+ 1 2] 3]]"

  test "SELECT eid() compiles to lookup-entity":
    let (_, r) = compileStmt("SELECT eid('company.name', 'ACME')")
    check $(r.program.body) == "[:result-row [:lookup-entity \"company.name\" \"ACME\"]]"

  test "SELECT param arithmetic compiles":
    let (_, r) = compileStmt("SELECT 20+%1")
    check $(r.program.body) == "[:result-row [:+ 20 [:param 1]]]"
