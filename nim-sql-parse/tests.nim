import std/[unittest, json]
import ast, parser

proc loadGolden(): JsonNode =
  parseFile("golden.json")

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
      "projections": [{"field": newJNull(), "literal": {"Int": 42}}],
      "conditions": [],
      "exists_mode": true,
      "star": false,
      "history": false
    }
    check got == expected
