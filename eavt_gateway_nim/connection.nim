## connection.nim — Gateway per-connection handling.
##
## One upstream client thread owns one dedicated downstream connection to the
## data server (streaming responses never share a connection — interleaved
## frames would corrupt the protocol).
##
## Dispatch:
##   sql    → compile locally (nim_sql_frontend), forward as tagged-AST scheme
##   scheme → forward raw frame verbatim
##   schema → serve from TTL cache (or fetch)
##   admin/kv → forward raw frame verbatim
##
## Response frames from the data server are relayed verbatim until more=false.

import std/[json, nativesockets, posix, strutils, options]
import msgpack4nim/msgpack2json
import scheme, wire
import stats
import eavt_server_nim/client
import eavt_server_nim/protocol
import shared
import frontend
import explain
import parser as sql_parser

proc jsonParamToSexpr(p: JsonNode): SExpr =
  case p.kind
  of JInt: newInt(p.getInt)
  of JFloat: newFloat(p.getFloat)
  of JString: newStr(p.getStr)
  of JBool: newBool(p.getBool)
  of JNull: newVoid()
  of JArray:
    var allInts = p.len > 0
    for v in p:
      if v.kind != JInt: allInts = false; break
    if allInts:
      var bs: seq[byte]
      for v in p:
        let i = v.getInt
        if i < 0 or i > 255:
          raise newException(ValueError, "param byte out of range: " & $i)
        bs.add(byte(i))
      newBytes(bs)
    else:
      raise newException(ValueError, "unsupported param type: array")
  of JObject:
    raise newException(ValueError, "unsupported param type: object")

proc ensureDownstream(gw: ptr SharedGateway; ds: var EavtClient) =
  if ds.fd == osInvalidSocket:
    if not ds.connect(gw.downstreamPath):
      raise newException(IOError, "cannot connect to data server at " & gw.downstreamPath)

proc relayFrames(ds: var EavtClient; fd: SocketHandle) =
  while true:
    let body = ds.recvFrame()
    if body.len == 0:
      raise newException(IOError, "data server closed connection mid-stream")
    let resp = toJsonNode(body)
    writeMsg(fd, body)
    if not resp.getOrDefault("more").getBool(false):
      break

proc forwardRaw(ds: var EavtClient; raw: string; fd: SocketHandle) =
  ds.sendFrame(raw)
  relayFrames(ds, fd)

proc handleSql(gw: ptr SharedGateway; ds: var EavtClient; node: JsonNode; fd: SocketHandle) =
  let sqlText = node["sql"].getStr
  var params: seq[SExpr] = @[]
  if node.hasKey("params"):
    for p in node["params"]:
      params.add(jsonParamToSexpr(p))

  var snapshot = getSnapshot(gw, ds)
  var compiled: CompileResult = nil
  var lastErr: ref CatchableError = nil
  for attempt in 0..1:
    let stmt = sql_parser.parse(sqlText)
    try:
      compiled = compileSql(stmt, snapshot)
      break
    except CatchableError as e:
      lastErr = e
      # A stale snapshot can only miss recently-declared attributes —
      # refetch once and recompile before giving up.
      if "attribute resolution failed" in e.msg and attempt == 0:
        snapshot = refreshSnapshot(gw, ds)
      else:
        raise
  if compiled == nil:
    raise lastErr

  if compiled.isExplain:
    writeResponse(fd, @[], @[@[SExpr(kind: sStr, sval: renderExplain(compiled))]], false)
    return

  let mode = if compiled.isSelect: "query" else: "exec"
  var req = newJObject()
  req["type"] = %"scheme"
  req["program"] = sexprToWire(compiled.program.body)
  req["mode"] = %mode
  if params.len > 0:
    var pa = newJArray()
    for p in params: pa.add(sexprToWire(p))
    req["params"] = pa
  ds.sendFrame(msgpack2json.fromJsonNode(req))
  relayFrames(ds, fd)

proc handleSchema(gw: ptr SharedGateway; ds: var EavtClient; fd: SocketHandle) =
  let snap = getSnapshot(gw, ds)
  var node = newJObject()
  node["schema"] = statsToJson(snap)
  node["more"] = %false
  writeMsg(fd, msgpack2json.fromJsonNode(node))

proc handleGatewayConnection*(gw: ptr SharedGateway; fd: SocketHandle) {.gcsafe.} =
  var ds = EavtClient()
  defer: ds.close()
  while true:
    let raw = readMsg(fd)
    if raw.len == 0: break
    var node: JsonNode
    try:
      node = toJsonNode(raw)
      if node.kind != JObject or not node.hasKey("type"):
        raise newException(ValueError, "request must be an object with a type")
    except CatchableError as e:
      writeError(fd, "parse error: " & e.msg)
      continue
    let t = node["type"].getStr
    try:
      ensureDownstream(gw, ds)
      case t
      of "sql":
        handleSql(gw, ds, node, fd)
      of "schema":
        handleSchema(gw, ds, fd)
      of "scheme", "admin", "kv":
        forwardRaw(ds, raw, fd)
      else:
        writeError(fd, "unknown request type: " & t)
    except CatchableError as e:
      writeError(fd, e.msg)
