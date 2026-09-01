## connection.nim — Gateway per-connection handling (chronos, single-thread).
##
## All clients share a single multiplexed connection to the transactor
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
##
## Mixed operations (UPDATE/DELETE with WHERE):
##   The query server scans the local replica to find matching entity IDs,
##   then sends batched concrete save/retract calls to the transactor.
##   The triejoin runs on the replica; the server only does direct writes.

import std/[strutils, options, streams]
import chronos
import msgpack4nim
import scheme, wire, msgpack_scan
import stats
import engine
import eavt_transactor_nim/protocol except readMsg, writeMsg
import shared
import downstream
import frontend
import logutil
import explain
import ast as sql_ast
import parser as sql_parser
import tx_compile
import datalog_compile

const BatchSize = 100

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

  # Compile with the same stale-schema retry as the SQL path.
  var findVars: seq[string] = @[]
  var compiled: frontend.CompileResult = nil
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
      let explainStr = renderExplain(compiled)
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

# ── Mixed-operation helpers ─────────────────────────────────────────────────

proc literalToSexpr(l: sql_ast.Literal): SExpr =
  case l.lkind
  of sql_ast.litInt: newInt(l.ival)
  of sql_ast.litFloat: newFloat(l.fval)
  of sql_ast.litStr: newStr(l.sval)
  of sql_ast.litBool: newBool(l.bval)
  of sql_ast.litBytes: newBytes(l.bytesval)

proc valueToSexpr(v: sql_ast.Value): SExpr =
  case v.vkind
  of sql_ast.valLiteral: literalToSexpr(v.vlit)
  of sql_ast.valParam: newList(@[newSymbol("param"), newInt(v.vparam.int64)])
  else: newInt(0)

proc canUseMixedUpdate(updateStmt: sql_ast.UpdateStmt): bool =
  ## Mixed UPDATE only when SET values are literals or params (no alias
  ## refs, no expression values — those need the triejoin's variable
  ## bindings).
  for clause in updateStmt.clauses:
    for iv in clause.values:
      if iv.value.vkind notin {sql_ast.valLiteral, sql_ast.valParam}:
        return false
  true

proc canUseMixedDelete(deleteStmt: sql_ast.DeleteStmt): bool =
  ## Mixed DELETE only when condition values are literals or params (no
  ## field refs, no IN/OR — those need the triejoin).
  for cond in deleteStmt.conditions:
    if cond.left.field == "eid": continue
    if cond.right.rkind notin {sql_ast.crLiteral, sql_ast.crParam}:
      return false
  true

proc compileSelectWithRetry(gw: GatewayState;
                            fakeStmt: sql_ast.SqlStmt): Future[CompileResult] {.async.} =
  ## Compile a fake SELECT with the same retry logic as handleSql.
  var snapshot = gw.getSnapshot()
  var lastErr: ref CatchableError = nil
  for attempt in 0..1:
    try:
      result = compileSql(fakeStmt, snapshot)
      return
    except CatchableError as e:
      lastErr = e
      if "attribute resolution failed" in e.msg and attempt == 0:
        await sleepAsync(15.milliseconds)
        gw.invalidateSnapshot()
        snapshot = gw.getSnapshot()
      else:
        raise newException(ValueError, e.msg)
  raise lastErr

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

# ── Mixed-operation handlers ────────────────────────────────────────────────

