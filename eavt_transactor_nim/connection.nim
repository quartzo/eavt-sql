## connection.nim — Data server per-connection handling (chronos).
##
## One event loop serves every connection.  Requests are dispatched
## pipelined: each frame is spawned as an independent async handler so
## that long-running streams yield between batches while the read loop
## continues accepting new frames.  Response frames carry the request's
## correlation id so the query server can demultiplex them on a single shared
## connection that also carries the replication event stream.
##
## Replication ("replicate") is handled inline: the server registers a
## subscriber, sends the snapshot, spawns the drain task, and returns to
## the read loop.  Replication events (wal/seal/root) are pushed by the
## drain task onto the same transport — chronos StreamTransport queues
## writes as complete vectors, so concurrent writers produce whole-frame
## interleaving (never mid-frame byte corruption).

import std/[options, strutils, json]
import chronos
import msgpack4nim/msgpack2json
import scheme
import stats
import engine, eavt, kvstore
import kvstore_async
import shared_engine
import protocol
import replication

proc writeFrameAsync(transp: StreamTransport; body: string) {.async.} =
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await transp.write(buf)

proc writeResponseAsync(transp: StreamTransport; columns: seq[string];
                        rows: seq[seq[SExpr]]; more: bool;
                        error: string = ""; id: string = "") {.async.} =
  var node = newJObject()
  if id.len > 0:
    node["id"] = %id
  if error.len > 0:
    node["error"] = %error
    node["more"] = %false
  else:
    var carr = newJArray()
    for c in columns: carr.add(%c)
    node["columns"] = carr
    var rarr = newJArray()
    for row in rows:
      var arr = newJArray()
      for v in row: arr.add(sexprToJson(v))
      rarr.add(arr)
    node["rows"] = rarr
    node["more"] = %more
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc writeErrorAsync(transp: StreamTransport; msg: string;
                     id: string = "") {.async.} =
  await writeResponseAsync(transp, @[], @[], false, msg, id)

proc nextBatchSafe(sess: StreamingSession; maxRows: int): (seq[seq[SExpr]], bool) {.
    raises: [ValueError].} =
  try:
    sess.nextBatch(maxRows)
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc executeProgramSafe(session: QuerySession): SExpr {.raises: [ValueError].} =
  try:
    executeProgram(session)
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc allocateTxSafe(eng: SharedEngine): int64 {.raises: [ValueError].} =
  try:
    eng.store.eavt.allocateTAndWriteTx()
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc buildStatsSafe(eng: SharedEngine): stats.CompileStats {.raises: [ValueError].} =
  try:
    eng.store.eavt.buildCompileStats()
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc scanDatomsSafe(eng: SharedEngine; cf: int): seq[eavt.Datom] {.
    raises: [ValueError].} =
  try:
    var res: seq[eavt.Datom]
    for d in eng.store.eavt.scanDatoms(cf):
      res.add(d)
    res
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc kvPutSafe(eng: SharedEngine; cf: int; key, val: seq[byte]) {.
    raises: [ValueError].} =
  try:
    eng.kv.putKv(cf, key, val)
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc kvDeleteSafe(eng: SharedEngine; cf: int; key: seq[byte]) {.
    raises: [ValueError].} =
  try:
    eng.kv.deleteKv(cf, key)
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc kvGetSafe(eng: SharedEngine; cf: int; key: seq[byte]): Option[seq[byte]] {.
    raises: [ValueError].} =
  try:
    eng.kv.getKv(cf, key)
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc kvScanPairsSafe(eng: SharedEngine; cf: int): seq[(seq[byte], seq[byte])] {.
    raises: [ValueError].} =
  try:
    var res: seq[(seq[byte], seq[byte])]
    let mc = eng.kv.openScanCursorKv(cf)
    while true:
      let kvp = mc.nextKv()
      if kvp.isNone: break
      res.add(kvp.get)
    res
  except Exception as e:
    raise (ref ValueError)(msg: e.msg)

