import std/[options, nativesockets, posix, strutils, json]
import scheme, engine, eavt, kvstore
import stats
import msgpack4nim/msgpack2json
import shared_engine, protocol

proc dumpDatoms(eng: SharedEngine; fd: SocketHandle; command: string) {.gcsafe.}

proc execScheme(eng: SharedEngine; req: Request; fd: SocketHandle) {.gcsafe.} =
  let program = SchemeProgram(body: req.program)
  if req.mode != "query" and req.mode != "exec":
    writeResponse(fd, @[], @[], false, "unknown scheme mode: " & req.mode)
    return
  let tx = eng.store.eavt.allocateTAndWriteTx()
  if req.mode == "query":
    let proto = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let sess = newStreamingSession(proto)
    while true:
      let (rows, more) = sess.nextBatch(100)
      writeResponse(fd, @[], rows, more)
      if not more: break
  else:
    let session = newQuerySession(eng.store, program, req.params, tx, none[int64]())
    let r = executeProgram(session)
    if r.kind == sList and r.items.len >= 2 and r.items[0].kind == sSymbol and r.items[0].symval == "result":
      writeResponse(fd, @[], @[r.items[1..^1]], false)
    else:
      writeResponse(fd, @[], @[], false, "unexpected result: " & $r)

proc handleSchema(eng: SharedEngine; fd: SocketHandle) {.gcsafe.} =
  let cstats = eng.store.eavt.buildCompileStats()
  var node = newJObject()
  node["schema"] = statsToJson(cstats)
  node["more"] = %false
  writeMsg(fd, msgpack2json.fromJsonNode(node))

proc execQuery(eng: SharedEngine; req: Request; fd: SocketHandle) {.gcsafe.} =
  case req.kind
  of rkScheme:
    execScheme(eng, req, fd)

  of rkSchema:
    handleSchema(eng, fd)

  of rkAdmin:
    if req.command.startsWith("dump"):
      dumpDatoms(eng, fd, req.command)
    else:
      let output = case req.command
        of "flush":
          kvstore.requestFlush(eng.kv)
          "ok: flush requested"
        of "flush-sync":
          kvstore.flushSync(eng.kv)
          "ok: flushed"
        of "status":
          "memtable: " & $eng.kv.memtableSize() & " bytes"
        of "memtable":
          $eng.kv.memtableSize()
        else:
          "unknown admin command: " & req.command
      var node = newJObject()
      node["output"] = %output
      node["more"] = %false
      writeMsg(fd, msgpack2json.fromJsonNode(node))

  of rkKv:
    case req.kvOp
    of "put":
      eng.kv.putKv(req.kvCf, req.kvKey, req.kvValue)
      writeResponse(fd, @[], @[], false)
    of "get":
      let val = eng.kv.getKv(req.kvCf, req.kvKey)
      if val.isSome:
        writeResponse(fd, @[], @[@[SExpr(kind: sBytes, bytesval: val.get)]], false)
      else:
        writeResponse(fd, @[], @[], false)
    of "scan":
      let mc = eng.kv.openScanCursorKv(req.kvCf)
      var rows: seq[seq[SExpr]]
      while true:
        let kvp = mc.nextKv()
        if kvp.isNone: break
        let (key, value) = kvp.get
        rows.add(@[
          SExpr(kind: sBytes, bytesval: key),
          SExpr(kind: sBytes, bytesval: value),
        ])
        if rows.len >= 100:
          writeResponse(fd, @["key", "value"], rows, true)
          rows.setLen(0)
      writeResponse(fd, @["key", "value"], rows, false)
    of "delete":
      eng.kv.deleteKv(req.kvCf, req.kvKey)
      writeResponse(fd, @[], @[], false)
    else:
      writeResponse(fd, @[], @[], false, "unknown kv op: " & req.kvOp)

proc dumpDatoms(eng: SharedEngine; fd: SocketHandle; command: string) {.gcsafe.} =
  let parts = command.splitWhitespace()
  let index = if parts.len >= 2: parts[1].toUpperAscii()
             else: "EAVT"
  let cf = case index
    of "AEVT": 1
    of "AVET": 2
    of "VAET": 3
    else: 0

  var rows: seq[seq[SExpr]]
  for datom in eng.store.eavt.scanDatoms(cf):
    if datom.retracted: continue
    rows.add(@[
      SExpr(kind: sInt, ival: datom.e),
      SExpr(kind: sStr, sval: datom.attrName & "(" & $datom.a & ")"),
      datom.value,
      SExpr(kind: sInt, ival: datom.t),
    ])
    if rows.len >= 100:
      writeResponse(fd, @["e", "attr", "value", "t"], rows, true)
      rows.setLen(0)
  writeResponse(fd, @["e", "attr", "value", "t"], rows, false)

proc handleConnection*(eng: SharedEngine; fd: SocketHandle) {.gcsafe.} =
  while true:
    let raw = readMsg(fd)
    if raw.len == 0: break
    var req: Request
    try:
      req = parseRequest(raw)
    except CatchableError as e:
      writeResponse(fd, @[], @[], false, "parse error: " & e.msg)
      continue
    case req.kind
    of rkScheme, rkSchema, rkAdmin, rkKv:
      try:
        execQuery(eng, req, fd)
      except CatchableError as e:
        writeResponse(fd, @[], @[], false, e.msg)
