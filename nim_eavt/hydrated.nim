## hydrated.nim — RAM-resident cache of "hydrated" eids for the EAVT CF.
##
## A hydrated eid has its COMPLETE set of active CF-0 datom keys in memory.
## `scanPrefixActive` serves any CF-0 scan whose prefix anchors at a hydrated
## eid entirely from here — no PageStore B-tree descent, no treap cursors,
## no multi-source merge.
##
## Membership invariant (what makes whole-entry eviction safe):
##   * an eid becomes hydrated only by (a) entity creation (`hydrateEmpty`,
##     before its first save) or (b) read-time hydration of the full eid
##     (`hydrate`, from a complete `scanPrefixActive(0, encodeEid(eid))`);
##   * every EAVT write funnels through `EavtEngine.batchWrite`, which mirrors
##     each CF-0 key here (`applyKey`: upsert on active, removal on retract).
## Therefore an entry always reflects the latest active state of its eid;
## dropping the whole entry at any time just falls back to the slow path.
##
## Storage is a flat byte buffer per entry (concatenated keys) + an offset
## array — no per-key seq allocation, and every comparison is a zero-alloc
## openArray view into the buffer.
##
## Admission: the only criterion is fit — an entry must fit within
## `maxBytes` after LRU-evicting older entries. There are no punitive guards:
## large hot entities are hydrated like any other (their absolute win per
## lookup is the largest). An eid larger than the entire budget cannot be
## cached under the hard memory cap and stays on the normal path.
##
## Single-threaded by construction (event loop); no locks.
## The intrusive LRU list creates reference cycles between entries — benign
## under ORC's cycle collector.

import std/[tables, algorithm, monotimes]
import keys
import nim_memtable/treap_backend  # KeyRef, cmpKeysByte

const DefaultMaxBytes* = 1 shl 30          ## 1 GiB — cfg `hydrated_max_bytes`

type
  HydratedEntry* = ref object
    eid*: int64               ## owning entity (O(1) LRU victim removal)
    buf*: seq[byte]           ## concatenated ACTIVE CF-0 keys, ascending
    offs*: seq[int32]         ## start offset of each key (len = nº de chaves)
    bytes*: int               ## == buf.len
    prev, next: HydratedEntry ## intrusive LRU (sentinel-headed)
    # memtable role (M1): a dirty entry holds unflushed CF-0 writes — the
    # entry IS the memtable for this eid; never evicted while dirty.
    dirty*: bool              ## has keys/tombstones above `watermark`
    watermark*: int64         ## t of the last successful drain (0 = none)
    lastWriteT*: int64        ## t of the newest applied key
    tombstones*: seq[seq[byte]] ## retracted keys pending pagestore drain
    dirtyPrev, dirtyNext: HydratedEntry ## intrusive dirty list
    # M4: a PARTIAL entry holds only the write delta for a cold eid — the
    # base CF-0 set stays in pagestore/treap.  Reads merge delta+base
    # (dedup by t: delta wins).  Drained partials are DROPPED (no cache
    # role), unlike complete entries which stay as the read fast path.
    partial*: bool

  HydratedSet* = ref object
    index*: Table[int64, HydratedEntry]
    head, tail: HydratedEntry ## sentinels: head.next = MRU, tail.prev = LRU
    maxBytes*: int
    curBytes*: int
    hits*: int64              ## probe() found the eid (fast path taken)
    misses*: int64            ## probe() missed (normal path)
    hydrations*: int64        ## hydrations accepted into the set
    rejected*: int64          ## hydrations refused (entry > maxBytes)
    evictions*: int64         ## entries dropped by the LRU sweeper
    # dirty bookkeeping (M1)
    dirtyHead: HydratedEntry  ## sentinel for the intrusive dirty list
    dirtyBytes*: int64        ## aproximação do volume não drenado (threshold)
    drains*: int64            ## collectDirty calls that emitted keys
    drainedKeys*: int64       ## keys emitted by collectDirty (cumulative)
    numKeys*: int64           ## chaves CF-0 retidas (estimativa do planner)

