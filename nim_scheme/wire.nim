## wire.nim — EDN-like transport encoding for SExpr over msgpack.
##
## A program node travels as a native msgpack value — no tag wrapper.
## The distinctions plain msgpack cannot express are carried by an
## application-defined ext type for symbols:
##
##   int    → msgpack int          str    → msgpack str
##   float  → msgpack float        bool   → msgpack bool
##   bytes  → msgpack bin          void   → msgpack nil
##   list   → msgpack array        symbol → ext 0x05 (payload = name)
##
## This replaces the legacy `[tag, value]` array encoding (see
## docs/scheme-transport.md §3.3).  The distinction symbol × string is
## preserved via the ext type; every other kind maps onto a native
## msgpack type, which is why `skipValue` (msgpack_scan.nim) can hop
## over program values without decoding them.
##
## Decode is fail-loud: unknown ext types, maps inside a program,
## truncated input and over-deep nesting raise WireError.

import std/[strutils, streams]
import msgpack4nim
import scheme, symtab, msgpack_scan

type
  WireError* = object of CatchableError

const
  extSymbol* = 0x05'i8  ## application ext type carrying a symbol name
  extKeyword* = 0x06'i8 ## application ext type carrying a keyword name
                        ## (EDN :ns/name; canonical storage form strips
                        ## the leading colon — docs/tx-protocol.md §8)

proc appendRaw*(s: MsgStream; bytes: string) {.inline.} =
  ## Append pre-encoded msgpack bytes to a MsgStream.  CRITICAL: plain
  ## `s.data.add(bytes)` does NOT advance the stream position — the next
  ## `pack` would overwrite the appended bytes (StringStream writes at
  ## `pos` via copyMem, not at data.len).
  if bytes.len > 0:
    s.data.add(bytes)
    s.setPosition(s.data.len)

proc writeSExprWire*(s: MsgStream; e: SExpr) =
  ## Write one SExpr as a native msgpack value (symbol → ext 0x05)
  ## directly into an existing MsgStream.
  case e.kind
  of sInt:
    s.pack(e.ival)
  of sFloat:
    s.pack(e.fval)
  of sStr:
    s.pack(e.sval)
  of sSymbol:
    s.pack_ext(e.symval.len, extSymbol)
    if e.symval.len > 0:
      appendRaw(s, e.symval)
  of sKeyword:
    s.pack_ext(e.kwval.len, extKeyword)
    if e.kwval.len > 0:
      appendRaw(s, e.kwval)
  of sBool:
    s.pack(e.bval)
  of sBytes:
    s.pack_bin(e.bytesval.len)
    if e.bytesval.len > 0:
      var tmp = newString(e.bytesval.len)
      copyMem(addr tmp[0], unsafeAddr e.bytesval[0], e.bytesval.len)
      appendRaw(s, tmp)
  of sVoid:
    s.pack_imp_nil()
  of sList:
    s.pack_array(e.items.len)
    for item in e.items: writeSExprWire(s, item)
  of sResource:
    raise newException(WireError, "cannot encode sResource on the wire")

proc sexprToMsgpack*(e: SExpr): string =
  ## Encode one SExpr as a native msgpack value.
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
    of sKeyword: s.pack(e.kwval)
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
  of sKeyword: s.pack(e.kwval)
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

# ── Direct msgpack decode (no intermediate tree) ────────────────────────────

proc mpReadInt*(buf: string; pos: var int; limit: int): int64 =
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

proc mpReadFloat(buf: string; pos: var int; limit: int): float64 =
  ## Read msgpack float (f64 0xcb or f32 0xca) at pos, advancing pos.
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
    return cast[float64](u)
  of 0xca:
    if pos + 4 > limit: raise newException(WireError, "truncated f32")
    var u: uint32 = 0
    for i in 0 ..< 4:
      u = (u shl 8) or uint32(ord(buf[pos + i]))
    inc pos, 4
    return float64(cast[float32](u))
  else:
    raise newException(WireError, "expected float value")

