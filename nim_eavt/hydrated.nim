## hydrated.nim — RAM-resident cache of "hydrated" eids for the EAVT CF.
##
## M5: an entry is a sorted list of SLOTS into the engine's DatomVector
## (chunks of canonical CF-0 keys). The entry no longer owns key bytes:
## "hidratado = apenas ptr" — comparisons resolve through the chunk
## (zero-alloc), reads copy on demand. insertKeyAt (O(k) byte memmove per
## datom) is gone: a slot insert moves 12-byte fixed records.
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
## Byte lifetime: every entry slot pins its chunk in the vector. A COMPLETE
## entry survives flushes (read cache role) — its chunks stay pinned until
## eviction, which is what makes its keys readable after the watermark
## passes. A PARTIAL entry is delta-only and dropped at drain. Unpinned
## durable chunks are reclaimed by the vector's publish.
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
import datoms
import nim_memtable/treap_backend  # KeyRef, cmpKeysByte

const DefaultMaxBytes* = 1 shl 30          ## 1 GiB — cfg `hydrated_max_bytes`

type
  HydratedEntry* = ref object
    eid*: int64               ## owning entity (O(1) LRU victim removal)
    slots*: seq[DatomSlot]    ## active keys, ascending (cmpSlotKey vs chunk)
    tombSlots*: seq[DatomSlot]## pending tombstones for the pagestore drain
    bytes*: int               ## sum of slot klens (accounting only)
    prev, next: HydratedEntry ## intrusive LRU (sentinel-headed)
    # memtable role (M1): a dirty entry holds unflushed CF-0 writes — the
    # entry IS the memtable for this eid; never evicted while dirty.
    dirty*: bool              ## has keys/tombstones above `watermark`
    watermark*: int64         ## t of the last successful drain (0 = none)
    lastWriteT*: int64        ## t of the newest applied key
    dirtyPrev, dirtyNext: HydratedEntry ## intrusive dirty list
    # M4: a PARTIAL entry holds only the write delta for a cold eid — the
    # base CF-0 set stays in pagestore.  Reads merge delta+base (dedup by
    # t: delta wins).  Drained partials are DROPPED (no cache role), unlike
    # complete entries which stay as the read fast path.
    partial*: bool

  HydratedSet* = ref object
    index*: Table[int64, HydratedEntry]
    head, tail: HydratedEntry ## sentinels: head.next = MRU, tail.prev = LRU
    maxBytes*: int
    curBytes*: int
    numKeys*: int
    dirtyHead*: HydratedEntry ## sentinel of the dirty list
    dirtyBytes*: int64
    evictions*: int64
    hydrations*: int64
    rejected*: int64
    drains*: int64
    drainedKeys*: int64
    hits*: int64
    misses*: int64
    vec*: DatomVector         ## M5: byte storage for every slot (shared)

proc newHydratedSet*(maxBytes: int = DefaultMaxBytes;
                     vec: DatomVector = nil): HydratedSet =
  let head = HydratedEntry(eid: 0)
  let tail = HydratedEntry(eid: 0)
  head.next = tail
  tail.prev = head
  let dhead = HydratedEntry(eid: 0)
  dhead.dirtyNext = dhead
  dhead.dirtyPrev = dhead
  result = HydratedSet(index: initTable[int64, HydratedEntry](),
                       maxBytes: maxBytes, vec: vec)
  result.head = head
  result.tail = tail
  result.dirtyHead = dhead

proc len*(h: HydratedSet): int {.inline.} = h.index.len

# ── LRU list ──────────────────────────────────────────────────────────────────

proc unlink(e: HydratedEntry) {.inline.} =
  e.prev.next = e.next
  e.next.prev = e.prev

proc pushFront(h: HydratedSet; e: HydratedEntry) {.inline.} =
  e.next = h.head.next
  e.prev = h.head
  h.head.next.prev = e
  h.head.next = e

