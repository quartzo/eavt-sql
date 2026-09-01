import std/[unittest, tables, sets, sequtils, strutils]
import edn
import ast, parser as sql_parser, scheme, scheme_compile, compiler, datalog_ast, pattern, planner_ast, planner, translate

suite "compiler: UPSERT":
  test "simple new entity":
    let stmt = sql_parser.parse("UPSERT AS D1 SET person.name = 'Alice'")
    check stmt.kind == stmtUpsert
    let prog = compileUpsertScheme(stmt.upsertStmt)
    let s = $prog.body
    check "alloc-entity" in s
    check "save" in s
    check "person.name" in s
    check "Alice" in s

  test "upsert with param":
    let stmt = sql_parser.parse("UPSERT AS D1 = %1 SET person.age = %2")
    check stmt.kind == stmtUpsert
    let prog = compileUpsertScheme(stmt.upsertStmt)
    let s = $prog.body
    check "[:param 1]" in s
    check "[:param 2]" in s

  test "alias ref in multi-clause":
    let stmt = sql_parser.parse("UPSERT AS D1 SET person.name = 'A' , AS D2 SET company.ceo = d1")
    check stmt.kind == stmtUpsert
    let prog = compileUpsertScheme(stmt.upsertStmt)
    let s = $prog.body
    check "D1" in s
    check "D2" in s
    check "[:result D1 2]" in s

  test "round-trip parseable":
    let stmt = sql_parser.parse("UPSERT AS D1 SET person.age = %1, person.name = 'Bob'")
    check stmt.kind == stmtUpsert
    let prog = compileUpsertScheme(stmt.upsertStmt)
    let schemeStr = $prog.body
    let reparsed = edn.readEdn(schemeStr)
    check $reparsed == schemeStr

suite "compiler: ATTRIBUTE":
  test "attribute string unique":
    let stmt = sql_parser.parse("ATTRIBUTE company.name STRING ONE UNIQUE")
    check stmt.kind == stmtAttribute
    let prog = compileAttributeScheme(stmt.attrStmt)
    let s = $prog.body
    check "declare-attr" in s
    check "company.name" in s
    check "STRING" in s

  test "attribute ref many":
    let stmt = sql_parser.parse("ATTRIBUTE company.partner REF MANY")
    check stmt.kind == stmtAttribute
    let prog = compileAttributeScheme(stmt.attrStmt)
    let s = $prog.body
    check "declare-attr" in s
    check "REF" in s

suite "compiler: PARTITION":
  test "partition statement":
    let stmt = sql_parser.parse("PARTITION my-part")
    check stmt.kind == stmtPartition
    let prog = compilePartitionScheme(stmt.partStmt)
    let s = $prog.body
    check "declare-partition" in s
    check "my-part" in s
    check "pid" in s

suite "compiler: DML direct (compileDmlDirect)":
  test "delete direct":
    let result = compileDeleteDirect(42, @[("user.name", 7'i64)])
    let s = $result.program.body
    check "retract" in s
    check "42" in s
    check "user.name" in s
    check "result" in s

suite "compiler: flattenBegins":
  proc sym(s: string): SExpr = newSymbol(s)
  proc begin(items: seq[SExpr]): SExpr =
    newList(@[newKeyword("begin")] & items)
  proc listItems(items: varargs[SExpr]): SExpr =
    newList(@items)

  test "right-nested flatten":
    let input = begin(@[sym("A"), begin(@[sym("B"), sym("C")])])
    let expected = begin(@[sym("A"), sym("B"), sym("C")])
    check $(flattenBegins(input)) == $(expected)

  test "deep nested":
    let input = begin(@[sym("A"), begin(@[sym("B"), begin(@[sym("C"), sym("D")])])])
    let expected = begin(@[sym("A"), sym("B"), sym("C"), sym("D")])
    check $(flattenBegins(input)) == $(expected)

  test "idempotent on flat":
    let input = begin(@[sym("A"), sym("B"), sym("C")])
    check $(flattenBegins(input)) == $(input)

  test "preserves inside non-begin":
    let input = newList(@[
      sym("scanner-iterate"), newList(@[sym("s0")]), newList(@[sym("x")]),
      begin(@[sym("A"), sym("B")]),
    ])
    check $(flattenBegins(input)) == $(input)
