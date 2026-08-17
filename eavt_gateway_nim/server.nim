import std/[os, json]
import chronos
import msgpack4nim/msgpack2json
import eavt_server_nim/client except connect, close
import shared, connection

proc gatewayCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  var gw = cast[GatewayState](server.udata)
  await serveGatewayConnection(gw, transp)

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt.sock"

proc main() {.async.} =
  var sockPath = getSocketPath()
  var downstream = downstreamSocketPath()
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]
      inc i
    elif args[i] == "--downstream-path" and i + 1 < args.len:
      downstream = args[i + 1]
      inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i
  echo "EAVT gateway (chronos) starting on ", sockPath, " → ", downstream
  let gw = initGatewayState(downstream)

  # Remove stale socket from a crashed gateway (probe first).
  block stale:
    try:
      let probe = await initTAddress(sockPath).connect()
      await probe.closeWait()
      stderr.writeLine "Gateway already running on ", sockPath
      quit(1)
    except CatchableError:
      removeFile(sockPath)

  let address = initTAddress(sockPath)
  let server = createStreamServer(address, gatewayCallback, udata = cast[pointer](gw))
  server.start()
  echo "Gateway initialized"
  echo "Listening..."
  await server.loopFuture

when isMainModule:
  waitFor main()
