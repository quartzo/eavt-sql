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
import engine, hostfns
import eavt
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

proc nextBatchSafe(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) =
  try: sess.nextBatch(maxRows)
  except Exception as e: raise (ref ValueError)(msg: e.msg)

proc allocateTxSafe(store: engine.QueryStore): int64 {.raises: [ValueError].} =
  try: store.eavt.allocateTAndWriteTx()
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

proc handleSql(gw: GatewayState; dsPtr: ptr DownstreamConn; node: JsonNode;
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
        # A stale snapshot can only miss recently-declared attributes —
        # refetch once and recompile before giving up.
        if "attribute resolution failed" in e.msg and attempt == 0:
          # The schema changed via a DML we just forwarded; its WAL bytes are
          # in flight (server drains subscribers every ~2ms). Wait briefly
          # for the replica to apply them, then rebuild stats.
          await sleepAsync(15.milliseconds)
          gw.invalidateSnapshot()
          snapshot = gw.getSnapshot()  # rebuild from replica engine
        else:
          raise
    except CatchableError as e:
      raise newException(ValueError, e.msg)
  if compiled == nil:
    raise lastErr

  if compiled.isExplain or (compiled.isSelect and gw.replica != nil):
    # Execute locally on the replica engine.  EXPLAIN is always local
    # (pure compilation, no I/O).  SELECT is local when a replica is
    # available; DML forwards to the data server regardless.
    if compiled.isExplain:
      var rnode = newJObject()
      rnode["columns"] = %newJArray()
      var rows = newJArray()
      rows.add(%[@[renderExplain(compiled)]])
      rnode["rows"] = rows
      rnode["more"] = %false
      await transp.writeFrameAsync(msgpack2json.fromJsonNode(rnode))
      return

    # SELECT local execution: same pattern as the data server's execScheme,
    # but with a DUMMY tx — the replica never writes txInstant datoms (it is
    # read-only; the tx value is only read by the tx-entity hostfn).
    let proto = newQuerySession(gw.replica.store, compiled.program, params,
                                1'i64, none[int64]())
    let sess = newStreamingSession(proto)
    while true:
      let (rows, more) = nextBatchSafe(sess, 100)
      await writeSelectFrame(transp, rows, more)
      if not more: break
    return

  # DML / schema changes: forward as scheme to the data server (lazy
  # downstream — read-only sessions never connect).
  if dsPtr[] == nil:
    dsPtr[] = await connectDownstream(gw.downstreamPath)
  let ds = dsPtr[]
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
  # Read-your-writes barrier: the DML's WAL bytes were queued to the
  # replication subscriber before the response above (the sink runs under
  # kv.lock during execution). The server drains subscribers every ~2ms
  # and the gateway applies on socket read — a short sleep lets the next
  # statement in this session see its own writes on the local replica.
  await sleepAsync(10.milliseconds)

proc handleSchema(gw: GatewayState; ds: DownstreamConn;
                  transp: StreamTransport) {.async.} =
  let snap = gw.getSnapshot()
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

      let t = node["type"].getStr
      # Downstream is connected lazily: SELECT/EXPLAIN execute on the local
      # replica and never need the data server. This also keeps reads alive
      # when the data server is down (stale-read availability).
      proc ensureDs() {.async.} =
        if ds == nil:
          ds = await connectDownstream(gw.downstreamPath)
      try:
        case t
        of "sql":
          await handleSql(gw, addr ds, node, transp)
        of "schema":
          await handleSchema(gw, ds, transp)
        of "scheme", "admin", "kv":
          await ensureDs()
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
