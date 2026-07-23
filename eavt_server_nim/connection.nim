import std/[json, options, nativesockets, posix, locks]
import ast, scheme, engine, hostfns, eavt, kvstore, translate, resolve, stats, planner_ast, planner
import frontend, parser as sql_parser, scheme_compile, datalog_ast, pattern
import shared_engine, protocol

proc lookupAttrId(e: EavtEngine; name: string): uint32 =
  eavt.lookupAttr(e, name).get(otherwise = 0)

proc execQuery(eng: SharedEngine; req: Request; fd: SocketHandle) =
  case req.kind
  of rkSql:
    let stmt = sql_parser.parse(req.sql)
    let cstats = CompileStats(
      lookupAttr: proc(name: string): uint32 =
        lookupAttrId(eng.eavt, name),
      estimateIndexSize: proc(index: string, bound: openArray[uint64]): float64 =
        10_000_000.0,
      partitionIdFor: proc(name: string): uint64 =
        eng.eavt.partitionIdFor(name).get(otherwise = 0),
      isRefAttr: proc(name: string): bool =
        let aid = lookupAttrId(eng.eavt, name)
        if aid == 0: false
        else: eng.eavt.valueTypeFor(aid).get(otherwise = 0) == 21'u32,
      isIndexedAttr: proc(name: string): bool = true,
    )
    let compiled = compileSql(stmt, cstats)
    let tx = eng.eavt.allocateTAndWriteTx()
    if compiled.isSelect:
      let proto = newQuerySession(eng.store, compiled.program, @[], tx, none[int64]())
      let sess = newStreamingSession(proto)
      var columns: seq[string]
      while true:
        let (rows, more) = sess.nextBatch(100)
        var stringRows: seq[seq[string]]
        for row in rows:
          var srow: seq[string]
          for val in row:
            srow.add($val)
          stringRows.add(srow)
        writeSqlChunk(fd, columns, stringRows, more)
        if not more: break
    else:
      let session = newQuerySession(eng.store, compiled.program, @[], tx, none[int64]())
      let r = executeProgram(session)
      if r.kind == sList and r.items.len >= 2 and r.items[0].kind == sSymbol and r.items[0].symval == "result":
        var rows: seq[seq[string]]
        var srow: seq[string]
        for i in 1..<r.items.len:
          srow.add($r.items[i])
        rows.add(srow)
        writeSqlChunk(fd, @[], rows, false)
      else:
        writeSqlChunk(fd, @[], @[], false, "unexpected result: " & $r)

  of rkAdmin:
    let output = eng.withLock(proc (): string =
      case req.command
      of "flush":
        kvstore.flush(eng.kv)
        "ok: flushed"
      of "status":
        "memtable: " & $eng.kv.memtableSize() & " bytes"
      of "tree":
        "tree command not implemented"
      of "memtable":
        $eng.kv.memtableSize()
      else:
        "unknown admin command: " & req.command
    )
    writeAdminResponse(fd, output)

proc handleConnection*(eng: SharedEngine; fd: SocketHandle) =
  while true:
    let raw = readMsg(fd)
    if raw.len == 0: break
    var req: Request
    try:
      req = parseRequest(raw)
    except CatchableError as e:
      writeError(fd, "parse error: " & e.msg)
      continue

    case req.kind
    of rkSql:
      try:
        acquire(eng.lock)
        execQuery(eng, req, fd)
        release(eng.lock)
      except CatchableError as e:
        release(eng.lock)
        writeError(fd, e.msg)
    of rkAdmin:
      try:
        execQuery(eng, req, fd)
      except CatchableError as e:
        writeError(fd, e.msg)
