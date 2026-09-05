## replica.nim — Gateway read-only replica engine.
##
## Opens a read-only KVStore on the shared data directory and populates it
## from the replication stream (snapshot + wal/seal/root events from the
## transactor).  SELECT/EXPLAIN queries execute against this engine; DML
## and schema changes are forwarded to the transactor.
##
## Replication events arrive via the onReplicationEvent callback, which
## the query server's MultiplexedConn reader task invokes for every "ev" frame.

import std/[tables, streams, options]
import chronos
import chronos_file
import msgpack4nim
import kvstore
import nim_memtable/memtypes
import keys as eavt_keys
import eavt, engine
import hydrated  # anchor hash mirror cleanup (M6)
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
  ## M5: the journal replay stays OFF (`replay_off`) — the snapshot/WAL
  ## stream delivers everything through the unified batchWrite; a treap
  ## replay here would duplicate every datom (treap + vector).
  var cfg = {"backend": "file", "path": dir}.toTable
  cfg["read_only"] = "true"
  cfg["replay_off"] = "true"
  let kv = newKVStore(cfg)
  if kv == nil:
    return nil
  let store = newQueryStore(kv)
  # M5: the replica NEVER invents schema.  With replay_off the adopted root
  # is empty until the transactor flushes, so the bootstrap probe would see
  # "unbootstrapped" and write system-attr datoms into the vector — garbage
  # for the dataset (the real db.* datoms arrive via the snapshot/WAL stream
  # and refreshResolverOnSchemaWal).  bootstrapResolver only reads.
  store.eavt.bootstrapResolver()
  ReplicaEngine(kv: kv, store: store, path: dir, connected: false)

proc refreshResolverOnSchemaWal*(r: ReplicaEngine) {.gcsafe, raises: [].}

proc routeSnapshotBatch(r: ReplicaEngine;
                        keys: seq[tuple[cf: uint8, key: seq[byte]]]) {.
    gcsafe, raises: [].} =
  ## batchWrite outside the async macro — the effect system inside async
  ## does not accept `except CatchableError` for a call whose inferred
  ## raises is the root Exception.  M6: owned key copies route through
  ## batchWriteForeignKeys (batchWrite references bytes; the copies land
  ## in the memtable arena).
  try:
    r.store.eavt.batchWriteForeignKeys(keys)
  except CatchableError as e:
    # routing failure here is fatal to consistency — the CF-0 truth was
    # NOT stored; log loud (the stream re-snapshots on reconnect)
    logError("replica", "snapshot batchWrite failed (" & excMsg(e) & ")")
  except Defect:
    raise  # fail-fast: defects never swallow
  {.cast(raises: []).}: discard

