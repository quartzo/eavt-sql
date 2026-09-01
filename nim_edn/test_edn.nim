## test_edn.nim — Unit tests for nim_edn (EDN reader → SExpr).

import std/[unittest, strutils]
import scheme, edn, wire, msgpack_scan

proc rt(s: string): SExpr = wireFromMsgpack(sexprToMsgpack(readEdn(s)))

suite "edn.scalars":
  test "int, negative tempid":
    check readEdn("42").ival == 42
    check readEdn("-1").kind == sInt and readEdn("-1").ival == -1
    check readEdn("-9223372036854775808").ival == int64.low
  test "float":
    check readEdn("3.25").fval == 3.25
  test "string with escapes":
    check readEdn("\"a\\nb\\\"c\"").sval == "a\nb\"c"
  test "true false nil":
    check readEdn("true").bval == true
    check readEdn("false").bval == false
    check readEdn("nil").kind == sVoid
  test "underscore is a plain symbol":
    let r = readEdn("_")
    check r.kind == sSymbol and r.symval == "_"

suite "edn.keywords":
  test "keyword strips leading colon":
    let r = readEdn(":person/name")
    check r.kind == sKeyword
    check r.kwval == "person/name"
  test "keyword is not symbol not str":
    check readEdn(":x").kind == sKeyword
    check readEdn(":x").kind != sSymbol
    check readEdn(":x").kind != sStr
  test "bare colon is an error":
    expect(EdnError): discard readEdn(": ")

suite "edn.symbols":
  test "plain symbol":
    let r = readEdn("db-add")
    check r.kind == sSymbol and r.symval == "db-add"
  test "question var":
    let r = readEdn("?nome")
    check r.kind == sSymbol and r.symval == "?nome"

suite "edn.collections":
  test "vector of ops":
    let r = readEdn("[[:db/add -1 :person/name \"x\"] [:db/retract 7 :a 1]]")
    check r.kind == sList and r.items.len == 2
    let op0 = r.items[0]
    check op0.items.len == 4
    check op0.items[0].kind == sKeyword and op0.items[0].kwval == "db/add"
    check op0.items[1].ival == -1
    check op0.items[2].kind == sKeyword and op0.items[2].kwval == "person/name"
    check op0.items[3].sval == "x"
  test "list parses like vector":
    check readEdn("(1 2 3)").kind == sList
    check readEdn("(1 2 3)").items.len == 3
  test "nested":
    let r = readEdn("[[:a [1 -2]]]")
    check r.items[0].items[1].items[1].ival == -2
  test "comma is whitespace":
    let r = readEdn("[1, 2,3]")
    check r.items.len == 3
  test "lookup ref shape":
    let r = readEdn("[[:person/email \"a@b.c\"] :person/name \"x\"]")
    let inner = r.items[0]
    check inner.items[0].kwval == "person/email"
    check inner.items[1].sval == "a@b.c"

suite "edn.errors":
  test "unterminated vector":
    expect(EdnError): discard readEdn("[1 2")
  test "unterminated string":
    expect(EdnError): discard readEdn("\"abc")
  test "map rejected":
    expect(EdnError): discard readEdn("{:a 1}")
  test "set rejected":
    expect(EdnError): discard readEdn("#{:a}")
  test "trailing content":
    expect(EdnError): discard readEdn("[1] [2]")
  test "unsupported dispatch":
    expect(EdnError): discard readEdn("#foo")
  test "empty atom via delimiter":
    expect(EdnError): discard readEdn("[)]")

suite "edn.wire-roundtrip":
  test "tx vector survives wire encode/decode":
    let tx = readEdn("""[[:db/add -1 :person/name "álvia"]
                         [:db/add -1 :person/employer -2]
                         [:db/add -2 :company/name "Acme"]
                         [:db/add :db/current-tx :audit/user "fabio"]]""")
    let r = wireFromMsgpack(sexprToMsgpack(tx))
    check $r == $tx
  test "keyword survives wire as ext 0x06":
    # 2-char name → fixext2 (0xd5) + type byte 0x06
    let bytes = sexprToMsgpack(readEdn(":db"))
    check bytes[0].ord == 0xd5
    check bytes[1].ord == 0x06
    check wireFromMsgpack(bytes).kwval == "db"
    # longer name → ext8 path (msgpack4nim uses fixext only for 1/2/4/8/16)
    let bytes6 = sexprToMsgpack(readEdn(":db/add"))
    check bytes6[0].ord == 0xc7  # ext8
    check bytes6[2].ord == 0x06  # type byte after len
    check wireFromMsgpack(bytes6).kwval == "db/add"
  test "keyword ≠ symbol ≠ str on wire":
    check wireFromMsgpack(sexprToMsgpack(newKeyword("x"))).kind == sKeyword
    check wireFromMsgpack(sexprToMsgpack(newSymbol("x"))).kind == sSymbol
    check wireFromMsgpack(sexprToMsgpack(newStr("x"))).kind == sStr
suite "edn.tx-frame":
  test "txdataFromMsgpack decodes a real python-packed frame":
    # exact bytes produced by msgpack-python: "db/ident" (8 bytes) rides a
    # fixext8 (0xd7); "db/add" (6) rides ext8 (0xc7); "wt2/audit" (9) ext8.
    let frame = "\x82\xa4type\xa2tx\xa6txdata\x91\x94\xc7\x06\x06db/add\x04\xd7\x06db/ident\xc7\x09\x06wt2/audit"
    let ops = txdataFromMsgpack(frame)
    check ops.len == 1
    check ops[0].items.len == 4
    check ops[0].items[0].kwval == "db/add"
    check ops[0].items[1].ival == 4
    check ops[0].items[2].kwval == "db/ident"
    check ops[0].items[3].kwval == "wt2/audit"
  test "multi-op frame with mixed ext sizes decodes":
    # fixext8 (0xd7) for 8-byte keywords, ext8 (0xc7) otherwise
    let frame = "\x82\xa4type\xa2tx\xa6txdata\x92" &
      "\x94\xc7\x06\x06db/add\x01\xd7\x06db/ident\xc7\x0b\x06person/name" &
      "\x94\xc7\x06\x06db/add\x2a\xc7\x0c\x06db/valueType\xc7\x0e\x06db.type/string"
    let ops = txdataFromMsgpack(frame)
    check ops.len == 2
    check ops[0].items[3].kwval == "person/name"
    check ops[1].items[1].ival == 42
    check ops[1].items[3].kwval == "db.type/string"