proc mpReadBin(buf: string; pos: var int; limit: int): seq[byte] =
  ## Read msgpack bin at pos, advancing pos.
  if pos >= limit: raise newException(WireError, "truncated bin")
  let b = ord(buf[pos])
  inc pos
  var n = -1
  case b
  of 0xc4:
    if pos >= limit: raise newException(WireError, "truncated bin header")
    n = ord(buf[pos]); inc pos
  of 0xc5:
    if pos + 2 > limit: raise newException(WireError, "truncated bin header")
    n = (ord(buf[pos]) shl 8) or ord(buf[pos + 1]); inc pos, 2
  of 0xc6:
    if pos + 4 > limit: raise newException(WireError, "truncated bin header")
    n = (int64(ord(buf[pos])) shl 24) or (int64(ord(buf[pos + 1])) shl 16) or
        (int64(ord(buf[pos + 2])) shl 8) or int64(ord(buf[pos + 3]))
    inc pos, 4
  else:
    raise newException(WireError, "expected bin value")
  if n < 0 or pos + n > limit:
    raise newException(WireError, "bin length out of range")
  result = newSeq[byte](n)
  if n > 0:
    copyMem(addr result[0], unsafeAddr buf[pos], n)
  inc pos, n

proc mpReadExt(buf: string; pos: var int; limit: int): (int8, string) =
  ## Read msgpack ext at pos, advancing pos.  Returns (type, payload).
  if pos >= limit: raise newException(WireError, "truncated ext")
  let b = ord(buf[pos])
  var n = -1          # payload length
  var hdrLen = 1      # bytes between the initial byte and the payload start
  case b
  of 0xd4: n = 1; hdrLen = 2   # byte0 + type byte; payload starts at pos+2
  of 0xd5: n = 2; hdrLen = 2
  of 0xd6: n = 4; hdrLen = 2
  of 0xd7: n = 8; hdrLen = 2
  of 0xd8: n = 16; hdrLen = 2
  of 0xc7:
    if pos + 2 > limit: raise newException(WireError, "truncated ext header")
    n = ord(buf[pos + 1]); hdrLen = 3
  of 0xc8:
    if pos + 3 > limit: raise newException(WireError, "truncated ext header")
    n = (ord(buf[pos + 1]) shl 8) or ord(buf[pos + 2]); hdrLen = 4
  of 0xc9:
    if pos + 5 > limit: raise newException(WireError, "truncated ext header")
    n = (int64(ord(buf[pos + 1])) shl 24) or (int64(ord(buf[pos + 2])) shl 16) or
        (int64(ord(buf[pos + 3])) shl 8) or int64(ord(buf[pos + 4]))
    hdrLen = 6
  else:
    raise newException(WireError, "expected ext value")
  if n < 0 or pos + hdrLen + n > limit:
    raise newException(WireError, "ext length out of range")
  let exttype = cast[int8](byte(ord(buf[pos + hdrLen - 1])))
  result = (exttype, buf[pos + hdrLen ..< pos + hdrLen + n])
  inc pos, hdrLen + n

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
  ## Decode one wire node at pos, advancing pos past it.  The node is a
  ## native msgpack value; symbol is ext 0x05.  Sequential — never
  ## pre-skips, so depth == wire nesting level.
  if depth > MaxDepth:
    raise newException(WireError,
      "wire node nesting deeper than " & $MaxDepth)
  if pos >= limit: raise newException(WireError, "truncated value")
  let b = ord(buf[pos])
  case b
  of 0x00..0x7f, 0xe0..0xff, 0xcc..0xcf, 0xd0..0xd3:
    newInt(mpReadInt(buf, pos, limit))
  of 0xca, 0xcb:
    newFloat(mpReadFloat(buf, pos, limit))
  of 0xa0..0xbf, 0xd9..0xdb:
    newStr(mpReadStr(buf, pos, limit))
  of 0xc0:
    inc pos
    newVoid()
  of 0xc2, 0xc3:
    inc pos
    newBool(b == 0xc3)
  of 0xc4, 0xc5, 0xc6:
    newBytes(mpReadBin(buf, pos, limit))
  of 0x90..0x9f, 0xdc, 0xdd:
    let n = mpReadArrayHeader(buf, pos, limit)
    var items = newSeq[SExpr](n)
    for i in 0 ..< n:
      items[i] = mpNode(buf, pos, limit, depth + 1)
    newList(items)
  of 0x80..0x8f, 0xde, 0xdf:
    raise newException(WireError,
      "maps are not allowed inside a wire program")
  of 0xd4..0xd8, 0xc7, 0xc8, 0xc9:
    let (exttype, payload) = mpReadExt(buf, pos, limit)
    if exttype == extSymbol:
      newSymbol(payload)
    elif exttype == extKeyword:
      newKeyword(payload)
    else:
      raise newException(WireError,
        "unknown ext type 0x" & toHex(int(exttype) and 0xff, 2) &
        " in wire program")
  else:
    raise newException(WireError,
      "unexpected msgpack byte 0x" & toHex(b, 2) & " in wire program")

