## eavt.nim — EAVT engine (save, retract, bootstrap, lookup).
##
## Port of spier-transactor/src/eavt.rs (~1099 lines Rust → Nim).
## Coordinates Resolver + KVStore for entity-attribute-value-time operations.

import std/[tables, strutils, options, times, sets, monotimes, algorithm, syncio]
import logutil
import resolver
import keys
export keys
import kvstore
import page_store     # CfTree
import page_cursor   # PageStoreSnapshot, PageStoreCursor
import treap_cursor   # newTreapCursor
import query/cursor   # treapCursor constructor
import nim_memtable/treap_backend
import scheme
import stats
import hydrated

# ═══════════════════════════════════════════════════════════════════════════════
# Value type mapping
# ═══════════════════════════════════════════════════════════════════════════════

proc valueTypeToEncodeMode*(vt: uint32): EncodeMode =
  case vt:
  of DbTypeRef:       return emRef
  of DbTypeString:    return emVariable
  of DbTypeKeyword:   return emVariable
  of DbTypeBoolean:   return emFixed
  of DbTypeLong:      return emFixed
  of DbTypeInstant:   return emFixed
  of DbTypeFloat:     return emFixed
  of DbTypeBytes:     return emBlob
  of DbTypeBlob:      return emBlob
  else:               return emVariable

proc valueTypeFromName*(name: string): uint32 =
  let n = if name.startsWith(":db.type/"): name[9..^1].toLowerAscii() else: name.toLowerAscii()
  case n:
  of "ref":     return DbTypeRef
  of "string":  return DbTypeString
  of "keyword": return DbTypeKeyword
  of "boolean": return DbTypeBoolean
  of "long":    return DbTypeLong
  of "instant": return DbTypeInstant
  of "float":   return DbTypeFloat
  of "bytes":   return DbTypeBytes
  of "blob":    return DbTypeBlob
  else:         return DbTypeString

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT Engine
# ═══════════════════════════════════════════════════════════════════════════════

type
  EavtEngine* = ref object
    kv*: KVStore                  # Nim ref — no C-ABI vtable
    resolver*: Resolver
    cachedStats*: CompileStats
    cachedStatsTime*: float64
    # Reusable cursor for scanPrefix (single-threaded event loop — no races)
    spCursor*: MergedCursor
    spCf*: int
    # Reusable cursors for scanPrefixActive
    saPs*: PageStoreCursor
    saFlush*: TreapCursor
    saLive*: TreapCursor
    saCf*: int
    # scanPrefix perf counters
    spCount*: int64
    spOpenCursorNs*: int64
    spSeekNs*: int64
    spIterateNs*: int64
    spKeysReturned*: int64
    # Hydrated-eid source (CF 0 fast path) — see hydrated.nim
    hydEnabled*: bool
    hyd*: HydratedSet
    # M2: CF-1/CF-3 are write-only on the transactor — no in-tx reads
    # (bootstrapResolver scans CF-1 at STARTUP only, when the buffers are
    # empty; buildCompileStats uses the in-memory resolver).  Deferred
    # append buffers drained at flush (sorted per CF); WAL covers durability.
    deferred*: array[4, seq[seq[byte]]]
    deferredBytes*: int64
    # M3': CF-2 anchor index as a HASH on the transactor — the anchor
    # lookup is a point query (attr,value)→eid; order matters only at
    # flush (pages) and on the replica (WAL, own treap).  Key = the CF-2
    # lookup prefix [aid 4B][value]; value = the full CF-2 key (carries t
    # for the publish filter).  The treap CF-2 exits the write path.
    anchorHash*: Table[seq[byte], seq[byte]]
    anchorBytes*: int64
    # TEMP scan diagnostics (-d:eavtScanDiag)
    diagSeekNs*: int64
    diagIterNs*: int64
    diagCalls*: int64
    diagDescendNs*: int64
    diagCrossNs*: int64

const
  DefaultHydratedMaxBytes = DefaultMaxBytes  # 1 GiB

proc newEavtEngine*(kv: KVStore; cfg: Table[string, string]): EavtEngine =
  ## cfg keys: `hydrated_enabled` ("true"/"false", default true),
  ## `hydrated_max_bytes` (bytes, default 1 GiB).
  let enabled = cfg.getOrDefault("hydrated_enabled", "true") != "false"
  let maxBytes = block:
    let v = cfg.getOrDefault("hydrated_max_bytes", "")
    if v.len > 0: parseInt(v) else: DefaultHydratedMaxBytes
  result = EavtEngine(
    kv: kv,
    resolver: newResolver(),
    hydEnabled: enabled,
    hyd: newHydratedSet(maxBytes),
    anchorHash: initTable[seq[byte], seq[byte]](),
  )
  # M1: the engine wires its own flush hooks — the hyd set IS the CF-0
  # memtable for hydrated eids, so every flush must drain it between
  # capture and commit.  Hooks run on the loop (single-thread owner).
  if enabled:
    let self = result
    self.kv.onFlushCollect = proc (): tuple[
        keysByCf: seq[(int, seq[seq[byte]])], maxT: int64] {.gcsafe, raises: [].} =
      let c = self.hyd.collectDirty()
      result.keysByCf = c.keysByCf
      result.maxT = c.maxT
      # M2: deferred CF-1/3 join the drain (raw order; the worker sorts).
      # Sorting here would block the loop with large buffers.
      for cf in [1, 3]:
        if self.deferred[cf].len > 0:
          var found = false
          for i in 0 ..< result.keysByCf.len:
            if result.keysByCf[i][0] == cf:
              result.keysByCf[i][1] &= self.deferred[cf]
              found = true
              break
          if not found: result.keysByCf.add (cf, self.deferred[cf])
          for k in self.deferred[cf]:
            let kt = (beUint64(k, k.len - 8) shr 1).int64
            if kt > result.maxT: result.maxT = kt
      # M3': anchor hash values join the drain (raw; worker sorts)
      if self.anchorHash.len > 0:
        var akeys: seq[seq[byte]]
        for v in self.anchorHash.values():
          akeys.add(v)
          let kt = (beUint64(v, v.len - 8) shr 1).int64
          if kt > result.maxT: result.maxT = kt
        var found2 = false
        for i in 0 ..< result.keysByCf.len:
          if result.keysByCf[i][0] == 2:
            result.keysByCf[i][1] &= akeys
            found2 = true
            break
        if not found2: result.keysByCf.add (2, akeys)
    self.kv.onFlushPublished = proc (maxT: int64) {.gcsafe, raises: [].} =
      self.hyd.publishWatermark(maxT)
      # M2: deferred keys ≤ maxT are durable in the pagestore — drop them;
      # keys written during the flush (t > maxT) stay pending.
      var freed: int64 = 0
      for cf in [1, 3]:
        if self.deferred[cf].len == 0: continue
        var keep: seq[seq[byte]]
        for k in self.deferred[cf]:
          let kt = (beUint64(k, k.len - 8) shr 1).int64
          if kt > maxT: keep.add(k) else: freed += k.len.int64
        self.deferred[cf] = keep
      self.deferredBytes -= freed
      if self.deferredBytes < 0: self.deferredBytes = 0
      # M3': hash entries ≤ maxT are durable in the pagestore — dropped;
      # keys written during the flush (t > maxT) stay pending.
      var toDel: seq[seq[byte]]
      for pfx, full in self.anchorHash:
        let kt = (beUint64(full, full.len - 8) shr 1).int64
        if kt <= maxT:
          toDel.add(pfx)
          freed += (full.len + pfx.len).int64
      for pfx in toDel: self.anchorHash.del(pfx)
      self.deferredBytes -= freed
      if self.deferredBytes < 0: self.deferredBytes = 0
  # bootstrap called after construction (avoids forward ref)

