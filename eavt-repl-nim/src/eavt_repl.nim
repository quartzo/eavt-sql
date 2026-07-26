## Entry point: optional <SOCKET_PATH> and run the REPL.
## Supports:
##   --help, -h              Show usage
##   -e "cmd1;cmd2;..."     Execute commands separated by ; and exit
##   --execute "cmd1;..."    Same as -e
##   Pipe mode               If stdin is not a TTY, read and execute from stdin
##   Interactive mode        Default REPL (no args, stdin is TTY)
import std/[os, strutils, terminal]
import eavt_server_nim/client
import repl

const UsageText = """Usage: eavt-sql-cli [OPTIONS] [SOCKET_PATH]

Options:
  --help, -h              Show this help
  -e, --execute "cmds"    Execute semicolon-separated commands and exit
  SOCKET_PATH             Unix socket path (default: auto-detect)

Modes:
  Interactive:    eavt-sql-cli                   (REPL with history)
  Execute:        eavt-sql-cli -e "SELECT 1;"   (run and exit)
  Pipe:           echo "SELECT 1;" | eavt-sql-cli (read stdin, no prompt)
"""

proc executeCommands(client: var EavtClient; commands: string): int =
  ## Execute semicolon-separated commands. Returns 0 on success, 1 on error.
  for line in commands.split(';'):
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("--"):
      continue
    if stripped.startsWith('.'):
      # dot commands handled inline
      case stripped.toLowerAscii()
      of ".quit", ".exit":
        return 0
      of ".flush":
        let r = client.admin("flush")
        echo r
      of ".flush-sync":
        let r = client.admin("flush-sync")
        echo r
      of ".status":
        let r = client.admin("status")
        echo r
      of ".memtable":
        let r = client.admin("memtable")
        echo r
      of ".tree":
        let r = client.admin("tree")
        echo r
      of ".help":
        echo UsageText
      else:
        if stripped.startsWith(".dump"):
          let parts = stripped.splitWhitespace()
          let index = if parts.len > 1: parts[1].toUpperAscii() else: "EAVT"
          for chunk in client.dump(index):
            if chunk.error.len > 0:
              stderr.writeLine "Error: ", chunk.error
              return 1
            for row in chunk.rows:
              echo row.join("\t")
        else:
          stderr.writeLine "Unknown command: ", stripped
          return 1
    else:
      # SQL command
      for chunk in client.exec(stripped):
        if chunk.error.len > 0:
          stderr.writeLine "Error: ", chunk.error
          return 1
        for row in chunk.rows:
          var parts: seq[string]
          for v in row: parts.add(parseValue(v))
          echo parts.join("\t")
  return 0

proc main =
  let args = commandLineParams()

  # Parse options
  var sockPath = ""
  var execCmd = ""
  var argIdx = 0

  while argIdx < args.len:
    let arg = args[argIdx]
    if arg == "--help" or arg == "-h":
      echo UsageText
      quit 0
    elif arg == "-e" or arg == "--execute":
      if argIdx + 1 >= args.len:
        stderr.writeLine "Error: ", arg, " requires an argument"
        quit 1
      execCmd = args[argIdx + 1]
      argIdx += 2
    elif arg.startsWith("-"):
      stderr.writeLine "Unknown option: ", arg
      stderr.writeLine UsageText
      quit 1
    else:
      sockPath = arg
      argIdx += 1

  if sockPath.len == 0:
    sockPath = getSocketPath()

  var client: EavtClient
  if not client.connect(sockPath):
    stderr.writeLine "Error: cannot connect to ", sockPath
    quit 1

  # -e mode: execute commands and exit
  if execCmd.len > 0:
    let rc = client.executeCommands(execCmd)
    client.close()
    quit rc

  # Pipe mode: stdin is not a TTY → read and execute from stdin
  if not stdin.isatty:
    let rc = client.executeCommands(stdin.readAll())
    client.close()
    quit rc

  # Interactive mode
  try:
    run(sockPath)
  except CatchableError as e:
    stderr.writeLine "Error: ", e.msg
    quit 1

main()
