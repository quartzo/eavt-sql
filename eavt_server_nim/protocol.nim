import std/[json, nativesockets, posix]

type
  RequestKind* = enum
    rkSql, rkAdmin

  Request* = object
    case kind*: RequestKind
    of rkSql:
      sql*: string
      params*: seq[string]
    of rkAdmin:
      command*: string

proc parseRequest*(data: string): Request =
  let node = parseJson(data)
  let t = node["type"].getStr
  case t
  of "sql":
    result = Request(kind: rkSql, sql: node["sql"].getStr)
    if node.hasKey("params"):
      for p in node["params"]:
        result.params.add(p.getStr)
  of "admin":
    result = Request(kind: rkAdmin, command: node["command"].getStr)
  else:
    raise newException(ValueError, "unknown request type: " & t)

proc writeU32(fd: SocketHandle; v: uint32) =
  var buf: array[4, byte]
  buf[0] = byte(v shr 24)
  buf[1] = byte(v shr 16)
  buf[2] = byte(v shr 8)
  buf[3] = byte(v)
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

proc sendAll(fd: SocketHandle; data: pointer; len: int): bool =
  var sent = 0
  var p = cast[ptr UncheckedArray[byte]](data)
  while sent < len:
    let n = posix.write(cint(fd), addr p[sent], len - sent)
    if n <= 0: return false
    sent += n
  return true

proc recvAll(fd: SocketHandle; data: pointer; len: int): bool =
  var got = 0
  var p = cast[ptr UncheckedArray[byte]](data)
  while got < len:
    let n = posix.read(cint(fd), addr p[got], len - got)
    if n <= 0: return false
    got += n
  return true

proc writeMsg*(fd: SocketHandle; data: string) =
  writeU32(fd, uint32(data.len))
  if data.len > 0:
    if not sendAll(fd, addr data[0], data.len):
      raise newException(IOError, "write failed")

proc readMsg*(fd: SocketHandle): string =
  let l = readU32(fd)
  if l <= 0 or l > 100_000_000:
    return ""
  result = newString(l)
  if l > 0:
    if not recvAll(fd, addr result[0], l):
      return ""

proc writeSqlChunk*(fd: SocketHandle; columns: seq[string]; rows: seq[seq[string]];
                     more: bool; error: string = "") =
  var node = newJObject()
  if error.len > 0:
    node["error"] = %error
    node["more"] = %false
  else:
    var colArr = newJArray()
    for c in columns: colArr.add(%c)
    node["columns"] = colArr
    var rowArr = newJArray()
    for row in rows:
      var rArr = newJArray()
      for v in row: rArr.add(%v)
      rowArr.add(rArr)
    node["rows"] = rowArr
    node["more"] = %more
  writeMsg(fd, $node)

proc writeAdminResponse*(fd: SocketHandle; output: string) =
  var node = newJObject()
  node["output"] = %output
  node["more"] = %false
  writeMsg(fd, $node)

proc writeError*(fd: SocketHandle; msg: string) =
  var node = newJObject()
  node["error"] = %msg
  node["more"] = %false
  writeMsg(fd, $node)