proc newEavtEngine*(kv: KVStore): EavtEngine =
  newEavtEngine(kv, initTable[string, string]())

# ── Batch write helper ──

proc keyToSeqEavt(key: KeyRef): seq[byte] {.inline.} =
  result = newSeq[byte](key.len)
  if key.len > 0:
    copyMem(addr result[0], unsafeAddr key.p[0], key.len)

proc batchWrite*(eng: EavtEngine; entries: var seq[EavtEntry]) =
  ## Consumes the entries: keys are arena-written by buildEavtEntries and
  ## referenced (ptr+len) into CfKey — zero copy on the load path.
  ##
  ## M1 write path: CF-0 datoms of HYDRATED eids go to the hydrated entry
  ## (which IS the memtable for that eid — dirty until the flush drains
  ## it); they do NOT enter the treap CF-0.  Non-hydrated eids and every
  ## secondary CF (1/2/3) go to the treap as before.  Reads are safe: the
  ## hyd fast path serves hydrated eids including dirty keys.
  if entries.len == 0: return
  var cfs = newSeq[CfKey](entries.len)
  var journaled = newSeq[CfKey]()
  var n = 0
  if eng.hydEnabled:
    for e in entries:
      if e.cf == 0:
        let eid = decodeEid(beUint64(e.key.p.toOpenArray(0, e.key.len - 1), 0))
        if not eng.hyd.contains(eid):
          # M4: cold eid — PARTIAL write-state entry (delta only; base
          # stays in pagestore).  The treap CF-0 exits the write path.
          discard eng.hyd.ensurePartial(eid)
        eng.hyd.applyKey(e.key)
        # entry is the memtable — no treap CF-0; the WAL record is still
        # MANDATORY (durability + replica feed) — M1 durability fix
        journaled.add CfKey(cf: e.cf, key: e.key)
        continue
      elif e.cf == 1 or e.cf == 3:
        # M2: write-only CFs — deferred append buffer, drained at flush
        let k = keyToSeqEavt(e.key)
        eng.deferred[e.cf.int].add(k)
        eng.deferredBytes += e.key.len.int64
        journaled.add CfKey(cf: e.cf, key: e.key)
        continue
      elif e.cf == 2:
        # M3': anchor index as a hash — the treap CF-2 exits the write
        # path.  Hash key = the lookup prefix [aid 4B][value]; value = the
        # full canonical CF-2 key (carries t for the publish filter).
        # Retract (sf bit 1) removes the mapping.
        let k = keyToSeqEavt(e.key)
        let sf = beUint64(k, k.len - 8)
        let prefix = k[0 ..< k.len - 16]
        if (sf and 1) == 0:
          eng.anchorHash[prefix] = k
          eng.anchorBytes += (k.len + prefix.len).int64
        else:
          if eng.anchorHash.hasKey(prefix):
            eng.anchorBytes -= (eng.anchorHash[prefix].len + prefix.len).int64
            eng.anchorHash.del(prefix)
        journaled.add CfKey(cf: e.cf, key: e.key)
        continue
      cfs[n] = CfKey(cf: e.cf, key: e.key)
      inc n
  else:
    for e in entries:
      cfs[n] = CfKey(cf: e.cf, key: e.key)
      inc n
  cfs.setLen(n)
  # WAL CF-0-only: o datom (CF-0) é a verdade — CF-1/2/3 são derivados e
  # re-derivados no replay (transactor routing + réplica). journalOnly é o
  # ponto de filtro do caminho de escrita EAVT.
  var durable: seq[CfKey]
  for e in journaled:
    if e.cf == 0: durable.add(e)
  if durable.len > 0: eng.kv.journalOnly(durable)
  eng.kv.batchWrite(cfs)
  # M1/M2/M3' flush pressure: hydrated CF-0, deferred CF-1/3 and the
  # anchor hash bypass the memtable — arm on their combined volume too.
  if eng.hydEnabled:
    let pressure = eng.hyd.dirtyBytes + eng.deferredBytes + eng.anchorBytes
    if pressure >= eng.kv.flushThreshold.int64:
      if eng.kv.onFlushRequest != nil: eng.kv.onFlushRequest()

