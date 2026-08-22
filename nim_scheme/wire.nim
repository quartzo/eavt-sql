## wire.nim — Tagged AST transport encoding for SExpr.
##
## Encodes/decodes SExpr trees as 2-element tagged arrays
## (`[tag, value]`) on the msgpack wire.  The tag preserves
## distinctions plain values cannot express: symbol × string,
## int64 × float64, and raw bytes.
##
## Tag table (see docs/scheme-transport.md §3.3):
##   0 = int, 1 = float, 2 = str, 3 = symbol, 4 = bool,
##   5 = bytes, 6 = void, 7 = list
##
## Two decode paths exist:
##   • wireToSexpr(JsonNode) — legacy, via a JSON tree (msgpack2json)
##   • wireFromMsgpack(string) — direct from raw msgpack bytes; builds
##     the SExpr in one pass with no intermediate tree.  This is what
##     the transactor uses per request.

import std/[json, strutils, streams]
import msgpack4nim
import scheme, msgpack_scan

type
  WireError* = object of CatchableError

const
  tagInt = 0
  tagFloat = 1
  tagStr = 2
  tagSymbol = 3
  tagBool = 4
  tagBytes = 5
  tagVoid = 6
  tagList = 7

proc sexprToWire*(e: SExpr): JsonNode =
  case e.kind
  of sInt:    %*[tagInt, e.ival]
  of sFloat:  %*[tagFloat, e.fval]
  of sStr:    %*[tagStr, e.sval]
  of sSymbol: %*[tagSymbol, e.symval]
  of sBool:   %*[tagBool, e.bval]
  of sBytes:
    var arr = newJArray()
    for b in e.bytesval: arr.add(%b)
    %*[tagBytes, arr]
  of sVoid:   %*[tagVoid, newJNull()]
  of sList:
    var arr = newJArray()
    for item in e.items: arr.add(sexprToWire(item))
    %*[tagList, arr]
  of sResource:
    raise newException(WireError, "cannot encode sResource on the wire")

proc appendRaw*(s: MsgStream; bytes: string) {.inline.} =
  ## Append pre-encoded msgpack bytes to a MsgStream.  CRITICAL: plain
  ## `s.data.add(bytes)` does NOT advance the stream position — the next
  ## `pack` would overwrite the appended bytes (StringStream writes at
  ## `pos` via copyMem, not at data.len).
  if bytes.len > 0:
    s.data.add(bytes)
    s.setPosition(s.data.len)

proc writeSExprWire*(s: MsgStream; e: SExpr) =
  ## Write one SExpr as a tagged wire node `[tag, value]` directly into
  ## an existing MsgStream.
  s.pack_array(2)
  case e.kind
  of sInt:
    s.pack(tagInt); s.pack(e.ival)
  of sFloat:
    s.pack(tagFloat); s.pack(e.fval)
  of sStr:
    s.pack(tagStr); s.pack(e.sval)
  of sSymbol:
    s.pack(tagSymbol); s.pack(e.symval)
  of sBool:
    s.pack(tagBool); s.pack(e.bval)
  of sBytes:
    s.pack(tagBytes)
    s.pack_array(e.bytesval.len)
    for b in e.bytesval: s.pack(int64(b))
  of sVoid:
    s.pack(tagVoid); s.pack_imp_nil()
  of sList:
    s.pack(tagList)
    s.pack_array(e.items.len)
    for item in e.items: writeSExprWire(s, item)
  of sResource:
    raise newException(WireError, "cannot encode sResource on the wire")

proc sexprToMsgpack*(e: SExpr): string =
  ## Encode one SExpr as a tagged wire node `[tag, value]` in msgpack bytes.
  ## Direct replacement for `fromJsonNode(sexprToWire(e))`.
  var s = MsgStream.init(64)
  writeSExprWire(s, e)
  s.data

proc sexprToPlainMsgpack*(e: SExpr): string =
  ## Encode one SExpr as a plain msgpack value (no wire tag wrapper).
  ## Used for response rows — values go directly as msgpack types.
  var s = MsgStream.init(64)
  proc encPlain(s: MsgStream; e: SExpr) =
    case e.kind
    of sInt:    s.pack(e.ival)
    of sFloat:  s.pack(e.fval)
    of sStr:    s.pack(e.sval)
    of sSymbol: s.pack(e.symval)
    of sBool:   s.pack(e.bval)
    of sBytes:
      s.pack_bin(e.bytesval.len)
      if e.bytesval.len > 0:
        var tmp = newString(e.bytesval.len)
        copyMem(addr tmp[0], unsafeAddr e.bytesval[0], e.bytesval.len)
        appendRaw(s, tmp)
    of sVoid:   s.pack_imp_nil()
    of sList:
      s.pack_array(e.items.len)
      for item in e.items: encPlain(s, item)
    of sResource:
      raise newException(WireError, "cannot encode sResource on the wire")
  encPlain(s, e)
  s.data

