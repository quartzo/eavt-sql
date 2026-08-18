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
##
## Mixed operations (UPDATE/DELETE with WHERE):
##   The gateway scans the local replica to find matching entity IDs,
##   then sends batched concrete save/retract calls to the data server.
##   The triejoin runs on the replica; the server only does direct writes.

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

const BatchSize = 100

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

proc sendSchemeExec(gw: GatewayState; program: SchemeProgram;
                    params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## Send a Scheme program to the data server as an exec request.
  var req = newJObject()
  req["type"] = %"scheme"
  req["program"] = sexprToWire(program.body)
  req["mode"] = %"exec"
  if params.len > 0:
    var pa = newJArray()
    for p in params: pa.add(sexprToWire(p))
    req["params"] = pa
  await gw.conn.request(req, transp)

# ── Mixed-operation handlers ────────────────────────────────────────────────

proc handleUpdateMux(gw: GatewayState; updateStmt: sql_ast.UpdateStmt;
                     params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## UPDATE with WHERE: gateway scans local replica for matching eids,
  ## sends batched concrete save calls to the data server.
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
      var stmts: seq[SExpr]
      for eid in batch:
        for clause in updateStmt.clauses:
          for iv in clause.values:
            stmts.add(newList(@[newSymbol("save"), newInt(eid),
                                newStr(iv.attr), valueToSexpr(iv.value)]))
      stmts.add(newList(@[newSymbol("result"), newInt(batch[0]),
                          newInt(totalValues)]))
      let body = if stmts.len == 1: stmts[0]
                 else: newList(@[newSymbol("begin")] & stmts)
      await sendSchemeExec(gw, SchemeProgram(body: body), params, transp)
      batch.setLen(0)
    if not more: break
  await sleepAsync(50.milliseconds)

proc handleDeleteMux(gw: GatewayState; deleteStmt: sql_ast.DeleteStmt;
                     params: seq[SExpr]; transp: StreamTransport) {.async.} =
  ## DELETE with WHERE: gateway scans local replica for matching eids,
  ## sends batched concrete retract calls to the data server.
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
      var stmts: seq[SExpr]
      for eid in batch:
        for cond in deleteStmt.conditions:
          if cond.left.field == "eid": continue
          let valExpr = case cond.right.rkind
            of sql_ast.crParam:
              newList(@[newSymbol("param"), newInt(cond.right.rparam.int64)])
            of sql_ast.crLiteral: literalToSexpr(cond.right.rlit)
            else: newInt(0)
          stmts.add(newList(@[newSymbol("retract"), newInt(eid),
                              newStr(cond.left.field), valExpr]))
      stmts.add(newList(@[newSymbol("result"), newInt(batch[0])]))
      let body = if stmts.len == 1: stmts[0]
                 else: newList(@[newSymbol("begin")] & stmts)
      await sendSchemeExec(gw, SchemeProgram(body: body), params, transp)
      batch.setLen(0)
    if not more: break
  await sleepAsync(50.milliseconds)

# ── Main SQL handler ────────────────────────────────────────────────────────

proc handleSql(gw: GatewayState; node: JsonNode;
               transp: StreamTransport) {.async.} =
  let sqlText = node["sql"].getStr
  var params: seq[SExpr] = @[]
  if node.hasKey("params"):
    for p in node["params"]:
      params.add(jsonParamToSexpr(p))

  let stmt = parseSqlText(sqlText)

  # Mixed operations: UPDATE/DELETE with WHERE → gateway scans, server writes.
  # Only when replica is available and conditions are simple (literal/param).
  if gw.replica != nil:
    if stmt.kind == sql_ast.stmtUpdate and canUseMixedUpdate(stmt.updateStmt):
      await handleUpdateMux(gw, stmt.updateStmt, params, transp)
      return
    if stmt.kind == sql_ast.stmtDelete and canUseMixedDelete(stmt.deleteStmt):
      await handleDeleteMux(gw, stmt.deleteStmt, params, transp)
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
