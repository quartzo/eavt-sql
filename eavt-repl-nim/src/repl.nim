## EAVT SQL REPL (pure Nim, gRPC client).
## Mirrors eavt-cli/src/main.rs: multi-line `;`-terminated statements, the
## .help/.flush/.status/.tree/.memtable/.dump dot-commands, server-streaming
## Sql + Dump, and a persistent ~/.eavt_sql_history.

import std/[asyncdispatch, strutils, strformat, os, terminal]
import grpc
import linenoise
import eavt_pb

# linenoise returns a malloc'd buffer; release it with libc free.
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
# The linenoise pkg's `linenoisePrompt` symbol fails to resolve on Nim 2.2
# (importc name "linenoise"); redeclaring it here works around it. The C
# object still comes from the linenoise pkg via its {.compile.} pragma.
proc lnPrompt(prompt: cstring): cstring {.cdecl, importc: "linenoise".}

type EavtClient = ClientContext

proc newEavtClient(host: string, port: int): EavtClient =
  ## Insecure (h2c) client, matches tonic's plaintext http:// listener.
  newClient(host, Port(port), ssl = false)

# ---------------------------------------------------------------- helpers

proc errDetail(e: ref CatchableError): string =
  ## Prefer the gRPC status message (server-side detail) when available;
  ## otherwise fall back to the exception .msg. Works for GrpcFailure
  ## (RPC status) and HyperxError (connection-level) alike.
  if e of GrpcFailure:
    let g = cast[ref GrpcFailure](e)
    if g.message.len > 0: return g.message
  return e.msg

proc fmtSize(n: uint64): string =
  if n < 1024: &"{n} B"
  elif n < 1024'u64 * 1024: formatFloat(n.float / 1024.0, ffDecimal, 1) & " KB"
  elif n < 1024'u64 * 1024 * 1024:
    formatFloat(n.float / (1024.0 * 1024.0), ffDecimal, 1) & " MB"
  else:
    formatFloat(n.float / (1024.0 * 1024.0 * 1024.0), ffDecimal, 1) & " GB"

proc protoValueToStr(v: Value): string =
  case v.kind.kind
  of ValueKindKind.int_val: $v.kind.int_val
  of ValueKindKind.float_val: formatFloat(v.kind.float_val, ffDecimal, 6)
  of ValueKindKind.text_val: v.kind.text_val
  of ValueKindKind.bool_val: $v.kind.bool_val
  of ValueKindKind.bytes_val: toHex(cast[string](v.kind.bytes_val)).toLowerAscii()
  of ValueKindKind.ref_val: $v.kind.ref_val
  of ValueKindKind.notSet: "null"

# ---------------------------------------------------------------- RPC handlers
# All sendMessage calls pass finish=true (half-close, END_STREAM). tonic/hyper
# won't dispatch a unary/server-streaming request until the client half-closes,
# so recvMessage would deadlock without it. (nim-grpc's own server is lenient;
# tonic is not.)

proc executeSql(client: EavtClient, sql: string) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceSqlPath)
    with s:
      await s.sendMessage(SqlRequest(query: sql), finish = true)
      whileRecvMessages s:
        let row = await s.recvMessage(SqlRow)
        var parts: seq[string] = @[]
        for v in row.values: parts.add(protoValueToStr(v))
        echo parts.join("\t")
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

proc cmdFlush(client: EavtClient) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceFlushPath)
    with s:
      await s.sendMessage(FlushRequest(), finish = true)
      let r = await s.recvMessage(FlushResponse)
      echo &"Flushed: MemTable {fmtSize(r.memtable_before)} -> {fmtSize(r.memtable_after)}, " &
           &"WAL {fmtSize(r.wal_before)} -> {fmtSize(r.wal_after)}"
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

proc cmdStatus(client: EavtClient) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceStatusPath)
    with s:
      await s.sendMessage(StatusRequest(), finish = true)
      let r = await s.recvMessage(StatusResponse)
      echo &"Database:     {r.db_path}"
      echo &"Storage mode: {r.storage_mode}"
      echo &"Disk usage:   {fmtSize(r.disk_usage)}"
      echo &"SST size:     {fmtSize(r.sst_size)}"
      echo &"Live data:    {fmtSize(r.live_data)}"
      echo &"MemTable:     {fmtSize(r.memtable_size)}"
      echo &"WAL:          {fmtSize(r.wal_size)}"
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

proc cmdTree(client: EavtClient) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceTreePath)
    with s:
      await s.sendMessage(TreeRequest(), finish = true)
      let r = await s.recvMessage(TreeResponse)
      for cf in r.cfs:
        echo "=== ", cf.name, " ==="
        echo "  Est. keys:    ", cf.num_keys
        echo "  Live size:    ", fmtSize(cf.live_size)
        echo "  SST size:     ", fmtSize(cf.sst_size)
        echo "  MemTable:     ", fmtSize(cf.memtable_size)
        echo ""
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

