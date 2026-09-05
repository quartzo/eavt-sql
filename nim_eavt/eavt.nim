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
import query/cursor   # cursor constructors
import nim_memtable/memtypes  # KeyRef, cmpKeysByte, CfKey
import nim_memtable/runs  # MemTable/Run (M8)
import nim_memtable/run_cursor  # RunCursor
import scheme
import stats
import hydrated
import anchor_index
export anchor_index

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
    saRunCursors*: seq[RunCursor]  ## draining + active, ordem fixa por chamada
    saCf*: int
    saGen*: uint64                 ## mt.gen na última coleta de fontes
    # scanPrefix perf counters
    spCount*: int64
    spOpenCursorNs*: int64
    spSeekNs*: int64
    spIterateNs*: int64
    spKeysReturned*: int64
    # Hydrated-eid source (CF 0 fast path) — see hydrated.nim
    hydEnabled*: bool
    hyd*: HydratedSet
    # M7: CF-2 anchor index as a PACKED hash — [aid 4B][val] → eid, permanent
    # with LRU eviction under `anchor_index_max_bytes`.  The treap CF-2
    # remains the durable write state; the index is a write-through read
    # mirror kept current by batchWrite — an evicted (or absent) anchor
    # falls back to the CF-2 scan.
    anchors*: AnchorIndex
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
  ## `hydrated_max_bytes` (bytes, default 1 GiB),
  ## `anchor_index_max_bytes` (bytes, default 256 MiB).
  let enabled = cfg.getOrDefault("hydrated_enabled", "true") != "false"
  let maxBytes = block:
    let v = cfg.getOrDefault("hydrated_max_bytes", "")
    if v.len > 0: parseInt(v) else: DefaultHydratedMaxBytes
  let anchorMax = block:
    let v = cfg.getOrDefault("anchor_index_max_bytes", "")
    if v.len > 0: parseInt(v) else: DefaultAnchorMaxBytes
  result = EavtEngine(
    kv: kv,
    resolver: newResolver(),
    hydEnabled: enabled,
    hyd: newHydratedSet(maxBytes),
    anchors: newAnchorIndex(anchorMax),
  )
  # M7: the run-ladder memtable holds ALL CFs and the anchor index is a
  # permanent read mirror — the generic KVStore flush needs no engine
  # cooperation, so no flush hooks are installed here.
  # bootstrap called after construction (avoids forward ref)

proc newEavtEngine*(kv: KVStore): EavtEngine =
  newEavtEngine(kv, initTable[string, string]())

# ── Batch write helper ──

proc batchWrite*(eng: EavtEngine; entries: var seq[EavtEntry]) =
  ## Consumes the entries: keys are arena-written by buildEavtEntries and
  ## referenced (ptr+len) into CfKey — zero copy on the load path.
  ##
  ## M6 write path: the run-ladder memtable holds ALL CFs again — every key
  ## (CF-0 datom + CF-1/2/3 indexes built by buildEavtEntries) enters the
  ## memtable and the generic flush carries it to the pagestore.  The WAL
  ## stays CF-0-only (the datom is the truth — CF-1/2/3 are re-derived at
  ## replay).  CF-2 keys are additionally mirrored into the anchor hash
  ## (M3' read-side O(1) unique lookup), and CF-0 keys are mirrored into
  ## the hydrated cache (read-your-writes).
  if entries.len == 0: return
  var cfs = newSeq[CfKey](entries.len)
  var durable = newSeq[CfKey]()   # CF-0 → WAL
  var n = 0
  for e in entries:
    if e.cf == 2:
      # M7: anchor index — write-through mirror of the unique anchors.
      # Key layout: [aid 4B][val][eid 8B][sf 8B] — parsed in place
      # (zero copy); put copies into the arena.  Retract (sf bit 1)
      # removes the mapping.
      let k = e.key
      let sf = beUint64(k.p.toOpenArray(0, k.len - 1), k.len - 8)
      let aid = beUint32(k.p.toOpenArray(0, k.len - 1), 0)
      if (sf and 1) == 0:
        let eid = decodeEid(beUint64(k.p.toOpenArray(0, k.len - 1), k.len - 16))
        eng.anchors.put(aid, k.p.toOpenArray(4, k.len - 17), eid)
      else:
        eng.anchors.del(aid, k.p.toOpenArray(4, k.len - 17))
    cfs[n] = CfKey(cf: e.cf, key: e.key)
    inc n
    if e.cf == 0:
      durable.add CfKey(cf: e.cf, key: e.key)
  cfs.setLen(n)
  # WAL CF-0-only: o datom (CF-0) é a verdade — CF-1/2/3 são derivados e
  # re-derivados no replay (transactor routing + réplica).
  if durable.len > 0: eng.kv.journalOnly(durable)
  # Mirror de leitura: CF-0 → cache hidratado (read-your-writes). Antes do
  # batchMove — os bytes emprestados (arena) são copiados pelo applyKey.
  if eng.hydEnabled:
    for d in durable:
      eng.hyd.applyKey(d.key)
  # M6: journal=false — o journalOnly acima já cobriu o CF-0; CF-1/2/3 não
  # vão ao WAL.  A escada de runs recebe TODOS os CFs (memtable).
  eng.kv.batchWrite(cfs, journal = false)