proc newHydratedSet*(maxBytes: int = DefaultMaxBytes): HydratedSet =
  result = HydratedSet(
    maxBytes: maxBytes,
    head: HydratedEntry(eid: 0, bytes: 0),
    tail: HydratedEntry(eid: 0, bytes: 0),
    dirtyHead: HydratedEntry(eid: 0, bytes: 0),
  )
  result.head.next = result.tail
  result.tail.prev = result.head
  result.dirtyHead.dirtyNext = result.dirtyHead
  result.dirtyHead.dirtyPrev = result.dirtyHead

proc len*(h: HydratedSet): int {.inline.} = h.index.len

# ── LRU plumbing ──────────────────────────────────────────────────────────────

proc unlink(e: HydratedEntry) {.inline.} =
  e.prev.next = e.next
  e.next.prev = e.prev

proc pushFront(h: HydratedSet; e: HydratedEntry) {.inline.} =
  e.next = h.head.next
  e.prev = h.head
  h.head.next.prev = e
  h.head.next = e

proc touch(h: HydratedSet; e: HydratedEntry) {.inline.} =
  unlink(e)
  pushFront(h, e)

# ── Membership / probing ──────────────────────────────────────────────────────

proc contains*(h: HydratedSet; eid: int64): bool {.inline.} =
  eid in h.index

proc probeComplete*(h: HydratedSet; eid: int64): bool {.inline.} =
  ## Membership AND complete+current (M4: partial entries are NOT
  ## authoritative — reads must merge delta+base).  LRU touch + hit/miss
  ## accounting like probe().
  if eid in h.index and not h.index[eid].partial:
    h.touch(h.index[eid])
    inc h.hits
    return true
  inc h.misses
  false

proc ensurePartial*(h: HydratedSet; eid: int64): HydratedEntry =
  ## The write-state entry for a COLD eid (M4): holds only the write delta.
  ## Creates it when absent; existing entries (partial or complete) return
  ## as-is — applyKey keeps working on them.
  if eid in h.index:
    result = h.index[eid]
    return
  let e = HydratedEntry(eid: eid, partial: true)
  h.index[eid] = e
  h.pushFront(e)
  result = e

proc probe*(h: HydratedSet; eid: int64): bool =
  ## Membership check with LRU touch + hit/miss accounting. This is the
  ## fast-path gate used by scanPrefixActive.
  if eid in h.index:
    h.touch(h.index[eid])
    inc h.hits
    true
  else:
    inc h.misses
    false

proc entryBytes*(h: HydratedSet; eid: int64): int =
  ## Diagnostics: byte size of one hydrated entry (0 when absent).
  if eid in h.index: h.index[eid].bytes else: 0

# ── Flat-buffer helpers ───────────────────────────────────────────────────────

proc keyStart(e: HydratedEntry; i: int): int {.inline.} = e.offs[i].int

proc keyEnd(e: HydratedEntry; i: int): int {.inline.} =
  if i + 1 < e.offs.len: e.offs[i + 1].int else: e.buf.len

proc keyLenAt(e: HydratedEntry; i: int): int {.inline.} =
  keyEnd(e, i) - keyStart(e, i)

proc cmpFullAt(e: HydratedEntry; i: int; key: openArray[byte]): int =
  ## Lexicographic comparison of the full stored key at `i` with `key`.
  let start = keyStart(e, i)
  let klen = keyLenAt(e, i)
  let n = min(klen, key.len)
  var j = 0
  while j < n:
    if e.buf[start + j] != key[j]:
      return if e.buf[start + j] < key[j]: -1 else: 1
    inc j
  if klen < key.len: -1
  elif klen > key.len: 1
  else: 0

proc cmpPrefixAt(e: HydratedEntry; i: int; key: openArray[byte]): int =
  ## Compare the stored key's datom-prefix (all but the last 8 suffix bytes)
  ## with `key`'s datom-prefix. Zero-allocation.
  let start = keyStart(e, i)
  let klen = keyLenAt(e, i)
  let alen = klen - 8
  let blen = key.len - 8
  let n = min(alen, blen)
  var j = 0
  while j < n:
    if e.buf[start + j] != key[j]:
      return if e.buf[start + j] < key[j]: -1 else: 1
    inc j
  if alen < blen: -1
  elif alen > blen: 1
  else: 0

proc findKeyPos(e: HydratedEntry; key: openArray[byte]): int =
  ## Index of the stored key whose datom-prefix equals `key`'s, or -1.
  var lo = 0
  var hi = e.offs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpPrefixAt(e, mid, key) < 0: lo = mid + 1
    else: hi = mid
  if lo < e.offs.len and cmpPrefixAt(e, lo, key) == 0: lo
  else: -1

