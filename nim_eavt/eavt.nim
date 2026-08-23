## eavt.nim — EAVT engine (save, retract, bootstrap, lookup).
##
## Port of spier-transactor/src/eavt.rs (~1099 lines Rust → Nim).
## Coordinates Resolver + KVStore for entity-attribute-value-time operations.

import std/[tables, strutils, options, times, sets, monotimes, algorithm]
import resolver
import keys
import kvstore
import page_store     # CfTree
import page_cursor   # PageStoreSnapshot, PageStoreCursor
import treap_cursor   # newTreapCursor
import query/cursor   # treapCursor constructor
import nim_memtable/treap_backend
import scheme
import stats

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

proc newEavtEngine*(kv: KVStore): EavtEngine =
  result = EavtEngine(kv: kv, resolver: newResolver())
  # bootstrap called after construction (avoids forward ref)

# ── Batch write helper ──

proc batchWrite*(eng: EavtEngine; entries: seq[EavtEntry]) =
  if entries.len == 0: return
  var cfs: seq[CfKey] = newSeq[CfKey](entries.len)
  for i, e in entries:
    cfs[i] = CfKey(cf: e.cf, key: e.key)
  eng.kv.batchWrite(cfs)

proc scanPrefix*(eng: EavtEngine; cf: int; prefix: seq[byte]): seq[seq[byte]] =
  ## Scan keys in CF matching prefix. Reuses cursor from previous call —
  ## updates in-place if roots changed, then seeks to new prefix.
  eng.spCount += 1
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
    eng.spCursor.update(psSnap.rootUuid, psSnap.height, flushRoot, liveRoot)

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
  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: TreapNode
  var tree = eng.kv.ps[].trees[cf]
  psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
  if eng.kv.flushRoots.len > 0:
    flushRoot = eng.kv.flushRoots[cf]
  liveRoot = eng.kv.mt.hnd.live[cf]

  # Reuse or create cursors
  if eng.saCf == cf and eng.saLive != nil:
    # Same CF — update in-place
    if eng.saPs != nil: eng.saPs.update(psSnap.rootUuid, psSnap.height)
    if eng.saFlush != nil: eng.saFlush.update(flushRoot)
    eng.saLive.update(liveRoot)
  else:
    # Different CF or first call — create new cursors
    if psSnap.rootUuid != default(array[16, byte]):
      eng.saPs = PageStoreCursor(
        s: eng.kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height,
        isKv: cf >= 10)
    else:
      eng.saPs = nil
    if flushRoot != nil:
      eng.saFlush = newTreapCursor(flushRoot)
    else:
      eng.saFlush = nil
    if liveRoot != nil:
      eng.saLive = newTreapCursor(liveRoot)
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

  if sourceCount == 0: return

  # ── Fast path: single source (live treap only) ──
  # Skip sort/merge, just collect + dedup + filter
  if sourceCount == 1 and eng.saLive != nil and liveRoot != nil:
    eng.saLive.seek(prefix)
    var sourceKeys: seq[seq[byte]] = @[]
    while true:
      let k = eng.saLive.peek()
      if k.isNone: break
      let key = k.get
      if key.len < prefix.len or key[0..<prefix.len] != prefix: break
      sourceKeys.add key
      discard eng.saLive.next()
    # Dedup backward by key-prefix, filter retracted
    var lastPrefix: seq[byte] = @[]
    for j in countdown(sourceKeys.len - 1, 0):
      let key = sourceKeys[j]
      let keyPrefix = key[0 ..< key.len - 8]
      if keyPrefix != lastPrefix:
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 0:  # not retracted
          result.add key
        lastPrefix = keyPrefix
    return

  # ── Multi-source path ──
  type SrcKind = enum skPageStore, skTreap
  type Src = object
    case kind: SrcKind
    of skPageStore: ps: PageStoreCursor
    of skTreap: tc: TreapCursor

  var sources: seq[Src] = @[]
  if eng.saPs != nil and psSnap.rootUuid != default(array[16, byte]):
    eng.saPs.seek(prefix)
    sources.add Src(kind: skPageStore, ps: eng.saPs)
  if eng.saFlush != nil and flushRoot != nil:
    eng.saFlush.seek(prefix)
    sources.add Src(kind: skTreap, tc: eng.saFlush)
  if eng.saLive != nil and liveRoot != nil:
    eng.saLive.seek(prefix)
    sources.add Src(kind: skTreap, tc: eng.saLive)

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

  # 3. Filter: for each unique key-prefix, if most recent is retracted → discard
  var lastPrefix: seq[byte] = @[]
  for (key, srcIdx) in collected:
    let keyPrefix = key[0 ..< key.len - 8]
    if keyPrefix == lastPrefix: continue
    let sf = beUint64(key, key.len - 8)
    if (sf and 1) == 1:
      lastPrefix = keyPrefix
      continue
    result.add key
    lastPrefix = keyPrefix

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

  # Pre-compute index estimates for all 4 indexes (empty prefix = total count)
  for index in ["EAVT", "AEVT", "AVET", "VAET"]:
    let cf = keys.cfNameToId(keys.cfForIndex(index))
    let count = float64(eng.estimateCount(cf, @[]))
    s.indexEstimates[index & ":"] = count

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

  seedPartitionCounters(eng)

