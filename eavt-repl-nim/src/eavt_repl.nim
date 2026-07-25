## Entry point: optional <SOCKET_PATH> and run the REPL.
import std/os
import eavt_server_nim/client
import repl

proc main =
  let args = commandLineParams()
  let sockPath = if args.len >= 1: args[0] else: getSocketPath()
  try:
    run(sockPath)
  except CatchableError as e:
    stderr.writeLine "Error: ", e.msg
    quit 1

main()
