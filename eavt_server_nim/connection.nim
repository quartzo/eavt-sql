import std/[options, nativesockets, posix, locks, strutils, tables, json]
import ast, scheme, engine, hostfns, eavt, kvstore, keys, resolver
import frontend, parser as sql_parser, scheme_compile, datalog_ast, pattern
import translate, resolve as datalog_resolve, stats, planner_ast, planner
import msgpack4nim/msgpack2json
import shared_engine, protocol

proc lookupAttrId(e: EavtEngine; name: string): uint32 =
  eavt.lookupAttr(e, name).get(otherwise = 0)

proc dumpDatoms(eng: SharedEngine; fd: SocketHandle; command: string)

proc execQuery(eng: SharedEngine; req: Request; fd: SocketHandle) =
  case req.kind
  of rkSql:
    let stmt = sql_parser.parse(req.sql)
    let cstats = CompileStats(
      lookupAttr: proc(name: string): uint32 = lookupAttrId(eng.store.eavt, name),
      estimateIndexSize: proc(index: string, bound: openArray[uint64]): float64 = 10_000_000.0,
      partitionIdFor: proc(name: string): uint64 = eng.store.eavt.partitionIdFor(name).get(otherwise = 0),
      isRefAttr: proc(name: string): bool =
        let aid = lookupAttrId(eng.store.eavt, name)
        if aid == 0: false else: eng.store.eavt.valueTypeFor(aid).get(otherwise = 0) == 21'u32,
      isIndexedAttr: proc(name: string): bool = true,
    )
    let compiled = compileSql(stmt, cstats)
    let tx = eng.store.eavt.allocateTAndWriteTx()
    if compiled.isSelect:
      let proto = newQuerySession(eng.store, compiled.program, @[], tx, none[int64]())
      let sess = newStreamingSession(proto)
      while true:
        let (rows, more) = sess.nextBatch(100)
        writeResponse(fd, @[], rows, more)
        if not more: break
    else:
      let session = newQuerySession(eng.store, compiled.program, @[], tx, none[int64]())
      let r = executeProgram(session)
      if r.kind == sList and r.items.len >= 2 and r.items[0].kind == sSymbol and r.items[0].symval == "result":
        writeResponse(fd, @[], @[r.items[1..^1]], false)
      else:
        writeResponse(fd, @[], @[], false, "unexpected result: " & $r)

  of rkAdmin:
    if req.command.startsWith("dump"):
      dumpDatoms(eng, fd, req.command)
    else:
      let output = eng.withLock(proc (): string =
        case req.command
        of "flush":
          kvstore.flush(eng.kv)
          "ok: flushed"
        of "status":
          "memtable: " & $eng.kv.memtableSize() & " bytes"
        of "memtable":
          $eng.kv.memtableSize()
        else:
          "unknown admin command: " & req.command)
      var node = newJObject()
      node["output"] = %output
      node["more"] = %false
      writeMsg(fd, msgpack2json.fromJsonNode(node))

proc dumpDatoms(eng: SharedEngine; fd: SocketHandle; command: string) =
  let parts = command.splitWhitespace()
  let index = if parts.len >= 2: parts[1].toUpperAscii()
             else: "EAVT"
  let cf = case index
    of "AEVT": 1
    of "AVET": 2
    of "VAET": 3
    else: 0

  var cursor = eng.kv.openScanCursor(cf)
  var rows: seq[seq[SExpr]]
  var count = 0
  while count < 100_000:
    let keyOpt = cursor.next()
    if not isSome(keyOpt): break
    let key = keyOpt.get
    rows.add(@[SExpr(kind: sBytes, bytesval: key)])
    inc count
    if rows.len >= 100:
      writeResponse(fd, @["key"], rows, true)
      rows.setLen(0)
  writeResponse(fd, @["key"], rows, false)

proc handleConnection*(eng: SharedEngine; fd: SocketHandle) =
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
    of rkSql:
      try:
        acquire(eng.lock)
        execQuery(eng, req, fd)
        release(eng.lock)
      except CatchableError as e:
        release(eng.lock)
        writeResponse(fd, @[], @[], false, e.msg)
    of rkAdmin:
      try:
        acquire(eng.lock)
        execQuery(eng, req, fd)
        release(eng.lock)
      except CatchableError as e:
        release(eng.lock)
        writeResponse(fd, @[], @[], false, e.msg)