proc execScheme(eng: SharedEngine; req: Request; transp: StreamTransport) {.async.} =
  let program = SchemeProgram(body: req.program)
  if req.mode != "query" and req.mode != "exec":
    await transp.writeErrorAsync("unknown scheme mode: " & req.mode, req.id)
    return
  let tx = if req.mode == "exec": allocateTxSafe(eng) else: 1'i64
  if req.mode == "query":
    let proto = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let sess = newStreamingSession(proto)
    while true:
      let (rows, more) = nextBatchSafe(sess, 100)
      await writeResponseAsync(transp, @[], rows, more, id = req.id)
      if not more: break
  else:
    let session = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let r = executeProgramSafe(session)
    eng.store.printSavePerf()
    eng.store.resetSaveCounters()
    eng.store.eavt.printSpPerf()
    eng.store.eavt.resetSpCounters()
    eng.store.kv.printBwPerf()
    eng.store.kv.resetBwCounters()
    if r.kind == sList and r.items.len >= 2 and r.items[0].kind == sSymbol and
       r.items[0].symval == "result":
      await writeResponseAsync(transp, @[], @[r.items[1..^1]], false, id = req.id)
    else:
      await writeResponseAsync(transp, @[], @[], false,
                                "unexpected result: " & $r, req.id)

proc handleSchema(eng: SharedEngine; id: string;
                  transp: StreamTransport) {.async.} =
  let cstats = buildStatsSafe(eng)
  var node = newJObject()
  if id.len > 0: node["id"] = %id
  node["schema"] = statsToJson(cstats)
  node["more"] = %false
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc handleAdmin(eng: SharedEngine; command: string; id: string;
                 transp: StreamTransport) {.async.} =
  proc gcReportText(rep: seq[byte]): string =
    if rep.len < 41: return "gc: no report"
    proc u64le(rep: seq[byte]; off: int): uint64 =
      for i in 0..7: result = result or (uint64(rep[off + i]) shl uint64(8 * i))
    "roots_scanned=" & $u64le(rep, 0) & " roots_removed=" & $u64le(rep, 8) &
      " blobs_scanned=" & $u64le(rep, 16) & " blobs_removed=" & $u64le(rep, 24) &
      " live_blobs=" & $u64le(rep, 32) & " dry_run=" & $rep[40]
  if command.startsWith("dump"):
    let parts = command.splitWhitespace()
    let index = if parts.len >= 2: parts[1].toUpperAscii() else: "EAVT"
    let cf = case index
      of "AEVT": 1
      of "AVET": 2
      of "VAET": 3
      else: 0
    var rows: seq[seq[SExpr]]
    let datoms = scanDatomsSafe(eng, cf)
    for datom in datoms:
      if datom.retracted: continue
      rows.add(@[
        SExpr(kind: sInt, ival: datom.e),
        SExpr(kind: sStr, sval: datom.attrName & "(" & $datom.a & ")"),
        datom.value,
        SExpr(kind: sInt, ival: datom.t),
      ])
      if rows.len >= 100:
        await writeResponseAsync(transp, @["e", "attr", "value", "t"], rows,
                                  true, id = id)
        rows.setLen(0)
    await writeResponseAsync(transp, @["e", "attr", "value", "t"], rows,
                              false, id = id)
  else:
    let output = case command
      of "flush":
        if eng.kv.readOnly:
          "error: read-only"
        else:
          let fut = eng.flusher.requestFlushAsync()
          fut.callback = proc(udata: pointer) {.gcsafe, raises: [].} = discard
          "ok: flush requested"
      of "flush-sync":
        if eng.kv.readOnly:
          "error: read-only"
        else:
          await eng.flusher.requestFlushAsync()
          "ok: flushed"
      of "gc", "gc-dry":
        if eng.kv.readOnly:
          "error: read-only"
        else:
          await eng.flusher.requestGcAsync(command == "gc-dry")
          gcReportText(eng.flusher.lastGcReport)
      of "status":
        "memtable: " & $eng.kv.memtableSize() & " bytes"
      of "memtable":
        $eng.kv.memtableSize()
      else:
        "unknown admin command: " & command
    var node = newJObject()
    if id.len > 0: node["id"] = %id
    node["output"] = %output
    node["more"] = %false
    await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc handleKv(eng: SharedEngine; req: Request; transp: StreamTransport) {.async.} =
  case req.kvOp
  of "put":
    kvPutSafe(eng, req.kvCf, req.kvKey, req.kvValue)
    await writeResponseAsync(transp, @[], @[], false, id = req.id)
  of "get":
    let val = kvGetSafe(eng, req.kvCf, req.kvKey)
    if val.isSome:
      await writeResponseAsync(transp, @[], @[@[SExpr(kind: sBytes, bytesval: val.get)]],
                                false, id = req.id)
    else:
      await writeResponseAsync(transp, @[], @[], false, id = req.id)
  of "scan":
    let pairs = kvScanPairsSafe(eng, req.kvCf)
    var rows: seq[seq[SExpr]]
    for (key, value) in pairs:
      rows.add(@[
        SExpr(kind: sBytes, bytesval: key),
        SExpr(kind: sBytes, bytesval: value),
      ])
      if rows.len >= 100:
        await writeResponseAsync(transp, @["key", "value"], rows, true, id = req.id)
        rows.setLen(0)
    await writeResponseAsync(transp, @["key", "value"], rows, false, id = req.id)
  of "delete":
    kvDeleteSafe(eng, req.kvCf, req.kvKey)
    await writeResponseAsync(transp, @[], @[], false, id = req.id)
  else:
    await writeResponseAsync(transp, @[], @[], false,
                              "unknown kv op: " & req.kvOp, req.id)

