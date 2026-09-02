## connection.nim — Gateway per-connection handling (chronos, single-thread).
##
## All clients share a single multiplexed connection to the transactor
## (MultiplexedConn in downstream.nim).  Requests carry a correlation id
## so responses can be routed back to the originating client transport.
##
## Dispatch:
##   datalog → compile locally (nim_datalog/query_edn → nim_compiler), stream rows
##   tx     → forward raw frame verbatim (the EDN write path)
##   schema → serve from TTL cache (never touches downstream)
##   admin/kv → forward raw frame verbatim (inject id)
##
## Queries (datalog) execute locally on the read-only replica. Writes go
## as EDN tx-data to the transactor (docs/tx-protocol.md).
## This means reads survive data-server outages (stale-read availability).

import std/[strutils, options, streams]
import chronos
import msgpack4nim
import scheme, wire, msgpack_scan
import stats
import engine
import eavt_transactor_nim/protocol except readMsg, writeMsg
import shared
import downstream
import compiler, explain as cexplain  # nim_compiler/explain.nim
import logutil
import explain
import datalog_compile
import edn

const BatchSize = 100


proc nextBatchSafe(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) =
  try: sess.nextBatch(maxRows)
  except Exception as e: raise (ref ValueError)(msg: e.msg)

proc writeSelectFrame(transp: StreamTransport; rows: seq[seq[SExpr]]; more: bool) {.async.} =
  var ms = MsgStream.init(256)
  ms.pack_map(3)
  ms.pack("columns"); ms.pack_array(0)
  ms.pack("rows")
  ms.pack_array(rows.len)
  for row in rows:
    ms.pack_array(row.len)
    for v in row:
      writeSExprPlain(ms, v)
  ms.pack("more"); ms.pack(more)
  await transp.writeFrameAsync(ms.data)

proc writeSelectFrameCols(transp: StreamTransport; columns: seq[string];
                          rows: seq[seq[SExpr]]; more: bool) {.async.} =
  ## Like writeSelectFrame but with named columns (the Datalog :find vars).
  var ms = MsgStream.init(256)
  ms.pack_map(3)
  ms.pack("columns"); ms.pack_array(columns.len)
  for c in columns: ms.pack(c)
  ms.pack("rows")
  ms.pack_array(rows.len)
  for row in rows:
    ms.pack_array(row.len)
    for v in row:
      writeSExprPlain(ms, v)
  ms.pack("more"); ms.pack(more)
  await transp.writeFrameAsync(ms.data)

proc buildSchemeRequest(program: SExpr; mode: string;
                         params: seq[SExpr]): string =
  ## Build a scheme request as raw msgpack bytes.
  var ms = MsgStream.init(256)
  let fieldCount = if params.len > 0: 4 else: 3
  ms.pack_map(fieldCount)
  ms.pack("type"); ms.pack("scheme")
  ms.pack("program")
  writeSExprWire(ms, program)
  ms.pack("mode"); ms.pack(mode)
  if params.len > 0:
    ms.pack("params")
    ms.pack_array(params.len)
    for p in params:
      writeSExprWire(ms, p)
  ms.data