proc wireFromMsgpackAt*(data: string; start, stop: int): SExpr {.
    raises: [WireError].} =
  ## Decode one wire node from the slot [start, stop) of raw msgpack.
  var pos = start
  result = mpNode(data, pos, stop, 0)
  if pos != stop:
    raise newException(WireError, "trailing bytes after wire node")

proc wireFromMsgpack*(data: string): SExpr {.raises: [WireError].} =
  ## Decode a whole program body from raw msgpack.
  wireFromMsgpackAt(data, 0, data.len)

proc programFromMsgpack*(data: string): SExpr {.raises: [WireError].} =
  ## Decode the top-level "program" value of a request frame.
  let (found, s, e) = topValue(data, "program")
  if not found:
    raise newException(WireError, "request is missing program")
  wireFromMsgpackAt(data, s, e)

proc txdataFromMsgpack*(data: string): seq[SExpr] {.raises: [WireError].} =
  ## Decode the top-level "txdata" value of a `tx` request frame — an array
  ## of EDN op vectors (docs/tx-protocol.md §3.1).  Each element slot comes
  ## from topArrayElems (exact element bounds), so each op decodes with
  ## wireFromMsgpackAt's strict "consume exactly the slot" check.
  let (found, s, e) = topValue(data, "txdata")
  if not found:
    raise newException(WireError, "tx request is missing txdata")
  for (sOp, eOp) in topArrayElems(data, s, e):
    result.add(wireFromMsgpackAt(data, sOp, eOp))
# ── Direct flat tx decode (bytes → TxWOp, no SExpr tree) ────────────────────

