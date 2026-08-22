## test_msgpack_scan.nim — Unit tests for eavt_query_nim/msgpack_scan
## (top-level map key scan + raw id injection).

import std/[unittest, json, tables]
import msgpack4nim/msgpack2json
import msgpack_scan

func fixstr(s: string): string = chr(0xa0 or s.len) & s
func mpU8(v: int): string = chr(0xcc) & chr(v)

suite "msgpack_scan.isMsgpackMap":
  test "json-built object":
    let raw = fromJsonNode(%*{"type": "scheme"})
    check isMsgpackMap(raw)
  test "array is not a map":
    check not isMsgpackMap(fromJsonNode(%[1, 2]))
  test "string is not a map":
    check not isMsgpackMap(fromJsonNode(%"hello"))
  test "empty input":
    check not isMsgpackMap("")
  test "bare empty fixmap":
    check isMsgpackMap("\x80")

suite "msgpack_scan.getTopStr":
  test "finds type and mode":
    let raw = fromJsonNode(%*{"type": "scheme", "mode": "exec"})
    check getTopStr(raw, "type") == "scheme"
    check getTopStr(raw, "mode") == "exec"
  test "missing key":
    let raw = fromJsonNode(%*{"type": "scheme"})
    check getTopStr(raw, "nope") == ""
  test "non-string value yields empty":
    let raw = fromJsonNode(%*{"type": 42})
    check getTopStr(raw, "type") == ""
  test "nested same-name keys do not confuse":
    ## program payload contains its own "type" key deeper down.
    let raw = fromJsonNode(%*{
      "type": "scheme",
      "program": [7, [[3, "save"], [3, "E"], [2, {"type": "inner"}]]]
    })
    check getTopStr(raw, "type") == "scheme"
  test "empty map":
    check getTopStr("\x80", "type") == ""

suite "msgpack_scan.getTopBool":
  test "true / false / missing / fallback":
    check getTopBool(fromJsonNode(%*{"more": true}), "more")
    check not getTopBool(fromJsonNode(%*{"more": false}), "more")
    check not getTopBool(fromJsonNode(%*{}), "more")
    check getTopBool(fromJsonNode(%*{}), "more", fallback = true)
  test "non-bool value falls back":
    check not getTopBool(fromJsonNode(%*{"more": "yes"}), "more")