proc applySnapshot*(r: ReplicaEngine; sealed: seq[string]; openTail: seq[byte];
                    rootName: string) {.async.} =
  ## Apply the initial snapshot from the transactor.  Sealed segments are
  ## listed by path (immutable files on the shared filesystem); the open
  ## tail bytes are the volatile in-memory WAL buffer at snapshot time.
  ## Segment files are read async (chronos-file thread pool), never
  ## blocking the event loop.
  ## M5: the snapshot's datoms route through the SAME batchWrite (vector +
  ## entries + anchor hash) — identical read semantics on both nodes; the
  ## adopted root supplies the durable set, the volatile window derives.
  # CRITICAL: route PER SEGMENT. `parseJournalRecords` borrows into `data`
  # (KeyRef pointers into the local seq) and batchWrite copies immediately;
  # keeping borrows alive across loop iterations past `data`'s scope copied
  # freed memory (255k zeroed keys on restart).
  var routedTotal = 0
  for segPath in sealed:
    var routed: seq[seq[byte]]
    try:
      let data = await readFileBytesAsync(segPath)  # seq[byte], async
      var records = parseJournalRecords(data)
      var expanded: seq[tuple[cf: uint8, key: seq[byte]]]
      for rec in records:
        if rec.cf == 0 and rec.key.len >= 20:
          let k = rec.key.toSeq()
          expanded.add (0'u8, k)
          let aid = beUint32(k, 8)
          var isRef = false
          try:
            let vt = r.store.eavt.valueTypeFor(aid)
            isRef = vt.isSome and vt.get == DbTypeRef
          except KeyError:
            discard
          for d in deriveIndexKeys(k, r.store.eavt.resolver.isIndexed(aid), isRef):
            expanded.add (d.cf, d.key)
      if expanded.len > 0:
        routeSnapshotBatch(r, expanded)
        inc routedTotal, expanded.len
    except CatchableError as e:
      # Tolerant by design (stream has what's needed) but durability-relevant.
      logWarn("replica", "snapshot: segment unreadable " & segPath & " (" &
        excMsg(e) & ")")
  if openTail.len > 0:
    var expanded: seq[tuple[cf: uint8, key: seq[byte]]]
    var records = parseJournalRecords(openTail)
    for rec in records:
      if rec.cf == 0 and rec.key.len >= 20:
        let k = rec.key.toSeq()
        expanded.add (0'u8, k)
        let aid = beUint32(k, 8)
        var isRef = false
        try:
          let vt = r.store.eavt.valueTypeFor(aid)
          isRef = vt.isSome and vt.get == DbTypeRef
        except KeyError:
          discard
        for d in deriveIndexKeys(k, r.store.eavt.resolver.isIndexed(aid), isRef):
          expanded.add (d.cf, d.key)
    if expanded.len > 0:
      routeSnapshotBatch(r, expanded)
      inc routedTotal, expanded.len
  if rootName.len > 0:
    try: r.kv.publishRoot(rootName)
    except Exception as e:
      logDebug("replica", "snapshot root not publishable (" & excMsg(e) &
        "); stream will deliver a newer one")
  # WAL CF-0-only: resolver primeiro (bootstrap lê o schema do pagestore
  # adotado), depois o roteamento batchWrite (batchWrite deriva âncoras).
  try:
    r.refreshResolverOnSchemaWal()
  except CatchableError as e:
    logWarn("replica", "snapshot resolver bootstrap falhou (" & excMsg(e) & ")")
  logInfo("replica", "snapshot aplicado: " & $routedTotal & " datoms via batchWrite")
  r.connected = true


proc routeWalBatch(r: ReplicaEngine; keys: seq[seq[byte]]) {.
    gcsafe, raises: [].} =
  ## Same effect-system wrapper as routeSnapshotBatch (plain proc: the
  ## async macro's effect analysis does not accept `except CatchableError`
  ## for a call whose inferred raises is the root Exception).
  ## M6: batchWrite REFERENCES the key bytes (treap memtable contract) —
  ## WAL frames are transient, so batchWriteForeignKeys copies each key
  ## into the memtable arena before routing.
  try:
    var expanded: seq[tuple[cf: uint8, key: seq[byte]]]
    for k in keys:
      expanded.add (0'u8, k)
      # M6: the WAL carries the datom (CF-0) only — the replica derives the
      # index keys for its volatile window (the primary's flush brings the
      # durable set via the adopted root).  Resolver is fresh: schema
      # datoms refreshed before routing.
      let aid = beUint32(k, 8)
      var isRef = false
      try:
        let vt = r.store.eavt.valueTypeFor(aid)
        isRef = vt.isSome and vt.get == DbTypeRef
      except KeyError:
        discard  # unknown aid: not a ref (best-effort derivation)
      for d in deriveIndexKeys(k, r.store.eavt.resolver.isIndexed(aid), isRef):
        expanded.add (d.cf, d.key)
    r.store.eavt.batchWriteForeignKeys(expanded)
  except CatchableError as e:
    # CF-0 truth NOT stored for this chunk — log loud; the reconnect
    # re-snapshot repairs.
    logError("replica", "wal batchWrite failed (" & excMsg(e) & ")")


proc applyWal*(r: ReplicaEngine; data: seq[byte]) {.gcsafe, raises: [].} =
  ## Apply incoming WAL records — M5: the replica uses the SAME write path
  ## as the transactor: datoms route through `batchWrite` (datom vector +
  ## hydrated entries + anchor hash).  The 4 treaps are out of the replica's
  ## write path too; CF-1/2/3 are derived (worker at the primary's flush —
  ## the adopted root — and at cursor open from the volatile window).
  ## This closes the stale-hydration bug: the read path's invariant
  ## (probeComplete → authoritative) is maintained by the same code that
  ## maintains it on the primary.
  inc r.evWalCount
  r.evWalBytes += data.len
  if r.evWalCount mod 100 == 0:
    logInfo("replica", "wal aplicado: " & $r.evWalCount & " frames / " &
      $r.evWalBytes & " bytes")
  let records = parseJournalRecords(data)
  if records.len == 0: return

  # Schema in the chunk → refresh the resolver BEFORE routing (batchWrite's
  # anchor routing needs isIndexed; cf1-derived reads need the attrs).
  var hasSchema = false
  for rec in records:
    if rec.cf == 0 and rec.key.len >= 12:
      let aid = beUint32(rec.key.p.toOpenArray(0, rec.key.len - 1), 8)
      if WalSchemaAids.contains(aid): hasSchema = true
  if hasSchema:
    try:
      r.refreshResolverOnSchemaWal()
    except CatchableError as e:
      logWarn("replica", "refresh resolver pós-schema falhou (" & e.msg &
        "); attrs faltantes re-derivam no próximo chunk de schema")

  # Route CF-0 truth through the unified write path (treap memtable +
  # hydrated mirror + anchor hash).  Owned copies: the borrowed KeyRefs die
  # with `data`; batchWriteForeign copies into the memtable arena.
  var keys: seq[seq[byte]]
  for rec in records:
    if rec.cf == 0 and rec.key.len >= 20:
      keys.add rec.key.toSeq()
  if keys.len > 0:
    routeWalBatch(r, keys)

proc applySeal*(r: ReplicaEngine) =
  inc r.evSealCount
  logInfo("replica", "seal #" & $r.evSealCount)
  ## Seal event: promote the live treap to flushRoots (pending treap),
  ## clear the live treap.
  r.kv.sealLiveToFlush()

proc applyRoot*(r: ReplicaEngine; rootName: string; maxT: int64) =
  ## Root event: load the new pagestore root, discard the pending treap,
  ## and advance the vector's watermark exactly (the root carries the
  ## primary's flush maxT — datoms after the capture stay volatile here).
  inc r.evRootCount
  logInfo("replica", "root #" & $r.evRootCount & ": " & rootName &
    " maxT=" & $maxT)
  try:
    r.kv.publishRoot(rootName)
    # Guard: only advance the watermark when the adopted root actually
    # carries data. The transactor's post-recovery flush can broadcast
    # (root=h0 empty, maxT=lastReplayT) — publishing that would mark vector
    # datoms "durable" while the replica's pagestore covers nothing, and
    # the next run-cache build would drain nothing (rows vanish).
    if not r.kv.rootHasData():
      logInfo("replica", "root " & rootName & " is empty — root not adopted")
      return
    # M7: the anchor index is a permanent read mirror on both nodes —
    # nothing to drop at root adoption (the WAL write-through keeps it
    # current; evicted/absent anchors fall back to the CF-2 scan).
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

proc refreshResolverOnSchemaWal(r: ReplicaEngine) {.gcsafe, raises: [].} =
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
    r.applyRoot(getTopStr(frame, "name"), getTopInt(frame, "maxT", -1))
  else: discard