proc scanPrefix*(eng: EavtEngine; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  ## Scan keys in CF matching prefix. Reuses cursor from previous call —
  ## updates in-place if roots changed, then seeks to new prefix.
  eng.spCount += 1
  # Hyd fast path (M1): COMPLETE hydrated eids' CF-0 keys live in the entry
  # (the memtable). Raw view: active + tombstones.  M4: partial eids and
  # full-range scans merge hyd keys below (raw view).
  var deltaKeys: seq[seq[byte]] = @[]
  if eng.hydEnabled and cf == 0:
    if prefix.len >= 8:
      let eid = decodeEid(beUint64(prefix, 0))
      if eng.hyd.probeComplete(eid):
        return eng.hyd.lookupRangeRaw(eid, prefix)
      if eng.hyd.contains(eid):
        deltaKeys = eng.hyd.lookupRangeRaw(eid, prefix)
    else:
      deltaKeys = eng.hyd.allKeys()
  var t0 = getMonoTime()

  # Read current roots
  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: TreapNode
  var tree = eng.kv.ps[].trees[cf]
  psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
  if eng.kv.flushRoots.len > 0:
    flushRoot = eng.kv.flushRoots[cf]
  liveRoot = eng.kv.mt.hnd.live[cf]

  if eng.spCursor == nil or eng.spCf != cf:
    # First call or different CF — create cursor from scratch
    eng.spCursor = eng.kv.openScanCursor(cf)
    eng.spCf = cf
  else:
    # Same CF — update in-place (zero allocs if roots unchanged)
    eng.spCursor.update(psSnap.rootUuid, psSnap.height,
                        flushRoot, eng.kv.flushArena,
                        liveRoot, eng.kv.mt.hnd.arena)

  eng.spOpenCursorNs += (getMonoTime().ticks - t0.ticks)

  t0 = getMonoTime()
  eng.spCursor.seek(prefix)
  eng.spSeekNs += (getMonoTime().ticks - t0.ticks)

  t0 = getMonoTime()
  while true:
    let k = eng.spCursor.next()
    if k.isNone: break
    let key = k.get
    if key.len < prefix.len or key[0..<prefix.len] != prefix: break
    result.add key
  # M4: partial/full-range hyd keys join the raw view (sorted)
  if deltaKeys.len > 0:
    result &= deltaKeys
    result.sort(cmpKeysByte)
  eng.spIterateNs += (getMonoTime().ticks - t0.ticks)
  eng.spKeysReturned += result.len

type
  CollectEntry = tuple[key: seq[byte], srcIdx: int]

proc scanPrefixActive*(eng: EavtEngine; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  ## Scan keys in CF matching prefix. Returns only active (non-retracted) datoms.
  ## Reuses cursors from previous call (update in-place). Single source fast path
  ## skips sort when only live treap has data.
  ##
  ## Hydrated fast path: CF-0 scans anchored at a COMPLETE hydrated eid are
  ## answered entirely from the in-memory key set (complete + current —
  ## see hydrated.nim). No PageStore descent, no merge.
  ## M4: PARTIAL entries (cold-eid deltas) do NOT take the fast path — the
  ## delta merges with the base below (newest-t wins).  Full-range scans
  ## (prefix < 8B) merge ALL hyd keys (the treap CF-0 is recovery-only).
  var deltaKeys: seq[seq[byte]] = @[]
  if eng.hydEnabled and cf == 0:
    if prefix.len >= 8:
      let eid = decodeEid(beUint64(prefix, 0))
      if eng.hyd.probeComplete(eid):
        return eng.hyd.lookupRange(eid, prefix)
      if eng.hyd.contains(eid):
        deltaKeys = eng.hyd.lookupRangeRaw(eid, prefix)
    else:
      deltaKeys = eng.hyd.allKeys()

  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: TreapNode
  var tree = eng.kv.ps[].trees[cf]
  psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
  if eng.kv.flushRoots.len > 0:
    flushRoot = eng.kv.flushRoots[cf]
  liveRoot = eng.kv.mt.hnd.live[cf]

  # TEMP diagnostics: where do cf≠0 scans spend time post-flush?

  # Reuse or create cursors
  if eng.saCf == cf and eng.saLive != nil:
    # Same CF — update in-place. NOTE: pagestore/flush cursors must be CREATED
    # lazily here too: a CF scanned before its first commitMerge has a default
    # root (no saPs); after the flush publishes a root, the cached-cursor path
    # must pick it up — otherwise every seek misses forever (sourceCount 0).
    if psSnap.rootUuid != default(array[16, byte]):
      if eng.saPs != nil:
        eng.saPs.update(psSnap.rootUuid, psSnap.height)
      else:
        eng.saPs = PageStoreCursor(
          s: eng.kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
          isKv: cf >= 10)
    else:
      eng.saPs = nil
    if flushRoot != nil:
      if eng.saFlush != nil:
        eng.saFlush.update(flushRoot, eng.kv.flushArena)
      else:
        eng.saFlush = newTreapCursor(flushRoot, eng.kv.flushArena)
    else:
      eng.saFlush = nil
    eng.saLive.update(liveRoot, eng.kv.mt.hnd.arena)
  else:
    # Different CF or first call — create new cursors
    if psSnap.rootUuid != default(array[16, byte]):
      eng.saPs = PageStoreCursor(
        s: eng.kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
        isKv: cf >= 10)
    else:
      eng.saPs = nil
    if flushRoot != nil:
      eng.saFlush = newTreapCursor(flushRoot, eng.kv.flushArena)
    else:
      eng.saFlush = nil
    if liveRoot != nil:
      eng.saLive = newTreapCursor(liveRoot, eng.kv.mt.hnd.arena)
    else:
      eng.saLive = nil
    eng.saCf = cf

  # Release treap reader holds when the scan ends — keeps readerCount at 0
  # between calls so batchWrite inserts mutate in-place (no COW path-copy).
  defer:
    if eng.saLive != nil: eng.saLive.release()
    if eng.saFlush != nil: eng.saFlush.release()

  # Count non-empty sources
  var sourceCount = 0
  if eng.saPs != nil and psSnap.rootUuid != default(array[16, byte]): inc sourceCount
  if eng.saFlush != nil and flushRoot != nil: inc sourceCount
  if eng.saLive != nil and liveRoot != nil: inc sourceCount

  if sourceCount == 0:
    if deltaKeys.len > 0:
      deltaKeys.sort(cmpKeysByte)
      var lastPfx: seq[byte] = @[]
      for j in countdown(deltaKeys.len - 1, 0):
        let key = deltaKeys[j]
        let keyPrefix = key[0 ..< key.len - 8]
        if keyPrefix == lastPfx: continue
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 0: result.add key
        lastPfx = keyPrefix
    return

  # ── Fast path: single source (live treap only) ──
  # Skip sort/merge, just collect + dedup + filter.  M4: delta/full-range
  # scans use the sorted multi-source path below (hyd keys join the merge).
  if sourceCount == 1 and eng.saLive != nil and liveRoot != nil and deltaKeys.len == 0:
    eng.saLive.seek(prefix)
    var sourceKeys: seq[seq[byte]] = @[]
    while true:
      let k = eng.saLive.peek()
      if k.isNone: break
      let key = k.get
      if key.len < prefix.len or key[0..<prefix.len] != prefix: break
      sourceKeys.add key
      discard eng.saLive.next()
    # Dedup backward by key-prefix (newest version wins), filter retracted,
    # then emit ASCENDING — same contract as the multi-source path below.
    var kept: seq[seq[byte]] = @[]
    var lastPrefix: seq[byte] = @[]
    for j in countdown(sourceKeys.len - 1, 0):
      let key = sourceKeys[j]
      let keyPrefix = key[0 ..< key.len - 8]
      if keyPrefix != lastPrefix:
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 0:  # not retracted
          kept.add key
        lastPrefix = keyPrefix
    for j in countdown(kept.len - 1, 0):
      result.add kept[j]
    return

  # ── Multi-source path ──
  type SrcKind = enum skPageStore, skTreap
  type Src = object
    case kind: SrcKind
    of skPageStore: ps: PageStoreCursor
    of skTreap: tc: TreapCursor

  var sources: seq[Src] = @[]
  when defined(eavtScanDiag):
    let tSeek = getMonoTime().ticks
  if eng.saPs != nil and psSnap.rootUuid != default(array[16, byte]):
    eng.saPs.seek(prefix)
    when defined(eavtScanDiag):
      if cf != 0:
        eng.diagDescendNs += eng.saPs.lastSeekDescendNs
        eng.diagCrossNs += eng.saPs.lastSeekCrossNs
    sources.add Src(kind: skPageStore, ps: eng.saPs)
  if eng.saFlush != nil and flushRoot != nil:
    eng.saFlush.seek(prefix)
    sources.add Src(kind: skTreap, tc: eng.saFlush)
  if eng.saLive != nil and liveRoot != nil:
    eng.saLive.seek(prefix)
    sources.add Src(kind: skTreap, tc: eng.saLive)
  when defined(eavtScanDiag):
    if cf != 0: eng.diagSeekNs += getMonoTime().ticks - tSeek
    let tIter = getMonoTime().ticks
  when defined(eavtScanDiag):
    if cf != 0:
      inc eng.diagCalls
      defer:
        eng.diagIterNs += getMonoTime().ticks - tIter
        if eng.diagCalls mod 2000 == 0:
          let cache = eng.kv.ps[].cache
          stderr.writeLine("scandiag cf=", cf,
            ": calls=", eng.diagCalls,
            " seekUs=", eng.diagSeekNs div max(eng.diagCalls, 1) div 1000,
            " [descend=", eng.diagDescendNs div max(eng.diagCalls, 1) div 1000,
            " cross=", eng.diagCrossNs div max(eng.diagCalls, 1) div 1000, "]",
            " iterUs=", eng.diagIterNs div max(eng.diagCalls, 1) div 1000,
            " idxPages=", eng.kv.ps[].indexPageLoads,
            " descend: idx=", page_cursor.gDiagIdxNs div max(page_cursor.gDiagDescends,1) div 1000,
            "us bin=", page_cursor.gDiagBinNs div max(page_cursor.gDiagDescends,1) div 1000,
            "us leaf=", page_cursor.gDiagLeafNs div max(page_cursor.gDiagDescends,1) div 1000,
            " n=", page_cursor.gDiagDescends,
            " cacheHits=", cache.hits, " misses=", cache.misses,
            " kindMisses=", cache.kindMisses)

  if sources.len == 0: return

  proc currentKey(s: Src): Option[seq[byte]] =
    case s.kind
    of skPageStore: s.ps.peek()
    of skTreap: s.tc.peek()

  proc advance(s: Src) =
    case s.kind
    of skPageStore: discard s.ps.next()
    of skTreap: discard s.tc.next()

  # 1. Collect from each source with dedup by key-prefix
  var collected: seq[CollectEntry] = @[]
  for i, s in sources:
    var sourceKeys: seq[seq[byte]] = @[]
    while true:
      let k = s.currentKey()
      if k.isNone: break
      let key = k.get
      if key.len < prefix.len or key[0..<prefix.len] != prefix: break
      sourceKeys.add key
      advance(s)
    var lastPrefix: seq[byte] = @[]
    for j in countdown(sourceKeys.len - 1, 0):
      let key = sourceKeys[j]
      let keyPrefix = key[0 ..< key.len - 8]
      if keyPrefix != lastPrefix:
        collected.add((key, i))
        lastPrefix = keyPrefix

  # M4: delta/full-range hyd keys join the merge (raw; the global sort +
  # newest-wins resolves delta vs base — delta carries the higher t)
  for dk in deltaKeys:
    collected.add((dk, sources.len))

  if collected.len == 0: return

  # 2. Merge by full key (ascending)
  collected.sort(proc (a, b: CollectEntry): int {.gcsafe.} =
    let ka = a.key
    let kb = b.key
    let minLen = min(ka.len, kb.len)
    for i in 0 ..< minLen:
      if ka[i] < kb[i]: return -1
      if ka[i] > kb[i]: return 1
    if ka.len < kb.len: return -1
    if ka.len > kb.len: return 1
    return 0
  )

  # 3. Filter: for each unique key-prefix, the NEWEST version wins
  # (ascending sort → walk BACKWARD; first per prefix = highest t).
  # Fix: o código anterior tomava a PRIMEIRA ocorrência (a mais antiga) —
  # um retract após flush ressuscitava o datom no scan.
  var kept: seq[seq[byte]] = @[]
  var lastPrefix: seq[byte] = @[]
  for j in countdown(collected.len - 1, 0):
    let key = collected[j].key
    let keyPrefix = key[0 ..< key.len - 8]
    if keyPrefix == lastPrefix: continue
    let sf = beUint64(key, key.len - 8)
    if (sf and 1) == 0:
      kept.add key
    lastPrefix = keyPrefix
  for j in countdown(kept.len - 1, 0):
    result.add kept[j]

proc resetSpCounters*(eng: EavtEngine) =
  eng.spCount = 0
  eng.spOpenCursorNs = 0
  eng.spSeekNs = 0
  eng.spIterateNs = 0
  eng.spKeysReturned = 0

proc printSpPerf*(eng: EavtEngine) =
  if eng.spCount == 0: return
  let total = eng.spOpenCursorNs + eng.spSeekNs + eng.spIterateNs
  template pct(ns: int64): string = formatFloat(ns.float / total.float * 100, ffDecimal, 1)
  template ms(ns: int64): string = formatFloat(ns.float / 1_000_000, ffDecimal, 1)
  echo "=== scanPrefix perf (", eng.spCount, " calls) ==="
  echo "  openCursor:     ", ms(eng.spOpenCursorNs), " ms  (", pct(eng.spOpenCursorNs), "%)"
  echo "  seek:           ", ms(eng.spSeekNs), " ms  (", pct(eng.spSeekNs), "%)"
  echo "  iterate:        ", ms(eng.spIterateNs), " ms  (", pct(eng.spIterateNs), "%)"
  echo "  total:          ", ms(total), " ms"
  echo "  keys returned:  ", eng.spKeysReturned
  echo "  empty scans:    ", eng.spCount - eng.spKeysReturned

proc estimateCount*(eng: EavtEngine; cf: int; prefix: seq[byte]): int64 =
  ## Count keys matching prefix. Uses seek() to jump to the first match.
  let mc = eng.kv.openScanCursor(cf)
  mc.seek(prefix)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if key.len < prefix.len or key[0..<prefix.len] != prefix: break
    inc result
  result = max(result, 1)

proc estimateIndexSize*(eng: EavtEngine; index: string; bound: openArray[uint64]): float64 =
  ## Cardinality estimate for planner: count keys matching prefix in index CF.
  let cf = keys.cfNameToId(keys.cfForIndex(index))
  let order = keys.indexOrder(index)
  var prefix: seq[byte] = @[]
  for i, pos in order:
    if i < bound.len and bound[i] != 0:
      let v = bound[i]
      prefix.add byte(v shr 56); prefix.add byte((v shr 48) and 0xFF)
      prefix.add byte((v shr 40) and 0xFF); prefix.add byte((v shr 32) and 0xFF)
      prefix.add byte(v shr 24); prefix.add byte((v shr 16) and 0xFF)
      prefix.add byte((v shr 8) and 0xFF); prefix.add byte(v and 0xFF)
  let count = eng.estimateCount(cf, prefix)
  result = float64(count)

proc buildCompileStats*(eng: EavtEngine): CompileStats =
  ## Pre-compute all compile-time statistics with 30s TTL cache.
  let now = epochTime()
  if now - eng.cachedStatsTime < 30.0 and eng.cachedStats.attrIds.len > 0:
    return eng.cachedStats

  var s: CompileStats
  s.attrIds = initTable[string, uint32]()
  s.indexEstimates = initTable[string, float64]()
  s.partitionIds = initTable[string, uint64]()
  s.refAttrs = initHashSet[string]()

  # Collect all declared attributes
  for name, aid in eng.resolver.attrs:
    s.attrIds[name] = aid
    let vt = eng.resolver.valueTypeFor(aid).get(otherwise = 0)
    if vt == 21'u32:  # DbTypeRef
      s.refAttrs.incl(name)
    if eng.resolver.isIndexed(aid):
      s.indexedAttrs.incl(name)

  # Pre-compute index estimates for all 4 indexes (empty prefix = total count).
  # M1..M4: the write state lives OUTSIDE the treap (hyd entries, deferred
  # buffers, anchor hash) — the treap-only count would clamp everything to 1
  # and degenerate the planner's join order (blind-var plans crash the VM).
  for index in ["EAVT", "AEVT", "AVET", "VAET"]:
    let cf = keys.cfNameToId(keys.cfForIndex(index))
    var count = eng.estimateCount(cf, @[])
    case cf
    of 0: count += eng.hyd.numKeys
    of 1: count += eng.deferred[1].len
    of 2: count += eng.anchorHash.len
    of 3: count += eng.deferred[3].len
    else: discard
    s.indexEstimates[index & ":"] = float64(count)

  eng.cachedStats = s
  eng.cachedStatsTime = now
  result = s

type
  Datom* = object
    e*: int64
    a*: uint32
    attrName*: string
    value*: SExpr
    t*: int64
    retracted*: bool

# ── Seed partition counters from existing EAVT data ──

proc seedPartitionCounters*(eng: EavtEngine) =
  ## Walk EAVT (CF 0) to find the highest eid per partition.
  let mc = eng.kv.openScanCursor(0)
  let targets = eng.resolver.knownPartitions()
  var covered: HashSet[uint64] = initHashSet[uint64]()
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if key.len < 8: continue
    let sf = beUint64(key, key.len - 8)
    if (sf and 1) == 1: continue
    let e = decodeEid(beUint64(key, 0))
    let p = partitionOf(e)
    if p in targets:
      eng.resolver.advancePast(e)
      covered.incl p
    if covered.len >= targets.len: break

# ── Bootstrap: scan KV for existing schema ──

proc bootstrapResolver*(eng: EavtEngine) =
  ## Load user attribute schema from db.* datoms.
  var identMap = initTable[int64, string]()
  var vtMap = initTable[int64, uint32]()
  var cardMap = initTable[int64, bool]()
  var uniqueSet = initHashSet[int64]()

  for k in eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(DbIdentAid)]):
    if k.len < 24: continue
    if beUint32(k, 0) != DbIdentAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = decodeEid(beUint64(k, 4))
    if e < BootstrapFirstUserId.int64: continue
    let name = decodeVariableStr(k, 12)
    if name.len > 0: identMap[e] = name

  for k in eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(DbValueTypeAid)]):
    if k.len < 28: continue
    if beUint32(k, 0) != DbValueTypeAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = decodeEid(beUint64(k, 4))
    vtMap[e] = cast[uint32](decodeInt64(beUint64(k, 12)))

  for k in eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(DbCardinalityAid)]):
    if k.len < 28: continue
    if beUint32(k, 0) != DbCardinalityAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = decodeEid(beUint64(k, 4))
    cardMap[e] = cast[uint32](decodeInt64(beUint64(k, 12))) == DbCardinalityManyAid

  # WAL CF-0-only: o resíduo não-flushado (treap CF-0, replay do journal)
  # carrega os datoms de schema como CF-0 — [eid][db-aid][val][sf]; o aid
  # fica nos bytes 8..12, o val em 12.. (mesmo offset do CF-1).
  for k in eng.scanPrefix(0, @[]):
    if k.len < 24: continue
    let aid = beUint32(k, 8)
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let e = decodeEid(beUint64(k, 0))
    case aid
    of DbIdentAid:
      if e >= BootstrapFirstUserId.int64:
        let name = decodeVariableStr(k, 12)
        if name.len > 0: identMap[e] = name
    of DbValueTypeAid:
      if e >= BootstrapFirstUserId.int64:
        vtMap[e] = cast[uint32](decodeInt64(beUint64(k, 12)))
    of DbCardinalityAid:
      if e >= BootstrapFirstUserId.int64:
        cardMap[e] = cast[uint32](decodeInt64(beUint64(k, 12))) == DbCardinalityManyAid
    of DbUniqueAid:
      if e >= BootstrapFirstUserId.int64: uniqueSet.incl(e)
    else: discard

  for k in eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(DbUniqueAid)]):
    if k.len < 20: continue
    if beUint32(k, 0) != DbUniqueAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    uniqueSet.incl decodeEid(beUint64(k, 4))

  for e, name in identMap:
    let vt = vtMap.getOrDefault(e, DbTypeString)
    let many = cardMap.getOrDefault(e, false)
    let unique = e in uniqueSet
    eng.resolver.loadUserAttr(name, e, vt, many, unique, false)
  var cf1snap = ""
  if eng.kv.ps != nil and eng.kv.ps[].trees.len > 1:
    let t = eng.kv.ps[].trees[1]
    var hex = ""
    for b in t.rootUuid: hex.add toHex(b)
    cf1snap = " cf1=h" & $t.height & "/" & hex[0 ..< 8] &
              " leaves=" & $t.numLeaves
  logInfo("resolver", "bootstrap: " & $identMap.len & " user attrs, " &
    $uniqueSet.len & " unique" & cf1snap)

  seedPartitionCounters(eng)

