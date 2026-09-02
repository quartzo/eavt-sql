## EAVT Datalog REPL (pure Nim, UDS client).
## Queries: Datalog EDN vectors
##          e.g. [:find ?name :where [?e :person/name ?name]];
## Writes:  EDN tx-data vectors
##          e.g. [[:db/add -1 :person/name "Alice"]];
## Dot commands mirror the original SQL REPL (.help/.flush/.status/...).

import std/[strutils, strformat, os, terminal, json]
import scheme, edn
import eavt_transactor_nim/client
import linenoise

proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc lnPrompt(prompt: cstring): cstring {.cdecl, importc: "linenoise".}

var gClient: EavtClient

# ── helpers ──────────────────────────────────────────────────────────

proc parseValue*(raw: string): string =
  try:
    let node = parseJson(raw)
    case node.kind
    of JString: return node.getStr
    of JInt: return $node.getInt()
    of JFloat: return $node.getFloat()
    of JBool: return $node.getBool()
    else: return raw
  except JsonParsingError:
    # Not JSON — the raw text IS the value. Grammar dispatch, not an error.
    return raw

proc bracketDepth(stmt: string): int =
  var d = 0
  var inStr = false
  var esc = false
  for ch in stmt:
    if esc: esc = false; continue
    if inStr:
      if ch == '\\': esc = true
      elif ch == '"': inStr = false
      continue
    if ch == '"': inStr = true
    elif ch == '[': inc d
    elif ch == ']': dec d
  d

proc isCompleteStatement(stmt: string): bool =
  stmt.startsWith("[") and bracketDepth(stmt) == 0

proc isTxData(stmt: string): bool =
  ":db/add" in stmt or ":db/retract" in stmt

# ── command handlers ─────────────────────────────────────────────────

template catchDisconnect(body: untyped) =
  try: body
  except ServerDisconnectedError: raise
  except CatchableError as e: stderr.writeLine "Error: ", e.msg

proc executeDatalog(query: string) =
  catchDisconnect:
    for chunk in gClient.datalog(query):
      if chunk.error.len > 0:
        stderr.writeLine "Error: ", chunk.error
        return
      for row in chunk.rows:
        var parts: seq[string]
        for v in row: parts.add(parseValue(v))
        echo parts.join("\t")

proc sexprToJson*(e: SExpr): JsonNode =
  case e.kind
  of sKeyword: %(e.kwval)
  of sInt: %(e.ival)
  of sFloat: %(e.fval)
  of sStr: %e.sval
  of sBool: %e.bval
  of sVoid: newJNull()
  of sList:
    var arr = newJArray()
    for item in e.items: arr.add(sexprToJson(item))
    arr
  else:
    raise newException(ValueError, "cannot encode " & $e.kind & " as tx-data")

proc executeTx(txdataText: string) =
  catchDisconnect:
    var ops: seq[SExpr]
    try:
      ops = readEdnVector(txdataText)
    except EdnError as e:
      stderr.writeLine "Error: EDN parse: ", e.msg
      return
    var txdata = newJArray()
    for op in ops:
      txdata.add(sexprToJson(op))
    echo gClient.txSExpr(ops)

proc cmdFlush() =
  catchDisconnect:
    let r = gClient.admin("flush")
    echo r

proc cmdFlushSync() =
  catchDisconnect:
    let r = gClient.admin("flush-sync")
    echo r

proc cmdGc(dryRun: bool) =
  catchDisconnect:
    let r = gClient.admin(if dryRun: "gc-dry" else: "gc")
    echo r

proc cmdStatus() =
  catchDisconnect:
    let r = gClient.admin("status")
    echo r

proc cmdTree() =
  catchDisconnect:
    let r = gClient.admin("tree")
    echo r

proc cmdMemtable() =
  catchDisconnect:
    let r = gClient.admin("memtable")
    echo r

proc cmdDump(index: string) =
  catchDisconnect:
    for chunk in gClient.dump(index):
      if chunk.error.len > 0:
        stderr.writeLine "Error: ", chunk.error
        return
      for row in chunk.rows:
        var parts: seq[string]
        for v in row: parts.add(parseValue(v))
        echo parts.join("\t")

proc cmdKvPut(cf: int; key, value: string) =
  catchDisconnect:
    echo gClient.kvPut(cf, key, value)

proc cmdKvGet(cf: int; key: string) =
  catchDisconnect:
    echo gClient.kvGet(cf, key)

proc cmdKvScan(cf: int) =
  catchDisconnect:
    for chunk in gClient.kvScan(cf):
      if chunk.error.len > 0:
        stderr.writeLine "Error: ", chunk.error
        return
      for row in chunk.rows:
        echo row.join("\t")

proc cmdKvDelete(cf: int; key: string) =
  catchDisconnect:
    echo gClient.kvDelete(cf, key)

# ── dot dispatcher ───────────────────────────────────────────────────

