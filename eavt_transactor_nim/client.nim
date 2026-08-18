import std/[nativesockets, posix, json, os, strutils, streams]
import msgpack4nim, msgpack4nim/msgpack2json

type
  ServerDisconnectedError* = object of IOError

  SqlResult* = object
    columns*: seq[string]
    rows*: seq[seq[string]]
    error*: string

  EavtClient* = ref object
    fd*: SocketHandle = SocketHandle(-1)
    sockPath*: string

proc getSocketPath*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-query.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-query.sock"

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

proc sendMsg(c: var EavtClient; data: string) =
  writeU32(c.fd, uint32(data.len))
  if data.len > 0:
    if not sendAll(c.fd, unsafeAddr data[0], data.len):
      c.close()
      raise newException(ServerDisconnectedError, "server disconnected (send)")

proc recvMsg(c: var EavtClient): string =
  let l = readU32(c.fd)
  if l <= 0:
    c.close()
    raise newException(ServerDisconnectedError, "server disconnected (recv)")
  if l > 100_000_000:
    c.close()
    raise newException(ServerDisconnectedError, "server disconnected (oversize frame)")
  result = newString(l)
  if l > 0:
    if not recvAll(c.fd, addr result[0], l):
      c.close()
      raise newException(ServerDisconnectedError, "server disconnected (read body)")

proc sendFrame*(c: var EavtClient; body: string) =
  ## Send a raw msgpack frame body (4-byte length prefix added here).
  sendMsg(c, body)

proc recvFrame*(c: var EavtClient): string =
  ## Receive one raw msgpack frame body. Empty string = connection closed.
  try:
    recvMsg(c)
  except ServerDisconnectedError:
    ""

proc downstreamSocketPath*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-transactor.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-transactor.sock"

proc exec*(c: var EavtClient; sql: string; params: seq[string] = @[]): seq[SqlResult] =
  var node = newJObject()
  node["type"] = %"sql"
  node["sql"] = %sql
  if params.len > 0:
    var pa = newJArray()
    for p in params: pa.add(%p)
    node["params"] = pa
  sendMsg(c, msgpack2json.fromJsonNode(node))
  while true:
    let resp = recvMsg(c)
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
        for v in row:
          if v.kind == JArray:
            var bs: seq[byte]
            for b in v: bs.add(byte(b.getInt()))
            var s = newString(bs.len)
            if bs.len > 0: copyMem(addr s[0], addr bs[0], bs.len)
            r.add(s)
          else:
            r.add($v)
        sr.rows.add(r)
    result.add(sr)
    if not node["more"].getBool: break

proc admin*(c: var EavtClient; command: string): string =
  var node = newJObject()
  node["type"] = %"admin"
  node["command"] = %command
  sendMsg(c, msgpack2json.fromJsonNode(node))
  let resp = recvMsg(c)
  if resp.len == 0: return ""
  try:
    let node = toJsonNode(resp)
    if node.hasKey("output"): return node["output"].getStr
  except: discard
  return ""

proc dump*(c: var EavtClient; index: string = "EAVT"): seq[SqlResult] =
  var node = newJObject()
  node["type"] = %"admin"
  node["command"] = %("dump " & index)
  sendMsg(c, msgpack2json.fromJsonNode(node))
  while true:
    let resp = recvMsg(c)
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
        for v in row:
          if v.kind == JArray:
            var bs: seq[byte]
            for b in v: bs.add(byte(b.getInt()))
            var s = newString(bs.len)
            if bs.len > 0: copyMem(addr s[0], addr bs[0], bs.len)
            r.add(s)
          else:
            r.add($v)
        sr.rows.add(r)
    result.add(sr)
    if not node["more"].getBool: break

proc kvPut*(c: var EavtClient; cf: int; key, value: string): string =
  ## Send a kv put request. key and value are raw byte strings.
  var node = newJObject()
  node["type"] = %"kv"
  node["op"] = %"put"
  node["cf"] = %cf
  node["key"] = %key
  node["value"] = %value
  sendMsg(c, msgpack2json.fromJsonNode(node))
  let resp = recvMsg(c)
  if resp.len == 0: return "ok"
  try:
    let n = toJsonNode(resp)
    if n.hasKey("error") and n["error"].getStr.len > 0:
      return "error: " & n["error"].getStr
  except: discard
  return "ok"

proc kvGet*(c: var EavtClient; cf: int; key: string): string =
  ## Send a kv get request. Returns the value as a raw string, or "(none)".
  var node = newJObject()
  node["type"] = %"kv"
  node["op"] = %"get"
  node["cf"] = %cf
  node["key"] = %key
  sendMsg(c, msgpack2json.fromJsonNode(node))
  let resp = recvMsg(c)
  if resp.len == 0: return "(none)"
  try:
    let n = toJsonNode(resp)
    if n.hasKey("error") and n["error"].getStr.len > 0:
      return "error: " & n["error"].getStr
    if n.hasKey("rows") and n["rows"].len > 0:
      let row = n["rows"][0]
      if row.len > 0:
        # If it's a JSON array of ints (bytes), decode to string
        if row[0].kind == JArray:
          var bs: seq[byte]
          for v in row[0]:
            bs.add(byte(v.getInt()))
          var s = newString(bs.len)
          if bs.len > 0: copyMem(addr s[0], addr bs[0], bs.len)
          return s
        return $row[0]
  except: discard
  return "(none)"

proc kvDelete*(c: var EavtClient; cf: int; key: string): string =
  ## Send a kv delete request.
  var node = newJObject()
  node["type"] = %"kv"
  node["op"] = %"delete"
  node["cf"] = %cf
  node["key"] = %key
  sendMsg(c, msgpack2json.fromJsonNode(node))
  let resp = recvMsg(c)
  if resp.len == 0: return "ok"
  try:
    let n = toJsonNode(resp)
    if n.hasKey("error") and n["error"].getStr.len > 0:
      return "error: " & n["error"].getStr
  except: discard
  return "ok"

proc kvScan*(c: var EavtClient; cf: int): seq[SqlResult] =
  ## Send a kv scan request. Returns streaming results like exec().
  var node = newJObject()
  node["type"] = %"kv"
  node["op"] = %"scan"
  node["cf"] = %cf
  sendMsg(c, msgpack2json.fromJsonNode(node))
  while true:
    let resp = recvMsg(c)
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
        for v in row:
          if v.kind == JArray:
            var bs: seq[byte]
            for b in v: bs.add(byte(b.getInt()))
            var s = newString(bs.len)
            if bs.len > 0: copyMem(addr s[0], addr bs[0], bs.len)
            r.add(s)
          else:
            r.add($v)
        sr.rows.add(r)
    result.add(sr)
    if not node["more"].getBool: break