# ── Save a datom ──

proc eavtSave*(eng: EavtEngine; eid: int64; attrName: string;
                value: string; t: int64): int64 {.discardable.} =
  let attrId = eng.resolver.internAttr(attrName)
  let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
  let many = eng.resolver.isMany(attrId)
  let mode = valueTypeToEncodeMode(vt)
  # REF: o valor carrega o eid do alvo (port do engine.py ref_eid=int(value)).
  let encoded =
    if mode == emRef:
      try: encodeValue(value, mode, parseInt(value))
      except ValueError:
        raise newException(ValueError,
          "REF value must be an entity id, got: \"" & value & "\"")
    else: encodeValue(value, mode, 0)
  let indexed = eng.resolver.isIndexed(attrId)
  if not many:
    # Retract any existing active datoms for this eid+attr.
    var ePrefix = encodeEid(eid)
    ePrefix.add byte(attrId shr 24); ePrefix.add byte((attrId shr 16) and 0xFF)
    ePrefix.add byte((attrId shr 8) and 0xFF); ePrefix.add byte(attrId and 0xFF)
    for ek in eng.scanPrefix(0, ePrefix):
      if ek.len < 20: continue
      let esf = beUint64(ek, ek.len - 8)
      if (esf and 1) != 0: continue
      var retEntries = buildEavtEntries(eng.kv.mt.hnd.arena, eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
      eng.batchWrite(retEntries)
  var entries = buildEavtEntries(eng.kv.mt.hnd.arena, eid, attrId, encoded, t, false, mode, indexed)
  eng.batchWrite(entries)
  return eid

proc eavtRetract*(eng: EavtEngine; eid: int64; attrName: string;
                   value: string; t: int64) =
  let attrId = eng.resolver.internAttr(attrName)
  let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded =
    if mode == emRef:
      try: encodeValue(value, mode, parseInt(value))
      except ValueError:
        raise newException(ValueError,
          "REF value must be an entity id, got: \"" & value & "\"")
    else: encodeValue(value, mode, 0)
  let indexed = eng.resolver.isIndexed(attrId)
  var entries = buildEavtEntries(eng.kv.mt.hnd.arena, eid, attrId, encoded, t, true, mode, indexed)
  eng.batchWrite(entries)

# ── Tx allocation + as-of resolution ──

proc nowMicros(): uint64 =
  let t = getTime()
  t.toUnix.uint64 * 1_000_000 + (t.nanosecond div 1000).uint64

proc allocateTAndWriteTx*(eng: EavtEngine): int64 =
  ## Allocate a fresh tx entity and write its db.txInstant datom.
  ## Port of Rust EavtEngine::allocate_t_and_write_tx.
  let txEid = eng.resolver.allocateInPartition(PartTx)
  let encoded = encodeValue($nowMicros(), emFixed, 0)
  var entries = buildEavtEntries(eng.kv.mt.hnd.arena, txEid, DbTxInstantAid, encoded, txEid,
                                  false, emFixed, false)
  eng.batchWrite(entries)
  return txEid

proc resolveAsOfTx*(eng: EavtEngine; asOfUs: uint64): Option[uint64] =
  ## Resolve an as-of timestamp (micros) to the newest tx entity whose
  ## db.txInstant is <= it. Port of Rust EavtEngine::resolve_as_of_tx.
  if asOfUs == uint64.high: return none[uint64]()
  if (asOfUs shr 44) == PartTx: return some(asOfUs)  # already a tx eid
  # aevt key: [attr 4B BE][eid 8B BE][val][sf 8B BE]
  var prefix = @[0'u8, 0'u8, 0'u8, byte(DbTxInstantAid)]
  var bestTx = 0'u64
  var bestInst = 0'u64
  var found = false
  for k in eng.scanPrefix(1, prefix):
    if k.len < 28: continue  # 4 + 8 + 8 + 8
    if beUint32(k, 0) != DbTxInstantAid: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue  # retracted
    let us = decodeInt64(beUint64(k, 12))
    if us < 0: continue
    let usU = cast[uint64](us)
    if usU <= asOfUs and (not found or usU > bestInst):
      bestTx = beUint64(k, 4)
      bestInst = usU
      found = true
  if found: some(bestTx) else: none[uint64]()

proc eavtDeclareAttr*(eng: EavtEngine; name: string; valueType: uint32;
                       many: bool; unique: bool = false): (uint32, bool) =
  let canonical = normalizeAttr(name)
  let (aid, isNew) = eng.resolver.declareAttr(canonical, valueType, many)
  if unique: eng.resolver.setUnique(aid, true)
  if isNew or unique:
    eng.cachedStatsTime = 0  # invalidate cache (novos attrs e mudança de unique)
  if isNew:
    # Persist schema as db.* datoms (Rust declare_attr_with_t).
    # The ident datom carries the CANONICAL name (same form the in-memory
    # resolver table uses) — replica bootstrap reads this datom raw, so a
    # raw name here would make transactor and replica disagree on lookup.
    let t = eng.resolver.allocateInPartition(PartTx)
    let e = aid.int64
    var bwTmp1 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbIdentAid,
      encodeValue(canonical, emVariable, 0), e, false, emVariable, true)
    eng.batchWrite(bwTmp1)
    var bwTmp2 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbValueTypeAid,
      encodeValue($valueType, emFixed, 0), t, false, emFixed, true)
    eng.batchWrite(bwTmp2)
    let cardId = if many: DbCardinalityManyAid else: DbCardinalityOneAid
    var bwTmp3 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbCardinalityAid,
      encodeValue($cardId, emFixed, 0), t, false, emFixed, true)
    eng.batchWrite(bwTmp3)
  if unique:
    # Persist db.unique FORA do if isNew: redeclarar UNIQUE sobre um attr
    # existente atualiza o resolver em memória, mas sem o datom a flag só
    # existe neste engine — réplicas nunca a recebem via WAL e ela se perde
    # no restart. Gravação idempotente (put).
    let t = eng.resolver.allocateInPartition(PartTx)
    let e = aid.int64
    var bwTmp4 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbUniqueAid,
      encodeValue($DbUniqueIdentityAid, emFixed, 0), t, false, emFixed, true)
    eng.batchWrite(bwTmp4)
  return (aid, isNew)

