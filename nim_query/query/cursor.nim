## cursor.nim — Cursor variant type + MergedCursor (heap merge).
##
## Replaces the closure-based NimCursor with a tagged union.
## MergedCursor and MinHeap live here to avoid circular imports.

import std/[options, tables, algorithm]
import page_store    # cmpSeq
import page_cursor   # PageStoreCursor, PageStoreSnapshot
import treap_cursor  # TreapCursor
import nim_memtable/treap_backend  # TreapNode
import hydrated  # HydratedEntry/HydratedSet (M1)
import datoms  # DatomSlot/DatomVector (M5)
import keys  # decodeEid/beUint64

# ═══════════════════════════════════════════════════════════════════════════════
# MinHeap for merge operations
# ═══════════════════════════════════════════════════════════════════════════════

type
  HeapEntry = tuple[key: seq[byte], srcIdx: int]
  MinHeap* = object
    data: seq[HeapEntry]

proc parent(i: int): int = (i - 1) shr 1
proc leftChild(i: int): int = (i shl 1) + 1

proc push*(h: var MinHeap; entry: HeapEntry) =
  h.data.add entry
  var i = h.data.len - 1
  while i > 0:
    let p = parent(i)
    if cmpSeq(h.data[i].key, h.data[p].key) < 0:
      swap(h.data[i], h.data[p])
      i = p
    else: break

proc pop*(h: var MinHeap): HeapEntry =
  result = h.data[0]
  h.data[0] = h.data[^1]
  h.data.setLen(h.data.len - 1)
  var i = 0
  while true:
    let l = leftChild(i)
    if l >= h.data.len: break
    var smallest = i
    if cmpSeq(h.data[l].key, h.data[smallest].key) < 0:
      smallest = l
    let r = l + 1
    if r < h.data.len and cmpSeq(h.data[r].key, h.data[smallest].key) < 0:
      smallest = r
    if smallest != i:
      swap(h.data[i], h.data[smallest])
      i = smallest
    else: break

proc len*(h: MinHeap): int = h.data.len

# ═══════════════════════════════════════════════════════════════════════════════
# Cursor variant + MergedCursor
# ═══════════════════════════════════════════════════════════════════════════════

type
  CursorKind* = enum
    ckPageStore
    ckTreap
    ckTreapKv  ## Treap cursor that filters tombstones via peekKv/nextKv
    ckMerged
    ckHyd      ## Hydrated entry cursor (M1): iterates the entry's CF-0
               ## buffer — the eid's memtable.  All keys are active.
    ckMock
    ckInvalid

  HydCursor* = ref object
    hs: HydratedSet      ## slot byte resolution goes through its vector
    e: HydratedEntry     ## the entry IS the memtable for this eid
    pos: int             ## current slot index in e.slots

  MergedCursor* = ref object
    sources*: seq[Cursor]
    heap*: MinHeap
    lastKey*: seq[byte]
    atEnd*: bool
    curKey*: Option[seq[byte]]
    curPair*: Option[(seq[byte], seq[byte])]
    isKv*: bool
    # Known roots for update detection
    cf*: int
    psRootUuid*: array[16, byte]
    psHeight*: uint8
    flushRoot*: TreapNode
    liveRoot*: TreapNode
    # M1 hyd mode: CF-0 seeks to a fully hydrated eid are served from the
    # entry (the memtable for that eid); baseSources are kept for fallback.
    hyd*: HydratedSet
    hydMode*: bool
    hydCursor*: Cursor
    baseSources*: seq[Cursor]
    deltaEid*: int64   ## M4: eid whose partial delta source is attached (0 = none)

  Cursor* = ref object
    case kind*: CursorKind
    of ckPageStore:
      ps*: PageStoreCursor
    of ckTreap:
      tc*: TreapCursor
    of ckTreapKv:
      tckv*: TreapCursor
    of ckMerged:
      mc*: MergedCursor
    of ckHyd:
      hc*: HydCursor
    of ckMock:
      mockKeys*: seq[seq[byte]]
      mockPos*: int
    of ckInvalid:
      discard

# ── Forward declarations ──

