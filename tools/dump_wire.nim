## dump_wire.nim — compile a Datalog EDN query and emit the wire-AST
## program on stdout (msgpack, writeSExprWire); :find vars on stderr.
## Fetches the CompileStats snapshot from the query server's internal
## socket ({"type":"schema"}) — the same snapshot the front will cache.
## Fase-1 smoke tool and Fase-2 golden-test seed (Nim vs OCaml compiler).
import std/[os, strutils, streams, posix]
import scheme, wire, msgpack_scan
import stats
import datalog_compile
import msgpack4nim

proc readMsg(fd: SocketHandle): string =
  var hdr: array[4, char]
  var got = 0
  while got < 4:
    let n = recv(fd, addr hdr[got], 4 - got, 0)
    if n <= 0: raise newException(IOError, "closed (hdr)")
    got += n
  let ln = (int(hdr[0].ord) shl 24) or (int(hdr[1].ord) shl 16) or
           (int(hdr[2].ord) shl 8) or int(hdr[3].ord)
  result = newString(ln)
  got = 0
  while got < ln:
    let n = recv(fd, addr result[got], ln - got, 0)
    if n <= 0: raise newException(IOError, "closed (body)")
    got += n

proc writeMsg(fd: SocketHandle; data: string) =
  var buf = newString(4 + data.len)
  buf[0] = chr((data.len shr 24) and 0xff)
  buf[1] = chr((data.len shr 16) and 0xff)
  buf[2] = chr((data.len shr 8) and 0xff)
  buf[3] = chr(data.len and 0xff)
  buf[4 .. ^1] = data
  var sent = 0
  while sent < buf.len:
    let n = send(fd, addr buf[sent], buf.len - sent, 0)
    if n <= 0: raise newException(IOError, "send failed")
    sent += n

proc fetchStats(sockPath: string): CompileStats =
  let fd = posix.socket(cint(posix.AF_UNIX), cint(posix.SOCK_STREAM), cint(0))
  if int(fd) < 0: raise newException(IOError, "socket failed")
  var addr_un: Sockaddr_un
  addr_un.sun_family = TSaFamily(AF_UNIX)
  copyMem(addr addr_un.sun_path, unsafeAddr sockPath[0], min(sockPath.len, 108))
  if connect(fd, cast[ptr SockAddr](addr addr_un), sizeof(Sockaddr_un).SockLen) < 0:
    raise newException(IOError, "connect failed: " & sockPath)
  var ms = MsgStream.init(64)
  ms.pack_map(2)
  ms.pack("type"); ms.pack("schema")
  writeMsg(fd, ms.data)
  let resp = readMsg(fd)
  discard close(fd)
  # the stats map is nested under the "schema" key of the response frame
  let (sf, ss, se) = topValue(resp, "schema")
  if not sf: raise newException(IOError, "schema response missing stats")
  statsFromMsgpack(resp[ss ..< se])

let query = stdin.readAll()
let snap = fetchStats(paramStr(1))
var fv: seq[string] = @[]
let compiled = compileDatalogQuery(query, snap, fv)
if paramCount() >= 2:
  writeFile(paramStr(2), statsToMsgpack(snap))
var ms = MsgStream.init(256)
writeSExprWire(ms, compiled.program.body)
stdout.write(ms.data)
stderr.writeLine fv.join("\t")
