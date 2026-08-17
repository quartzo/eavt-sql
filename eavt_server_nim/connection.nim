## connection.nim — Data server per-connection handling (chronos).
##
## One event loop serves every connection; each callback runs a request loop
## (request → response/stream). Query execution uses the VM's yield/resume:
## nextBatch(100) between frames is the natural suspension point. Errors are
## always written as frames — nothing escapes the callback.

import std/[options, strutils, json, os]
import chronos
import msgpack4nim/msgpack2json
import scheme, wire
import stats
import engine, eavt, kvstore
import shared_engine
import protocol

proc writeFrameAsync(transp: StreamTransport; body: string) {.async.} =
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await transp.write(buf)

proc writeResponseAsync(transp: StreamTransport; columns: seq[string];
                        rows: seq[seq[SExpr]]; more: bool;
                        error: string = "") {.async.} =
  var node = newJObject()
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

proc writeErrorAsync(transp: StreamTransport; msg: string) {.async.} =
  await writeResponseAsync(transp, @[], @[], false, msg)

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
    await transp.writeErrorAsync("unknown scheme mode: " & req.mode)
    return
  let tx = allocateTxSafe(eng)
  if req.mode == "query":
    let proto = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let sess = newStreamingSession(proto)
    while true:
      let (rows, more) = nextBatchSafe(sess, 100)
      await writeResponseAsync(transp, @[], rows, more)
      if not more: break
  else:
    let session = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let r = executeProgramSafe(session)
    if r.kind == sList and r.items.len >= 2 and r.items[0].kind == sSymbol and
       r.items[0].symval == "result":
      await writeResponseAsync(transp, @[], @[r.items[1..^1]], false)
    else:
      await writeResponseAsync(transp, @[], @[], false, "unexpected result: " & $r)

proc handleSchema(eng: SharedEngine; transp: StreamTransport) {.async.} =
  let cstats = buildStatsSafe(eng)
  var node = newJObject()
  node["schema"] = statsToJson(cstats)
  node["more"] = %false
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc handleAdmin(eng: SharedEngine; command: string;
                 transp: StreamTransport) {.async.} =
  proc flushSettled(): bool =
    eng.kv.flushStartSeq() <= eng.kv.flushEndSeq()
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
        await writeResponseAsync(transp, @["e", "attr", "value", "t"], rows, true)
        rows.setLen(0)
    await writeResponseAsync(transp, @["e", "attr", "value", "t"], rows, false)
  else:
    let output = case command
      of "flush":
        kvstore.requestFlush(eng.kv)
        "ok: flush requested"
      of "flush-sync":
        # Wait async for any in-flight background flush, then arm one and
        # wait for it — the heavy work stays on the flush thread, never the
        # event loop.
        while not flushSettled():
          await sleepAsync(2.milliseconds)
        kvstore.requestFlush(eng.kv)
        while not flushSettled():
          await sleepAsync(2.milliseconds)
        "ok: flushed"
      of "status":
        "memtable: " & $eng.kv.memtableSize() & " bytes"
      of "memtable":
        $eng.kv.memtableSize()
      else:
        "unknown admin command: " & command
    var node = newJObject()
    node["output"] = %output
    node["more"] = %false
    await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

proc handleKv(eng: SharedEngine; req: Request; transp: StreamTransport) {.async.} =
  case req.kvOp
  of "put":
    kvPutSafe(eng, req.kvCf, req.kvKey, req.kvValue)
    await writeResponseAsync(transp, @[], @[], false)
  of "get":
    let val = kvGetSafe(eng, req.kvCf, req.kvKey)
    if val.isSome:
      await writeResponseAsync(transp, @[], @[@[SExpr(kind: sBytes, bytesval: val.get)]], false)
    else:
      await writeResponseAsync(transp, @[], @[], false)
  of "scan":
    let pairs = kvScanPairsSafe(eng, req.kvCf)
    var rows: seq[seq[SExpr]]
    for (key, value) in pairs:
      rows.add(@[
        SExpr(kind: sBytes, bytesval: key),
        SExpr(kind: sBytes, bytesval: value),
      ])
      if rows.len >= 100:
        await writeResponseAsync(transp, @["key", "value"], rows, true)
        rows.setLen(0)
    await writeResponseAsync(transp, @["key", "value"], rows, false)
  of "delete":
    kvDeleteSafe(eng, req.kvCf, req.kvKey)
    await writeResponseAsync(transp, @[], @[], false)
  else:
    await writeResponseAsync(transp, @[], @[], false, "unknown kv op: " & req.kvOp)

proc serveConnection*(eng: SharedEngine; transp: StreamTransport) {.
    async: (raises: []).} =
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

    var req: Request
    try:
      req = parseRequest(raw)
    except CatchableError as e:
      try:
        await transp.writeErrorAsync("parse error: " & e.msg)
      except CatchableError:
        break
      continue

    try:
      case req.kind
      of rkScheme: await execScheme(eng, req, transp)
      of rkSchema: await handleSchema(eng, transp)
      of rkAdmin: await handleAdmin(eng, req.command, transp)
      of rkKv: await handleKv(eng, req, transp)
    except CatchableError as e:
      try:
        await transp.writeErrorAsync(e.msg)
      except CatchableError:
        break