proc isValid*(c: Cursor): bool {.gcsafe.}
proc currentKey*(c: Cursor): Option[seq[byte]] {.gcsafe.}
proc currentPair*(c: Cursor): Option[(seq[byte], seq[byte])] {.gcsafe.}
proc step*(c: Cursor) {.gcsafe.}
proc seek*(c: Cursor; target: seq[byte]) {.gcsafe.}
proc invalidate*(c: Cursor) {.gcsafe.}
proc mockCursor*(keys: seq[seq[byte]]): Cursor {.gcsafe.}

# ── HydCursor (M1/M5) — iterate a hydrated entry's CF-0 slots ──

proc hydSeekFrom(hs: HydratedSet; e: HydratedEntry; target: openArray[byte]): int =
  ## First slot index with key >= target (binary search; keys resolve
  ## through the vector's chunks — zero copy).
  var lo, hi = 0
  hi = e.slots.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let c = hs.vec.cmpSlotKey(e.slots[mid], target)
    if c < 0: lo = mid + 1
    else: hi = mid
  lo

proc hydKeyAt(hs: HydratedSet; e: HydratedEntry; i: int): seq[byte] =
  hs.vec.keyCopy(e.slots[i])

proc hydCursorSeek(hc: HydCursor; target: seq[byte]) =
  hc.pos = hydSeekFrom(hc.hs, hc.e, target)

proc hydCursorCurrent(hc: HydCursor): Option[seq[byte]] =
  if hc.pos >= hc.e.slots.len: return none(seq[byte])
  some(hydKeyAt(hc.hs, hc.e, hc.pos))

proc newHydCursor*(hs: HydratedSet; e: HydratedEntry; target: seq[byte]): Cursor =
  let hc = HydCursor(hs: hs, e: e)
  hydCursorSeek(hc, target)
  Cursor(kind: ckHyd, hc: hc)

# ── MergedCursor procs ──

proc advance*(mc: MergedCursor) {.gcsafe.} =
  if mc.atEnd: return
  while mc.heap.len > 0:
    let (key, srcIdx) = mc.heap.pop()
    if mc.lastKey.len > 0 and key == mc.lastKey:
      var src = mc.sources[srcIdx]
      if src.isValid():
        src.step()
        if src.isValid():
          let nk = src.currentKey()
          if nk.isSome: mc.heap.push((nk.get, srcIdx))
      continue
    mc.lastKey = key
    mc.curKey = some(key)
    if mc.isKv:
      var src = mc.sources[srcIdx]
      mc.curPair = src.currentPair()
    var src2 = mc.sources[srcIdx]
    src2.step()
    if src2.isValid():
      let nk = src2.currentKey()
      if nk.isSome: mc.heap.push((nk.get, srcIdx))
    return
  mc.atEnd = true
  mc.curKey = none(seq[byte])
  mc.curPair = none((seq[byte], seq[byte]))

proc addSource*(mc: MergedCursor; src: Cursor) {.gcsafe.} =
  ## Add a source after construction (before iteration starts) — pushes its
  ## current key into the merge heap.
  mc.sources.add(src)
  if src.isValid():
    let k = src.currentKey()
    if k.isSome: mc.heap.push((k.get, mc.sources.len - 1))

proc newMergedCursor*(sources: seq[Cursor]): MergedCursor {.gcsafe.} =
  result = MergedCursor(sources: sources, atEnd: false)
  var heap: MinHeap
  for i, src in sources:
    if src.isValid():
      let k = src.currentKey()
      if k.isSome:
        heap.push((k.get, i))
  result.heap = heap

proc ensure*(mc: MergedCursor) {.gcsafe.} =
  if mc.curKey.isNone and not mc.atEnd:
    mc.advance()

proc peek*(mc: MergedCursor): Option[seq[byte]] {.gcsafe.} =
  mc.ensure()
  if mc.atEnd: none(seq[byte]) else: mc.curKey

proc next*(mc: MergedCursor): Option[seq[byte]] {.gcsafe.} =
  mc.ensure()
  result = mc.curKey
  mc.curKey = none(seq[byte])
  mc.advance()

proc peekKv*(mc: MergedCursor): Option[(seq[byte], seq[byte])] {.gcsafe.} =
  mc.ensure()
  if mc.atEnd: none((seq[byte], seq[byte])) else: mc.curPair