proc bootstrapSystemAttrs*(eng: EavtEngine) =
  ## Write EAVT datoms for all built-in schema attributes if not already done.
  ## Checks for existing db.ident datom to avoid re-bootstrapping.

  # Check if already bootstrapped by looking for any db.ident entity
  let probeKeys = eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(DbIdentAid)])
  var bootstrapped = false
  for k in probeKeys:
    if k.len >= 24:
      let e = decodeEid(beUint64(k, 4))
      if e == DbIdentAid.int64:
        bootstrapped = true; break
  if bootstrapped: return

  let tx = eng.resolver.allocateInPartition(PartTx)

  proc meta(name: string): tuple[vt: uint32, cardId: uint32, uniqueId: uint32] =
    let vt = if name in ["db/ident", "db.part/id"]: DbTypeString
             elif name == "db/txInstant": DbTypeInstant
             elif name in ["db/isComponent", "db/index", "db/fulltext", "db/noHistory"]: DbTypeBoolean
             else: DbTypeRef
    let cardId = DbCardinalityOneAid
    let uniqueId = (if name == "db/unique/value": DbUniqueValueAid
                    elif name == "db/unique/identity": DbUniqueIdentityAid
                    else: 0'u32)
    (vt, cardId, uniqueId)

  for (name, aid) in BootstrapSchema:
    let (vt, cardId, uniqueId) = meta(name)
    let e = aid.int64
    var bwTmp5 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbIdentAid,
      encodeValue(name, emVariable, 0), tx, false, emVariable, true)
    eng.batchWrite(bwTmp5)
    var bwTmp6 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbValueTypeAid,
      encodeValue("", emRef, vt.int64), tx, false, emRef, true)
    eng.batchWrite(bwTmp6)
    var bwTmp7 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbCardinalityAid,
      encodeValue("", emRef, cardId.int64), tx, false, emRef, true)
    eng.batchWrite(bwTmp7)
    if uniqueId != 0:
      var bwTmp8 = buildEavtEntries(eng.kv.mt.hnd.arena, e, DbUniqueAid,
        encodeValue("", emRef, uniqueId.int64), tx, false, emRef, true)
      eng.batchWrite(bwTmp8)

