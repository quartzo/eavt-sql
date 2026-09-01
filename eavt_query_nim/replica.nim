## replica.nim — Gateway read-only replica engine.
##
## Opens a read-only KVStore on the shared data directory and populates it
## from the replication stream (snapshot + wal/seal/root events from the
## transactor).  SELECT/EXPLAIN queries execute against this engine; DML
## and schema changes are forwarded to the transactor.
##
## Replication events arrive via the onReplicationEvent callback, which
## the query server's MultiplexedConn reader task invokes for every "ev" frame.

import std/[tables, streams]
import chronos
import chronos_file
import msgpack4nim
import kvstore, eavt, engine
import resolver
import stats
import msgpack_scan
import logutil

type
  ReplicaEngine* = ref object
    evWalCount*: int64
    evWalBytes*: int64
    evSealCount*: int64
    evRootCount*: int64
    kv*: KVStore
    store*: QueryStore
    connected*: bool
    path*: string          # data dir (shared with transactor)
    ## Set quando o WAL entregou datoms db.*: o snapshot de stats do gateway
    ## está stale independentemente do TTL de 30s (getSnapshot consome).
    schemaDirty*: bool

const
  ## Datoms de schema (nim_eavt/resolver) — cf 1 (AEVT), aid nos 4 primeiros bytes BE.
  WalSchemaAids = [DbIdentAid, DbCardinalityAid, DbValueTypeAid, DbUniqueAid]

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
    except CatchableError as e:
      # Tolerant by design (stream has what's needed) but durability-relevant.
      logWarn("replica", "snapshot: segment unreadable " & segPath & " (" &
        excMsg(e) & ")")
  if openTail.len > 0:
    r.kv.applyJournalRecords(openTail)
  if rootName.len > 0:
    try: r.kv.publishRoot(rootName)
    except Exception as e:
      logDebug("replica", "snapshot root not publishable (" & excMsg(e) &
        "); stream will deliver a newer one")
  r.connected = true

proc applyWal*(r: ReplicaEngine; data: seq[byte]) =
  ## Apply incoming WAL records to the live treap.
  inc r.evWalCount
  r.evWalBytes += data.len
  if r.evWalCount mod 100 == 0:
    logInfo("replica", "wal aplicado: " & $r.evWalCount & " frames / " &
      $r.evWalBytes & " bytes")
  r.kv.applyJournalRecords(data)

proc applySeal*(r: ReplicaEngine) =
  inc r.evSealCount
  logInfo("replica", "seal #" & $r.evSealCount)
  ## Seal event: promote the live treap to flushRoots (pending treap),
  ## clear the live treap.
  r.kv.sealLiveToFlush()

proc applyRoot*(r: ReplicaEngine; rootName: string) =
  ## Root event: load the new pagestore root, discard the pending treap.
  inc r.evRootCount
  logInfo("replica", "root #" & $r.evRootCount & ": " & rootName)
  try:
    r.kv.publishRoot(rootName)
  except Exception as e:
    # Falha ao publicar raiz NÃO é operação esperada: a réplica fica presa
    # numa geração antiga (leituras por índice erram pós-flush).
    logWarn("replica", "publishRoot " & rootName & " failed (" & excMsg(e) &
      "); replica pagestore stale")

proc getStats*(r: ReplicaEngine): stats.CompileStats =
  ## Build compile stats from the current replica state.
  ## Re-bootstraps the resolver and BYPASSES the engine's 30s stats cache —
  ## attributes declared after open arrive as db.* datoms via the WAL
  ## stream, and the query server's own invalidation must see them immediately.
  try:
    r.store.eavt.bootstrapResolver()
  except Exception as e:
    logWarn("replica", "resolver re-scan failed, stats may be stale (" &
      excMsg(e) & ")")
  r.store.eavt.cachedStatsTime = 0.0  # force rebuild past the engine TTL
  r.store.eavt.buildCompileStats()

proc refreshResolverOnSchemaWal*(r: ReplicaEngine) =
  ## Datoms db.* chegaram via WAL. applyWal só escreve no treap — o resolver
  ## em memória (tabela de attrs, flags UNIQUE) NÃO se atualiza sozinho;
  ## sem este refresh, isUniqueAttr na réplica fica stale até o TTL de 30s
  ## do gateway. Re-bootstrap imediato (raro: só em mudança de schema) e
  ## invalidação do snapshot de stats.
  try:
    r.store.eavt.bootstrapResolver()
  except Exception as e:
    logWarn("replica", "resolver refresh on schema wal failed (" &
      excMsg(e) & "); stats may be stale")
  r.schemaDirty = true

proc close*(r: ReplicaEngine) =
  if r != nil and r.kv != nil:
    r.kv.close()

# ── Replication event handler (called by MultiplexedConn reader) ─────────────

proc handleSnapshot(r: ReplicaEngine; frame: string) {.async.} =
  var sealed: seq[string] = @[]
  let (sf, ss, se) = topValue(frame, "sealed")
  if sf:
    for (s, e) in topArrayElems(frame, ss, se):
      let decoded = decodeStrAt(frame, s, e)
      if decoded.len > 0: sealed.add(decoded)
  var tail: seq[byte] = @[]
  let (tf, ts, te) = topValue(frame, "openTail")
  if tf:
    for (s, e) in topArrayElems(frame, ts, te):
      # Each element is a byte (int)
      if s < e and e <= frame.len:
        let b = ord(frame[s])
        if b >= 0x00 and b <= 0x7f: tail.add(byte(b))
        elif b >= 0xcc and b <= 0xcf:
          # uint — read value from subsequent bytes
          var val = 0
          for i in 1 ..< (e - s): val = (val shl 8) or ord(frame[s + i])
          tail.add(byte(val and 0xff))
  let root = getTopStr(frame, "root")
  await applySnapshot(r, sealed, tail, root)

proc onReplicationEvent*(r: ReplicaEngine; frame: string) {.gcsafe, raises: [].} =
  ## Dispatch one replication event frame (raw msgpack bytes).  Called from
  ## the MultiplexedConn reader task on the event loop — safe to touch the
  ## replica without locks.
  let ev = getTopStr(frame, "ev")
  case ev
  of "snapshot":
    try:
      asyncSpawn handleSnapshot(r, frame)
      # Count sealed segments for the log message
      var sealedCount = 0
      let (sf, ss, se) = topValue(frame, "sealed")
      if sf:
        for (s, e) in topArrayElems(frame, ss, se): inc sealedCount
      echo "Replication: snapshot received (",
           sealedCount, " segments, root=",
           getTopStr(frame, "root"), ")"
    except CatchableError as e:
      logError("replica", "snapshot event dispatch failed (" & excMsg(e) & ")")
  of "wal":
    var data: seq[byte] = @[]
    let (df, ds, de) = topValue(frame, "data")
    if df:
      let raw = valueBytesAt(frame, ds, de)
      if raw.len > 0: data = raw
      else:
        # Fallback: array of ints
        for (s, e) in topArrayElems(frame, ds, de):
          if s < e and e <= frame.len:
            let b = ord(frame[s])
            if b >= 0x00 and b <= 0x7f: data.add(byte(b))
    r.applyWal(data)
    if journalHasSchemaRecords(data, WalSchemaAids):
      r.refreshResolverOnSchemaWal()
  of "seal":
    r.applySeal()
  of "root":
    r.applyRoot(getTopStr(frame, "name"))
  else: discard
