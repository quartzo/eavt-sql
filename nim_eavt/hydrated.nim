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
## Admission: the only criterion is fit — an entry must fit within
## `maxBytes` after LRU-evicting older entries. There are no punitive guards:
## large hot entities are hydrated like any other (their absolute win per
## lookup is the largest). An eid larger than the entire budget cannot be
## cached under the hard memory cap and stays on the normal path.
##
## Single-threaded by construction (event loop); no locks.
## The intrusive LRU list creates reference cycles between entries — benign
## under ORC's cycle collector.

import std/[tables]
import keys

const DefaultMaxBytes* = 1 shl 30          ## 1 GiB — cfg `hydrated_max_bytes`

proc cmpBytes(a, b: openArray[byte]): int =
  ## Lexicographic byte comparison (local twin of page_store.cmpSeq).
  let n = min(a.len, b.len)
  var i = 0
  while i < n:
    if a[i] != b[i]:
      return if a[i] < b[i]: -1 else: 1
    inc i
  if a.len < b.len: -1
  elif a.len > b.len: 1
  else: 0

type
  HydratedEntry = ref object
    eid: int64                ## owning entity (O(1) LRU victim removal)
    keys: seq[seq[byte]]      ## ACTIVE CF-0 keys of this eid, ascending
    bytes: int                ## sum of len(keys[])
    prev, next: HydratedEntry ## intrusive LRU (sentinel-headed)

  HydratedSet* = ref object
    index: Table[int64, HydratedEntry]
    head, tail: HydratedEntry ## sentinels: head.next = MRU, tail.prev = LRU
    maxBytes*: int
    curBytes*: int
    hits*: int64              ## probe() found the eid (fast path taken)
    misses*: int64            ## probe() missed (normal path)
    hydrations*: int64        ## hydrations accepted into the set
    rejected*: int64          ## hydrations refused (entry > maxBytes)
    evictions*: int64         ## entries dropped by the LRU sweeper

proc newHydratedSet*(maxBytes: int = DefaultMaxBytes): HydratedSet =
  result = HydratedSet(
    maxBytes: maxBytes,
    head: HydratedEntry(keys: @[], bytes: 0),
    tail: HydratedEntry(keys: @[], bytes: 0),
  )
  result.head.next = result.tail
  result.tail.prev = result.head

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

# ── Reads ─────────────────────────────────────────────────────────────────────

proc keyCount*(h: HydratedSet; eid: int64): int {.inline.} =
  ## Nº de chaves CF-0 ativas conhecidas para o eid (0 quando ausente).
  ## Autoritativo enquanto a entrada estiver hidratada (invariante
  ## complete+current — ver cabeçalho do módulo).
  if eid notin h.index: return 0
  h.index[eid].keys.len

proc lookupRange*(h: HydratedSet; eid: int64; prefix: seq[byte]): seq[seq[byte]] =
  ## All stored keys starting with `prefix`, ascending. The caller has already
  ## probed membership for the eid anchored at prefix[0..<8].
  if eid notin h.index: return
  let ks = h.index[eid].keys
  # lower bound: first index with keys[i] >= prefix
  var lo = 0
  var hi = ks.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpBytes(ks[mid], prefix) < 0: lo = mid + 1
    else: hi = mid
  var i = lo
  while i < ks.len and ks[i].len >= prefix.len and
        ks[i][0 ..< prefix.len] == prefix:
    result.add ks[i]
    inc i

# ── Writes (mirror path) ──────────────────────────────────────────────────────

proc cmpPrefix(a, b: openArray[byte]): int =
  ## Compare the datom-prefix (all but the last 8 suffix bytes) of `a` and `b`.
  ## Zero-allocation — avoids the `[0 ..< len-8]` slice that was the hot spot.
  let alen = a.len - 8
  let blen = b.len - 8
  let n = min(alen, blen)
  var i = 0
  while i < n:
    if a[i] != b[i]:
      return if a[i] < b[i]: -1 else: 1
    inc i
  if alen < blen: -1
  elif alen > blen: 1
  else: 0

proc findKeyPos(ks: seq[seq[byte]]; key: seq[byte]): int =
  ## Index of the stored key whose datom-prefix equals `key`'s, or -1.
  var lo = 0
  var hi = ks.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpPrefix(ks[mid], key) < 0: lo = mid + 1
    else: hi = mid
  if lo < ks.len and cmpPrefix(ks[lo], key) == 0: lo
  else: -1

proc applyKey*(h: HydratedSet; key: seq[byte]) =
  ## Mirror one CF-0 write (already filtered by the caller). No-op when the
  ## eid is not hydrated. Active suffix → upsert; retracted → remove.
  if key.len < 20 or h.index.len == 0: return
  let eid = decodeEid(beUint64(key, 0))
  if eid notin h.index: return
  let e = h.index[eid]
  let sf = beUint64(key, key.len - 8)
  let pos = findKeyPos(e.keys, key)
  if (sf and 1) == 0:
    # active: replace in place (new version) or insert sorted
    if pos >= 0:
      dec h.curBytes, e.keys[pos].len
      dec e.bytes, e.keys[pos].len
      e.keys[pos] = key
      inc h.curBytes, key.len
      inc e.bytes, key.len
    else:
      var idx = e.keys.len
      while idx > 0 and cmpBytes(e.keys[idx - 1], key) > 0: dec idx
      e.keys.insert(key, idx)
      inc h.curBytes, key.len
      inc e.bytes, key.len
  else:
    if pos >= 0:
      dec h.curBytes, e.keys[pos].len
      dec e.bytes, e.keys[pos].len
      e.keys.delete(pos)

# ── Insertion / eviction ──────────────────────────────────────────────────────

proc drop(h: HydratedSet; eid: int64; e: HydratedEntry) {.inline.} =
  h.index.del(eid)
  unlink(e)
  dec h.curBytes, e.bytes

proc evictLruUntilFits(h: HydratedSet; incomingBytes: int) =
  ## Evict least-recently-used entries until `incomingBytes` fits alongside
  ## whatever remains. Stops when nothing but the incoming entry would remain
  ## (caller rejects that case beforehand).
  while h.curBytes + incomingBytes > h.maxBytes and h.index.len > 0:
    let victim = h.tail.prev
    if victim.eid == 0 and victim.keys.len == 0: break  # safety: sentinel/empty
    h.drop(victim.eid, victim)
    inc h.evictions

proc hydrateEmpty*(h: HydratedSet; eid: int64) =
  ## Mark a freshly allocated entity as hydrated (empty until its first save).
  if eid in h.index:
    h.touch(h.index[eid])
    return
  let e = HydratedEntry(eid: eid, keys: @[], bytes: 0)
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
  let e = HydratedEntry(eid: eid, keys: keys, bytes: total)
  h.index[eid] = e
  h.pushFront(e)
  inc h.curBytes, total
  inc h.hydrations

proc evictEid*(h: HydratedSet; eid: int64) =
  ## Explicit removal (future seam for replica WAL invalidation).
  if eid in h.index:
    h.drop(eid, h.index[eid])

proc clear*(h: HydratedSet) =
  ## Drop every entry (config change / tests).
  h.index.clear()
  h.head.next = h.tail
  h.tail.prev = h.head
  h.curBytes = 0
