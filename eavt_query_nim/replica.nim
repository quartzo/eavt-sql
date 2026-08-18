## replica.nim — Gateway read-only replica engine.
##
## Opens a read-only KVStore on the shared data directory and populates it
## from the replication stream (snapshot + wal/seal/root events from the
## transactor).  SELECT/EXPLAIN queries execute against this engine; DML
## and schema changes are forwarded to the transactor.
##
## Replication events arrive via the onReplicationEvent callback, which
## the query server's MultiplexedConn reader task invokes for every "ev" frame.

import std/[json, tables]
import chronos
import chronos_file
import kvstore, eavt, engine
import stats

type
  ReplicaEngine* = ref object
    kv*: KVStore
    store*: QueryStore
    connected*: bool
    path*: string          # data dir (shared with transactor)

proc openReplica*(dir: string): ReplicaEngine =
  ## Open a read-only KVStore on the data directory.  The journal replay
  ## happens here (replaying whatever is on disk — harmless with the
  ## replication stream delivering incremental records after this point).
  var cfg = {"backend": "file", "path": dir}.toTable
  cfg["read_only"] = "true"
  let kv = newKVStore(cfg)
  if kv == nil:
    return nil
  let store = newQueryStore(kv)
  store.eavt.bootstrapSystemAttrs()
  ReplicaEngine(kv: kv, store: store, path: dir, connected: false)

proc applySnapshot*(r: ReplicaEngine; sealed: seq[string]; openTail: seq[byte];
                    rootName: string) {.async.} =
  ## Apply the initial snapshot from the transactor.  Sealed segments are
  ## listed by path (immutable files on the shared filesystem); the open
  ## tail bytes are the volatile in-memory WAL buffer at snapshot time.
  ## Segment files are read async (chronos-file thread pool), never
  ## blocking the event loop.
  for segPath in sealed:
    try:
      let data = await readFileBytesAsync(segPath)  # seq[byte], async
      r.kv.applyJournalRecords(data)
    except CatchableError:
      discard  # missing/torn segment — stream has what's needed
  if openTail.len > 0:
    r.kv.applyJournalRecords(openTail)
  if rootName.len > 0:
    try: r.kv.publishRoot(rootName)
    except Exception: discard  # blobstore raises Exception per base trait
  r.connected = true

proc applyWal*(r: ReplicaEngine; data: seq[byte]) =
  ## Apply incoming WAL records to the live treap.
  r.kv.applyJournalRecords(data)

proc applySeal*(r: ReplicaEngine) =
  ## Seal event: promote the live treap to flushRoots (pending treap),
  ## clear the live treap.
  r.kv.sealLiveToFlush()

proc applyRoot*(r: ReplicaEngine; rootName: string) =
  ## Root event: load the new pagestore root, discard the pending treap.
  try:
    r.kv.publishRoot(rootName)
  except Exception:
    discard  # stale/missing root; stream will deliver a newer one

proc getStats*(r: ReplicaEngine): stats.CompileStats =
  ## Build compile stats from the current replica state.
  ## Re-bootstraps the resolver and BYPASSES the engine's 30s stats cache —
  ## attributes declared after open arrive as db.* datoms via the WAL
  ## stream, and the query server's own invalidation must see them immediately.
  try:
    r.store.eavt.bootstrapResolver()
  except Exception:
    discard  # resolver re-scan is best-effort; stats may be stale
  r.store.eavt.cachedStatsTime = 0.0  # force rebuild past the engine TTL
  r.store.eavt.buildCompileStats()

proc close*(r: ReplicaEngine) =
  if r != nil and r.kv != nil:
    r.kv.close()

# ── Replication event handler (called by MultiplexedConn reader) ─────────────

proc handleSnapshot(r: ReplicaEngine; node: JsonNode) {.async.} =
  var sealed: seq[string] = @[]
  for s in node.getOrDefault("sealed"):
    sealed.add(s.getStr)
  var tail: seq[byte] = @[]
  for b in node.getOrDefault("openTail"):
    tail.add(byte(b.getInt))
  let root = node.getOrDefault("root").getStr("")
  await applySnapshot(r, sealed, tail, root)

proc onReplicationEvent*(r: ReplicaEngine; frame: JsonNode) {.gcsafe, raises: [].} =
  ## Dispatch one replication event frame.  Called from the MultiplexedConn
  ## reader task on the event loop — safe to touch the replica without locks.
  let ev = frame.getOrDefault("ev").getStr
  case ev
  of "snapshot":
    try:
      asyncSpawn handleSnapshot(r, frame)
      echo "Replication: snapshot received (",
           frame.getOrDefault("sealed").len, " segments, root=",
           frame.getOrDefault("root").getStr, ")"
    except CatchableError:
      discard
  of "wal":
    var data: seq[byte] = @[]
    for b in frame.getOrDefault("data"):
      data.add(byte(b.getInt))
    r.applyWal(data)
  of "seal":
    r.applySeal()
  of "root":
    r.applyRoot(frame.getOrDefault("name").getStr(""))
  else: discard