# ── Save a datom ──

proc eavtSave*(eng: EavtEngine; eid: int64; attrName: string;
                value: string; t: int64): int64 {.discardable.} =
  let attrId = eng.resolver.internAttr(attrName)
  let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
  let many = eng.resolver.isMany(attrId)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(value, mode, 0)
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
      var retEntries = buildEavtEntries(eid, attrId, ek[12 ..< ek.len - 8], t, true, mode, indexed)
      eng.batchWrite(retEntries)
  let entries = buildEavtEntries(eid, attrId, encoded, t, false, mode, indexed)
  eng.batchWrite(entries)
  return eid

proc eavtRetract*(eng: EavtEngine; eid: int64; attrName: string;
                   value: string; t: int64) =
  let attrId = eng.resolver.internAttr(attrName)
  let vt = eng.resolver.valueTypeFor(attrId).get(DbTypeString)
  let mode = valueTypeToEncodeMode(vt)
  let encoded = encodeValue(value, mode, 0)
  let indexed = eng.resolver.isIndexed(attrId)
  let entries = buildEavtEntries(eid, attrId, encoded, t, true, mode, indexed)
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
  let entries = buildEavtEntries(txEid, DbTxInstantAid, encoded, txEid,
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
  let (aid, isNew) = eng.resolver.declareAttr(name, valueType, many)
  if unique: eng.resolver.setUnique(aid, true)
  if isNew:
    eng.cachedStatsTime = 0  # invalidate cache
    # Persist schema as db.* datoms (Rust declare_attr_with_t).
    let t = eng.resolver.allocateInPartition(PartTx)
    let e = aid.int64
    eng.batchWrite(buildEavtEntries(e, DbIdentAid,
      encodeValue(name, emVariable, 0), e, false, emVariable, true))
    eng.batchWrite(buildEavtEntries(e, DbValueTypeAid,
      encodeValue($valueType, emFixed, 0), t, false, emFixed, true))
    let cardId = if many: DbCardinalityManyAid else: DbCardinalityOneAid
    eng.batchWrite(buildEavtEntries(e, DbCardinalityAid,
      encodeValue($cardId, emFixed, 0), t, false, emFixed, true))
    if unique:
      eng.batchWrite(buildEavtEntries(e, DbUniqueAid,
        encodeValue($DbUniqueIdentityAid, emFixed, 0), t, false, emFixed, true))
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
    let vt = if name in ["db.ident", "db.part/id"]: DbTypeString
             elif name == "db.txInstant": DbTypeInstant
             elif name in ["db.isComponent", "db.index", "db.fulltext", "db.noHistory"]: DbTypeBoolean
             else: DbTypeRef
    let cardId = DbCardinalityOneAid
    let uniqueId = (if name == "db.unique.value": DbUniqueValueAid
                    elif name == "db.unique.identity": DbUniqueIdentityAid
                    else: 0'u32)
    (vt, cardId, uniqueId)

  for (name, aid) in BootstrapSchema:
    let (vt, cardId, uniqueId) = meta(name)
    let e = aid.int64
    eng.batchWrite(buildEavtEntries(e, DbIdentAid,
      encodeValue(name, emVariable, 0), tx, false, emVariable, true))
    eng.batchWrite(buildEavtEntries(e, DbValueTypeAid,
      encodeValue("", emRef, vt.int64), tx, false, emRef, true))
    eng.batchWrite(buildEavtEntries(e, DbCardinalityAid,
      encodeValue("", emRef, cardId.int64), tx, false, emRef, true))
    if uniqueId != 0:
      eng.batchWrite(buildEavtEntries(e, DbUniqueAid,
        encodeValue("", emRef, uniqueId.int64), tx, false, emRef, true))

# ── Resolver accessors ──

proc lookupAttr*(eng: EavtEngine; name: string): Option[uint32] =
  eng.resolver.lookupAttr(name)

proc attrName*(eng: EavtEngine; aid: uint32): string =
  eng.resolver.attrName(aid)

proc allocateEntityId*(eng: EavtEngine): int64 =
  eng.resolver.allocateEntityId()

proc isDeclared*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isDeclared(aid)

proc isMany*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isMany(aid)

proc isUnique*(eng: EavtEngine; aid: uint32): bool =
  eng.resolver.isUnique(aid)

proc valueTypeFor*(eng: EavtEngine; aid: uint32): Option[uint32] =
  eng.resolver.valueTypeFor(aid)

proc allocateInPartition*(eng: EavtEngine; pid: uint64): int64 =
  eng.resolver.allocateInPartition(pid)

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