proc touch(h: HydratedSet; e: HydratedEntry) {.inline.} =
  if h.head.next == e: return
  e.unlink()
  h.pushFront(e)

# ── Membership / probes ───────────────────────────────────────────────────────

proc contains*(h: HydratedSet; eid: int64): bool {.inline.} = eid in h.index

proc probeComplete*(h: HydratedSet; eid: int64): bool {.inline.} =
  ## Membership AND complete+current (M4: partial entries are NOT
  ## authoritative — reads must merge delta+base).  LRU touch + hit/miss
  ## accounting like probe().  Dirty entries are probeComplete: the entry
  ## IS the memtable for its eid (dirty keys included — read-your-writes).
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
  if eid in h.index: h.index[eid].bytes else: 0

# ── Slot key resolution (through the chunk — zero copy) ──────────────────────

proc cmpSlotFull(h: HydratedSet; e: HydratedEntry; i: int;
                 key: openArray[byte]): int {.inline.} =
  h.vec.cmpSlotKey(e.slots[i], key)

proc cmpSlotPrefix(h: HydratedSet; e: HydratedEntry; i: int;
                   key: openArray[byte]): int {.inline.} =
  ## Prefix comparison: only the first key.len bytes participate — equal on
  ## the shared prefix is a MATCH (0), regardless of the slot key's full
  ## length (range-scan semantics; the old cmpPrefixAt behaved the same).
  let c = h.vec.chunkAt(e.slots[i])
  if c == nil: return -1
  let s = e.slots[i]
  let n = min(s.klen.int, key.len)
  for j in 0 ..< n:
    let a = c.buf[s.off + j]
    if a != key[j]:
      return (if a < key[j]: -1 else: 1)
  0

proc cmpSlotDatomPrefix(h: HydratedSet; e: HydratedEntry; i: int;
                        key: openArray[byte]): int {.inline.} =
  ## Compare the stored key's datom-prefix (all but the last 8 suffix bytes)
  ## with `key`'s — the upsert/retract matcher (old cmpPrefixAt semantics).
  let c = h.vec.chunkAt(e.slots[i])
  if c == nil: return -1
  let s = e.slots[i]
  let alen = s.klen.int - 8
  let blen = key.len - 8
  let n = min(alen, blen)
  for j in 0 ..< n:
    let a = c.buf[s.off + j]
    if a != key[j]:
      return (if a < key[j]: -1 else: 1)
  if alen < blen: -1
  elif alen > blen: 1
  else: 0

proc findKeyPos(h: HydratedSet; e: HydratedEntry; key: openArray[byte]): int =
  ## Index of the stored key whose datom-prefix equals `key`'s, or
  ## -1-(insertion point).  Prefix match (not full-key): an upsert or a
  ## retract targets the same (eid, aid, val) regardless of its suffix t.
  var lo, hi = 0
  hi = e.slots.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if h.cmpSlotDatomPrefix(e, mid, key) < 0: lo = mid + 1
    else: hi = mid
  if lo < e.slots.len and h.cmpSlotDatomPrefix(e, lo, key) == 0: lo
  else: -1 - lo

proc keyCount*(h: HydratedSet; eid: int64): int {.inline.} =
  ## Nº de chaves CF-0 ativas conhecidas para o eid (0 quando ausente).
  ## Autoritativo enquanto a entrada estiver hidratada (invariante
  ## complete+current — ver cabeçalho do módulo).
  if eid notin h.index: return 0
  h.index[eid].slots.len