proc writeSExprPlain*(s: MsgStream; e: SExpr) =
  ## Write one SExpr as a plain msgpack value directly to a MsgStream.
  case e.kind
  of sInt:    s.pack(e.ival)
  of sFloat:  s.pack(e.fval)
  of sStr:    s.pack(e.sval)
  of sSymbol: s.pack(e.symval)
  of sBool:   s.pack(e.bval)
  of sBytes:
    s.pack_bin(e.bytesval.len)
    if e.bytesval.len > 0:
      var tmp = newString(e.bytesval.len)
      copyMem(addr tmp[0], unsafeAddr e.bytesval[0], e.bytesval.len)
      appendRaw(s, tmp)
  of sVoid:   s.pack_imp_nil()
  of sList:
    s.pack_array(e.items.len)
    for item in e.items: writeSExprPlain(s, item)
  of sResource:
    raise newException(WireError, "cannot encode sResource on the wire")

proc expectArr(n: JsonNode; what: string): JsonNode =
  if n.kind != JArray:
    raise newException(WireError, "wire node for " & what & " must be an array, got " & $n.kind)
  result = n

proc wireToSexpr*(n: JsonNode): SExpr =
  let arr = expectArr(n, "node")
  if arr.len != 2:
    raise newException(WireError, "wire node must be [tag, value], got " & $arr.len & " elements")
  if arr[0].kind != JInt:
    raise newException(WireError, "wire tag must be an int, got " & $arr[0].kind)
  let tag = arr[0].getInt
  let v = arr[1]
  case tag
  of tagInt:
    if v.kind != JInt: raise newException(WireError, "tag 0 (int) value must be a number")
    newInt(v.getInt)
  of tagFloat:
    if v.kind notin {JInt, JFloat}: raise newException(WireError, "tag 1 (float) value must be a number")
    newFloat(v.getFloat)
  of tagStr:
    if v.kind != JString: raise newException(WireError, "tag 2 (str) value must be a string")
    newStr(v.getStr)
  of tagSymbol:
    if v.kind != JString: raise newException(WireError, "tag 3 (symbol) value must be a string")
    newSymbol(v.getStr)
  of tagBool:
    if v.kind != JBool: raise newException(WireError, "tag 4 (bool) value must be a bool")
    newBool(v.getBool)
  of tagBytes:
    let barr = expectArr(v, "bytes value")
    var bs: seq[byte]
    for b in barr:
      if b.kind != JInt: raise newException(WireError, "bytes array items must be ints")
      let i = b.getInt
      if i < 0 or i > 255: raise newException(WireError, "bytes array item out of range: " & $i)
      bs.add(byte(i))
    newBytes(bs)
  of tagVoid: newVoid()
  of tagList:
    let larr = expectArr(v, "list value")
    var items: seq[SExpr]
    for item in larr: items.add(wireToSexpr(item))
    newList(items)
  else:
    raise newException(WireError, "unknown wire tag: " & $tag)

# ── Direct msgpack decode (no intermediate JSON tree) ───────────────────────