proc replaceKeyAt(e: HydratedEntry; pos: int; key: ptr UncheckedArray[byte];
                  klen: int) =
  let start = keyStart(e, pos)
  let next = keyEnd(e, pos)
  let delta = klen - (next - start)
  if delta != 0:
    let tail = e.buf.len - next
    if delta > 0: e.buf.setLen(e.buf.len + delta)
    if tail > 0: moveMem(addr e.buf[next + delta], addr e.buf[next], tail)
    if delta < 0: e.buf.setLen(e.buf.len + delta)
    for j in (pos + 1) ..< e.offs.len:
      e.offs[j] = (e.offs[j].int + delta).int32
  copyMem(addr e.buf[start], key, klen)

proc insertKeyAt(e: HydratedEntry; idx: int; key: ptr UncheckedArray[byte];
                 klen: int) =
  let ins = (if idx < e.offs.len: keyStart(e, idx) else: e.buf.len)
  e.buf.setLen(e.buf.len + klen)
  let tail = e.buf.len - ins - klen
  if tail > 0: moveMem(addr e.buf[ins + klen], addr e.buf[ins], tail)
  copyMem(addr e.buf[ins], key, klen)
  e.offs.insert(ins.int32, idx)
  for j in (idx + 1) ..< e.offs.len:
    e.offs[j] = (e.offs[j].int + klen).int32

proc removeKeyAt(e: HydratedEntry; pos: int): int =
  ## Remove the key at pos; returns its byte length.
  let start = keyStart(e, pos)
  let next = keyEnd(e, pos)
  let oldLen = next - start
  let tail = e.buf.len - next
  if tail > 0: moveMem(addr e.buf[start], addr e.buf[next], tail)
  e.buf.setLen(e.buf.len - oldLen)
  e.offs.delete(pos)
  for j in pos ..< e.offs.len:
    e.offs[j] = (e.offs[j].int - oldLen).int32
  oldLen

# ── Reads ─────────────────────────────────────────────────────────────────────

proc keyCount*(h: HydratedSet; eid: int64): int {.inline.} =
  ## Nº de chaves CF-0 ativas conhecidas para o eid (0 quando ausente).
  ## Autoritativo enquanto a entrada estiver hidratada (invariante
  ## complete+current — ver cabeçalho do módulo).
  if eid notin h.index: return 0
  h.index[eid].offs.len