proc cmdMemtable(client: EavtClient) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceMemtablePath)
    with s:
      await s.sendMessage(MemtableRequest(), finish = true)
      let r = await s.recvMessage(MemtableResponse)
      echo &"MemTable: {fmtSize(r.memtable_size)}   WAL: {fmtSize(r.wal_size)}"
      echo ""
      echo alignLeft("CF", 8) & " " & align("Count", 10)
      echo "-".repeat(20)
      for cf in r.cfs:
        echo alignLeft(cf.name, 8) & " " & align($cf.count, 10)
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

proc cmdDump(client: EavtClient, index: string) {.async.} =
  try:
    let s = client.newGrpcStream(EavtServiceDumpPath)
    with s:
      await s.sendMessage(DumpRequest(index: index), finish = true)
      var count = 0
      whileRecvMessages s:
        let d = await s.recvMessage(DatomRow)
        echo &"{d.e}\t{d.attr}\t{protoValueToStr(d.value)}\t{d.t}"
        inc count
      stderr.writeLine &"-- {count} datoms"
  except CatchableError as e:
    stderr.writeLine "Error: ", errDetail(e)

# ---------------------------------------------------------------- dot dispatcher

const HelpText = """
Dot commands (no semicolon):
  .quit, .exit           Exit the REPL
  .help                  Show this help
  .flush                 Flush MemTable to disk
  .status                Database overview
  .tree                  Per-column-family stats
  .memtable              MemTable contents and sizes
  .dump [EAVT|AEVT|...]  Dump active datoms

SQL statements must end with ;"""

proc handleDot(client: EavtClient, line: string): Future[bool] {.async.} =
  let parts = splitWhitespace(line)
  let cmd = parts[0].toLowerAscii()
  let args = if parts.len > 1: parts[1 .. ^1] else: @[]
  case cmd
  of ".quit", ".exit":
    return true
  of ".help":
    echo HelpText
  of ".flush":
    await cmdFlush(client)
  of ".status":
    await cmdStatus(client)
  of ".tree":
    await cmdTree(client)
  of ".memtable":
    await cmdMemtable(client)
  of ".dump":
    let index = if args.len > 0: args[0].toUpperAscii() else: "EAVT"
    const valid = ["EAVT", "AEVT", "AVET", "VAET"]
    if index notin valid:
      stderr.writeLine &"Error: index must be one of {valid.join(\", \")}"
      return false
    await cmdDump(client, index)
  else:
    stderr.writeLine &"Unknown command: {line}"
  return false

# ---------------------------------------------------------------- REPL loop

# Read a line, echoing the prompt. Uses linenoise on a TTY (arrows, history
# navigation); falls back to plain stdin readLine when input is piped/scripted
# (linenoise blocks on non-TTY stdin). Returns false on EOF/Ctrl-D.
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

proc run*(host: string, port: int) {.async.} =
  var client = newEavtClient(host, port)
  with client:
    echo &"eavt-sql repl: server={host}:{port}"
    echo "Type .help for commands, .quit to exit"
    echo ""

    let isTTY = stdin.isatty
    let histFile = getHomeDir() / ".eavt_sql_history"
    if isTTY: discard historyLoad(histFile.cstring)

    var accumulated = ""
    while true:
      let prompt = if accumulated.len == 0: "eavt-sql> " else: "       -> "
      var line: string
      if not readInput(prompt, isTTY, line):  # EOF / Ctrl-D
        echo ""
        break

      let stripped = line.strip()

      if accumulated.len == 0 and stripped.startsWith('.'):
        if isTTY: discard historyAdd(line.cstring)
        try:
          let quit = await handleDot(client, stripped)
          if quit: break
        except CatchableError as e:
          stderr.writeLine "Error: ", errDetail(e)
        continue

      accumulated.add(line)
      accumulated.add(' ')

      while true:
        let semiPos = accumulated.find(';')
        if semiPos < 0: break
        let stmt = accumulated[0 ..< semiPos].strip()
        accumulated = accumulated[semiPos + 1 .. ^1].strip(leading = true)
        if stmt.len == 0 or stmt.startsWith("--"):
          continue
        if isTTY: discard historyAdd((stmt & ";").cstring)
        try:
          await executeSql(client, stmt)
        except CatchableError as e:
          stderr.writeLine "Error: ", errDetail(e)

      let trimmed = accumulated.strip()
      if trimmed.len > 0 and not trimmed.startsWith("--"):
        continue
      accumulated = ""

    if isTTY: discard historySave(histFile.cstring)
