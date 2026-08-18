import std/[os, json]
import chronos
import shared, connection, replica, downstream

proc gatewayCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  var gw = cast[GatewayState](server.udata)
  await serveGatewayConnection(gw, transp)

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt.sock"

proc defaultDataDir(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0:
    return xdg / "eavt" / "db"
  return getHomeDir() / ".local" / "state" / "eavt" / "db"

proc main() {.async.} =
  var sockPath = getSocketPath()
  var downstream = downstreamSocketPath()
  var dataPath = ""
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]; inc i
    elif args[i] == "--downstream-path" and i + 1 < args.len:
      downstream = args[i + 1]; inc i
    elif args[i] == "--data-path" and i + 1 < args.len:
      dataPath = args[i + 1]; inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i
  if dataPath.len == 0:
    dataPath = defaultDataDir()
  echo "EAVT gateway (chronos) starting on ", sockPath, " → ", downstream,
       "  data=", dataPath

  let gw = initGatewayState(downstream)

  # Open the read-only replica engine on the data directory.  journal
  # replay happens here (sync, before the loop starts — acceptable).
  try:
    gw.replica = openReplica(dataPath)
  except Exception:
    gw.replica = nil
  if gw.replica != nil:
    echo "Replica engine opened on ", dataPath
    # Open the single multiplexed connection to the data server.
    # Replication events (snapshot/wal/seal/root) arrive as "ev" frames
    # and are dispatched to the replica via onReplicationEvent.
    gw.conn = openMultiplexed(downstream,
      proc(frame: JsonNode) {.gcsafe.} =
        gw.replica.onReplicationEvent(frame)
    )
  else:
    echo "Replica disabled (data dir not readable): ", dataPath

  # chronos unlinks the stale socket path but does not create its parent
  # directory — do it before bind.
  createDir(sockPath.parentDir())

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