proc sendSchemeExec(gw: GatewayState; program: SchemeProgram;
                    params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## Send a Scheme program to the transactor as an exec request.
  let req = buildSchemeRequest(program.body, "exec", params)
  await gw.conn.request(req, transp)

# ── EDN tx write path (docs/tx-protocol.md §3) ──────────────────────────────

proc buildTxRequest(txdata: seq[SExpr]): string =
  ## Build a `tx` request as raw msgpack bytes — ops are native msgpack
  ## values (keywords ext 0x06), no `params` field (§5.4: values are
  ## substituted at compile time).
  var ms = MsgStream.init(256)
  ms.pack_map(2)
  ms.pack("type"); ms.pack("tx")
  ms.pack("txdata")
  ms.pack_array(txdata.len)
  for op in txdata:
    writeSExprWire(ms, op)
  ms.data

proc firstFrameBody(collected: string): string =
  ## Body of the first frame in a collected (4B length prefix + body) buffer.
  if collected.len < 4: return ""
  let ln = (int(collected[0]) shl 24) or (int(collected[1]) shl 16) or
           (int(collected[2]) shl 8) or int(collected[3])
  if 4 + ln > collected.len: return ""
  collected[4 ..< 4 + ln]

proc getTopReportFields(raw: string): tuple[tempids: seq[(int64, int64)], tx: int64] =
  ## Extract (tempids, tx) from a tx-report frame — msgpack map at frame
  ## level, read with topValue/skipValue/mpReadInt, no full tree.
  var tempids: seq[(int64, int64)] = @[]
  var tx: int64 = 0
  var pos = 0
  let (tf, ts, te) = topValue(raw, "tx")
  if tf:
    var p = ts
    tx = mpReadInt(raw, p, te)
  let (f, s, e) = topValue(raw, "tempids")
  if f:
    # parse the map header manually: mapCountAndHeaderLen over the slot
    let (n, hdr) = mapCountAndHeaderLen(raw[s ..< e])
    if n >= 0:
      var kp = s + hdr
      for i in 1 .. n:
        if kp >= e: break
        let kStart = kp
        kp = skipValue(raw, kp, 0)
        if kp < 0: break
        let kEnd = kp
        kp = skipValue(raw, kp, 0)
        if kp < 0 or kp > e: break
        let vEnd = kp
        var kpos = kStart
        let tid = mpReadInt(raw, kpos, kEnd)
        var vpos = kEnd
        let vid = mpReadInt(raw, vpos, vEnd)
        tempids.add((tid, vid))
  (tempids, tx)

proc sendTxCollect(gw: GatewayState; txdata: seq[SExpr]): Future[string] {.async.} =
  ## Send a tx request and return the collected raw response frames.
  ## NB: no `return await` — that pattern yields a nil future in Nim's async
  ## transform (the yielded-nil Assert the logs show).
  let req = buildTxRequest(txdata)
  result = await gw.conn.requestCollect(req)

proc relayReport(transp: StreamTransport; collected: string) {.async.} =
  ## Relay collected tx-report frames (4B length prefix + body) verbatim to
  ## the client transport.
  var pos = 0
  while pos < collected.len:
    if pos + 4 > collected.len: break
    let ln = (int(collected[pos]) shl 24) or (int(collected[pos+1]) shl 16) or
             (int(collected[pos+2]) shl 8) or int(collected[pos+3])
    pos += 4
    if pos + ln > collected.len: break
    await transp.writeFrameAsync(collected[pos ..< pos + ln])
    pos += ln

proc parseEdnOps(text: string): seq[SExpr] =
  ## Parse a tx-data EDN text (the REPL sends raw EDN) into op vectors.
  readEdnVector(text)

proc handleDatalog(gw: GatewayState; raw: string;
                   transp: StreamTransport) {.async.} =
  ## Datalog EDN query (docs/datalog-reference.md):
  ##   {"type": "datalog", "query": "[:find ... :where ...]",
  ##    "params": [wire ASTs], "explain": bool}
  ## Compiles via the Datalog IR directly (no SQL AST) and streams rows on
  ## the replica — the same consistency model as SELECT.
  let queryText = getTopStr(raw, "query")
  if queryText.len == 0:
    await transp.writeErrorAsync("datalog request missing query field")
    return
  var params: seq[SExpr] = @[]
  let (pf, ps, pe) = topValue(raw, "params")
  if pf:
    for (s, e) in topArrayElems(raw, ps, pe):
      params.add(wireFromMsgpackAt(raw, s, e))
  let explain = getTopBool(raw, "explain")

  # Route tx-data to the transactor directly (the REPL sends tx-data EDN
  # in the same request shape).
  if ":db/add" in queryText or ":db/retract" in queryText:
    let ops = parseEdnOps(queryText)
    let collected = await sendTxCollect(gw, ops)
    if collected.len == 0:
      await transp.writeErrorAsync("transactor disconnected")
      return
    await relayReport(transp, collected)
    return

  # Compile with the same stale-schema retry as the SQL path.
  var findVars: seq[string] = @[]
  var compiled: CompileResult = nil
  var lastErr: ref CatchableError = nil
  for attempt in 0..1:
    try:
      var fv: seq[string] = @[]
      compiled = compileDatalogQuery(queryText, gw.getSnapshot(), fv)
      findVars = fv
      break
    except CatchableError as e:
      lastErr = e
      if "attribute resolution failed" in e.msg and attempt == 0:
        await sleepAsync(15.milliseconds)
        gw.invalidateSnapshot()
        try:
          discard gw.getSnapshot()
        except CatchableError:
          discard
      else:
        raise
  if compiled == nil:
    raise lastErr

  if explain or gw.replica == nil:
    if explain:
      var ms = MsgStream.init(4096)
      ms.pack_map(3)
      ms.pack("columns"); ms.pack_array(0)
      ms.pack("rows"); ms.pack_array(1); ms.pack_array(1)
      let explainStr = cexplain.renderExplain(compiled)
      ms.pack(explainStr)
      ms.pack("more"); ms.pack(false)
      await transp.writeFrameAsync(ms.data)
      return
    if gw.replica == nil:
      await transp.writeErrorAsync("replica unavailable")
      return

  # Streaming execution on the replica (same as SELECT).
  let proto = newQuerySession(gw.replica.store, compiled.program, params,
                              1'i64, none[int64]())
  let sess = newStreamingSession(proto)
  var first = true
  while true:
    let (rows, more) = nextBatchSafe(sess, 100)
    var ms = MsgStream.init(256)
    ms.pack_map(3)
    ms.pack("columns")
    if first:
      ms.pack_array(findVars.len)
      for v in findVars: ms.pack(v)
    else:
      ms.pack_array(0)
    ms.pack("rows")
    ms.pack_array(rows.len)
    for row in rows:
      ms.pack_array(row.len)
      for v in row:
        writeSExprPlain(ms, v)
    ms.pack("more"); ms.pack(more)
    await transp.writeFrameAsync(ms.data)
    first = false
    if not more: break

proc handleSchema(gw: GatewayState; transp: StreamTransport) {.async.} =
  ## Served from the local replica's stats — never touches the transactor.
  let snap = gw.getSnapshot()
  var ms = MsgStream.init(256)
  ms.pack_map(2)
  ms.pack("schema")
  packStats(ms, snap)
  ms.pack("more"); ms.pack(false)
  await transp.writeFrameAsync(ms.data)

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

      # Dispatch by top-level "type" key only.  Forwarded types
      # (scheme/admin/kv) never get a full msgpack→JsonNode conversion —
      # their payload passes through raw; only the sql path parses (small
      # frames, compiled locally anyway).
      if not isMsgpackMap(raw):
        await transp.writeErrorAsync("parse error: request must be an object")
        continue

      let t = getTopStr(raw, "type")
      try:
        case t
        of "datalog":
          await handleDatalog(gw, raw, transp)
        of "schema":
          await handleSchema(gw, transp)
        of "scheme", "tx", "admin", "kv":
          await gw.conn.forwardRaw(raw, transp)
        else:
          if not hasTopKey(raw, "type"):
            await transp.writeErrorAsync(
              "parse error: request must be an object with a type")
          else:
            await transp.writeErrorAsync("unknown request type: " & t)
      except CatchableError as e:
        await transp.writeErrorAsync(e.msg)
  except CatchableError as e:
    # Expected: client disconnected mid-frame.
    logDebug("query", "client handler ended (" & excMsg(e) & ")")