# ── Pipelined request dispatch ──────────────────────────────────────────────

proc processFrame(eng: SharedEngine; raw: string; id: string;
                  transp: StreamTransport) {.async: (raises: []).} =
  ## Parse one request frame and dispatch to the appropriate handler.
  ## Errors are written back as response frames (tagged with the request's
  ## correlation id) — nothing escapes this proc.
  try:
    var req = parseRequest(raw)
    req.id = id  # id from the outer frame header (already parsed)
    case req.kind
    of rkScheme: await execScheme(eng, req, transp)
    of rkSchema: await handleSchema(eng, req.id, transp)
    of rkAdmin: await handleAdmin(eng, req.command, req.id, transp)
    of rkKv: await handleKv(eng, req, transp)
  except CatchableError as e:
    try:
      await transp.writeErrorAsync(e.msg, id)
    except CatchableError:
      discard

# ── Main connection loop ────────────────────────────────────────────────────

proc serveConnection*(eng: SharedEngine; transp: StreamTransport) {.
    async: (raises: []).} =
  var isReplication = false
  while true:
    var hdr: array[4, byte]
    try:
      await transp.readExactly(addr hdr[0], 4)
    except CatchableError:
      break  # client disconnected
    let len = int(hdr[0]) shl 24 or int(hdr[1]) shl 16 or
              int(hdr[2]) shl 8 or int(hdr[3])
    if len <= 0 or len > 100_000_000:
      break
    let raw = newString(len)
    if len > 0:
      try:
        await transp.readExactly(addr raw[0], len)
      except CatchableError:
        break

    # Replication subscription: register subscriber, send snapshot, spawn
    # the drain task, and continue reading.  The drain loop pushes
    # wal/seal/root events onto the same transport concurrently with
    # response frames from spawned request handlers — chronos StreamTransport
    # queues writes as complete vectors, so frames never interleave bytes.
    if not isReplication:
      try:
        let node = toJsonNode(raw)
        if node["type"].getStr == "replicate":
          isReplication = true
          var sub = Subscriber(transp: transp)
          eng.hub.register(sub)
          try:
            let sealed = collectSnapshot(eng.kv.path, eng.kv.ps[].currentRoot)
            var tail: seq[byte] = @[]
            if eng.walw != nil:
              tail = eng.walw.buf
            let rootName = eng.kv.ps[].currentRoot
            await sub.sendSnapshot(sealed, tail, rootName, eng.kv.path)
            # Spawn the drain loop — runs forever, pushes events.
            asyncSpawn subscriberLoop(eng.kv, sub, addr eng.hub)
          except CatchableError:
            sub.closed = true
            eng.hub.remove(sub)
          continue  # back to read loop (pipelined)
      except CatchableError:
        discard  # not valid JSON, fall through to normal parse

    # Extract correlation id (quick JSON peek) then spawn the handler.
    var id = ""
    try:
      let node = toJsonNode(raw)
      if node.hasKey("id"):
        id = node["id"].getStr
    except CatchableError:
      discard  # malformed — processFrame will surface the parse error

    asyncSpawn processFrame(eng, raw, id, transp)