proc hasAttrKey*(h: HydratedSet; eid: int64; attrId: uint32): bool =
  ## True quando a entrada hidratada tem chave CF-0 ativa para (eid, attrId).
  ## Exato sob complete+current: a entrada é autoritativa para o eid inteiro,
  ## então "não tem chave para o attr" ⇒ não existe datom ativo a retrair.
  ## Busca binária pelos primeiros 12B ([eid 8B][aid 4B]) — as chaves estão
  ## ordenadas e chaves do mesmo (eid, aid) são contíguas.
  if eid notin h.index: return false
  let e = h.index[eid]
  var pfx: array[12, byte]
  let ex = cast[uint64](eid) xor (1'u64 shl 63)
  storeBE64(cast[ptr UncheckedArray[byte]](addr pfx[0]), 0, ex)
  storeBE32(cast[ptr UncheckedArray[byte]](addr pfx[0]), 8, attrId)

  proc cmpAttrAt(e: HydratedEntry; i: int; pfx: array[12, byte]): int {.inline.} =
    let start = keyStart(e, i)
    let klen = keyLenAt(e, i)
    let n = min(klen, 12)
    for j in 0 ..< n:
      if e.buf[start + j] != pfx[j]:
        return if e.buf[start + j] < pfx[j]: -1 else: 1
    if klen < 12: -1 else: 0

  var lo = 0
  var hi = e.offs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpAttrAt(e, mid, pfx) < 0: lo = mid + 1
    else: hi = mid
  result = lo < e.offs.len and cmpAttrAt(e, lo, pfx) == 0

proc lookupRange*(h: HydratedSet; eid: int64; prefix: seq[byte]): seq[seq[byte]] =
  ## All stored keys starting with `prefix`, ascending. The caller has already
  ## probed membership for the eid anchored at prefix[0..<8].
  if eid notin h.index: return
  let e = h.index[eid]
  var lo = 0
  var hi = e.offs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpFullAt(e, mid, prefix) < 0: lo = mid + 1
    else: hi = mid
  var i = lo
  while i < e.offs.len:
    let start = keyStart(e, i)
    let klen = keyLenAt(e, i)
    if klen < prefix.len: break
    var matches = true
    for j in 0 ..< prefix.len:
      if e.buf[start + j] != prefix[j]:
        matches = false
        break
    if not matches: break
    result.add(e.buf[start ..< start + klen])
    inc i

# ── Writes (mirror path) ──────────────────────────────────────────────────────

proc markDirty(h: HydratedSet; e: HydratedEntry; t: int64) {.inline.} =
  ## Join the dirty list on first sight; the entry's watermark selection
  ## (sf.t > watermark) makes per-key bookkeeping unnecessary.
  e.lastWriteT = t
  if e.dirty: return
  e.dirty = true
  e.dirtyNext = h.dirtyHead.dirtyNext
  e.dirtyPrev = h.dirtyHead
  h.dirtyHead.dirtyNext.dirtyPrev = e
  h.dirtyHead.dirtyNext = e
  h.dirtyBytes += e.bytes.int64

proc keySuffixT(key: KeyRef): int64 {.inline.} =
  ## The write t carried in the key suffix (sf = t<<1 | retracted).
  (beUint64(key.p.toOpenArray(0, key.len - 1), key.len - 8) shr 1).int64

proc keyToSeq(key: KeyRef): seq[byte] {.inline.} =
  result = newSeq[byte](key.len)
  if key.len > 0:
    copyMem(addr result[0], unsafeAddr key.p[0], key.len)

proc applyKey*(h: HydratedSet; key: KeyRef) =
  ## Apply one CF-0 write.  When the eid is hydrated the entry IS the
  ## memtable (M1): active → upsert; retracted → remove + tombstone for the
  ## pagestore drain.  Selection at drain time is by suffix t > watermark.
  if key.len < 20 or h.index.len == 0: return
  let klen = key.len
  let eid = decodeEid(beUint64(key.p.toOpenArray(0, klen - 1), 0))
  if eid notin h.index: return
  let e = h.index[eid]
  let sf = beUint64(key.p.toOpenArray(0, klen - 1), klen - 8)
  let pos = findKeyPos(e, key.p.toOpenArray(0, klen - 1))
  if (sf and 1) == 0:
    # active: replace in place (new version) or insert sorted
    if pos >= 0:
      let oldLen = keyLenAt(e, pos)
      replaceKeyAt(e, pos, key.p, klen)
      let delta = klen - oldLen
      h.curBytes += delta
      e.bytes += delta
      if e.dirty: h.dirtyBytes += delta.int64
    else:
      var idx = e.offs.len
      while idx > 0 and cmpFullAt(e, idx - 1, key.p.toOpenArray(0, klen - 1)) > 0: dec idx
      insertKeyAt(e, idx, key.p, klen)
      h.curBytes += klen
      e.bytes += klen
      inc h.numKeys
      if e.dirty: h.dirtyBytes += klen.int64
    h.markDirty(e, keySuffixT(key))
  else:
    if pos >= 0:
      let oldLen = removeKeyAt(e, pos)
      h.curBytes -= oldLen
      e.bytes -= oldLen
      dec h.numKeys
      if e.dirty: h.dirtyBytes -= oldLen.int64
    # tombstone records the retraction for the pagestore drain (the active
    # key is gone from buf — without the tombstone the pagestore would
    # keep serving the retracted datom)
    e.tombstones.add(keyToSeq(key))
    inc h.numKeys
    h.markDirty(e, keySuffixT(key))

# ── Insertion / eviction ──────────────────────────────────────────────────────

proc dirtyUnlink(h: HydratedSet; e: HydratedEntry) {.inline.} =
  if not e.dirty: return
  e.dirtyPrev.dirtyNext = e.dirtyNext
  e.dirtyNext.dirtyPrev = e.dirtyPrev
  h.dirtyBytes -= e.bytes.int64
  e.dirty = false

proc drop(h: HydratedSet; eid: int64; e: HydratedEntry) {.inline.} =
  h.index.del(eid)
  unlink(e)
  dec h.curBytes, e.bytes
  dec h.numKeys, e.offs.len + e.tombstones.len
  h.dirtyUnlink(e)

proc evictLruUntilFits(h: HydratedSet; incomingBytes: int) =
  ## Evict least-recently-used entries until `incomingBytes` fits alongside
  ## whatever remains.  Dirty entries are SKIPPED: they hold unflushed
  ## memtable data (M1).  Stops when nothing but the incoming entry would
  ## remain (caller rejects that case beforehand) or no clean victim exists
  ## (flush pressure drains the dirty set).
  var victim = h.tail.prev
  while h.curBytes + incomingBytes > h.maxBytes and victim != h.head:
    if victim.eid == 0 and victim.offs.len == 0: break  # safety: sentinel/empty
    if victim.dirty:
      victim = victim.prev          # pinned até o drain — segue para a LRU anterior
      continue
    let nxt = victim.prev
    h.drop(victim.eid, victim)
    inc h.evictions
    victim = nxt

proc hydrateEmpty*(h: HydratedSet; eid: int64) =
  ## Mark a freshly allocated entity as hydrated (empty until its first save).
  if eid in h.index:
    h.touch(h.index[eid])
    return
  let e = HydratedEntry(eid: eid, bytes: 0)
  h.index[eid] = e
  h.pushFront(e)

proc hydrate*(h: HydratedSet; eid: int64; keys: seq[seq[byte]]) =
  ## Install the complete active CF-0 key set for `eid`. `keys` must be the
  ## ascending output of scanPrefixActive(0, encodeEid(eid)) — already deduped
  ## and retract-filtered.
  if eid in h.index:
    h.touch(h.index[eid])
    return
  var total = 0
  for k in keys: total += k.len
  if total > h.maxBytes:
    inc h.rejected
    return
  h.evictLruUntilFits(total)
  let e = HydratedEntry(eid: eid, bytes: total)
  for k in keys:
    e.offs.add(e.buf.len.int32)
    e.buf.add(k)
  h.index[eid] = e
  h.pushFront(e)
  inc h.curBytes, total
  inc h.hydrations

proc evictEid*(h: HydratedSet; eid: int64) =
  ## Explicit removal (future seam for replica WAL invalidation).
  ## A dirty entry holds unflushed memtable data — not evictable.
  if eid in h.index and not h.index[eid].dirty:
    h.drop(eid, h.index[eid])

proc clear*(h: HydratedSet) =
  ## Drop every entry (config change / tests).
  h.index.clear()
  h.head.next = h.tail
  h.tail.prev = h.head
  h.curBytes = 0

# ── Memtable drain (M1) ───────────────────────────────────────────────────────

proc collectDirty*(h: HydratedSet): tuple[keysByCf: seq[(int, seq[seq[byte]])],
                                          maxT: int64, collected: int64] =
  ## Drain pass: emit every CF-0 key whose suffix t is above the entry's
  ## watermark, plus pending tombstones.  Selection is by CONTENT (the t
  ## carried in the key), so it is stable under any insertion/removal.
  ## Entries that emit nothing leave the dirty list here.  State is NOT
  ## cleared — publishWatermark commits it after the pagestore accepts the
  ## data (a failed flush re-collects the same keys; pagestore inserts are
  ## idempotent).  Runs on the loop (single-thread owner of the set).
  var keys: seq[seq[byte]]
  var maxT: int64 = 0
  var collected: int64 = 0
  var e = h.dirtyHead.dirtyNext
  while e != h.dirtyHead:
    let nxt = e.dirtyNext
    var emitted = 0
    for i in 0 ..< e.offs.len:
      let start = keyStart(e, i)
      let klen = keyLenAt(e, i)
      let kt = (beUint64(e.buf.toOpenArray(start, e.buf.len - 1),
                         klen - 8) shr 1).int64
      if kt > e.watermark:
        keys.add(e.buf[start ..< start + klen])
        inc emitted
        if kt > maxT: maxT = kt
    for j in countdown(e.tombstones.len - 1, 0):
      let tmb = e.tombstones[j]
      let kt = (beUint64(tmb, tmb.len - 8) shr 1).int64
      if kt > e.watermark:
        keys.add(tmb)
        inc emitted
        if kt > maxT: maxT = kt
    if emitted == 0:
      # everything already drained (or nothing new) — leave the dirty list
      e.dirty = false
      e.dirtyPrev.dirtyNext = e.dirtyNext
      e.dirtyNext.dirtyPrev = e.dirtyPrev
      if collected >= 0: discard
    else:
      collected += emitted.int64
    e = nxt
  if keys.len > 0:
    # unsorted — o worker ordena (O(n log n) off-loop; sortar aqui
    # bloquearia o event loop com buffers grandes)
    result.keysByCf = @[(0, keys)]
  result.maxT = maxT
  result.collected = collected
  h.drains += 1
  h.drainedKeys += collected

proc publishWatermark*(h: HydratedSet; maxT: int64) =
  ## Commit a successful drain: entries' watermark advances to `maxT`;
  ## entries written AFTER the collect (lastWriteT > maxT) stay dirty and
  ## will be re-collected next pass.  Tombstones above the new watermark
  ## remain pending (they were not collected — maxT covers only emitted t).
  if maxT <= 0: return
  var e = h.dirtyHead.dirtyNext
  while e != h.dirtyHead:
    let nxt = e.dirtyNext
    if e.watermark < maxT: e.watermark = maxT
    e.dirty = e.lastWriteT > e.watermark or e.tombstones.len > 0
    if not e.dirty:
      if e.partial:
        h.drop(e.eid, e)      # M4: drained partial = dropped (no cache role)
      else:
        e.dirtyPrev.dirtyNext = e.dirtyNext
        e.dirtyNext.dirtyPrev = e.dirtyPrev
    e = nxt

proc lookupRangeRaw*(h: HydratedSet; eid: int64;
                     prefix: seq[byte]): seq[seq[byte]] =
  ## Raw CF-0 view for a hydrated eid: active keys (buf) + pending
  ## tombstones, filtered by `prefix`, ascending — mirrors the treap's raw
  ## scan semantics (old versions superseded by replaceKeyAt are not
  ## reconstructible, which is fine: they only occur for superseded writes).
  ## Caller has already probed membership.
  if eid notin h.index: return
  let e = h.index[eid]
  result = h.lookupRange(eid, prefix)
  for tmb in e.tombstones:
    if tmb.len >= prefix.len and tmb[0 ..< prefix.len] == prefix:
      result.add(tmb)
  if result.len > 1:
    sort(result, cmpKeysByte)

proc isPartial*(h: HydratedSet; eid: int64): bool {.inline.} =
  ## True when the entry is an M4 partial (delta-only) write-state entry.
  if eid notin h.index: return false
  h.index[eid].partial

proc upgradePartial*(h: HydratedSet; eid: int64; keys: seq[seq[byte]]) =
  ## M4: replace a partial entry's delta-only content with the COMPLETE
  ## active set (merged view).  Pending tombstones survive — they belong to
  ## the drain.  partial → false: the entry becomes the read fast path.
  if eid notin h.index: return
  let e = h.index[eid]
  h.curBytes -= e.bytes
  dec h.numKeys, e.offs.len + e.tombstones.len
  var total = 0
  e.offs = @[]
  e.buf = @[]
  for k in keys:
    e.offs.add(e.buf.len.int32)
    e.buf.add(k)
    total += k.len
  e.bytes = total
  h.curBytes += total
  inc h.numKeys, e.offs.len
  e.partial = false

proc isDirty*(h: HydratedSet; eid: int64): bool {.inline.} =
  ## True when the entry holds unflushed memtable data (or doesn't exist).
  if eid notin h.index: return false
  h.index[eid].dirty

proc allKeys*(h: HydratedSet): seq[seq[byte]] =
  ## Every CF-0 key held by the set: active buf keys of ALL entries plus
  ## pending tombstones.  M1/M4 full-range support: the write path no
  ## longer feeds the treap CF-0, so this set IS the source of in-memory
  ## keys for prefix-agnostic (full-range) scans.  Unsorted.
  for e in h.index.values():
    for i in 0 ..< e.offs.len:
      let start = e.offs[i].int
      let klen = (if i + 1 < e.offs.len: e.offs[i + 1].int else: e.buf.len) - start
      result.add e.buf[start ..< start + klen]
    for tmb in e.tombstones:
      result.add(tmb)
