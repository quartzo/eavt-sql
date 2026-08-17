import std/[os, tables]
import chronos
import kvstore
import shared_engine, connection
import wal

proc serverCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  var eng = cast[SharedEngine](server.udata)
  await serveConnection(eng, transp)

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-data.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-data.sock"

proc initEngineSafe(cfg: Table[string, string]): SharedEngine {.raises: [].} =
  try:
    initSharedEngine(cfg)
  except Exception:
    echo "engine init failed"
    quit(1)

proc main() {.async.} =
  var sockPath = getSocketPath()
  var backend = "memory"
  var dbPath = ""
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]; inc i
    elif args[i] == "--backend" and i + 1 < args.len:
      backend = args[i + 1]; inc i
    elif args[i] == "--path" and i + 1 < args.len:
      dbPath = args[i + 1]; inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i

  if backend notin ["memory", "file"]:
    echo "unknown backend: ", backend, " (use memory|file)"
    quit(1)
  if backend == "file" and dbPath.len == 0:
    echo "--backend file requires --path DIR"
    quit(1)

  echo "EAVT data server (chronos) starting on ", sockPath,
       "  backend=", backend

  var cfg: Table[string, string]
  if backend == "file":
    createDir(dbPath)
    cfg["backend"] = "file"
    cfg["path"] = dbPath
  # initSpawn() runs inside the KVStore constructor (background flush thread);
  # for file backend the journal replay happens synchronously here, before
  # the loop starts serving.
  let eng = initEngineSafe(cfg)
  var walw: WalWriter = nil
  if backend == "file":
    walw = await attachWal(eng.kv, dbPath)
    echo "WAL attached: ", dbPath / "journal" / "journal"

  # Remove stale socket from a crashed server (probe first).
  block stale:
    try:
      let probe = await initTAddress(sockPath).connect()
      await probe.closeWait()
      stderr.writeLine "Server already running on ", sockPath
      quit(1)
    except CatchableError:
      removeFile(sockPath)

  let address = initTAddress(sockPath)
  let server = createStreamServer(address, serverCallback, udata = cast[pointer](eng))
  server.start()
  echo "Listening..."
  await server.loopFuture
  if walw != nil:
    await walw.stop()

when isMainModule:
  waitFor main()
