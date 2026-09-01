## test_wire.nim — Unit tests for nim_scheme/wire (EDN-like transport:
## native msgpack values + ext 0x05 for symbols).

import std/[unittest, strutils]
import scheme, wire

proc rt(e: SExpr): SExpr = wireFromMsgpack(sexprToMsgpack(e))

suite "wire.roundtrip":
  test "void":       check rt(newVoid()).kind == sVoid
  test "bool":       check rt(newBool(true)).bval == true
  test "bool false": check rt(newBool(false)).bval == false
  test "int":        check rt(newInt(-42)).ival == -42
  test "int64 min":  check rt(newInt(int64.low)).ival == int64.low
  test "int64 max":  check rt(newInt(int64.high)).ival == int64.high
  test "float":      check rt(newFloat(3.25)).fval == 3.25
  test "float negative zero":
    check rt(newFloat(-0.0)).fval == -0.0
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

  test "empty symbol name":
    let r = rt(newSymbol(""))
    check r.kind == sSymbol
    check r.symval == ""

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

suite "wire.encoding-shape":
  test "symbol is ext 0x05":
    # fixext1 (0xd4) + type 0x05 + payload "a"
    check sexprToMsgpack(newSymbol("a")) == "\xd4\x05a"
  test "str is native msgpack str":
    check sexprToMsgpack(newStr("a")) == "\xa1a"
  test "bytes is native bin":
    check sexprToMsgpack(newBytes(@[byte(1), byte(2)])) == "\xc4\x02\x01\x02"
  test "long symbol uses ext8 path":
    let s = "x".repeat(40)
    let bytes = sexprToMsgpack(newSymbol(s))
    check bytes[0].ord == 0xc7  # ext8
    check bytes[1].ord == 40
    check bytes[2].ord == 0x05  # type byte
    check wireFromMsgpack(bytes).symval == s

suite "wire.errors":
  test "resource rejected":
    expect(WireError): discard sexprToMsgpack(newResource(1))

suite "wire.program":
  test "parsed program text round-trips through wire":
    let src = """(begin (set! s0 (scanner-open "EAVT")) (result-row (intern-a "company.name") 42 "x"))"""
    let prog = SchemeProgram(body: parse(src))
    let r = rt(prog.body)
    check $r == $prog.body

# ── Direct msgpack decode edge cases ────────────────────────────────────────

proc sameSexpr(a, b: SExpr): bool =
  if a.kind != b.kind: return false
  case a.kind
  of sVoid: true
  of sBool: a.bval == b.bval
  of sInt: a.ival == b.ival
  of sFloat: a.fval == b.fval
  of sStr: a.sval == b.sval
  of sSymbol: a.symval == b.symval
  of sKeyword: a.kwval == b.kwval
  of sBytes: a.bytesval == b.bytesval
  of sResource: a.rid == b.rid
  of sList:
    if a.items.len != b.items.len: return false
    for i in 0 ..< a.items.len:
      if not sameSexpr(a.items[i], b.items[i]): return false
    true

suite "wire.msgpack-direct":
  test "round-trips all scalar kinds":
    check sameSexpr(rt(newInt(-42)), newInt(-42))
    check sameSexpr(rt(newInt(int64.high)), newInt(int64.high))
    check sameSexpr(rt(newInt(int64.low)), newInt(int64.low))
    check sameSexpr(rt(newFloat(3.25)), newFloat(3.25))
    check sameSexpr(rt(newStr("hé\"llo\n")), newStr("hé\"llo\n"))
    check sameSexpr(rt(newSymbol("scanner-open")), newSymbol("scanner-open"))
    check rt(newBool(true)).bval == true
    check rt(newVoid()).kind == sVoid
    check sameSexpr(rt(newBytes(@[byte(0), byte(255)])),
                    newBytes(@[byte(0), byte(255)]))
    check rt(newBytes(@[])).bytesval.len == 0
  test "long string (>31 chars uses str8/str16 path)":
    let long = newStr("x".repeat(100))
    check sameSexpr(rt(long), long)
  test "nested program shape round-trips":
    let e = newList(@[
      newSymbol("begin"),
      newList(@[newSymbol("save"), newSymbol("E"), newStr("company.name"),
                newStr("Acme")]),
      newList(@[newSymbol("get-or-create-entity"), newStr("empresa.cnpj_base"),
                newStr("12345678")]),
      newList(@[newSymbol("result"), newSymbol("E"), newInt(80)]),
    ])
    check sameSexpr(rt(e), e)
  test "deep nesting under the cap":
    var e = newInt(1)
    for i in 0 ..< 50:
      e = newList(@[newSymbol("wrap"), e])
    check sameSexpr(rt(e), e)
  test "truncated input raises":
    let bytes = sexprToMsgpack(newList(@[newSymbol("ab"), newInt(5)]))
    for n in 0 ..< bytes.len:
      expect(WireError): discard wireFromMsgpack(bytes[0 ..< n])
  test "bare scalar values decode as themselves":
    check wireFromMsgpack("\x05").kind == sInt
    check wireFromMsgpack("\xa1x").sval == "x"
    check wireFromMsgpack("\xc3").bval == true
    check wireFromMsgpack("\xc0").kind == sVoid
  test "f32 input decodes as f64":
    # 0xca + big-endian float32 2.0
    check wireFromMsgpack("\xca\x40\x00\x00\x00").fval == 2.0
  test "map inside program raises":
    expect(WireError): discard wireFromMsgpack("\x81\xa1k\x01")
    expect(WireError): discard wireFromMsgpack("\x92\x81\xa1k\x01\x01")
  test "unknown ext type raises":
    expect(WireError): discard wireFromMsgpack("\xd4\x02A")       # fixext1 type 2
    expect(WireError): discard wireFromMsgpack("\xd4\x07A")       # fixext1 type 7
    expect(WireError): discard wireFromMsgpack("\xc7\x01\x42A")   # ext8 type 0x42
  test "timestamp ext (type -1) raises":
    # 0xd6 fixext4 with type 0xff (-1)
    expect(WireError): discard wireFromMsgpack("\xd6\xff\x00\x00\x00\x00")
  test "str8/str16/str32 decode":
    check wireFromMsgpack("\xd9\x05" & "abcde").sval == "abcde"
    check wireFromMsgpack("\xda\x00\x05" & "abcde").sval == "abcde"
    check wireFromMsgpack("\xdb\x00\x00\x00\x05" & "abcde").sval == "abcde"
  test "bin8/bin16/bin32 decode":
    check wireFromMsgpack("\xc4\x02\x01\x02").bytesval == @[byte(1), byte(2)]
    check wireFromMsgpack("\xc5\x00\x02\x01\x02").bytesval == @[byte(1), byte(2)]
    check wireFromMsgpack("\xc6\x00\x00\x00\x02\x01\x02").bytesval == @[byte(1), byte(2)]
  test "ext16/ext32 symbol decode":
    check wireFromMsgpack("\xc8\x00\x02\x05ab").symval == "ab"
    check wireFromMsgpack("\xc9\x00\x00\x00\x02\x05ab").symval == "ab"
  test "trailing bytes raise":
    expect(WireError): discard wireFromMsgpack("\xd4\x05a" & "\x01")
  test "depth cap raises":
    var bytes = "\x01"
    for i in 0 ..< 70:
      bytes = "\x92\xd4\x05w" & bytes
    expect(WireError): discard wireFromMsgpack(bytes)