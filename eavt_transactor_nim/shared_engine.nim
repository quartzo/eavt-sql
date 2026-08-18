import std/tables
import chronos
import blobstore_async
import kvstore, eavt, engine
import kvstore_async
import replication
import wal

type
  SharedEngine* = ref object
    kv*: KVStore
    store*: QueryStore
    ## Blob pool: POD workers for zstd + blob I/O (pages, roots, GC walks).
    pool*: BlobPool
    ## Single-flight flush/GC driver (runs on THIS loop — no threads).
    flusher*: AsyncFlusher
    ## Push-based replication hub.  Nil when no replicas are connected.
    hub*: ReplicationHub
    ## WAL writer — needed by the replication snapshot (open-tail bytes).
    walw*: WalWriter

proc initSharedEngine*(cfg: Table[string, string]): SharedEngine =
  ## cfg must carry backend (file|s3) and a local path (WAL/journal).
  ## Must be called on the event loop that will serve requests: the pool's
  ## completion dispatcher and the flusher's runner live on it.
  let kv = newKVStore(cfg)
  if kv == nil:
    raise newException(IOError, "cannot open store at " & cfg.getOrDefault("path", ""))
  let store = newQueryStore(kv)
  store.eavt.bootstrapSystemAttrs()
  let pool = startBlobPool()
  let flusher = newAsyncFlusher(kv, pool)
  let eng = SharedEngine(kv: kv, store: store, pool: pool, flusher: flusher)
  # Auto-flush arming (threshold crossing in batchWrite / admin "flush"):
  # schedule on the loop; never blocks the caller. Failure lands in the
  # future — logged here, since nobody awaits the hook's request.
  proc armFlush(e: SharedEngine) {.gcsafe.} =
    let fut = e.flusher.requestFlushAsync()
    fut.callback = proc(udata: pointer) {.gcsafe, raises: [].} =
      if fut.failed():
        try:
          stderr.writeLine("auto-flush failed: " & fut.error().msg)
        except CatchableError:
          discard
  kv.onFlushRequest = proc() {.gcsafe.} = armFlush(eng)
  return eng

proc close*(eng: SharedEngine) {.async.} =
  ## Drain the flusher's pending work, stop the pool workers, close the
  ## store. Call on the loop, after the WAL writer stopped.
  eng.kv.onFlushRequest = nil
  await eng.pool.closeBlobPool()
  eng.kv.close()