proc nextKv*(mc: MergedCursor): Option[(seq[byte], seq[byte])] {.gcsafe.} =
  mc.ensure()
  result = mc.curPair
  mc.curPair = none((seq[byte], seq[byte]))
  mc.advance()

proc seek*(mc: MergedCursor; target: seq[byte]) {.gcsafe.} =
  # M1/M4 branch: a CF-0 seek anchored at a COMPLETE hydrated eid is served
  # exclusively by the entry (the memtable for that eid — complete+current).
  # A PARTIAL eid gets its DELTA as an extra source (merged with the base
  # sources — the delta does not supersede them).
  if mc.hyd != nil and mc.cf == 0 and target.len >= 8:
    let eid = decodeEid(beUint64(target, 0))
    if mc.hyd.probeComplete(eid):
      if mc.deltaEid != 0:
        mc.sources = mc.baseSources
        mc.deltaEid = 0
      if not mc.hydMode:
        mc.baseSources = mc.sources
        mc.hydCursor = newHydCursor(mc.hyd, mc.hyd.index[eid], target)
        mc.sources = @[mc.hydCursor]
        mc.hydMode = true
      mc.hydCursor.hc.pos = hydSeekFrom(mc.hyd, mc.hyd.index[eid], target)
      mc.heap.data = @[]
      if mc.sources[0].isValid():
        let k = mc.sources[0].currentKey()
        if k.isSome: mc.heap.push((k.get, 0))
      mc.lastKey = @[]
      mc.atEnd = false
      mc.curKey = none(seq[byte])
      mc.curPair = none((seq[byte], seq[byte]))
      mc.advance()
      return
    # M4: partial delta as an extra source (switched when the eid changes)
    let needDelta = mc.hyd.contains(eid)
    if needDelta and mc.deltaEid != eid:
      mc.sources = mc.baseSources
      mc.hydMode = false
      let e = mc.hyd.index[eid]
      var dkeys: seq[seq[byte]] = @[]
      for s in e.slots:
        dkeys.add mc.hyd.vec.keyCopy(s)
      for s in e.tombSlots:
        dkeys.add mc.hyd.vec.keyCopy(s)
      if dkeys.len > 1: dkeys.sort(cmpKeysByte)
      mc.sources = mc.sources & @[mockCursor(dkeys)]
      mc.deltaEid = eid
    elif not needDelta and mc.deltaEid != 0:
      mc.sources = mc.baseSources
      mc.deltaEid = 0
  for src in mc.sources:
    src.seek(target)
  mc.heap.data = @[]
  for i, src in mc.sources:
    if src.isValid():
      let k = src.currentKey()
      if k.isSome: mc.heap.push((k.get, i))
  mc.lastKey = @[]
  mc.atEnd = false
  mc.curKey = none(seq[byte])
  mc.advance()

proc update*(mc: MergedCursor; psRootUuid: array[16, byte]; psHeight: uint8;
             flushRoot: TreapNode; flushArena: Arena;
             liveRoot: TreapNode; liveArena: Arena) {.gcsafe.} =
  ## Update cursor in-place to reflect new roots. Same semantics as creating
  ## a new cursor: reset to initial state, ready to read first element.
  ## Caller must seek() before iterating. Zero allocations when roots unchanged.
  # In hyd mode the base sources are parked — update their roots so a later
  # exitHydMode resumes from current state.
  let src = if mc.hydMode: mc.baseSources else: mc.sources
  # Source 0: PageStore
  if src.len > 0 and src[0].kind == ckPageStore:
    if mc.psRootUuid != psRootUuid:
      src[0].ps.update(psRootUuid, psHeight)
      mc.psRootUuid = psRootUuid
      mc.psHeight = psHeight
  # Source 1: flush treap
  if src.len > 1 and src[1].kind == ckTreap:
    if mc.flushRoot != flushRoot:
      src[1].tc.update(flushRoot, flushArena)
      mc.flushRoot = flushRoot
  # Source 2: live treap — always changes (new datoms written)
  if src.len > 2 and src[2].kind == ckTreap:
    src[2].tc.update(liveRoot, liveArena)
    mc.liveRoot = liveRoot
  # Reset to initial state — same as newMergedCursor
  mc.heap.data.setLen(0)
  mc.lastKey.setLen(0)
  mc.curKey = none(seq[byte])
  mc.curPair = none((seq[byte], seq[byte]))
  mc.atEnd = false

