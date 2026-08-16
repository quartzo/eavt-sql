## test_wire.nim — Unit tests for nim_scheme/wire (tagged AST transport).

import std/[unittest, json]
import scheme, wire

proc rt(e: SExpr): SExpr = wireToSexpr(sexprToWire(e))

suite "wire.roundtrip":
  test "void":       check rt(newVoid()).kind == sVoid
  test "bool":       check rt(newBool(true)).bval == true
  test "int":        check rt(newInt(-42)).ival == -42
  test "int64 min":  check rt(newInt(int64.low)).ival == int64.low
  test "int64 max":  check rt(newInt(int64.high)).ival == int64.high
  test "float":      check rt(newFloat(3.25)).fval == 3.25
  test "str":        check rt(newStr("hello")).sval == "hello"
  test "str with quotes and newline":
    check rt(newStr("a \"b\"\nc")).sval == "a \"b\"\nc"

  test "symbol not str":
    let r = rt(newSymbol("scanner-open"))
    check r.kind == sSymbol
    check r.symval == "scanner-open"

  test "str not symbol":
    let r = rt(newStr("scanner-open"))
    check r.kind == sStr

  test "bytes":
    let r = rt(newBytes(@[byte(0), byte(1), byte(255), byte(10)]))
    check r.kind == sBytes
    check r.bytesval == @[byte(0), byte(1), byte(255), byte(10)]

  test "empty bytes":
    check rt(newBytes(@[])).bytesval.len == 0

  test "empty list":
    let r = rt(newList(@[]))
    check r.kind == sList
    check r.items.len == 0

  test "nested list mixes kinds":
    let e = newList(@[
      newSymbol("result-row"),
      newInt(7),
      newStr("x"),
      newBytes(@[byte(200)]),
      newList(@[newBool(false), newFloat(-0.5)]),
    ])
    let r = rt(e)
    check r.kind == sList
    check r.items.len == 5
    check r.items[0].kind == sSymbol and r.items[0].symval == "result-row"
    check r.items[1].ival == 7
    check r.items[2].sval == "x"
    check r.items[3].kind == sBytes and r.items[3].bytesval == @[byte(200)]
    check r.items[4].items[0].bval == false
    check r.items[4].items[1].fval == -0.5

  test "float tag survives float value":
    # tag 1 must decode as float even though msgpack/json may normalize numbers
    let r = wireToSexpr(%*[1, 2.0])
    check r.kind == sFloat
    check r.fval == 2.0

  test "int tag with integral value stays int":
    let r = wireToSexpr(%*[0, 5])
    check r.kind == sInt
    check r.ival == 5

suite "wire.errors":
  test "resource rejected":
    expect(WireError): discard sexprToWire(newResource(1))

  test "unknown tag":
    expect(WireError): discard wireToSexpr(%*[99, 1])

  test "not an array":
    expect(WireError): discard wireToSexpr(%*"oops")

  test "wrong arity":
    expect(WireError): discard wireToSexpr(%*[0, 1, 2])

  test "tag not int":
    expect(WireError): discard wireToSexpr(%*["0", 1])

  test "bytes item out of range":
    expect(WireError): discard wireToSexpr(%*[5, [300]])

  test "bytes item not int":
    expect(WireError): discard wireToSexpr(%*[5, ["a"]])

suite "wire.program":
  test "parsed program text round-trips through wire":
    let src = """(begin (set! s0 (scanner-open "EAVT")) (result-row (intern-a "company.name") 42 "x"))"""
    let prog = SchemeProgram(body: parse(src))
    let r = rt(prog.body)
    check $r == $prog.body