suite "msgpack_scan.topValue on hand-crafted frames":
  test "map16 header scanned":
    ## \xde 00 02 {a:1} {b:"two"}
    let raw = "\xde\x00\x02" & fixstr("a") & mpU8(1) & fixstr("b") & fixstr("two")
    check getTopStr(raw, "b") == "two"
    check not topValue(raw, "c")[0]

  test "all value types skipped correctly":
    ## One key whose value is an array exercising every skip branch,
    ## followed by a second top-level key that must still be found.
    const blob =
      "\xc0" &                       # nil
      "\xc2\xc3" &                   # false, true
      "\x05\xe5" &                   # pos fixint 5, neg fixint -27
      "\xcc\xff\xcd\x01\x00" &       # u8 255, u16 256
      "\xce\xde\xad\xbe\xef" &       # u32
      "\xcf\xff\xff\xff\xff\xff\xff\xff\xff" &  # u64 max
      "\xd0\x80\xd1\x80\x00\xd2\xff\xff\xff\xff" &  # i8/i16/i32 minima
      "\xd3\x80\x00\x00\x00\x00\x00\x00\x00" &      # i64 min
      "\xca\x3f\x80\x00\x00" &       # f32 1.0
      "\xcb\x3f\xf0\x00\x00\x00\x00\x00\x00" &      # f64 1.0
      "\xa5hello" &                  # fixstr
      "\xd9\x0adirect str" &         # str8 (len 10)
      "\xda\x00\x03abc" &            # str16
      "\xdb\x00\x00\x00\x04wxyz" &   # str32
      "\xc4\x02\x01\x02" &           # bin8
      "\xc5\x00\x03\x0a\x0b\x0c" &   # bin16
      "\xc6\x00\x00\x00\x01\xaa" &   # bin32
      "\xd4\x01\x42" &               # fixext1
      "\xd5\x02\x43\x44" &           # fixext2
      "\xd6\x03\x45\x46\x47\x48" &   # fixext4
      "\xd7\x04" & "\x00\x00\x00\x00\x00\x00\x00\x00" &  # fixext8
      "\xd8\x05" &
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" &
      "\xc7\x03\x06\x61\x62\x63" &   # ext8 len 3
      "\xc8\x00\x02\x07\x61\x62" &   # ext16
      "\xc9\x00\x00\x00\x01\x08\x61" &  # ext32
      "\x92\x01\x02"                 # fixarray [1, 2]
    check blob.len <= 255
    ## 31 elements total (counted by hand below); array16 header.
    var raw = "\x82" & fixstr("blob") & "\xdc\x00\x1f" & blob
    raw.add fixstr("tail")
    raw.add fixstr("found-it")
    check getTopStr(raw, "tail") == "found-it"
    check getTopStr(raw, "missing") == ""

  test "deep nesting beyond cap is rejected":
    ## 100 nested one-element fixarrays — scanner must bail out.
    var raw = "\x81" & fixstr("deep")
    for i in 1 .. 100:
      raw.add "\x91"
    raw.add "\x01"
    check not hasTopKey(raw, "anything")

  test "malformed truncations are safe":
    ## For every prefix of a valid frame the scan must terminate without
    ## crashing (defects fail the suite).
    let base = fromJsonNode(%*{"type": "scheme", "mode": "query"})
    for n in 0 ..< base.len:
      let cut = base[0 ..< n]
      discard hasTopKey(cut, "type")
      discard getTopStr(cut, "type")
      discard getTopBool(cut, "more")
      discard injectTopPair(cut, "id", "1")

suite "msgpack_scan.injectTopPair":
  test "round-trip through json parser preserves content":
    let orig = %*{
      "type": "scheme", "mode": "exec",
      "program": [7, [[3, "begin"], [7, [[3, "result"], [3, "E"]]]]],
      "params": [[2, "abc"], [0, 17]]
    }
    let framed = injectTopPair(fromJsonNode(orig), "id", "41")
    check framed.len > 0
    let back = toJsonNode(framed)
    check back["type"].getStr == "scheme"
    check back["mode"].getStr == "exec"
    check back["id"].getStr == "41"
    check back["program"] == orig["program"]
    check back["params"] == orig["params"]
  test "inject twice appends both":
    let once = injectTopPair(fromJsonNode(%*{"type": "kv"}), "id", "7")
    let twice = injectTopPair(once, "seq", "9")
    let back = toJsonNode(twice)
    check back["id"].getStr == "7"
    check back["seq"].getStr == "9"
    check back["type"].getStr == "kv"
  test "fixmap 15 -> map16 promotion":
    ## Hand-crafted fixmap with exactly 15 pairs (0x8f header).
    var body = ""
    for i in 0 ..< 15:
      body.add fixstr("k" & $i)
      body.add mpU8(i)
    let raw = "\x8f" & body
    check ord(raw[0]) == 0x8f
    let framed = injectTopPair(raw, "id", "3")
    check framed.len > 0
    check ord(framed[0]) == 0xde          # promoted to map16
    let back = toJsonNode(framed)
    check len(back.fields) == 16
    check back["id"].getStr == "3"
    check back["k14"].getInt == 14
  test "plain map16 stays map16":
    let raw = "\xde\x00\x02" & fixstr("a") & mpU8(1) & fixstr("b") & fixstr("two")
    let framed = injectTopPair(raw, "id", "12")
    check framed.len > 0
    check ord(framed[0]) == 0xde
    check toJsonNode(framed)["id"].getStr == "12"
  test "empty map gains one pair":
    let back = toJsonNode(injectTopPair("\x80", "id", "1"))
    check len(back.fields) == 1
    check back["id"].getStr == "1"
  test "non-map returns empty":
    check injectTopPair(fromJsonNode(%[1, 2]), "id", "1") == ""
    check injectTopPair("", "id", "1") == ""
