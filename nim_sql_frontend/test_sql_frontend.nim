import std/[unittest, tables, sets, strutils]
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