proc batchWriteForeignKeys*(eng: EavtEngine;
                            keys: openArray[tuple[cf: uint8, key: seq[byte]]]) =
  ## Route datom/index keys that are NOT arena-owned (replica WAL frames,
  ## tests) through the write path.  batchWrite REFERENCES the key bytes
  ## (batchMove contract — arena-written by buildEavtEntries); foreign
  ## buffers die with their frame, so each key is copied into the memtable
  ## arena first.  The copy is stable for the memtable's lifetime: the
  ## flush capture swaps the arena but keeps it alive via flushArena while
  ## the captured roots reference its bytes.
  if keys.len == 0: return
  let arena = eng.kv.mt.arenaScratch()
  var entries = newSeqOfCap[EavtEntry](keys.len)
  for k in keys:
    if k.key.len < 20: continue
    let dst = allocKeyBytes(arena, k.key.len)
    copyMem(addr dst[0], unsafeAddr k.key[0], k.key.len)
    entries.add EavtEntry(cf: k.cf, key: KeyRef(p: dst, len: k.key.len))
  eng.batchWrite(entries)

proc batchWriteForeign*(eng: EavtEngine; keys: openArray[seq[byte]]) =
  ## CF-0-only convenience wrapper over batchWriteForeignKeys.
  var expanded = newSeqOfCap[tuple[cf: uint8, key: seq[byte]]](keys.len)
  for k in keys:
    expanded.add (0'u8, k)
  eng.batchWriteForeignKeys(expanded)

proc scanPrefix*(eng: EavtEngine; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  ## Scan keys in CF matching prefix. Reuses cursor from previous call —
  ## updates in-place if roots changed, then seeks to new prefix.
  ## M6: raw view is served entirely by the storage cursors — the treap
  ## CF-0 is the memtable again (active + tombstones + versions).
  eng.spCount += 1
  var t0 = getMonoTime()

  # Read current roots
  var tree = eng.kv.ps[].trees[cf]
  let psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)

  if eng.spCursor == nil or eng.spCf != cf:
    # First call or different CF — create cursor from scratch
    eng.spCursor = eng.kv.openScanCursor(cf)
    eng.spCf = cf
  else:
    # Same CF — update in-place (runs re-coletadas só quando mt.gen muda)
    eng.kv.mt.ensureMaterialized(cf)
    eng.spCursor.update(psSnap.rootUuid, psSnap.height,
                        eng.kv.mt.draining[cf], eng.kv.mt.runs[cf],
                        eng.kv.mt.gen)

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
  eng.spIterateNs += (getMonoTime().ticks - t0.ticks)
  eng.spKeysReturned += result.len

type
  CollectEntry = tuple[key: seq[byte], srcIdx: int]

proc scanPrefixActive*(eng: EavtEngine; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  ## Scan keys in CF matching prefix. Returns only active (non-retracted) datoms.
  ## Reuses cursors from previous call (update in-place). Single source fast path
  ## skips sort when only live treap has data.
  ##
  ## Hydrated fast path: CF-0 scans anchored at a hydrated eid are answered
  ## entirely from the in-memory key set (complete + current — see
  ## hydrated.nim). No PageStore descent, no merge.
  if eng.hydEnabled and cf == 0 and prefix.len >= 8:
    let eid = decodeEid(beUint64(prefix, 0))
    if eng.hyd.probeComplete(eid):
      return eng.hyd.lookupRange(eid, prefix)

  var tree = eng.kv.ps[].trees[cf]
  let psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)

  # TEMP diagnostics: where do cf≠0 scans spend time post-flush?

  # PageStore cursor: reuse in-place (root change é a única invalidação).
  # Criado LAZILY: um CF antes do primeiro commitMerge tem root default; após
  # o flush publicar, o caminho cacheado precisa pegá-lo.
  if psSnap.rootUuid != default(array[16, byte]):
    if eng.saCf == cf and eng.saPs != nil:
      eng.saPs.update(psSnap.rootUuid, psSnap.height)
    else:
      eng.saPs = PageStoreCursor(
        s: eng.kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
        isKv: cf >= 10)
  else:
    eng.saPs = nil

  # Run sources: re-coletadas quando o CF muda OU a geração do memtable
  # mudou (materialize/merge/freeze/publish). RunCursor é barato — refs.
  eng.kv.mt.ensureMaterialized(cf)
  if eng.saCf != cf or eng.saGen != eng.kv.mt.gen:
    eng.saRunCursors = @[]
    for r in eng.kv.mt.draining[cf]: eng.saRunCursors.add(newRunCursor(r))
    for r in eng.kv.mt.runs[cf]: eng.saRunCursors.add(newRunCursor(r))
    eng.saGen = eng.kv.mt.gen
  eng.saCf = cf

  # Count non-empty sources — re-seek dos runs: cursores reutilizados
  # chegam consumidos do scan anterior (seek reseta pos/atEnd).
  var sourceCount = 0
  if eng.saPs != nil and psSnap.rootUuid != default(array[16, byte]): inc sourceCount
  for rc in eng.saRunCursors:
    rc.seek(prefix)
    if not rc.atEnd: inc sourceCount

  if sourceCount == 0:
    return

  # ── Fast path: single run, sem pagestore ──
  # Skip sort/merge, just collect + dedup + filter.
  if sourceCount == 1 and eng.saRunCursors.len == 1:
    let rc = eng.saRunCursors[0]
    rc.seek(prefix)
    var sourceKeys: seq[seq[byte]] = @[]
    while true:
      let k = rc.peek()
      if k.isNone: break
      let key = k.get
      if key.len < prefix.len or key[0..<prefix.len] != prefix: break
      sourceKeys.add key
      discard rc.next()
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
  type SrcKind = enum skPageStore, skRun
  type Src = object
    case kind: SrcKind
    of skPageStore: ps: PageStoreCursor
    of skRun: rc: RunCursor

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
  for rc in eng.saRunCursors:
    if not rc.atEnd:
      rc.seek(prefix)
      sources.add Src(kind: skRun, rc: rc)
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
    of skRun: s.rc.peek()

  proc advance(s: Src) =
    case s.kind
    of skPageStore: discard s.ps.next()
    of skRun: discard s.rc.next()

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
  # M6: the run-ladder memtable holds all CFs — the storage cursor count is
  # complete (memtable + flush + pagestore), no write-state adjustments.
  for index in ["EAVT", "AEVT", "AVET", "VAET"]:
    let cf = keys.cfNameToId(keys.cfForIndex(index))
    let count = eng.estimateCount(cf, @[])
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
      var retEntries = buildEavtEntries(eng.kv.mt.arenaScratch(), eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
      eng.batchWrite(retEntries)
  var entries = buildEavtEntries(eng.kv.mt.arenaScratch(), eid, attrId, encoded, t, false, mode, indexed)
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
  var entries = buildEavtEntries(eng.kv.mt.arenaScratch(), eid, attrId, encoded, t, true, mode, indexed)
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
  var entries = buildEavtEntries(eng.kv.mt.arenaScratch(), txEid, DbTxInstantAid, encoded, txEid,
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
    var bwTmp1 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbIdentAid,
      encodeValue(canonical, emVariable, 0), e, false, emVariable, true)
    eng.batchWrite(bwTmp1)
    var bwTmp2 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbValueTypeAid,
      encodeValue($valueType, emFixed, 0), t, false, emFixed, true)
    eng.batchWrite(bwTmp2)
    let cardId = if many: DbCardinalityManyAid else: DbCardinalityOneAid
    var bwTmp3 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbCardinalityAid,
      encodeValue($cardId, emFixed, 0), t, false, emFixed, true)
    eng.batchWrite(bwTmp3)
  if unique:
    # Persist db.unique FORA do if isNew: redeclarar UNIQUE sobre um attr
    # existente atualiza o resolver em memória, mas sem o datom a flag só
    # existe neste engine — réplicas nunca a recebem via WAL e ela se perde
    # no restart. Gravação idempotente (put).
    let t = eng.resolver.allocateInPartition(PartTx)
    let e = aid.int64
    var bwTmp4 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbUniqueAid,
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
    var bwTmp5 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbIdentAid,
      encodeValue(name, emVariable, 0), tx, false, emVariable, true)
    eng.batchWrite(bwTmp5)
    var bwTmp6 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbValueTypeAid,
      encodeValue("", emRef, vt.int64), tx, false, emRef, true)
    eng.batchWrite(bwTmp6)
    var bwTmp7 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbCardinalityAid,
      encodeValue("", emRef, cardId.int64), tx, false, emRef, true)
    eng.batchWrite(bwTmp7)
    if uniqueId != 0:
      var bwTmp8 = buildEavtEntries(eng.kv.mt.arenaScratch(), e, DbUniqueAid,
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
  ## No-op when disabled or already hydrated.  Entities with no datoms are
  ## left unhydrated (don't spend budget on phantoms); empty-by-construction
  ## entities created via allocateInPartition are members already.
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
  buildEavtEntries(eng.kv.mt.arenaScratch(), txEid, DbTxInstantAid, encoded, txEid,
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
  ## Unique-attr anchor lookup (test/recovery helper): anchor index probe
  ## first (O(1), permanent), CF-2 scan fallback (also correct).
  let aidOpt = eng.lookupAttr(attrName)
  if aidOpt.isNone: return none[int64]()
  let aid = aidOpt.get
  let vt = eng.valueTypeFor(aid).get(DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(value, mode, 0)
  let hit = eng.anchors.probe(aid, encoded)
  if hit.isSome:
    let eid = hit.get
    eng.hydrateEid(eid)
    return some(eid)
  var prefix = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
                byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  prefix.add encoded
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

proc deriveIndexKeys*(k: seq[byte]; indexed, isRef: bool):
    seq[tuple[cf: uint8, key: seq[byte]]] =
  ## Byte reshuffle of one CF-0 datom key ([eid 8B][aid 4B][val][sf 8B]) into
  ## its derived index keys — CF-1 always, CF-2 if indexed, CF-3 if ref.
  ## Same derivation the flush worker did under M5; used by recovery (the
  ## WAL is CF-0-only, the residue needs its index keys rebuilt).  Owned
  ## copies — the caller borrows them into CfKey just for the mt.batch call
  ## (which copies into the arena).
  if k.len < 20: return
  let aid = beUint32(k, 8)
  var k1 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
            byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  k1.add k[0 ..< 8]
  k1.add k[12 ..< k.len]
  result.add (1'u8, k1)
  if indexed:
    var k2 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
              byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    k2.add k[12 ..< k.len - 8]
    k2.add k[0 ..< 8]
    k2.add k[k.len - 8 ..< k.len]
    result.add (2'u8, k2)
  if isRef:
    var k3 = k[12 ..< k.len - 8]
    k3.add @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
            byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
    k3.add k[0 ..< 8]
    k3.add k[k.len - 8 ..< k.len]
    result.add (3'u8, k3)

proc recoverWriteState*(eng: EavtEngine) =
  ## WAL CF-0-only recovery (M6): the journal carries the datom (CF-0) only,
  ## so the replay residue in the treap needs its DERIVED index keys rebuilt
  ## — CF-1 always, CF-2 if indexed (+ anchor hash for the O(1) probe), CF-3
  ## if ref — including retracts (index tombstones; otherwise the pagestore's
  ## older active version resurrects).  The residue STAYS in the treap: with
  ## M6 the treap IS the memtable.  Called once at bootstrap, AFTER
  ## bootstrapResolver.  No journaling: the datom is already durable in the
  ## WAL.
  var derivedKeys: seq[tuple[cf: uint8, key: seq[byte]]] = @[]
  let mc = eng.kv.openScanCursor(0)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if key.len < 20: continue
    let aid = beUint32(key, 8)
    if aid == DbTxInstantAid: continue      # datoms do tx-entity: ruído de recovery
    let sf = beUint64(key, key.len - 8)
    let retracted = (sf and 1) == 1
    let indexed = eng.resolver.isIndexed(aid)
    var isRef = false
    if not retracted:
      try:
        let vt = eng.resolver.valueTypeFor(aid)
        isRef = vt.isSome and vt.get == DbTypeRef
      except KeyError:
        discard  # unknown aid: not a ref (recovery best-effort)
    for d in deriveIndexKeys(key, indexed, isRef):
      derivedKeys.add d
    if not retracted and indexed:
      # anchor index rebuild: [aid][val] → eid for the O(1) probe
      eng.anchors.put(aid, key.toOpenArray(12, key.len - 9),
                      decodeEid(beUint64(key, 0)))
  # Treap insert without journaling (the datom is the durable truth) — the
  # KeyRefs borrow derivedKeys only for the duration of the batch call,
  # which copies the bytes into the treap arena.
  var derived: seq[CfKey] = newSeqOfCap[CfKey](derivedKeys.len)
  for d in derivedKeys:
    derived.add CfKey(cf: d.cf, key: toKeyRef(d.key))
  eng.kv.applyJournalRecordsExpanded(derived)