const HelpText = """
Dot commands (no semicolon):
  .quit, .exit           Exit the REPL
  .help                  Show this help
  .flush                 Request background flush (returns immediately)
  .flush-sync            Flush and wait for completion
  .gc                    Run blob GC now (report roots/blobs removed)
  .gc-dry                Dry-run GC (report only, removes nothing)
  .status                Database overview
  .tree                  Per-column-family stats
  .memtable              MemTable contents and sizes
  .dump [EAVT|AEVT|...|CF]  Dump active datoms (or KV CF if number >= 10)
  .kv-put <cf> <key> <value>  Put key-value pair (CFs >= 10)
  .kv-get <cf> <key>          Get value by key
  .kv-delete <cf> <key>       Delete key
  .kv-scan <cf>               Scan all pairs in a CF

Datalog queries end with ;   e.g.  [:find ?name :where [?e :person/name ?name]];
"""

proc handleDot(line: string): bool =
  let parts = splitWhitespace(line)
  let cmd = parts[0].toLowerAscii()
  let args = if parts.len > 1: parts[1 .. ^1] else: @[]
  case cmd
  of ".quit", ".exit":
    return true
  of ".help":
    echo HelpText
  of ".flush":
    cmdFlush()
  of ".flush-sync":
    cmdFlushSync()
  of ".gc":
    cmdGc(false)
  of ".gc-dry":
    cmdGc(true)
  of ".status":
    cmdStatus()
  of ".tree":
    cmdTree()
  of ".memtable":
    cmdMemtable()
  of ".dump":
    let arg = if args.len > 0: args[0] else: "EAVT"
    let cfNum = try: parseInt(arg) except: -1
    if cfNum >= 10:
      cmdKvScan(cfNum)
    else:
      let index = arg.toUpperAscii()
      const valid = ["EAVT", "AEVT", "AVET", "VAET"]
      if index notin valid:
        stderr.writeLine &"Error: index must be one of {valid.join(\", \")} or a CF number >= 10"
        return false
      cmdDump(index)
  of ".kv-put":
    if args.len < 3:
      stderr.writeLine "Usage: .kv-put <cf> <key> <value>"
      return false
    let cf = try: parseInt(args[0]) except: -1
    if cf < 10:
      stderr.writeLine "Error: cf must be >= 10 for key-value operations"
      return false
    cmdKvPut(cf, args[1], args[2])
  of ".kv-get":
    if args.len < 2:
      stderr.writeLine "Usage: .kv-get <cf> <key>"
      return false
    let cf = try: parseInt(args[0]) except: -1
    if cf < 10:
      stderr.writeLine "Error: cf must be >= 10 for key-value operations"
      return false
    cmdKvGet(cf, args[1])
  of ".kv-scan":
    if args.len < 1:
      stderr.writeLine "Usage: .kv-scan <cf>"
      return false
    let cf = try: parseInt(args[0]) except: -1
    if cf < 10:
      stderr.writeLine "Error: cf must be >= 10 for key-value operations"
      return false
    cmdKvScan(cf)
  of ".kv-delete":
    if args.len < 2:
      stderr.writeLine "Usage: .kv-delete <cf> <key>"
      return false
    let cf = try: parseInt(args[0]) except: -1
    if cf < 10:
      stderr.writeLine "Error: cf must be >= 10 for key-value operations"
      return false
    cmdKvDelete(cf, args[1])
  else:
    stderr.writeLine &"Unknown command: {line}"
  return false

# ── REPL loop ────────────────────────────────────────────────────────

proc readInput(prompt: string, isTTY: bool, line: var string): bool =
  if isTTY:
    let cs = lnPrompt(prompt.cstring)
    if cs.isNil: return false
    line = $cs
    cFree(cast[pointer](cs))
    result = true
  else:
    stdout.write(prompt)
    stdout.flushFile()
    result = stdin.readLine(line)

proc isDatalogQuery(stmt: string): bool =
  ## A Datalog query starts with [:find — EDN vector with :find section.
  stmt.startsWith("[:find")

proc run*(sockPath: string = getSocketPath()) =
  if not gClient.connect(sockPath):
    stderr.writeLine "Error: cannot connect to ", sockPath
    quit(1)

  echo &"eavt datalog repl: socket={sockPath}"
  echo "Queries: [:find ?v :where [?e :attr ?v]];"
  echo "Type .help for commands, .quit to exit"
  echo ""

  let isTTY = stdin.isatty
  let histFile = getHomeDir() / ".eavt_datalog_history"
  if isTTY: discard historyLoad(histFile.cstring)

  var accumulated = ""
  while true:
    let prompt = if accumulated.len == 0: "eavt-dl> " else: "       -> "
    var line: string
    if not readInput(prompt, isTTY, line):
      echo ""
      break

    let stripped = line.strip()

    if accumulated.len == 0 and stripped.startsWith('.'):
      if isTTY: discard historyAdd(line.cstring)
      try:
        let quit = handleDot(stripped)
        if quit: break
      except ServerDisconnectedError as e:
        stderr.writeLine "\nError: ", e.msg
        return
      except CatchableError as e:
        stderr.writeLine "Error: ", e.msg
      continue

    if stripped.startsWith("--"):
      continue

    accumulated.add(line)
    accumulated.add(' ')

    let trimmed = accumulated.strip()
    if trimmed.len > 0 and isCompleteStatement(trimmed):
      if isTTY: discard historyAdd(trimmed.cstring)
      if isTxData(trimmed):
        executeTx(trimmed)
      else:
        executeDatalog(trimmed)
      accumulated = ""

  if isTTY: discard historySave(histFile.cstring)
  gClient.close()
