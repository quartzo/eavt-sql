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

import std/[tables]
import keys
import nim_memtable/treap_backend  # KeyRef

const DefaultMaxBytes* = 1 shl 30          ## 1 GiB — cfg `hydrated_max_bytes`

type
  HydratedEntry = ref object
    eid: int64                ## owning entity (O(1) LRU victim removal)
    buf: seq[byte]            ## concatenated ACTIVE CF-0 keys, ascending
    offs: seq[int32]          ## start offset of each key (len = nº de chaves)
    bytes: int                ## == buf.len
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
    head: HydratedEntry(eid: 0, bytes: 0),
    tail: HydratedEntry(eid: 0, bytes: 0),
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

proc applyKey*(h: HydratedSet; key: KeyRef) =
  ## Mirror one CF-0 write (already filtered by the caller). No-op when the
  ## eid is not hydrated. Active suffix → upsert; retracted → remove.
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
    else:
      var idx = e.offs.len
      while idx > 0 and cmpFullAt(e, idx - 1, key.p.toOpenArray(0, klen - 1)) > 0: dec idx
      insertKeyAt(e, idx, key.p, klen)
      h.curBytes += klen
      e.bytes += klen
  else:
    if pos >= 0:
      let oldLen = removeKeyAt(e, pos)
      h.curBytes -= oldLen
      e.bytes -= oldLen

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
    if victim.eid == 0 and victim.offs.len == 0: break  # safety: sentinel/empty
    h.drop(victim.eid, victim)
    inc h.evictions

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
  if eid in h.index:
    h.drop(eid, h.index[eid])

proc clear*(h: HydratedSet) =
  ## Drop every entry (config change / tests).
  h.index.clear()
  h.head.next = h.tail
  h.tail.prev = h.head
  h.curBytes = 0
