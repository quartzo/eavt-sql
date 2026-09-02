## Entry point: optional <SOCKET_PATH> and run the REPL.
## Supports:
##   --help, -h              Show usage
##   -e "cmd"               Execute Datalog query and exit
##   --execute "cmd"         Same as -e
##   Pipe mode               If stdin is not a TTY, read and execute from stdin
##   Interactive mode        Default REPL (no args, stdin is TTY)
import std/[os, strutils, terminal, json]
import scheme, edn
import eavt_transactor_nim/client
import repl

const UsageText = """Usage: eavt-sql-cli [OPTIONS] [SOCKET_PATH]

Options:
  --help, -h              Show this help
  -e, --execute "query"   Execute a Datalog query and exit
  SOCKET_PATH             Unix socket path (default: auto-detect)

Modes:
  Interactive:    eavt-sql-cli                   (REPL with history)
  Execute:        eavt-sql-cli -e "[:find ?v :where [_ :dummy/x ?v]]"   (run and exit)
  Pipe:           echo "[:find ?v :where [?e :attr ?v]]" | eavt-sql-cli (read stdin, no prompt)
"""

proc main =
  let args = commandLineParams()

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

  # All modes go through run() which handles routing (datalog/tx/dot commands)
  try:
    run(sockPath)
  except CatchableError as e:
    stderr.writeLine "Error: ", e.msg
    quit 1

main()
