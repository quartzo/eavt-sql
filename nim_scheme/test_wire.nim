## test_wire.nim — Unit tests for nim_scheme/wire (tagged AST transport).

import std/[unittest, json, strutils]
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

# ── Direct msgpack decode (wireFromMsgpack) ─────────────────────────────────
import msgpack4nim/msgpack2json

proc sameSexpr(a, b: SExpr): bool =
  if a.kind != b.kind: return false
  case a.kind
  of sVoid: true
  of sBool: a.bval == b.bval
  of sInt: a.ival == b.ival
  of sFloat: a.fval == b.fval
  of sStr: a.sval == b.sval
  of sSymbol: a.symval == b.symval
  of sBytes: a.bytesval == b.bytesval
  of sResource: a.rid == b.rid
  of sList:
    if a.items.len != b.items.len: return false
    for i in 0 ..< a.items.len:
      if not sameSexpr(a.items[i], b.items[i]): return false
    true

proc mpRoundTrip(e: SExpr): SExpr =
  ## encode → JsonNode → msgpack bytes → direct decode
  wireFromMsgpack(fromJsonNode(sexprToWire(e)))

suite "wire.msgpack-direct":
  test "round-trips all scalar kinds":
    check sameSexpr(mpRoundTrip(newInt(-42)), newInt(-42))
    check sameSexpr(mpRoundTrip(newInt(int64.high)), newInt(int64.high))
    check sameSexpr(mpRoundTrip(newInt(int64.low)), newInt(int64.low))
    check sameSexpr(mpRoundTrip(newFloat(3.25)), newFloat(3.25))
    check sameSexpr(mpRoundTrip(newStr("hé\"llo\n")), newStr("hé\"llo\n"))
    check sameSexpr(mpRoundTrip(newSymbol("scanner-open")), newSymbol("scanner-open"))
    check mpRoundTrip(newBool(true)).bval == true
    check mpRoundTrip(newVoid()).kind == sVoid
    check sameSexpr(mpRoundTrip(newBytes(@[byte(0), byte(255)])),
                    newBytes(@[byte(0), byte(255)]))
    check mpRoundTrip(newBytes(@[])).bytesval.len == 0
  test "long string (>31 chars uses str8/str16 path)":
    let long = newStr("x".repeat(100))
    check sameSexpr(mpRoundTrip(long), long)
  test "nested program shape round-trips":
    let e = newList(@[
      newSymbol("begin"),
      newList(@[newSymbol("save"), newSymbol("E"), newStr("company.name"),
                newStr("Acme")]),
      newList(@[newSymbol("get-or-create-entity"), newStr("empresa.cnpj_base"),
                newStr("12345678")]),
      newList(@[newSymbol("result"), newSymbol("E"), newInt(80)]),
    ])
    check sameSexpr(mpRoundTrip(e), e)
  test "deep nesting under the cap":
    var e = newInt(1)
    for i in 0 ..< 50:
      e = newList(@[newSymbol("wrap"), e])
    check sameSexpr(mpRoundTrip(e), e)
  test "truncated input raises":
    let bytes = fromJsonNode(sexprToWire(newList(@[newSymbol("ab"), newInt(5)])))
    for n in 0 ..< bytes.len:
      expect(WireError): discard wireFromMsgpack(bytes[0 ..< n])
  test "non-array input raises":
    expect(WireError): discard wireFromMsgpack(fromJsonNode(%"hello"))
    expect(WireError): discard wireFromMsgpack(fromJsonNode(%*[1, 2, 3]))
  test "unknown tag raises":
    expect(WireError): discard wireFromMsgpack(fromJsonNode(%*[99, 1]))
  test "bool tag with non-bool payload raises":
    expect(WireError): discard wireFromMsgpack(fromJsonNode(%*[4, "x"]))

  test "sexprToMsgpack matches sexprToWire+fromJsonNode":
    proc mpDirect(e: SExpr): SExpr = wireFromMsgpack(sexprToMsgpack(e))
    check sameSexpr(mpDirect(newInt(-42)), newInt(-42))
    check sameSexpr(mpDirect(newFloat(3.25)), newFloat(3.25))
    check sameSexpr(mpDirect(newStr("hello")), newStr("hello"))
    check sameSexpr(mpDirect(newSymbol("save")), newSymbol("save"))
    check mpDirect(newBool(true)).bval == true
    check mpDirect(newVoid()).kind == sVoid
    check sameSexpr(mpDirect(newBytes(@[byte(0), byte(255)])),
                    newBytes(@[byte(0), byte(255)]))
    let nested = newList(@[newSymbol("begin"),
                           newList(@[newSymbol("save"), newSymbol("E"),
                                     newStr("x"), newInt(1)])])
    check sameSexpr(mpDirect(nested), nested)
    # Verify byte-level equality with legacy path
    check sexprToMsgpack(newInt(42)) == fromJsonNode(sexprToWire(newInt(42)))
    check sexprToMsgpack(newStr("x")) == fromJsonNode(sexprToWire(newStr("x")))
    check sexprToMsgpack(newSymbol("a")) == fromJsonNode(sexprToWire(newSymbol("a")))