proc hasAttrKey*(h: HydratedSet; eid: int64; attrId: uint32): bool =
  ## True quando a entrada hidratada tem chave CF-0 ativa para (eid, attrId).
  ## Exato sob complete+current: a entrada é autoritativa para o eid inteiro,
  ## então "não tem chave para o attr" ⇒ não existe datom ativo a retrair.
  ## Busca binária pelos primeiros 12B ([eid 8B][aid 4B]) — chaves do mesmo
  ## (eid, aid) são contíguas.
  if eid notin h.index: return false
  let e = h.index[eid]
  var pfx: array[12, byte]
  let ex = cast[uint64](eid) xor (1'u64 shl 63)
  storeBE64(cast[ptr UncheckedArray[byte]](addr pfx[0]), 0, ex)
  storeBE32(cast[ptr UncheckedArray[byte]](addr pfx[0]), 8, attrId)
  var lo, hi = 0
  hi = e.slots.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let c = h.cmpSlotPrefix(e, mid, pfx)
    if c < 0: lo = mid + 1
    else: hi = mid
  if lo >= e.slots.len: return false
  h.cmpSlotPrefix(e, lo, pfx) == 0

proc lookupRange*(h: HydratedSet; eid: int64; prefix: seq[byte]): seq[seq[byte]] =
  ## All stored keys starting with `prefix`, ascending. The caller has already
  ## probed membership for the eid anchored at prefix[0..<8].
  if eid notin h.index: return
  let e = h.index[eid]
  var lo, hi = 0
  hi = e.slots.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if h.cmpSlotPrefix(e, mid, prefix) < 0: lo = mid + 1
    else: hi = mid
  var i = lo
  while i < e.slots.len:
    if h.cmpSlotPrefix(e, i, prefix) != 0: break
    result.add(h.vec.keyCopy(e.slots[i]))
    inc i

# ── Writes (mirror path) ──────────────────────────────────────────────────────

proc entryRemoveSlot(h: HydratedSet; e: HydratedEntry; pos: int): int {.inline.} =
  ## Remove the slot at pos (unpins the chunk); returns the key length.
  let klen = e.slots[pos].klen.int
  h.vec.unpin(e.slots[pos])
  e.slots.delete(pos)
  h.curBytes -= klen
  e.bytes -= klen
  klen


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

proc slotKeyT(h: HydratedSet; s: DatomSlot): int64 {.inline.} =
  let c = h.vec.chunkAt(s)
  if c == nil: return 0
  (beUint64(c.buf.toOpenArray(s.off, s.off + s.klen.int - 1),
            s.klen.int - 8) shr 1).int64

proc applyKey*(h: HydratedSet; key: KeyRef) =
  ## Apply one CF-0 write.  When the eid is hydrated the entry IS the
  ## memtable (M1): active → upsert; retracted → remove + tombstone for the
  ## pagestore drain.  Selection at drain time is by suffix t > watermark.
  ## M5: the key bytes land in the vector (append) — the entry gets a slot.
  if key.len < 20 or h.vec == nil: return
  let klen = key.len
  let eid = decodeEid(beUint64(key.p.toOpenArray(0, klen - 1), 0))
  if eid notin h.index: return
  let e = h.index[eid]
  let sf = beUint64(key.p.toOpenArray(0, klen - 1), klen - 8)
  let t = keySuffixT(key)
  let slot = h.vec.append(key.p.toOpenArray(0, klen - 1), t)
  h.vec.pin(slot)          # the entry retains its bytes until drop/drain
  let pos = h.findKeyPos(e, key.p.toOpenArray(0, klen - 1))
  if (sf and 1) == 0:
    if pos >= 0:
      # replace in place (new version): remove the old slot, insert new
      let delta = klen - e.slots[pos].klen.int
      discard h.entryRemoveSlot(e, pos)  # (defined below — forward ref ok)
      e.slots.insert(slot, pos)
      h.curBytes += klen
      e.bytes += klen
      inc h.numKeys
      if e.dirty: h.dirtyBytes += delta.int64
    else:
      let idx = -pos - 1
      e.slots.insert(slot, idx)
      h.curBytes += klen
      e.bytes += klen
      inc h.numKeys
      if e.dirty: h.dirtyBytes += klen.int64
    h.markDirty(e, t)
  else:
    if pos >= 0:
      let oldLen = h.entryRemoveSlot(e, pos)
      dec h.numKeys
      if e.dirty: h.dirtyBytes -= oldLen.int64
    e.tombSlots.add(slot)
    inc h.numKeys
    h.markDirty(e, t)

# ── Insertion / eviction ──────────────────────────────────────────────────────

proc dirtyUnlink(h: HydratedSet; e: HydratedEntry) {.inline.} =
  if not e.dirty: return
  e.dirtyPrev.dirtyNext = e.dirtyNext
  e.dirtyNext.dirtyPrev = e.dirtyPrev
  h.dirtyBytes -= e.bytes.int64
  e.dirty = false

proc drop(h: HydratedSet; eid: int64; e: HydratedEntry) {.inline.} =
  ## Remove the entry entirely and unpin its chunks (M5 byte lifetime).
  for s in e.slots: h.vec.unpin(s)
  for s in e.tombSlots: h.vec.unpin(s)
  h.index.del(eid)
  e.unlink()
  dec h.curBytes, e.bytes
  dec h.numKeys, e.slots.len + e.tombSlots.len
  h.dirtyUnlink(e)

proc evictLruUntilFits(h: HydratedSet; incomingBytes: int) =
  ## Evict least-recently-used entries until `incomingBytes` fits alongside
  ## whatever remains.  Dirty entries are SKIPPED: they hold unflushed
  ## memtable data (M1).  Stops when nothing but the incoming entry would
  ## remain (caller rejects that case beforehand) or no clean victim exists
  ## (flush pressure drains the dirty set).
  var victim = h.tail.prev
  while h.curBytes + incomingBytes > h.maxBytes and victim != h.head:
    if victim.eid == 0 and victim.slots.len == 0: break  # safety: sentinel/empty
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
  ## and retract-filtered.  M5: keys are appended to the vector (pinned);
  ## the entry holds slots.
  if eid in h.index:
    h.touch(h.index[eid])
    return
  var total = 0
  for k in keys: total += k.len
  if total > h.maxBytes:
    inc h.rejected
    return
  h.evictLruUntilFits(total)
  let e = HydratedEntry(eid: eid, bytes: 0)
  for k in keys:
    if k.len < 20: continue
    let t = (beUint64(k.toOpenArray(0, k.len - 1), k.len - 8) shr 1).int64
    let s = h.vec.append(k, t)
    h.vec.pin(s)
    e.slots.add(s)
  e.bytes = total
  h.index[eid] = e
  h.pushFront(e)
  inc h.curBytes, total
  inc h.numKeys, e.slots.len
  inc h.hydrations

proc evictEid*(h: HydratedSet; eid: int64) =
  ## Explicit removal (future seam for replica WAL invalidation).
  ## A dirty entry holds unflushed memtable data — not evictable.
  if eid in h.index and not h.index[eid].dirty:
    h.drop(eid, h.index[eid])

proc clear*(h: HydratedSet) =
  ## Drop every entry (config change / tests).
  var eids: seq[int64] = @[]
  for eid in h.index.keys(): eids.add(eid)
  for eid in eids: h.drop(eid, h.index[eid])
  h.head.next = h.tail
  h.tail.prev = h.head
  h.curBytes = 0

# ── Memtable drain (M1) ───────────────────────────────────────────────────────

proc collectDirty*(h: HydratedSet): tuple[maxT: int64, collected: int64] =
  ## Drain pass (M5): the BYTE source is the vector (`drainVolatile`) — the
  ## entries' per-key watermark selection is subsumed by publishedT.  What
  ## remains here is the dirty-list bookkeeping: entries that emitted
  ## nothing leave the dirty list.  State is NOT cleared — publishWatermark
  ## commits it after the pagestore accepts the data (a failed flush
  ## re-collects the same keys; pagestore inserts are idempotent).
  var maxT: int64 = 0
  var collected: int64 = 0
  var e = h.dirtyHead.dirtyNext
  while e != h.dirtyHead:
    let nxt = e.dirtyNext
    if e.lastWriteT > maxT: maxT = e.lastWriteT
    var emitted = 0
    for s in e.slots:
      if h.slotKeyT(s) > e.watermark: inc emitted
    for s in e.tombSlots:
      if h.slotKeyT(s) > e.watermark: inc emitted
    if emitted == 0:
      e.dirty = false
      e.dirtyPrev.dirtyNext = e.dirtyNext
      e.dirtyNext.dirtyPrev = e.dirtyPrev
    else:
      collected += emitted.int64
    e = nxt
  result.maxT = maxT
  result.collected = collected
  h.drains += 1
  h.drainedKeys += collected

proc publishWatermark*(h: HydratedSet; maxT: int64) =
  ## Commit a successful drain: entries' watermark advances to `maxT`;
  ## entries written AFTER the collect (lastWriteT > maxT) stay dirty.
  ## Tombstones drained with this flush are cleared.  MUST run BEFORE the
  ## vector's publish (dropped partial entries unpin their chunks so the
  ## vector can reclaim them).
  if maxT <= 0: return
  var e = h.dirtyHead.dirtyNext
  while e != h.dirtyHead:
    let nxt = e.dirtyNext
    if e.watermark < maxT: e.watermark = maxT
    var keep: seq[DatomSlot] = @[]
    for s in e.tombSlots:
      if h.slotKeyT(s) > maxT: keep.add(s)
    h.numKeys -= e.tombSlots.len - keep.len
    e.tombSlots = keep
    e.dirty = e.lastWriteT > e.watermark or e.tombSlots.len > 0
    if not e.dirty:
      if e.partial:
        h.drop(e.eid, e)      # M4: drained partial = dropped (no cache role)
      else:
        e.dirtyPrev.dirtyNext = e.dirtyNext
        e.dirtyNext.dirtyPrev = e.dirtyPrev
    e = nxt

proc lookupRangeRaw*(h: HydratedSet; eid: int64;
                     prefix: seq[byte]): seq[seq[byte]] =
  ## Raw CF-0 view for a hydrated eid: active slots + pending tombstones,
  ## filtered by `prefix`, ascending — mirrors the treap's raw scan
  ## semantics (old versions superseded by the upsert are not
  ## reconstructible, which is fine: they only occur for superseded writes).
  ## Caller has already probed membership.
  if eid notin h.index: return
  let e = h.index[eid]
  result = h.lookupRange(eid, prefix)
  for s in e.tombSlots:
    let k = h.vec.keyCopy(s)
    if k.len >= prefix.len and k[0 ..< prefix.len] == prefix:
      result.add(k)
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
  dec h.numKeys, e.slots.len + e.tombSlots.len
  var total = 0
  for s in e.slots: h.vec.unpin(s)  # the merged set replaces the delta
  e.slots = @[]
  e.bytes = 0
  for k in keys:
    if k.len < 20: continue
    let t = (beUint64(k.toOpenArray(0, k.len - 1), k.len - 8) shr 1).int64
    let s = h.vec.append(k, t)
    h.vec.pin(s)
    e.slots.add(s)
    total += k.len
  e.bytes = total
  h.curBytes += total
  inc h.numKeys, e.slots.len + e.tombSlots.len
  e.partial = false

proc isDirty*(h: HydratedSet; eid: int64): bool {.inline.} =
  ## True when the entry holds unflushed memtable data (or doesn't exist).
  if eid notin h.index: return false
  h.index[eid].dirty

proc allKeys*(h: HydratedSet): seq[seq[byte]] =
  ## Every CF-0 key held by the set: active slots of ALL entries plus
  ## pending tombstones.  M1/M4 full-range support: the write path no
  ## longer feeds the treap CF-0, so this set IS the source of in-memory
  ## keys for prefix-agnostic (full-range) scans.  Unsorted.
  for e in h.index.values():
    for s in e.slots:
      result.add(h.vec.keyCopy(s))
    for s in e.tombSlots:
      result.add(h.vec.keyCopy(s))
