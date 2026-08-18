## replica.nim — Gateway read-only replica engine.
##
## Opens a read-only KVStore on the shared data directory and populates it
## from the replication stream (snapshot + wal/seal/root events from the
## data server).  SELECT/EXPLAIN queries execute against this engine; DML
## and schema changes are forwarded to the data server.

import std/[json, os, tables, options]
import chronos
import chronos_file
import msgpack4nim/msgpack2json
import scheme
import kvstore, eavt, engine, hostfns
import eavt_server_nim/client as ds
import stats

type
  ReplicaEngine* = ref object
    kv*: KVStore
    store*: QueryStore
    connected*: bool
    path*: string          # data dir (shared with data server)

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
  ## Apply the initial snapshot from the data server.  Sealed segments are
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
  ## stream, and the gateway's own invalidation must see them immediately.
  try:
    r.store.eavt.bootstrapResolver()
  except Exception:
    discard  # resolver re-scan is best-effort; stats may be stale
  r.store.eavt.cachedStatsTime = 0.0  # force rebuild past the engine TTL
  r.store.eavt.buildCompileStats()

proc close*(r: ReplicaEngine) =
  if r != nil and r.kv != nil:
    r.kv.close()

# ── Replication subscription ─────────────────────────────────────────────────

proc connectDownstream(dataPath: string): Future[StreamTransport] {.async.} =
  let address = initTAddress(dataPath)
  return await address.connect()

proc sendReplicateRequest(transp: StreamTransport) {.async.} =
  var node = newJObject()
  node["type"] = %"replicate"
  let body = msgpack2json.fromJsonNode(node)
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  copyMem(addr buf[4], unsafeAddr body[0], body.len)
  discard await transp.write(buf)

proc readFrameAsync(transp: StreamTransport): Future[JsonNode] {.async.} =
  ## Read one msgpack frame and parse to JsonNode.  Returns nil on disconnect.
  var hdr: array[4, byte]
  try:
    await transp.readExactly(addr hdr[0], 4)
  except CatchableError:
    return nil
  let len = int(hdr[0]) shl 24 or int(hdr[1]) shl 16 or
            int(hdr[2]) shl 8 or int(hdr[3])
  if len <= 0 or len > 100_000_000:
    return nil
  let raw = newString(len)
  try:
    await transp.readExactly(addr raw[0], len)
  except CatchableError:
    return nil
  try:
    result = toJsonNode(raw)
  except CatchableError:
    result = nil

proc handleSnapshot(r: ReplicaEngine; node: JsonNode) {.async.} =
  var sealed: seq[string] = @[]
  for s in node.getOrDefault("sealed"):
    sealed.add(s.getStr)
  var tail: seq[byte] = @[]
  for b in node.getOrDefault("openTail"):
    tail.add(byte(b.getInt))
  let root = node.getOrDefault("root").getStr("")
  await applySnapshot(r, sealed, tail, root)

proc replicationLoop*(r: ReplicaEngine; downstreamPath: string) {.async.} =
  ## Long-lived async task: subscribe to the data server's replication
  ## stream and apply events to the local replica engine.
  while true:
    var transp: StreamTransport
    try:
      transp = await connectDownstream(downstreamPath)
    except CatchableError:
      await sleepAsync(1000.milliseconds)
      continue

    try:
      await sendReplicateRequest(transp)
      # Read snapshot
      let snapshot = await readFrameAsync(transp)
      if snapshot == nil or snapshot.getOrDefault("ev").getStr != "snapshot":
        await transp.closeWait()
        await sleepAsync(1000.milliseconds)
        continue
      await handleSnapshot(r, snapshot)
      echo "Replication: snapshot applied (",
           snapshot["sealed"].len, " segments, root=", snapshot["root"].getStr, ")"

      # Stream loop: wal/seal/root events
      while true:
        let frame = await readFrameAsync(transp)
        if frame == nil: break
        let ev = frame.getOrDefault("ev").getStr
        case ev
        of "wal":
          var data: seq[byte] = @[]
          for b in frame.getOrDefault("data"):
            data.add(byte(b.getInt))
          r.applyWal(data)
        of "seal":
          r.applySeal()
        of "root":
          r.applyRoot(frame.getOrDefault("name").getStr(""))
        else: discard  # unknown event type — ignore
    except CatchableError:
      discard  # disconnect or parse error — reconnect

    r.connected = false
    await transp.closeWait()
    await sleepAsync(1000.milliseconds)  # reconnect delay
