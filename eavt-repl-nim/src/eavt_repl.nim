## Entry point: parse <SERVER> (host:port) and run the REPL.
import std/[os, strutils, strformat, asyncdispatch]
import repl

proc parseServer(s: string): tuple[host: string, port: int] =
  let idx = s.rfind(':')
  if idx <= 0:
    stderr.writeLine &"Error: invalid server address '{s}' (expected host:port)"
    quit 1
  let portStr = s[idx + 1 .. ^1]
  let port = try: parseInt(portStr)
             except ValueError:
               stderr.writeLine &"Error: invalid port '{portStr}'"
               quit 1
  if port < 1 or port > 65535:
    stderr.writeLine &"Error: port out of range: {port}"
    quit 1
  (s[0 ..< idx], port)

proc main =
  let args = commandLineParams()
  if args.len != 1:
    stderr.writeLine "Usage: eavt-repl-nim <SERVER>   (e.g. localhost:50051)"
    quit 1
  let (host, port) = parseServer(args[0])
  # Startup connection failure (server down): waitFor re-raises it; print a
  # clean message and exit non-zero. Per-command errors are caught inside the
  # REPL loop (resilient mid-session, mirrors the Rust client).
  try:
    waitFor(run(host, port))
  except CatchableError as e:
    stderr.writeLine "Error: ", e.msg
    quit 1

main()
