import std/[os, strutils]
import chronos
import shared, connection, replica, downstream

proc gatewayCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  var gw = cast[GatewayState](server.udata)
  await serveGatewayConnection(gw, transp)

proc internalCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  ## Internal executor socket — consumed by the OCaml front (Fase 1 of
  ## the two-layer split: compile in the front, execute on the replica).
  var gw = cast[GatewayState](server.udata)
  await serveInternalConnection(gw, transp)

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-query.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-query.sock"

proc internalSocketPath(clientPath: string): string =
  ## Derived from the client socket: <dir>/<name>.sock →
  ## <dir>/<name>-internal.sock (works for eavt-query.sock and for a
  ## back-only socket like eavt-query-back.sock).
  let dir = clientPath.parentDir()
  let name = clientPath.extractFilename()
  let stem = if name.endsWith(".sock"): name[0 ..< name.len - 5] else: name
  dir / (stem & "-internal.sock")

proc defaultDataDir(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0:
    return xdg / "eavt" / "db"
  return getHomeDir() / ".local" / "state" / "eavt" / "db"

proc main() {.async.} =
  var sockPath = getSocketPath()
  var downstream = downstreamSocketPath()
  var internalPath = ""
  var dataPath = ""
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]; inc i
    elif args[i] == "--downstream-path" and i + 1 < args.len:
      downstream = args[i + 1]; inc i
    elif args[i] == "--internal-path" and i + 1 < args.len:
      internalPath = args[i + 1]; inc i
    elif args[i] == "--data-path" and i + 1 < args.len:
      dataPath = args[i + 1]; inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i
  if dataPath.len == 0:
    dataPath = defaultDataDir()
  if internalPath.len == 0:
    internalPath = internalSocketPath(sockPath)
  echo "EAVT query server (chronos) starting on ", sockPath, " → ", downstream,
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
      proc(frame: string) {.gcsafe.} =
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
      stderr.writeLine "Query server already running on ", sockPath
      quit(1)
    except CatchableError:
      removeFile(sockPath)

  let address = initTAddress(sockPath)
  let server = createStreamServer(address, gatewayCallback, udata = cast[pointer](gw))
  server.start()

  # Internal executor socket (Fase 1): always-on, consumed by the OCaml
  # front.  Stale socket from a crash is removed unconditionally — the
  # client-socket probe above already guards against a second instance.
  block internal:
    removeFile(internalPath)
    let iaddr = initTAddress(internalPath)
    let iserver = createStreamServer(iaddr, internalCallback, udata = cast[pointer](gw))
    iserver.start()
    echo "Internal executor socket on ", internalPath

  echo "Query server initialized"
  echo "Listening..."
  await server.loopFuture

when isMainModule:
  waitFor main()