proc txSlotFromMsgpack(buf: string; pos: var int; limit: int;
                       tab: SymTab): TxWSlot {.
    raises: [WireError].} =
  ## Decode one tx-op slot directly into a flat TxWSlot.  Same accepted
  ## encodings as mpNode; lookup refs (2-element arrays, keyword first)
  ## become tskLookupRef without building an SExpr list.  Keywords are
  ## interned into `tab` at capture.
  if pos >= limit: raise newException(WireError, "truncated tx slot")
  let b = ord(buf[pos])
  case b
  of 0x00..0x7f, 0xe0..0xff, 0xcc..0xcf, 0xd0..0xd3:
    result = TxWSlot(kind: tskInt, i: mpReadInt(buf, pos, limit))
  of 0xca, 0xcb:
    result = TxWSlot(kind: tskFloat, f: mpReadFloat(buf, pos, limit))
  of 0xa0..0xbf, 0xd9..0xdb:
    result = TxWSlot(kind: tskStr, s: mpReadStr(buf, pos, limit))
  of 0xc0:
    inc pos
    result = TxWSlot(kind: tskMissing)
  of 0xc2, 0xc3:
    result = TxWSlot(kind: tskBool, b: b == 0xc3)
    inc pos
  of 0xc4, 0xc5, 0xc6:
    result = TxWSlot(kind: tskBytes, bin: mpReadBin(buf, pos, limit))
  of 0xd4..0xd8, 0xc7, 0xc8, 0xc9:
    let (exttype, payload) = mpReadExt(buf, pos, limit)
    if exttype == extKeyword:
      # interned at capture: identity is a uint32 from here on
      result = TxWSlot(kind: tskKw, sym: uint32(tab.internSym(payload)))
    elif exttype == extSymbol:
      # env-variable symbols in the tx path (rare) — keep readable
      result = TxWSlot(kind: tskStr, s: payload)
    else:
      raise newException(WireError,
        "unknown ext type 0x" & toHex(int(exttype) and 0xff, 2) & " in tx op")
  of 0x90..0x9f, 0xdc, 0xdd:
    let n = mpReadArrayHeader(buf, pos, limit)
    if n != 2:
      raise newException(WireError,
        "tx lookup ref must be a 2-element array")
    let attrSlot = txSlotFromMsgpack(buf, pos, limit, tab)
    if attrSlot.kind != tskKw:
      raise newException(WireError,
        "tx lookup ref attr must be a keyword")
    let vSlot = txSlotFromMsgpack(buf, pos, limit, tab)
    new(result.refVal)
    result.refVal[] = vSlot
    result.kind = tskLookupRef
    result.sym = attrSlot.sym
  else:
    raise newException(WireError,
      "unexpected msgpack byte 0x" & toHex(b, 2) & " in tx op")

proc txOpFromMsgpack(buf: string; pos: var int; limit: int;
                     tab: SymTab): TxWOp {.raises: [WireError].} =
  ## One op vector: [op-kw, e, attr-kw, v] — flat, no SExpr.
  if pos >= limit: raise newException(WireError, "truncated tx op")
  let n = mpReadArrayHeader(buf, pos, limit)
  if n != 4:
    raise newException(WireError,
      "tx op must be a 4-element vector (got " & $n & ")")
  let opHead = txSlotFromMsgpack(buf, pos, limit, tab)
  if opHead.kind != tskKw:
    raise newException(WireError, "tx op must start with a keyword")
  if opHead.sym == uint32(tab.dbAdd):
    result.isRetract = false
  elif opHead.sym == uint32(tab.dbRetract):
    result.isRetract = true
  else:
    raise newException(WireError,
      "tx: unknown op keyword: :" & tab.symName(SymId(opHead.sym)))
  result.e = txSlotFromMsgpack(buf, pos, limit, tab)
  let attrSlot = txSlotFromMsgpack(buf, pos, limit, tab)
  if attrSlot.kind == tskKw:
    result.attrSym = attrSlot.sym
  else:
    result.attrSym = 0          # interpreter raises "expected keyword"
  result.v = txSlotFromMsgpack(buf, pos, limit, tab)

proc txopsFromMsgpack*(data: string; tab: SymTab): seq[TxWOp] {.
    raises: [WireError].} =
  ## Decode the top-level "txdata" array of a `tx` request directly into
  ## flat TxWOp records — no intermediate SExpr tree (one seq + value
  ## strings; per-op cost is O(bytes), no heap objects beyond payloads).
  ## Keywords interned into `tab` at capture.
  let (found, s, e) = topValue(data, "txdata")
  if not found:
    raise newException(WireError, "tx request is missing txdata")
  for (sOp, eOp) in topArrayElems(data, s, e):
    var pos = sOp
    result.add(txOpFromMsgpack(data, pos, eOp, tab))
    if pos != eOp:
      raise newException(WireError, "trailing bytes in tx op")
