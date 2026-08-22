import std/[json, nativesockets, posix]
import msgpack4nim/msgpack2json
import scheme, wire, msgpack_scan

type
  RequestKind* = enum
    rkScheme, rkSchema, rkAdmin, rkKv
  Request* = object
    id*: string            ## correlation id — echoed in responses (multiplexing)
    case kind*: RequestKind
    of rkScheme:
      program*: SExpr      ## decoded tagged-AST program body
      mode*: string        ## "query" (streaming) | "exec" (batch)
      params*: seq[SExpr]  ## decoded tagged-AST params, 1-indexed via (param N)
    of rkSchema:
      discard
    of rkAdmin:
      command*: string
    of rkKv:
      kvOp*: string       ## "put", "get", "scan"
      kvCf*: int
      kvKey*: seq[byte]
      kvValue*: seq[byte]  ## used for "put"

proc parseRequest*(data: string): Request =
  ## Decode a client frame straight from raw msgpack — the tagged-AST
  ## program never materializes as an intermediate JSON tree.
  if not isMsgpackMap(data):
    raise newException(ValueError, "request must be an object")
  result.id = getTopStr(data, "id")
  let t = getTopStr(data, "type")
  case t
  of "scheme":
    result = Request(kind: rkScheme, id: result.id,
                     program: programFromMsgpack(data),
                     mode: getTopStr(data, "mode"))
    let (pf, ps, pe) = topValue(data, "params")
    if pf:
      for (s, e) in topArrayElems(data, ps, pe):
        result.params.add(wireFromMsgpackAt(data, s, e))
  of "schema":
    result = Request(kind: rkSchema, id: result.id)
  of "admin":
    if not hasTopKey(data, "command"):
      raise newException(ValueError, "request is missing command")
    result = Request(kind: rkAdmin, id: result.id,
                     command: getTopStr(data, "command"))
  of "kv":
    if not hasTopKey(data, "cf"):
      raise newException(ValueError, "request is missing cf")
    result = Request(kind: rkKv, id: result.id, kvOp: getTopStr(data, "op"),
                     kvCf: int(getTopInt(data, "cf")))
    let (kf, ks, ke) = topValue(data, "key")
    if kf: result.kvKey = valueBytesAt(data, ks, ke)
    let (vf, vs, ve) = topValue(data, "value")
    if vf: result.kvValue = valueBytesAt(data, vs, ve)
  else:
    raise newException(ValueError, "unknown request type: " & t)

proc writeU32(fd: SocketHandle; v: uint32) =
  var buf: array[4, byte]
  buf[0] = byte(v shr 24); buf[1] = byte(v shr 16)
  buf[2] = byte(v shr 8); buf[3] = byte(v)
  if posix.write(cint(fd), addr buf, 4) != 4:
    raise newException(IOError, "write failed")

proc readU32(fd: SocketHandle): int =
  var buf: array[4, byte]
  var got = 0
  while got < 4:
    let n = posix.read(cint(fd), addr buf[got], 4 - got)
    if n <= 0: return -1
    got += n
  result = int(buf[0]) shl 24 or int(buf[1]) shl 16 or int(buf[2]) shl 8 or int(buf[3])

proc writeMsg*(fd: SocketHandle; data: string) =
  writeU32(fd, uint32(data.len))
  if data.len > 0:
    var sent = 0
    var p = cast[ptr UncheckedArray[byte]](addr data[0])
    while sent < data.len:
      let n = posix.write(cint(fd), addr p[sent], data.len - sent)
      if n <= 0: raise newException(IOError, "write failed")
      sent += n

proc readMsg*(fd: SocketHandle): string =
  let l = readU32(fd)
  if l <= 0 or l > 100_000_000: return ""
  result = newString(l)
  if l > 0:
    var got = 0
    var p = cast[ptr UncheckedArray[byte]](addr result[0])
    while got < l:
      let n = posix.read(cint(fd), addr p[got], l - got)
      if n <= 0: return ""
      got += n

proc sexprToJson*(e: SExpr): JsonNode =
  case e.kind
  of sVoid: newJNull()
  of sBool: %e.bval
  of sInt: %e.ival
  of sFloat: %e.fval
  of sStr: %e.sval
  of sBytes:
    var arr = newJArray()
    for b in e.bytesval: arr.add(%b)
    arr
  of sSymbol: %e.symval
  of sList:
    var arr = newJArray()
    for item in e.items: arr.add(sexprToJson(item))
    arr
  of sResource: %e.rid

proc writeResponse*(fd: SocketHandle; columns: seq[string]; rows: seq[seq[SExpr]];
                     more: bool; error: string = ""; id: string = "") =
  var node = newJObject()
  if id.len > 0:
    node["id"] = %id
  if error.len > 0:
    node["error"] = %error
    node["more"] = %false
  else:
    var carr = newJArray()
    for c in columns: carr.add(%c)
    node["columns"] = carr
    var rarr = newJArray()
    for row in rows:
      var arr = newJArray()
      for v in row: arr.add(sexprToJson(v))
      rarr.add(arr)
    node["rows"] = rarr
    node["more"] = %more
  writeMsg(fd, msgpack2json.fromJsonNode(node))

proc writeError*(fd: SocketHandle; msg: string; id: string = "") =
  writeResponse(fd, @[], @[], false, msg, id)
