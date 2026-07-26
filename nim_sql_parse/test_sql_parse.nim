import std/[unittest, json, os, options]
import ast, parser

proc loadGolden(): JsonNode =
  let p = parentDir(currentSourcePath()) / "golden.json"
  parseFile(p)

suite "SQL parser: golden tests (vs Rust parser)":
  let golden = loadGolden()
  for entry in golden:
    let label = entry["label"].getStr
    let sql = entry["sql"].getStr
    let expected = entry["expected"]

    test label & " (" & sql[0..min(sql.len-1, 40)] & ")":
      let stmt = parse(sql)
      let got = toJson(stmt)
      check got == expected

suite "SQL parser: error tests":
  test "invalid SQL":
    expect CatchableError:
      discard parse("NOT VALID SQL !!!")

  test "unexpected EOF":
    expect CatchableError:
      discard parse("SELECT d1.eid WHERE")

  test "empty string":
    expect CatchableError:
      discard parse("")

  test "ATTRIBUTE missing type":
    expect CatchableError:
      discard parse("ATTRIBUTE company.name")

  test "ATTRIBUTE missing namespace":
    expect CatchableError:
      discard parse("ATTRIBUTE nodot STRING MANY")

  test "expected EOF":
    expect CatchableError:
      discard parse("SELECT d1.name WHERE d1.eid = %1 garbage")

  test "EXPLAIN without statement":
    expect CatchableError:
      discard parse("EXPLAIN")

  test "unterminated string":
    expect CatchableError:
      discard parse("WHERE d1.name = 'unterminated")

  test "param without digit":
    expect CatchableError:
      discard parse("WHERE d1.eid = %")

  test "unexpected character":
    expect CatchableError:
      discard parse("SELECT d1.eid # comment")

  test "SELECT literal in projection":
    let stmt = parse("SELECT 42")
    let got = toJson(stmt)
    var expected = newJObject()
    expected["Select"] = %*{
      "projections": [{"field": newJNull(), "literal": {"Int": 42}, "expr": newJNull()}],
      "conditions": [],
      "exists_mode": true,
      "star": false,
      "history": false
    }
    check got == expected

suite "SQL parser: expression projections":
  test "SELECT arithmetic add":
    let stmt = parse("SELECT 20+20")
    check(not stmt.selectStmt.projections[0].field.isSome)
    check(not stmt.selectStmt.projections[0].literal.isSome)
    let e = stmt.selectStmt.projections[0].expr.get
    check e.vkind == valBinOp
    check e.binOp == "+"
    check e.binLeft.vkind == valLiteral
    check e.binLeft.vlit.ival == 20
    check e.binRight.vlit.ival == 20

  test "SELECT arithmetic precedence (mul before add)":
    let stmt = parse("SELECT 2+3*4")
    let e = stmt.selectStmt.projections[0].expr.get
    check e.vkind == valBinOp and e.binOp == "+"
    check e.binLeft.vlit.ival == 2
    check e.binRight.vkind == valBinOp and e.binRight.binOp == "*"

  test "SELECT parenthesised expression":
    let stmt = parse("SELECT (1+2)*3")
    let e = stmt.selectStmt.projections[0].expr.get
    check e.vkind == valBinOp and e.binOp == "*"
    check e.binLeft.vkind == valBinOp and e.binLeft.binOp == "+"

  test "SELECT eid() lookup":
    let stmt = parse("SELECT eid('company.name', 'ACME')")
    let e = stmt.selectStmt.projections[0].expr.get
    check e.vkind == valEidLookup
    check e.eidAttr.vkind == valLiteral
    check e.eidAttr.vlit.sval == "company.name"

  test "SELECT unary minus on literal":
    # -7 is tokenised by the lexer as a single ttINTEGER(-7) (minus is
    # consumed by readNumber).  So the Projection is a literal, not a
    # unary-op — the minus is baked into the integer literal value.
    let stmt = parse("SELECT -7")
    check stmt.selectStmt.projections[0].literal.isSome
    check stmt.selectStmt.projections[0].literal.get.ival == -7

  test "SELECT unary minus on parenthesised expr":
    # -(1+2): ttMINUS is a separate token, so parseProjection enters
    # the expression branch → valUnaryOp wrapping a BinOp.
    let stmt = parse("SELECT -(1+2)")
    let e = stmt.selectStmt.projections[0].expr.get
    check e.vkind == valUnaryOp
    check e.unOp == "-"
    check e.unOperand.vkind == valBinOp
    check e.unOperand.binOp == "+"

  test "isolated literal still uses literal field (AST compat)":
    let stmt = parse("SELECT 42")
    check stmt.selectStmt.projections[0].literal.isSome
    check(not stmt.selectStmt.projections[0].expr.isSome)