# ── Resolver accessors ──

proc lookupAttr*(eng: EavtEngine; name: string): Option[uint32] =
  eng.resolver.lookupAttr(name)

proc attrName*(eng: EavtEngine; aid: uint32): string =
  eng.resolver.attrName(aid)

proc allocateEntityId*(eng: EavtEngine): int64 =
  let eid = eng.resolver.allocateInPartition(PartUser)
  # Mark hydrated (same contract as allocateInPartition below).
  if eng.hydEnabled:
    eng.hyd.hydrateEmpty(eid)
  eid

proc isDeclared*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isDeclared(aid)

proc isMany*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isMany(aid)

proc isUnique*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isUnique(aid)

proc valueTypeFor*(eng: EavtEngine; aid: uint32): Option[uint32] =
  eng.resolver.valueTypeFor(aid)

proc allocateInPartition*(eng: EavtEngine; pid: uint64): int64 =
  let eid = eng.resolver.allocateInPartition(pid)
  # New entity starts hydrated (empty): its first saves mirror into the
  # source via batchWrite, so every later lookup hits the fast path.
  if eng.hydEnabled:
    eng.hyd.hydrateEmpty(eid)
  eid

proc hydrateEid*(eng: EavtEngine; eid: int64) =
  ## Read-time hydration: install the full active CF-0 key set for `eid`.
  ## No-op when disabled or already hydrated. The scan itself runs the normal
  ## multi-source path — the eid is not a member yet, so the fast path skips.
  ## Entities with no datoms are left unhydrated (don't spend budget on
  ## phantoms); empty-by-construction entities created via allocateInPartition
  ## are members already.
  if not eng.hydEnabled: return
  if eng.hyd.contains(eid): return
  let ks = eng.scanPrefixActive(0, keys.encodeEid(eid))
  if ks.len > 0:
    eng.hyd.hydrate(eid, ks)

