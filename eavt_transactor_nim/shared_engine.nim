import std/[tables, os, strutils]
import chronos
import logutil
import blobstore_async
import kvstore, eavt, engine
import hydrated, anchor_index
import kvstore_async
import flush_worker
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
  # Knob de operações: threshold de flush do memtable (bytes de chave)
  let ft = getEnv("EAVT_FLUSH_THRESHOLD")
  if ft.len > 0:
    kv.flushThreshold = cast[uint64](parseInt(ft))
  store.eavt.bootstrapSystemAttrs()
  store.eavt.bootstrapResolver()
  store.eavt.recoverWriteState()   # WAL CF-0-only: resíduo → estruturas de escrita
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
          discard  # whitelisted: reporting failure of the report itself
  kv.onFlushRequest = proc() {.gcsafe.} = armFlush(eng)
  # M9: ledger periódico de memória — RSS por componente, para separar
  # leak de budget legítimo (roda no loop; leitura de /proc é barata).
  if getEnv("EAVT_MEM_LEDGER", "1") == "1":
    proc memLedger(e: SharedEngine) {.async.} =
      while true:
        await sleepAsync(chronos.seconds(10))
        var rssKb = 0'i64
        try:
          var f = open("/proc/self/statm")
          var line = ""
          discard f.readLine(line)
          f.close()
          let fields = line.splitWhitespace()
          if fields.len >= 2: rssKb = parseInt(fields[1]) * 4
        except CatchableError:
          discard  # ledger é diagnóstico: falha de leitura não pode derrubar
        let hyd = e.store.eavt.hyd
        let anch = e.store.eavt.anchors
        let mt = e.kv.mt
        var drainRuns = 0
        for cf in 0 ..< mt.numCf: drainRuns += mt.draining[cf].len
        var activeRuns = 0
        for cf in 0 ..< mt.numCf: activeRuns += mt.runs[cf].len
        logInfo("memledger",
          "rss=" & $(rssKb div 1024) & "MB" &
          " hyd=" & $(hyd.curBytes div 1048576) & "MB/" & $(hydrated.len(hyd)) & "eids" &
          " anchor=" & $(anch.bytes div 1048576) & "MB/" & $(anchor_index.len(anch)) &
          " mt=" & $(e.kv.mtSize div 1048576) & "MB" &
          " runs=" & $activeRuns & "+" & $drainRuns &
          " gen=" & $mt.gen &
          " flushActive=" & $e.kv.flushActive)
    asyncCheck eng.memLedger()
  return eng

proc close*(eng: SharedEngine) {.async.} =
  ## Drain the flusher's pending work, stop the pool workers, close the
  ## store. Call on the loop, after the WAL writer stopped.
  eng.kv.onFlushRequest = nil
  await eng.flusher.worker.closeFlushWorker()
  await eng.pool.closeBlobPool()
  eng.kv.close()
