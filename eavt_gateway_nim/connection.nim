## connection.nim — Gateway per-connection handling (chronos, single-thread).
##
## One client callback owns one dedicated downstream connection to the data
## server (streaming responses never share a connection — interleaved frames
## would corrupt the protocol).
##
## Dispatch:
##   sql    → compile locally (nim_sql_frontend), forward as tagged-AST scheme
##   scheme → forward raw frame verbatim
##   schema → serve from TTL cache (or fetch)
##   admin/kv → forward raw frame verbatim
##
## Response frames from the data server are relayed verbatim until more=false.

import std/[json, strutils, options]
import chronos
import msgpack4nim/msgpack2json
import scheme, wire
import stats
import eavt_server_nim/protocol except readMsg, writeMsg
import shared
import downstream
import frontend
import explain
import ast as sql_ast
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

proc writeErrorAsync(transp: StreamTransport; msg: string) {.async.} =
  var node = newJObject()
  node["error"] = %msg
  node["more"] = %false
  let body = msgpack2json.fromJsonNode(node)
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  copyMem(addr buf[4], addr body[0], body.len)
  discard await transp.write(buf)

proc writeFrameAsync(transp: StreamTransport; body: string) {.async.} =
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await transp.write(buf)

proc relayFrames(ds: DownstreamConn; transp: StreamTransport) {.async.} =
  while true:
    let body = await ds.readFrame()
    if body.len == 0:
      raise newException(IOError, "data server closed connection mid-stream")
    await transp.writeFrameAsync(body)
    let resp = toJsonNode(body)
    if not resp.getOrDefault("more").getBool(false):
      break

proc forwardRaw(ds: DownstreamConn; raw: string; transp: StreamTransport) {.async.} =
  await ds.sendFrame(raw)
  await relayFrames(ds, transp)

proc parseSqlText(text: string): sql_ast.SqlStmt =
  try:
    sql_parser.parse(text)
  except Exception as e:
    var err = newException(ValueError, "SQL parse error: " & e.msg)
    raise err

proc handleSql(gw: GatewayState; ds: DownstreamConn; node: JsonNode;
               transp: StreamTransport) {.async.} =
  let sqlText = node["sql"].getStr
  var params: seq[SExpr] = @[]
  if node.hasKey("params"):
    for p in node["params"]:
      params.add(jsonParamToSexpr(p))

  var snapshot = await getSnapshot(gw, ds)
  var compiled: CompileResult = nil
  var lastErr: ref CatchableError = nil
  for attempt in 0..1:
    try:
      let stmt = parseSqlText(sqlText)
      try:
        compiled = compileSql(stmt, snapshot)
        break
      except CatchableError as e:
        lastErr = e
        # A stale snapshot can only miss recently-declared attributes —
        # refetch once and recompile before giving up.
        if "attribute resolution failed" in e.msg and attempt == 0:
          snapshot = await refreshSnapshot(gw, ds)
        else:
          raise
    except CatchableError as e:
      raise newException(ValueError, e.msg)
  if compiled == nil:
    raise lastErr

  if compiled.isExplain:
    var rnode = newJObject()
    rnode["columns"] = %newJArray()
    var rows = newJArray()
    rows.add(%[@[renderExplain(compiled)]])
    rnode["rows"] = rows
    rnode["more"] = %false
    await transp.writeFrameAsync(msgpack2json.fromJsonNode(rnode))
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
  await ds.sendJson(req)
  await relayFrames(ds, transp)

proc handleSchema(gw: GatewayState; ds: DownstreamConn;
                  transp: StreamTransport) {.async.} =
  let snap = await getSnapshot(gw, ds)
  var node = newJObject()
  node["schema"] = statsToJson(snap)
  node["more"] = %false
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc serveGatewayConnection*(gw: GatewayState; transp: StreamTransport) {.
    async: (raises: []).} =
  var ds: DownstreamConn = nil
  try:
    while true:
      var hdr: array[4, byte]
      await transp.readExactly(addr hdr[0], 4)
      let len = int(hdr[0]) shl 24 or int(hdr[1]) shl 16 or
                int(hdr[2]) shl 8 or int(hdr[3])
      if len <= 0 or len > 100_000_000:
        break
      let raw = newString(len)
      if len > 0:
        await transp.readExactly(addr raw[0], len)

      var node: JsonNode
      try:
        node = toJsonNode(raw)
        if node.kind != JObject or not node.hasKey("type"):
          raise newException(ValueError, "request must be an object with a type")
      except CatchableError as e:
        await transp.writeErrorAsync("parse error: " & e.msg)
        continue

      if ds == nil:
        try:
          ds = await connectDownstream(gw.downstreamPath)
        except CatchableError:
          await transp.writeErrorAsync(
            "cannot connect to data server at " & gw.downstreamPath)
          break

      let t = node["type"].getStr
      try:
        case t
        of "sql":
          await handleSql(gw, ds, node, transp)
        of "schema":
          await handleSchema(gw, ds, transp)
        of "scheme", "admin", "kv":
          await forwardRaw(ds, raw, transp)
        else:
          await transp.writeErrorAsync("unknown request type: " & t)
      except CatchableError as e:
        await transp.writeErrorAsync(e.msg)
  except CatchableError:
    discard  # client disconnected mid-frame
  finally:
    if ds != nil:
      await ds.close()
