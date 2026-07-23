import std/[nativesockets, posix, json, os, strutils, streams]
import msgpack4nim, msgpack4nim/msgpack2json

type
  SqlResult* = object
    columns*: seq[string]
    rows*: seq[seq[string]]
    error*: string

  EavtClient* = ref object
    fd*: SocketHandle
    sockPath*: string

proc getSocketPath*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt.sock"

proc connect*(c: var EavtClient; sockPath: string = getSocketPath()): bool =
  c = EavtClient(sockPath: sockPath)
  c.fd = nativesockets.createNativeSocket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  if c.fd == osInvalidSocket: return false
  var addr_un: Sockaddr_un
  addr_un.sun_family = TSaFamily(posix.AF_UNIX)
  copyMem(addr addr_un.sun_path, unsafeAddr c.sockPath[0], min(c.sockPath.len, 108))
  let r = posix.connect(c.fd, cast[ptr SockAddr](addr addr_un), sizeof(Sockaddr_un).SockLen)
  return r >= 0

proc close*(c: EavtClient) =
  if c.fd != osInvalidSocket:
    discard posix.close(cint(c.fd))
    c.fd = osInvalidSocket

proc writeU32(fd: SocketHandle; v: uint32) =
  var buf: array[4, byte]
  buf[0] = byte(v shr 24); buf[1] = byte(v shr 16)
  buf[2] = byte(v shr 8); buf[3] = byte(v)
  discard posix.write(cint(fd), addr buf, 4)

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

proc sendMsg(fd: SocketHandle; data: string) =
  writeU32(fd, uint32(data.len))
  if data.len > 0:
    if not sendAll(fd, unsafeAddr data[0], data.len):
      raise newException(IOError, "send failed")

proc recvMsg(fd: SocketHandle): string =
  let l = readU32(fd)
  if l <= 0 or l > 100_000_000: return ""
  result = newString(l)
  if l > 0:
    if not recvAll(fd, addr result[0], l): return ""

proc exec*(c: EavtClient; sql: string; params: seq[string] = @[]): seq[SqlResult] =
  var node = newJObject()
  node["type"] = %"sql"
  node["sql"] = %sql
  if params.len > 0:
    var pa = newJArray()
    for p in params: pa.add(%p)
    node["params"] = pa
  sendMsg(c.fd, msgpack2json.fromJsonNode(node))
  while true:
    let resp = recvMsg(c.fd)
    if resp.len == 0: break
    let node = toJsonNode(resp)
    if node.hasKey("error") and node["error"].getStr.len > 0:
      result.add(SqlResult(error: node["error"].getStr))
      break
    var sr = SqlResult()
    if node.hasKey("columns"):
      for col in node["columns"]: sr.columns.add(col.getStr)
    if node.hasKey("rows"):
      for row in node["rows"]:
        var r: seq[string]
        for v in row: r.add($v)
        sr.rows.add(r)
    result.add(sr)
    if not node["more"].getBool: break

proc admin*(c: EavtClient; command: string): string =
  var node = newJObject()
  node["type"] = %"admin"
  node["command"] = %command
  sendMsg(c.fd, msgpack2json.fromJsonNode(node))
  let resp = recvMsg(c.fd)
  if resp.len == 0: return ""
  var output: string
  unpack(resp, output)
  try:
    let node = toJsonNode(resp)
    if node.hasKey("output"): return node["output"].getStr
  except: discard
  return output
