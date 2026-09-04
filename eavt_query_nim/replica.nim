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
import nim_memtable/treap_backend as mt_be
import treap_cursor
import keys as eavt_keys
import eavt, engine
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

proc refreshResolverOnSchemaWal*(r: ReplicaEngine) {.gcsafe, raises: [].}
proc deriveFromCf0(r: ReplicaEngine; key: seq[byte]): seq[(uint8, seq[byte])] {.gcsafe.}

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
  # WAL CF-0-only: o snapshot/tail tem apenas datoms CF-0 — os índices
  # CF-1/2/3 precisam ser derivados.  Primeiro o resolver (bootstrap lê
  # CF-1 do pagestore adotado + CF-0 do treap), depois a derivação.
  try:
    r.refreshResolverOnSchemaWal()
  except CatchableError as e:
    logWarn("replica", "snapshot resolver bootstrap falhou (" & excMsg(e) & ")")
  block:
    let root = r.kv.mt.hnd.live[0]
    if root != nil:
      var cf0Keys: seq[seq[byte]]
      var tc = newTreapCursor(root, r.kv.mt.hnd.arena)
      while not tc.atEnd:
        let k = tc.next()
        if k.isSome: cf0Keys.add(k.get)
      var owned: seq[(uint8, seq[byte])]  # mantém os buffers vivos até o batch copiar
      for key in cf0Keys:
        try:
          for pair in r.deriveFromCf0(key): owned.add pair
        except Exception as e:
          logWarn("replica", "snapshot derive falhou (" & excMsg(e) & ")")
      if owned.len > 0:
        var derived: seq[mt_be.CfKey]
        for (cf, k) in owned:
          derived.add mt_be.CfKey(cf: cf, key: mt_be.toKeyRef(k))
        r.kv.applyJournalRecordsExpanded(derived)
  r.connected = true

proc deriveFromCf0(r: ReplicaEngine; key: seq[byte]): seq[(uint8, seq[byte])] {.gcsafe.} =
  ## Derive CF-1/2/3 keys from a CF-0 datom key [eid 8B][aid 4B][val][sf 8B].
  ## The replica builds its query indexes from the datom truth (WAL CF-0-only):
  ## CF-1 always; CF-2 when the attr is indexed; CF-3 when it is a ref.
  ## Metadata comes from the resolver (schema datoms replay before data —
  ## WAL order; refreshResolverOnSchemaWal runs on schema chunks).
  ## Returns OWNED (cf, key) pairs: the caller materializes KeyRef borrows
  ## only after collecting them — returning CfKey(borrowed KeyRef) directly
  ## dangles the stack-local seq at return (all borrows converge to the
  ## reused buffer → the treap dedups everything into garbage).
  result = @[]
  if key.len < 20: return
  let aid = (uint32(key[8]) shl 24) or (uint32(key[9]) shl 16) or
            (uint32(key[10]) shl 8) or uint32(key[11])
  let vtOpt = r.store.eavt.valueTypeFor(aid)
  if vtOpt.isNone: return                 # attr desconhecido (schema não chegou)
  let vlen = key.len - 20
  let val = key[12 ..< 12 + vlen]
  let sf = key[key.len - 8 ..< key.len]
  # CF-1 [aid][eid][val][sf]
  var k1 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
            byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  k1.add key[0 ..< 8]; k1.add val; k1.add sf
  result.add (1'u8, k1)
  if r.store.eavt.resolver.isIndexed(aid):
    # CF-2 [aid][val][eid][sf]
    var k2 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
              byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    k2.add val; k2.add key[0 ..< 8]; k2.add sf
    result.add (2'u8, k2)
  let isRef = valueTypeToEncodeMode(vtOpt.get) == emRef
  if isRef:
    # CF-3 [val][aid][eid][sf]
    var k3 = val
    k3.add @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
            byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    k3.add key[0 ..< 8]; k3.add sf
    result.add (3'u8, k3)

proc applyWal*(r: ReplicaEngine; data: seq[byte]) {.gcsafe, raises: [].} =
  ## Apply incoming WAL records to the live treap.
  ## WAL CF-0-only, applied in TWO PHASES: (1) CF-0 datom truth verbatim;
  ## (2) schema refresh if the chunk carries db.* datoms (bootstrapResolver
  ## lê o CF-0 do treap — fases resolvem o chicken-and-egg do schema no
  ## mesmo chunk); (3) derivação de CF-1/2/3 (o resolver já conhece os
  ## attrs).  Os treaps CF-1/2/3 da réplica ficam completos para as queries.
  inc r.evWalCount
  r.evWalBytes += data.len
  if r.evWalCount mod 100 == 0:
    logInfo("replica", "wal aplicado: " & $r.evWalCount & " frames / " &
      $r.evWalBytes & " bytes")
  let records = parseJournalRecords(data)
  if records.len == 0: return

  # Fase 1: CF-0 (verdade) + legado verbatim
  r.kv.applyJournalRecordsExpanded(records)

  # Fase 2: schema no chunk → refresh do resolver (lê CF-0 do treap)
  var cf0Keys: seq[seq[byte]]
  var hasSchema = false
  for rec in records:
    if rec.cf != 0: continue
    let key = mt_be.toSeq(rec.key)
    cf0Keys.add(key)
    if key.len >= 12:
      let aid = (uint32(key[8]) shl 24) or (uint32(key[9]) shl 16) or
                (uint32(key[10]) shl 8) or uint32(key[11])
      if WalSchemaAids.contains(aid): hasSchema = true
  if hasSchema:
    try:
      r.refreshResolverOnSchemaWal()
    except CatchableError as e:
      logWarn("replica", "refresh resolver pós-schema falhou (" & e.msg &
        "); attrs faltantes re-derivam no próximo chunk de schema")

  # Fase 3: derivação dos índices (o resolver já conhece os attrs).
  # Falha de metadado p/ um datom (attr ainda desconhecido) → log + skip:
  # o CF-0 verdade já foi aplicado; o índice faltante materializa no
  # pagestore pelo flush do primário (adotado pela réplica).
  var owned: seq[(uint8, seq[byte])]   # mantém os buffers vivos até o batch copiar
  for key in cf0Keys:
    try:
      for pair in r.deriveFromCf0(key): owned.add pair
    except CatchableError as e:
      logWarn("replica", "derive falhou p/ datom CF-0 (" & e.msg & "); índice faltante re-materializa via flush do primário")
  if owned.len > 0:
    var derived: seq[mt_be.CfKey]
    for (cf, k) in owned:
      derived.add mt_be.CfKey(cf: cf, key: mt_be.toKeyRef(k))
    r.kv.applyJournalRecordsExpanded(derived)

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
    r.applyRoot(getTopStr(frame, "name"))
  else: discard