proc declarePartition*(eng: EavtEngine; name: string): uint64 =
  eng.resolver.declarePartition(name)

proc partitionIdFor*(eng: EavtEngine; name: string): Option[uint64] =
  eng.resolver.partitionIdFor(name)

proc defaultUserPartition*(eng: EavtEngine): uint64 =
  PartUser

iterator scanDatoms*(eng: EavtEngine; cf: int): Datom =
  let mc = eng.kv.openScanCursor(cf)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if key.len < 20: continue

    let suffixRaw = beUint64(key, key.len - 8)
    let (t, retracted) = decodeSuffix(suffixRaw)

    var eid: int64
    var aid: uint32
    var vStart: int
    var vEnd: int

    case cf
    of 0:
      eid = decodeEid(beUint64(key, 0))
      aid = beUint32(key, 8)
      vStart = 12; vEnd = key.len - 8
    of 1:
      aid = beUint32(key, 0)
      eid = decodeEid(beUint64(key, 4))
      vStart = 12; vEnd = key.len - 8
    of 2:
      aid = beUint32(key, 0)
      vStart = 4; vEnd = key.len - 16
      eid = decodeEid(beUint64(key, key.len - 16))
    of 3:
      vStart = 0; vEnd = key.len - 20
      eid = decodeEid(beUint64(key, key.len - 12))
      aid = beUint32(key, key.len - 16)
    else: continue

    if vEnd <= vStart: continue

    let rawValue = key[vStart..<vEnd]
    let vt = eng.valueTypeFor(aid).get(otherwise = DbTypeString)
    let valSexpr = decodeStoredValue(rawValue, vt)
    let attrName = eng.attrName(aid)

    yield Datom(e: eid, a: aid, attrName: attrName,
                value: valSexpr, t: t, retracted: retracted)

