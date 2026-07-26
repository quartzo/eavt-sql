import std/[options, nativesockets, posix, strutils, json]
import scheme, engine, eavt, kvstore
import frontend, parser as sql_parser
import planner_ast
import msgpack4nim/msgpack2json
import shared_engine, protocol

proc dumpDatoms(eng: SharedEngine; fd: SocketHandle; command: string) {.gcsafe.}

proc execQuery(eng: SharedEngine; req: Request; fd: SocketHandle) {.gcsafe.} =
  case req.kind
  of rkSql:
    let stmt = sql_parser.parse(req.sql)
    let cstats = eng.store.eavt.buildCompileStats()
    let compiled = compileSql(stmt, cstats)
    if compiled.isExplain:
      var outStr = ""
      # Plan section
      if compiled.iterPlans.len > 0:
        outStr.add("Plan:\n")
        let histTag = if compiled.history: " (history)" else: ""
        let existsTag = if compiled.existsMode: " (exists)" else: ""
        outStr.add("  Join order: [" & compiled.orderedVars.join(", ") & "]" & histTag & existsTag & "\n")
        for i, ip in compiled.iterPlans:
          outStr.add("  p" & $i & " @ " & ip.indexName & "\n")
          for posIdx, pos in ip.idxOrder:
            let spec = ip.specs[posIdx]
            var varLabel = ""
            for (d, p) in ip.varDepths:
              if p == pos:
                varLabel = " [depth " & $d & "]"
                break
            case spec.kind
            of skVar:
              outStr.add("    " & pos & " = ?" & spec.varName & varLabel & "\n")
            of skBound:
              if spec.boundVal != 0:
                outStr.add("    " & pos & " = #" & $spec.boundVal & varLabel & "\n")
              else:
                outStr.add("    " & pos & " = _" & varLabel & "\n")
            of skBoundAttr:
              outStr.add("    " & pos & " = attr(id=" & $spec.attrId & ")" & varLabel & "\n")
            of skBoundValue:
              if spec.bvStr != "":
                outStr.add("    " & pos & " = \"" & spec.bvStr & "\"" & varLabel & "\n")
              elif spec.bvFloat != 0:
                outStr.add("    " & pos & " = " & $spec.bvFloat & varLabel & "\n")
              else:
                outStr.add("    " & pos & " = " & $spec.bvInt & varLabel & "\n")
            of skBoundParam:
              outStr.add("    " & pos & " = %" & $spec.paramIdx & varLabel & "\n")
            of skBoundExpr:
              outStr.add("    " & pos & " = expr(" & spec.bvExprRepr & ")" & varLabel & "\n")
        outStr.add("\n")
      # Traces
      for t in compiled.traces:
        outStr.add($t & "\n")
      outStr.add("\n" & writeSchemePretty(compiled.program))
      writeResponse(fd, @[], @[@[SExpr(kind: sStr, sval: outStr)]], false)
      return
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
    of rkSql:
      try:
        execQuery(eng, req, fd)
      except CatchableError as e:
        writeResponse(fd, @[], @[], false, e.msg)
    of rkAdmin:
      try:
        execQuery(eng, req, fd)
      except CatchableError as e:
        writeResponse(fd, @[], @[], false, e.msg)
