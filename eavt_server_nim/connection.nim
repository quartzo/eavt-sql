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
      lookupAttr: proc(name: string): uint32 = lookupAttrId(eng.eavt, name),
      estimateIndexSize: proc(index: string, bound: openArray[uint64]): float64 = 10_000_000.0,
      partitionIdFor: proc(name: string): uint64 = eng.eavt.partitionIdFor(name).get(otherwise = 0),
      isRefAttr: proc(name: string): bool =
        let aid = lookupAttrId(eng.eavt, name)
        if aid == 0: false else: eng.eavt.valueTypeFor(aid).get(otherwise = 0) == 21'u32,
      isIndexedAttr: proc(name: string): bool = true,
    )
    let compiled = compileSql(stmt, cstats)
    let tx = eng.eavt.allocateTAndWriteTx()
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
  let index = if parts.len >= 2: parts[1].toUpperAscii() else: "EAVT"
  let cf = case index
    of "AEVT": 1
    of "AVET": 2
    of "VAET": 3
    else: 0

  var cursor = eng.kv.openScanCursor(cf)
  var rows: seq[seq[SExpr]]
  var totalIter = 0

  while totalIter < 1_000_000:
    inc totalIter
    let keyOpt = cursor.next()
    if not isSome(keyOpt): break
    let key = keyOpt.get
    if key.len < 20: continue

    let suffixRaw = beUint64(key, key.len - 8)
    let (t, retracted) = decodeSuffix(suffixRaw)
    if retracted: continue

    var eid: int64
    var aid: uint32
    case cf
    of 0:
      eid = cast[int64](beUint64(key, 0))
      aid = beUint32(key, 8)
    of 1:
      aid = beUint32(key, 0)
      eid = cast[int64](beUint64(key, 4))
    of 2:
      aid = beUint32(key, 0)
      eid = cast[int64](beUint64(key, key.len - 16))
    of 3:
      aid = beUint32(key, key.len - 16)
      eid = cast[int64](beUint64(key, key.len - 16 + 4))
    else: continue

    let vtOpt = eng.eavt.valueTypeFor(aid)
    let vt = vtOpt.get(otherwise = DbTypeLong)
    let vStart = case cf
      of 0: 12
      of 1: 12
      of 2: 4
      of 3: 0
      else: 12
    let vEnd = case cf
      of 0: key.len - 8
      of 1: key.len - 8
      of 2: key.len - 16
      of 3: key.len - 20
      else: key.len - 8
    if vEnd <= vStart: continue

    let rawValue = key[vStart..<vEnd]
    var valSexpr: SExpr

    case vt
    of DbTypeRef:
      if rawValue.len >= 8: valSexpr = SExpr(kind: sInt, ival: cast[int64](beUint64(rawValue, 0)))
      else: valSexpr = SExpr(kind: sInt, ival: 0)
    of DbTypeLong, DbTypeInstant:
      if rawValue.len >= 8: valSexpr = SExpr(kind: sInt, ival: decodeInt64(beUint64(rawValue, 0)))
      else: valSexpr = SExpr(kind: sInt, ival: 0)
    of DbTypeBoolean:
      if rawValue.len >= 8: valSexpr = SExpr(kind: sBool, bval: decodeInt64(beUint64(rawValue, 0)) != 0)
      else: valSexpr = SExpr(kind: sBool, bval: false)
    of DbTypeFloat:
      if rawValue.len >= 8: valSexpr = SExpr(kind: sFloat, fval: decodeFloat64(beUint64(rawValue, 0)))
      else: valSexpr = SExpr(kind: sFloat, fval: 0.0)
    of DbTypeString, DbTypeKeyword:
      valSexpr = SExpr(kind: sBytes, bytesval: rawValue)
    of DbTypeBytes, DbTypeBlob:
      valSexpr = SExpr(kind: sBytes, bytesval: rawValue)
    else:
      valSexpr = SExpr(kind: sBytes, bytesval: rawValue)

    let attrName = eng.eavt.attrName(aid)
    rows.add(@[
      SExpr(kind: sInt, ival: eid),
      SExpr(kind: sStr, sval: attrName),
      valSexpr,
      SExpr(kind: sInt, ival: cast[int64](t)),
    ])
    if rows.len >= 100:
      writeResponse(fd, @["e", "attr", "value", "t"], rows, true)
      rows.setLen(0)

  writeResponse(fd, @["e", "attr", "value", "t"], rows, false)

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
