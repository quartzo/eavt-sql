## connection.nim — Gateway per-connection handling (chronos, single-thread).
##
## All clients share a single multiplexed connection to the data server
## (MultiplexedConn in downstream.nim).  Requests carry a correlation id
## so responses can be routed back to the originating client transport.
##
## Dispatch:
##   sql    → compile locally (nim_sql_frontend), forward as tagged-AST scheme
##   scheme → forward raw frame verbatim (inject id)
##   schema → serve from TTL cache (never touches downstream)
##   admin/kv → forward raw frame verbatim (inject id)
##
## SELECT/EXPLAIN execute locally on the read-only replica — the data
## server is only contacted for writes (DML) and admin/kv operations.
## This means reads survive data-server outages (stale-read availability).

import std/[json, strutils, options]
import chronos
import msgpack4nim/msgpack2json
import scheme, wire
import stats
import engine
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

proc parseSqlText(text: string): sql_ast.SqlStmt =
  try:
    sql_parser.parse(text)
  except Exception as e:
    var err = newException(ValueError, "SQL parse error: " & e.msg)
    raise err

proc nextBatchSafe(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) =
  try: sess.nextBatch(maxRows)
  except Exception as e: raise (ref ValueError)(msg: e.msg)

proc writeSelectFrame(transp: StreamTransport; rows: seq[seq[SExpr]]; more: bool) {.async.} =
  var node = newJObject()
  node["columns"] = %newJArray()
  var rarr = newJArray()
  for row in rows:
    var arr = newJArray()
    for v in row: arr.add(sexprToJson(v))
    rarr.add(arr)
  node["rows"] = rarr
  node["more"] = %more
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc handleSql(gw: GatewayState; node: JsonNode;
               transp: StreamTransport) {.async.} =
  let sqlText = node["sql"].getStr
  var params: seq[SExpr] = @[]
  if node.hasKey("params"):
    for p in node["params"]:
      params.add(jsonParamToSexpr(p))

  var snapshot = gw.getSnapshot()
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
        if "attribute resolution failed" in e.msg and attempt == 0:
          await sleepAsync(15.milliseconds)
          gw.invalidateSnapshot()
          snapshot = gw.getSnapshot()
        else:
          raise
    except CatchableError as e:
      raise newException(ValueError, e.msg)
  if compiled == nil:
    raise lastErr

  if compiled.isExplain or (compiled.isSelect and gw.replica != nil):
    # Execute locally on the replica engine.
    if compiled.isExplain:
      var rnode = newJObject()
      rnode["columns"] = %newJArray()
      var rows = newJArray()
      rows.add(%[@[renderExplain(compiled)]])
      rnode["rows"] = rows
      rnode["more"] = %false
      await transp.writeFrameAsync(msgpack2json.fromJsonNode(rnode))
      return

    # SELECT local execution: dummy tx (replica is read-only).
    let proto = newQuerySession(gw.replica.store, compiled.program, params,
                                1'i64, none[int64]())
    let sess = newStreamingSession(proto)
    while true:
      let (rows, more) = nextBatchSafe(sess, 100)
      await writeSelectFrame(transp, rows, more)
      if not more: break
    return

  # DML / schema changes: forward as scheme to the data server via the
  # shared multiplexed connection.
  let mode = if compiled.isSelect: "query" else: "exec"
  var req = newJObject()
  req["type"] = %"scheme"
  req["program"] = sexprToWire(compiled.program.body)
  req["mode"] = %mode
  if params.len > 0:
    var pa = newJArray()
    for p in params: pa.add(sexprToWire(p))
    req["params"] = pa
  await gw.conn.request(req, transp)
  # Read-your-writes barrier: the DML's WAL bytes were queued to the
  # replication subscriber before the response above (the sink runs under
  # kv.lock during execution). The server drains subscribers every ~2ms
  # and the gateway applies on socket read — a short sleep lets the next
  # statement in this session see its own writes on the local replica.
  await sleepAsync(50.milliseconds)

proc handleSchema(gw: GatewayState; transp: StreamTransport) {.async.} =
  ## Served from the local replica's stats — never touches the data server.
  let snap = gw.getSnapshot()
  var node = newJObject()
  node["schema"] = statsToJson(snap)
  node["more"] = %false
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc serveGatewayConnection*(gw: GatewayState; transp: StreamTransport) {.
    async: (raises: []).} =
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

      let t = node["type"].getStr
      try:
        case t
        of "sql":
          await handleSql(gw, node, transp)
        of "schema":
          await handleSchema(gw, transp)
        of "scheme", "admin", "kv":
          await gw.conn.forwardRaw(raw, transp)
        else:
          await transp.writeErrorAsync("unknown request type: " & t)
      except CatchableError as e:
        await transp.writeErrorAsync(e.msg)
  except CatchableError:
    discard  # client disconnected mid-frame
