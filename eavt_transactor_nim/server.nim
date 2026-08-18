import std/[os, tables, strutils]
import chronos
import kvstore
import shared_engine, connection
import wal
import replication

proc serverCallback(server: StreamServer, transp: StreamTransport) {.
    async: (raises: []).} =
  var eng = cast[SharedEngine](server.udata)
  await serveConnection(eng, transp)

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-transactor.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-transactor.sock"

proc defaultDataDir(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0:
    return xdg / "eavt" / "db"
  return getHomeDir() / ".local" / "state" / "eavt" / "db"

proc flagOrEnv(args: seq[string]; flag: string; env: string;
               default: string = ""): tuple[val: string, found: bool] =
  for i in 0..<args.len - 1:
    if args[i] == flag:
      return (args[i + 1], true)
  let e = getEnv(env)
  if e.len > 0:
    return (e, true)
  (default, false)

proc initEngineSafe(cfg: Table[string, string]): SharedEngine {.raises: [].} =
  try:
    initSharedEngine(cfg)
  except Exception:
    echo "engine init failed"
    quit(1)

const S3Usage = """s3 backend requires (--s3-* flags or EAVT_S3_* env):
  --s3-endpoint   / EAVT_S3_ENDPOINT    (required)
  --s3-bucket     / EAVT_S3_BUCKET      (required)
  --s3-access-key / EAVT_S3_ACCESS_KEY  (required)
  --s3-secret-key / EAVT_S3_SECRET_KEY  (required)
  --s3-region     / EAVT_S3_REGION      (default us-east-1)
  --s3-prefix     / EAVT_S3_PREFIX      (default "")
  --s3-path-style / EAVT_S3_PATH_STYLE  (default true)
and a local --path for the WAL/journal (blobs live in S3, recent writes
in the local WAL)."""

proc main() {.async.} =
  var sockPath = getSocketPath()
  var backend = "file"
  var dbPath = defaultDataDir()
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]; inc i
    elif args[i] == "--backend" and i + 1 < args.len:
      backend = args[i + 1].toLowerAscii(); inc i
    elif args[i] == "--path" and i + 1 < args.len:
      dbPath = args[i + 1]; inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i

  if backend notin ["file", "s3"]:
    echo "unknown backend: ", backend, " (use file|s3)"
    quit(1)

  var cfg: Table[string, string]
  cfg["backend"] = backend
  cfg["path"] = dbPath

  if backend == "s3":
    let endpoint = flagOrEnv(args, "--s3-endpoint", "EAVT_S3_ENDPOINT")
    let bucket = flagOrEnv(args, "--s3-bucket", "EAVT_S3_BUCKET")
    let accessKey = flagOrEnv(args, "--s3-access-key", "EAVT_S3_ACCESS_KEY")
    let secretKey = flagOrEnv(args, "--s3-secret-key", "EAVT_S3_SECRET_KEY")
    if not endpoint.found or not bucket.found or
       not accessKey.found or not secretKey.found:
      echo S3Usage
      quit(1)
    cfg["endpoint"] = endpoint.val
    cfg["bucket_name"] = bucket.val
    cfg["access_key"] = accessKey.val
    cfg["secret_key"] = secretKey.val
    let region = flagOrEnv(args, "--s3-region", "EAVT_S3_REGION")
    if region.found: cfg["region"] = region.val
    let prefix = flagOrEnv(args, "--s3-prefix", "EAVT_S3_PREFIX")
    if prefix.found: cfg["prefix"] = prefix.val
    let pathStyle = flagOrEnv(args, "--s3-path-style", "EAVT_S3_PATH_STYLE", "true")
    cfg["path_style"] = pathStyle.val

  echo "EAVT transactor (chronos) starting on ", sockPath,
       "  backend=", backend, "  path=", dbPath

  # The data dir holds the WAL/journal (and blobs for file). It is created
  # before the engine so journal replay can find prior state; for s3 the
  # local dir still hosts the WAL — blobs go to the bucket.
  createDir(dbPath)


  # The KVStore is single-threaded; flush/GC run on this event loop (the
  # AsyncFlusher + blob pool created inside initSharedEngine) — no spawn
  # threads. Journal replay happens synchronously here, before the loop serves.
  let eng = initEngineSafe(cfg)

  # Replication hub — subscribers get WAL bytes + seal/root notifications.
  eng.hub = initReplicationHub(dbPath)

  # Hook the replication broadcasts into the WAL writer and flush path.
  # Both callbacks do memcpy only (socket writes are async, elsewhere on
  # this same loop).
  var walw: WalWriter = nil
  walw = await attachWal(eng.kv, dbPath)
  eng.walw = walw
  walw.onSeal = proc(segIdx: int) {.gcsafe.} =
    broadcastSeal(addr eng.hub, segIdx)
  walw.onWal = proc(data: seq[byte]) {.gcsafe.} =
    broadcastWal(addr eng.hub, data)
  eng.kv.onFlushPublish = proc(rootName: string) {.gcsafe.} =
    broadcastRoot(addr eng.hub, rootName)
  echo "WAL attached: ", dbPath / "journal" / "journal"

  # chronos unlinks the stale socket path but does not create its parent
  # directory — do it before bind.
  createDir(sockPath.parentDir())

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
  # Order: WAL stops first (final drain + fsync), then the pool (in-flight
  # blob writes finish), then the store itself.
  await eng.close()
  echo "Shutdown complete."

when isMainModule:
  waitFor main()