proc mpReadInt(buf: string; pos: var int; limit: int): int64 =
  ## Read any msgpack int encoding at pos, advancing pos.
  if pos >= limit: raise newException(WireError, "truncated int")
  let b = ord(buf[pos])
  inc pos
  case b
  of 0x00..0x7f: return int64(b)
  of 0xe0..0xff: return int64(cast[int8](byte(b)))
  else:
    let n = case b
      of 0xcc, 0xd0: 1
      of 0xcd, 0xd1: 2
      of 0xce, 0xd2: 4
      of 0xcf, 0xd3: 8
      else: -1
    if n < 0 or pos + n > limit:
      raise newException(WireError, "bad or truncated int")
    var v: uint64 = 0
    for i in 0 ..< n:
      v = (v shl 8) or uint64(ord(buf[pos + i]))
    inc pos, n
    case b
    of 0xd0: return int64(cast[int8](byte(v and 0xff)))
    of 0xd1: return int64(cast[int16](uint16(v and 0xffff)))
    of 0xd2: return int64(cast[int32](uint32(v and 0xffffffff'u64)))
    of 0xd3: return cast[int64](v)
    else:    return cast[int64](v)

proc mpReadStr(buf: string; pos: var int; limit: int): string =
  ## Read any msgpack str encoding at pos, advancing pos.
  if pos >= limit: raise newException(WireError, "truncated str")
  let b = ord(buf[pos])
  inc pos
  var n = -1
  case b
  of 0xa0..0xbf: n = b and 0x1f
  of 0xd9:
    if pos >= limit: raise newException(WireError, "truncated str header")
    n = ord(buf[pos]); inc pos
  of 0xda:
    if pos + 2 > limit: raise newException(WireError, "truncated str header")
    n = (ord(buf[pos]) shl 8) or ord(buf[pos + 1]); inc pos, 2
  of 0xdb:
    if pos + 4 > limit: raise newException(WireError, "truncated str header")
    n = int64(ord(buf[pos])) shl 24 or (int64(ord(buf[pos + 1])) shl 16) or
        (int64(ord(buf[pos + 2])) shl 8) or int64(ord(buf[pos + 3]))
    inc pos, 4
  else:
    raise newException(WireError, "expected str value")
  if n < 0 or pos + n > limit:
    raise newException(WireError, "str length out of range")
  result = newString(n)
  if n > 0:
    copyMem(addr result[0], unsafeAddr buf[pos], n)
  inc pos, n

proc mpReadArrayHeader(buf: string; pos: var int; limit: int): int =
  ## Read array element count at pos, advancing past the header.
  if pos >= limit: raise newException(WireError, "truncated array")
  let b = ord(buf[pos])
  inc pos
  case b
  of 0x90..0x9f: return b and 0x0f
  of 0xdc:
    if pos + 2 > limit: raise newException(WireError, "truncated array header")
    let n = (ord(buf[pos]) shl 8) or ord(buf[pos + 1])
    inc pos, 2
    return n
  of 0xdd:
    if pos + 4 > limit: raise newException(WireError, "truncated array header")
    let n = (int64(ord(buf[pos])) shl 24) or (int64(ord(buf[pos + 1])) shl 16) or
            (int64(ord(buf[pos + 2])) shl 8) or int64(ord(buf[pos + 3]))
    inc pos, 4
    if n < 0 or n > int64(limit): raise newException(WireError, "array too long")
    return int(n)
  else:
    raise newException(WireError, "expected array value")

proc mpNode(buf: string; pos: var int; limit: int; depth: int): SExpr =
  ## Decode one tagged-AST node `[tag, value]` at pos, advancing pos past
  ## it.  Sequential — never pre-skips, so depth == wire nesting level.
  if depth > MaxDepth:
    raise newException(WireError,
      "wire node nesting deeper than " & $MaxDepth)
  let count = mpReadArrayHeader(buf, pos, limit)
  if count != 2:
    raise newException(WireError,
      "wire node must be [tag, value], got " & $count & " elements")
  let tag = mpReadInt(buf, pos, limit)
  case tag
  of tagInt:
    newInt(mpReadInt(buf, pos, limit))
  of tagFloat:
    if pos >= limit: raise newException(WireError, "truncated float")
    let b = ord(buf[pos])
    inc pos
    case b
    of 0xcb:
      if pos + 8 > limit: raise newException(WireError, "truncated f64")
      var u: uint64 = 0
      for i in 0 ..< 8:                      # msgpack floats are big-endian
        u = (u shl 8) or uint64(ord(buf[pos + i]))
      inc pos, 8
      newFloat(cast[float64](u))
    of 0xca:
      if pos + 4 > limit: raise newException(WireError, "truncated f32")
      var u: uint32 = 0
      for i in 0 ..< 4:
        u = (u shl 8) or uint32(ord(buf[pos + i]))
      inc pos, 4
      newFloat(float64(cast[float32](u)))
    else:
      dec pos
      newFloat(float64(mpReadInt(buf, pos, limit)))  # ints coerce, as in wireToSexpr
  of tagStr:
    newStr(mpReadStr(buf, pos, limit))
  of tagSymbol:
    newSymbol(mpReadStr(buf, pos, limit))
  of tagBool:
    if pos >= limit: raise newException(WireError, "truncated bool")
    let b = ord(buf[pos]); inc pos
    case b
    of 0xc2: newBool(false)
    of 0xc3: newBool(true)
    else: raise newException(WireError, "tag 4 (bool) value must be a bool")
  of tagBytes:
    # encoder emits [5, [b0, b1, ...]] — an ARRAY OF INTS
    let n = mpReadArrayHeader(buf, pos, limit)
    var bs = newSeq[byte](n)
    for i in 0 ..< n:
      let v = mpReadInt(buf, pos, limit)
      if v < 0 or v > 255:
        raise newException(WireError, "bytes array item out of range: " & $v)
      bs[i] = byte(v)
    newBytes(bs)
  of tagVoid:
    if pos >= limit or ord(buf[pos]) != 0xc0:
      raise newException(WireError, "tag 6 (void) value must be nil")
    inc pos
    newVoid()
  of tagList:
    let n = mpReadArrayHeader(buf, pos, limit)
    var items = newSeq[SExpr](n)
    for i in 0 ..< n:
      items[i] = mpNode(buf, pos, limit, depth + 1)
    newList(items)
  else:
    raise newException(WireError, "unknown wire tag: " & $tag)

proc wireFromMsgpackAt*(data: string; start, stop: int): SExpr {.
    raises: [WireError].} =
  ## Decode one tagged node from the slot [start, stop) of raw msgpack.
  var pos = start
  result = mpNode(data, pos, stop, 0)
  if pos != stop:
    raise newException(WireError, "trailing bytes after wire node")

proc wireFromMsgpack*(data: string): SExpr {.raises: [WireError].} =
  ## Decode a whole tagged-AST program body from raw msgpack — the direct
  ## replacement for `toJsonNode(data)` + `wireToSexpr(node)`.
  wireFromMsgpackAt(data, 0, data.len)

proc programFromMsgpack*(data: string): SExpr {.raises: [WireError].} =
  ## Decode the top-level "program" value of a request frame.
  let (found, s, e) = topValue(data, "program")
  if not found:
    raise newException(WireError, "request is missing program")
  wireFromMsgpackAt(data, s, e)