# ── Dispatch procs (call MergedCursor procs defined above) ──

proc isValid*(c: Cursor): bool {.gcsafe.} =
  case c.kind
  of ckPageStore: not c.ps.atEnd
  of ckTreap: not c.tc.atEnd
  of ckTreapKv: not c.tckv.atEnd
  of ckMerged: not c.mc.atEnd
  of ckHyd: c.hc.pos < c.hc.e.slots.len
  of ckMock: c.mockPos < c.mockKeys.len
  of ckInvalid: false

proc currentKey*(c: Cursor): Option[seq[byte]] {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.peek()
  of ckTreap: c.tc.peek()
  of ckTreapKv:
    let kvp = c.tckv.peekKv()
    if kvp.isSome: some(kvp.get[0]) else: none[seq[byte]]()
  of ckMerged: c.mc.peek()
  of ckHyd: hydCursorCurrent(c.hc)
  of ckMock:
    if c.mockPos < c.mockKeys.len: some(c.mockKeys[c.mockPos])
    else: none[seq[byte]]()
  of ckInvalid: none[seq[byte]]()

proc currentPair*(c: Cursor): Option[(seq[byte], seq[byte])] {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.peekKv()
  of ckTreap: c.tc.peekKv()
  of ckTreapKv: c.tckv.peekKv()
  of ckMerged: c.mc.peekKv()
  of ckHyd: none((seq[byte], seq[byte]))
  of ckMock: none((seq[byte], seq[byte]))
  of ckInvalid: none((seq[byte], seq[byte]))

proc step*(c: Cursor) {.gcsafe.} =
  case c.kind
  of ckPageStore: discard c.ps.next()
  of ckTreap: discard c.tc.next()
  of ckTreapKv: discard c.tckv.nextKv()
  of ckMerged: discard c.mc.next()
  of ckHyd: inc c.hc.pos
  of ckMock: inc c.mockPos
  of ckInvalid: discard

proc seek*(c: Cursor; target: seq[byte]) {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.seek(target)
  of ckTreap: c.tc.seek(target)
  of ckTreapKv: c.tckv.seek(target)
  of ckMerged: c.mc.seek(target)
  of ckHyd: hydCursorSeek(c.hc, target)
  of ckMock:
    # Random-access seek (binary search): first key >= target under the
    # prefix-compare (k vs target up to target.len).  The scanner reuses one
    # cursor for outer and inner scans — the inner seek goes BACKWARD, so a
    # forward-only walk is wrong.
    var lo = 0
    var hi = c.mockKeys.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      let k = c.mockKeys[mid]
      var ge = true
      var f = 0
      for i in 0..<target.len:
        if i >= k.len: f = -1; break   # k shorter → k < target
        if k[i] < target[i]: f = -1; break
        if k[i] > target[i]: f = 1; break
      if f != 0: ge = false
      if ge or f > 0: hi = mid
      else: lo = mid + 1
    c.mockPos = lo
  of ckInvalid: discard

proc invalidate*(c: Cursor) {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.atEnd = true
  of ckTreap: c.tc.atEnd = true
  of ckTreapKv: c.tckv.atEnd = true
  of ckMerged: c.mc.atEnd = true
  of ckHyd: c.hc.pos = c.hc.e.slots.len
  of ckMock: c.mockPos = c.mockKeys.len
  of ckInvalid: discard

# ── Constructors ──

proc pageStoreCursor*(psc: PageStoreCursor): Cursor =
  Cursor(kind: ckPageStore, ps: psc)

proc treapCursor*(tc: TreapCursor): Cursor =
  Cursor(kind: ckTreap, tc: tc)

proc treapKvCursor*(tc: TreapCursor): Cursor =
  ## Wrap a TreapCursor for key-value scan, filtering tombstones.
  Cursor(kind: ckTreapKv, tckv: tc)

proc mergedCursor*(mc: MergedCursor): Cursor =
  Cursor(kind: ckMerged, mc: mc)

proc mockCursor*(keys: seq[seq[byte]]): Cursor {.gcsafe.} =
  Cursor(kind: ckMock, mockKeys: keys, mockPos: 0)

proc invalidCursor*(): Cursor =
  Cursor(kind: ckInvalid)