proc handleUpdateMux(gw: GatewayState; updateStmt: sql_ast.UpdateStmt;
                     params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## UPDATE with WHERE: query server scans local replica for matching eids,
  ## sends batched concrete save calls to the transactor.
  let fakeSelect = fakeSelectFromUpdate(updateStmt)
  let fakeStmt = sql_ast.SqlStmt(kind: sql_ast.stmtSelect, selectStmt: fakeSelect)
  let selectResult = await compileSelectWithRetry(gw, fakeStmt)

  let proto = newQuerySession(gw.replica.store, selectResult.program,
                              params, 1'i64, none[int64]())
  let sess = newStreamingSession(proto)

  var batch: seq[int64]
  let totalValues = updateStmt.clauses[0].values.len.int64
  while true:
    let (rows, more) = nextBatchSafe(sess, BatchSize)
    for row in rows:
      if row.len > 0 and row[0].kind == sInt:
        batch.add(row[0].ival)
    if batch.len >= BatchSize or (not more and batch.len > 0):
      var txdata: seq[SExpr]
      for eid in batch:
        for clause in updateStmt.clauses:
          for iv in clause.values:
            txdata.add(txAdd(newInt(eid), iv.attr,
                             valueToVal(iv.value, params)))
      let collected = await sendTxCollect(gw, txdata)
      let reportBody = firstFrameBody(collected)
      if getTopStr(reportBody, "error").len > 0:
        await transp.writeErrorAsync(getTopStr(reportBody, "error"))
        return
      # Legacy UPDATE row contract: [[firstEid, totalValues]]
      var ms = MsgStream.init(128)
      ms.pack_map(3)
      ms.pack("columns"); ms.pack_array(0)
      ms.pack("rows"); ms.pack_array(1); ms.pack_array(2)
      ms.pack(batch[0]); ms.pack(totalValues)
      ms.pack("more"); ms.pack(false)
      await transp.writeFrameAsync(ms.data)
      batch.setLen(0)
    if not more: break

proc handleDeleteMux(gw: GatewayState; deleteStmt: sql_ast.DeleteStmt;
                     params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## DELETE with WHERE: query server scans local replica for matching eids,
  ## sends batched concrete retract calls to the transactor.
  let fakeSelect = fakeSelectFromDelete(deleteStmt)
  let fakeStmt = sql_ast.SqlStmt(kind: sql_ast.stmtSelect, selectStmt: fakeSelect)
  let selectResult = await compileSelectWithRetry(gw, fakeStmt)

  let proto = newQuerySession(gw.replica.store, selectResult.program,
                              params, 1'i64, none[int64]())
  let sess = newStreamingSession(proto)

  var batch: seq[int64]
  while true:
    let (rows, more) = nextBatchSafe(sess, BatchSize)
    for row in rows:
      if row.len > 0 and row[0].kind == sInt:
        batch.add(row[0].ival)
    if batch.len >= BatchSize or (not more and batch.len > 0):
      var txdata: seq[SExpr]
      for eid in batch:
        for cond in deleteStmt.conditions:
          if cond.left.field == "eid": continue
          let valExpr = case cond.right.rkind
            of sql_ast.crParam: valueToVal(
                sql_ast.Value(vkind: sql_ast.valParam, vparam: cond.right.rparam),
                params)
            of sql_ast.crLiteral: literalToVal(cond.right.rlit)
            else: newInt(0)
          txdata.add(txRetract(newInt(eid), cond.left.field, valExpr))
      let collected = await sendTxCollect(gw, txdata)
      let reportBody = firstFrameBody(collected)
      if getTopStr(reportBody, "error").len > 0:
        await transp.writeErrorAsync(getTopStr(reportBody, "error"))
        return
      # Legacy DELETE row contract: [[firstEid]]
      var ms = MsgStream.init(128)
      ms.pack_map(3)
      ms.pack("columns"); ms.pack_array(0)
      ms.pack("rows"); ms.pack_array(1); ms.pack_array(1)
      ms.pack(batch[0])
      ms.pack("more"); ms.pack(false)
      await transp.writeFrameAsync(ms.data)
      batch.setLen(0)
    if not more: break

# ── Main SQL handler ────────────────────────────────────────────────────────

proc handleSql(gw: GatewayState; raw: string;
               transp: StreamTransport) {.async.} =
  let sqlText = getTopStr(raw, "sql")
  if sqlText.len == 0:
    await transp.writeErrorAsync("sql request missing sql field")
    return
  var params: seq[SExpr] = @[]
  let (pf, ps, pe) = topValue(raw, "params")
  if pf:
    for (s, e) in topArrayElems(raw, ps, pe):
      params.add(wireFromMsgpackAt(raw, s, e))

  let stmt = parseSqlText(sqlText)

  # Mixed operations: UPDATE/DELETE with WHERE → query server scans, transactor writes.
  # Only when replica is available and conditions are simple (literal/param).
  # DELETE with an eid condition (no other retractable conditions) retracts
  # nothing by definition — answer with the legacy empty row shape.
  if gw.replica != nil:
    if stmt.kind == sql_ast.stmtUpdate and canUseMixedUpdate(stmt.updateStmt):
      await handleUpdateMux(gw, stmt.updateStmt, params, transp)
      return
    if stmt.kind == sql_ast.stmtDelete and canUseMixedDelete(stmt.deleteStmt):
      await handleDeleteMux(gw, stmt.deleteStmt, params, transp)
      return
  if stmt.kind == sql_ast.stmtDelete and frontend.isDeleteDirect(stmt.deleteStmt):
    # eid-only delete: the compiled scheme path retracts nothing either
    var ms = MsgStream.init(128)
    ms.pack_map(3)
    ms.pack("columns"); ms.pack_array(0)
    ms.pack("rows"); ms.pack_array(1); ms.pack_array(1); ms.pack(0)
    ms.pack("more"); ms.pack(false)
    await transp.writeFrameAsync(ms.data)
    return

  # Existing logic: compile with retry, route by isSelect/isExplain.
  var snapshot = gw.getSnapshot()
  var compiled: CompileResult = nil
  var lastErr: ref CatchableError = nil
  for attempt in 0..1:
    try:
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
      var ms = MsgStream.init(256)
      ms.pack_map(3)
      ms.pack("columns"); ms.pack_array(0)
      ms.pack("rows")
      ms.pack_array(1)
      ms.pack_array(1)
      let explainStr = renderExplain(compiled)
      ms.pack(explainStr)
      ms.pack("more"); ms.pack(false)
      await transp.writeFrameAsync(ms.data)
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

  # PARTITION keeps the legacy scheme path (engine-managed partitions; the
  # declare-partition hostfn is transactor-internal, §9 of tx-protocol.md).
  if stmt.kind == sql_ast.stmtPartition:
    let req = buildSchemeRequest(compiled.program.body, "exec", params)
    await gw.conn.request(req, transp)
    return

  # DML / schema changes: compile to EDN tx-data and send a `tx` request
  # (docs/tx-protocol.md §3).  The tx-report is inspected locally to rebuild
  # the legacy UPSERT row contract [[eid, N]] for REPL/Python clients; the
  # transactor's single output queue guarantees the WAL frames precede the
  # ack, so the replica has applied the datoms when the client proceeds.
  let txdata: seq[SExpr] = case stmt.kind
    of sql_ast.stmtUpsert:
      compileUpsertTx(stmt.upsertStmt, params)
    of sql_ast.stmtAttribute:
      compileAttributeTx(stmt.attrStmt)
    else:
      @[]
  if txdata.len == 0:
    # Nothing to write (e.g. PARTITION): answer with the legacy empty row shape.
    var ms = MsgStream.init(128)
    ms.pack_map(3)
    ms.pack("columns"); ms.pack_array(0)
    ms.pack("rows"); ms.pack_array(1); ms.pack_array(1); ms.pack(0)
    ms.pack("more"); ms.pack(false)
    await transp.writeFrameAsync(ms.data)
    return
  let collected = await sendTxCollect(gw, txdata)
  if collected.len == 0:
    await transp.writeErrorAsync("transactor disconnected")
    return
  # Rebuild the legacy result row for UPSERT: [[firstTempidEid, totalValues]].
  # For ATTRIBUTE: [[attr, valueType]] (the old (result attr vt) contract).
  # REPL/Python clients keep their row contract; the transactor's single
  # output queue guarantees the WAL frames precede the ack, so the replica
  # has applied the datoms when the client proceeds.
  let reportBody = firstFrameBody(collected)
  if getTopStr(reportBody, "error").len > 0:
    # Surface tx errors (lookup miss, unknown attr...) as SQL errors.
    await transp.writeErrorAsync(getTopStr(reportBody, "error"))
    return
  if stmt.kind == sql_ast.stmtUpsert:
    let (tempids, _) = getTopReportFields(reportBody)
    var ms = MsgStream.init(128)
    ms.pack_map(3)
    ms.pack("columns"); ms.pack_array(0)
    ms.pack("rows")
    if tempids.len > 0:
      ms.pack_array(1)
      ms.pack_array(2)
      ms.pack(tempids[0][1])
      var n = 0
      for clause in stmt.upsertStmt.clauses: n += clause.values.len
      ms.pack(n)
    else:
      ms.pack_array(0)
    ms.pack("more"); ms.pack(false)
    await transp.writeFrameAsync(ms.data)
  elif stmt.kind == sql_ast.stmtAttribute:
    var ms = MsgStream.init(128)
    ms.pack_map(3)
    ms.pack("columns"); ms.pack_array(0)
    ms.pack("rows"); ms.pack_array(1); ms.pack_array(2)
    ms.pack(stmt.attrStmt.attr); ms.pack(stmt.attrStmt.valueType)
    ms.pack("more"); ms.pack(false)
    await transp.writeFrameAsync(ms.data)
  else:
    await relayReport(transp, collected)

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
        of "sql":
          await handleSql(gw, raw, transp)
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