proc allocateTDeferred*(eng: EavtEngine): int64 =
  ## Allocate a fresh tx entity WITHOUT writing its db.txInstant datom.
  ## The interpreter appends the datom to the tx's main batchWrite instead
  ## (one storage cycle per tx, not two).  Callers that want the datom
  ## written immediately keep using allocateTAndWriteTx.
  eng.resolver.allocateInPartition(PartTx)

proc txInstantEntry*(eng: EavtEngine; txEid: int64): seq[EavtEntry] =
  ## The deferred db.txInstant datom for a txEid from allocateTDeferred —
  ## built like allocateTAndWriteTx writes it.
  let encoded = encodeValue($nowMicros(), emFixed, 0)
  buildEavtEntries(eng.kv.mt.hnd.arena, txEid, DbTxInstantAid, encoded, txEid,
                   false, emFixed, false)

proc batchLookupAvet*(eng: EavtEngine;
                      keys: seq[seq[byte]]): seq[Option[int64]] =
  ## Batched unique-index lookups (AVET, CF-2).  `keys` are prefixes
  ## [aid 4B][value]; results are POSITIONAL — the eid of the first active
  ## datom with that prefix, or none.  Identical prefixes are deduped and
  ## scanned in sorted order (seek locality); each distinct prefix reuses
  ## the scanPrefixActive cursor machinery (in-place update per CF).
  ## Stateless across txs — concurrency-safe.
  result = newSeq[Option[int64]](keys.len)
  if keys.len == 0: return
  var order = newSeq[int](keys.len)
  for i in 0 ..< keys.len: order[i] = i
  order.sort() do(a, b: int) -> int:
    if keys[a].len != keys[b].len: return cmp(keys[a].len, keys[b].len)
    for i in 0 ..< keys[a].len:
      if keys[a][i] != keys[b][i]:
        return cmp(keys[a][i], keys[b][i])
    return 0
  var lastIdx = -1              # dedup: previous sorted entry with same key
  for oi in 0 ..< order.len:
    let i = order[oi]
    if lastIdx >= 0 and keys[order[lastIdx]] == keys[i]:
      result[i] = result[order[lastIdx]]
      continue
    let scanRes = eng.scanPrefixActive(2, keys[i])
    if scanRes.len > 0 and scanRes[0].len >= 20:
      result[i] = some(decodeEid(beUint64(scanRes[0], scanRes[0].len - 16)))
    lastIdx = oi

proc lookupEntityByValue*(eng: EavtEngine; attrName: string; value: string): Option[int64] =
  ## Unique-attr anchor lookup (test/recovery helper): hash probe first
  ## (unflushed), CF-2 scan fallback (committed).
  let aidOpt = eng.lookupAttr(attrName)
  if aidOpt.isNone: return none[int64]()
  let aid = aidOpt.get
  let vt = eng.valueTypeFor(aid).get(DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  var prefix = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
                byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  prefix.add encodeValue(value, mode, 0)
  if eng.anchorHash.hasKey(prefix):
    let full = eng.anchorHash[prefix]
    let eid = decodeEid(beUint64(full, full.len - 16))
    eng.hydrateEid(eid)
    return some(eid)
  for k in eng.scanPrefixActive(2, prefix):
    if k.len >= 20:
      let eid = decodeEid(beUint64(k, k.len - 16))
      eng.hydrateEid(eid)
      return some(eid)
  return none[int64]()

proc lookupValueStr*(eng: EavtEngine; eid: int64; attrName: string): Option[string] =
  ## Read a string attr value for `eid` (test/recovery helper).
  let aidOpt = eng.lookupAttr(attrName)
  if aidOpt.isNone: return none[string]()
  let aid = aidOpt.get
  var prefix = keys.encodeEid(eid)
  prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
  prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
  for k in eng.scanPrefixActive(0, prefix):
    if k.len < 20: continue
    let sf = beUint64(k, k.len - 8)
    if (sf and 1) == 1: continue
    let vt = eng.valueTypeFor(aid).get(resolver.DbTypeString)
    let mode = valueTypeToEncodeMode(vt)
    let sx = decodeStoredValue(k[12 ..< k.len - 8], vt)
    if sx.kind == sStr: return some(sx.sval)
    return none[string]()
  return none[string]()

proc recoverWriteState*(eng: EavtEngine) =
  ## WAL CF-0-only recovery: route the journal-replay residue (treap CF-0)
  ## through the write structures — hyd partial entries + deferred CF-1/3 +
  ## anchor hash CF-2.  The treap is recovery STAGING only; the write path
  ## lives in the M1..M3 structures.  Called once at bootstrap, AFTER
  ## bootstrapResolver (needs isIndexed/ref metadata).  No journaling: the
  ## journal is the source of these datoms.
  ## The residue STAYS in the treap (reads merge it; the flush drains both
  ## — idempotent in the pagestore).
  let mc = eng.kv.openScanCursor(0)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if key.len < 20: continue
    let aid = beUint32(key, 8)
    if aid == DbTxInstantAid: continue      # datoms do tx-entity: ruído de recovery
    if eng.hydEnabled:
      let eid = decodeEid(beUint64(key, 0))
      if not eng.hyd.contains(eid):
        discard eng.hyd.ensurePartial(eid)
      eng.hyd.applyKey(KeyRef(p: cast[ptr UncheckedArray[byte]](unsafeAddr key[0]),
                         len: key.len))
    # CF-1 [aid][eid][val][sf] — sempre
    var k1 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
              byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    k1.add key[0 ..< 8]
    k1.add key[12 ..< key.len]
    eng.deferred[1].add(k1)
    eng.deferredBytes += k1.len.int64
    if eng.resolver.isIndexed(aid):
      # CF-2 [aid][val][eid][sf]
      var k2 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
                byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
      k2.add key[12 ..< key.len - 8]
      k2.add key[0 ..< 8]
      k2.add key[key.len - 8 ..< key.len]
      eng.anchorHash[k2[0 ..< k2.len - 16]] = k2
      eng.anchorBytes += k2.len.int64
    if eng.resolver.valueTypeFor(aid).get(0) == DbTypeRef:
      # CF-3 [val][aid][eid][sf]
      var k3 = key[12 ..< key.len - 8]
      k3.add @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
              byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
      k3.add key[0 ..< 8]
      k3.add key[key.len - 8 ..< key.len]
      eng.deferred[3].add(k3)
      eng.deferredBytes += k3.len.int64
