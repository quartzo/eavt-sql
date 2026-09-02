import std/[nativesockets, posix, streams]
import msgpack4nim
import scheme, symtab, wire, msgpack_scan

type
  RequestKind* = enum
    rkScheme, rkTx, rkSchema, rkAdmin, rkKv
  Request* = object
    id*: string            ## correlation id — echoed in responses (multiplexing)
    case kind*: RequestKind
    of rkScheme:
      program*: SExpr      ## decoded wire-AST program body
      mode*: string        ## "query" (streaming) | "exec" (batch)
      params*: seq[SExpr]  ## decoded wire-AST params, 1-indexed via (param N)
    of rkTx:
      txdata*: seq[TxWOp]  ## flat op vectors, decoded with no SExpr tree
                           ## (docs/tx-protocol.md §3.1)
    of rkSchema:
      discard
    of rkAdmin:
      command*: string
    of rkKv:
      kvOp*: string       ## "put", "get", "scan"
      kvCf*: int
      kvKey*: seq[byte]
      kvValue*: seq[byte]  ## used for "put"

proc parseRequest*(data: string; tab: SymTab): Request =
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
  of "tx":
    result = Request(kind: rkTx, id: result.id,
                     txdata: txopsFromMsgpack(data, tab))
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

proc writeResponse*(fd: SocketHandle; columns: seq[string]; rows: seq[seq[SExpr]];
                     more: bool; error: string = ""; id: string = "") =
  var ms = MsgStream.init(256)
  var fieldCount = 1  # "more" is always present
  if id.len > 0: inc fieldCount
  if error.len > 0:
    inc fieldCount  # "error"
  else:
    fieldCount += 2  # "columns" + "rows"
  ms.pack_map(fieldCount)
  if id.len > 0:
    ms.pack("id"); ms.pack(id)
  if error.len > 0:
    ms.pack("error"); ms.pack(error)
    ms.pack("more"); ms.pack(false)
  else:
    ms.pack("columns")
    ms.pack_array(columns.len)
    for c in columns: ms.pack(c)
    ms.pack("rows")
    ms.pack_array(rows.len)
    for row in rows:
      ms.pack_array(row.len)
      for v in row:
        writeSExprPlain(ms, v)
    ms.pack("more"); ms.pack(more)
  writeMsg(fd, ms.data)

proc writeError*(fd: SocketHandle; msg: string; id: string = "") =
  writeResponse(fd, @[], @[], false, msg, id)
