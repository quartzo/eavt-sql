## cursor.nim — Cursor variant type + MergedCursor (heap merge).
##
## Replaces the closure-based NimCursor with a tagged union.
## MergedCursor and MinHeap live here to avoid circular imports.

import std/[options, tables, algorithm]
import page_store    # cmpSeq
import page_cursor   # PageStoreCursor, PageStoreSnapshot
import nim_memtable/memtypes  # Key/Value, cmpKeysByte
import nim_memtable/runs  # Run (M8)
import nim_memtable/run_cursor  # RunCursor
import hydrated  # HydratedEntry/HydratedSet (M1/M6 flat)
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
    ckRun
    ckRunKv  ## Run cursor that filters tombstones via peekKv/nextKv (M8)
    ckMerged
    ckHyd      ## Hydrated entry cursor (M1/M6): iterates the entry's flat
               ## CF-0 buffer — the eid's cached active set.  All keys are
               ## active.
    ckMock
    ckInvalid

  HydCursor* = ref object
    hs: HydratedSet      ## touched on construction (LRU probe)
    e: HydratedEntry     ## the entry's flat buffer (buf + offs)
    pos: int             ## current key index in e.offs

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
    runGen*: uint64   ## mt.gen na abertura — runs são re-coletadas se mudou
    # M1/M6 hyd mode: CF-0 seeks to a hydrated eid are served from the
    # entry's flat buffer; baseSources are parked (kept for fallback when
    # a later seek anchors at a non-hydrated eid... actually M6 entries
    # never un-hydrate per seek — parking keeps update() correct).
    hyd*: HydratedSet
    hydMode*: bool
    hydCursor*: Cursor
    baseSources*: seq[Cursor]

  RunKeys* = ref object
    ## Wraps a large sorted key run so sharing it between the store and open
    ## cursors is a ref bump (O(1)).  A bare seq[seq[byte]] copy/destroy is
    ## O(n) under ARC/ORC (per-element destructor churn) — measured ~10 ms
    ## for a 315k-key run, paid PER QUERY when the mock was built from the
    ## store's seq field directly.
    keys*: seq[seq[byte]]

  Cursor* = ref object
    case kind*: CursorKind
    of ckPageStore:
      ps*: PageStoreCursor
    of ckRun:
      rc*: RunCursor
    of ckRunKv:
      rckv*: RunCursor
    of ckMerged:
      mc*: MergedCursor
    of ckHyd:
      hc*: HydCursor
    of ckMock:
      mockKeysRef*: RunKeys
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
proc runCursor*(rc: RunCursor): Cursor {.gcsafe.}
proc runKvCursor*(rc: RunCursor): Cursor {.gcsafe.}
proc mockCursor*(keys: seq[seq[byte]]): Cursor {.gcsafe.}
proc mockCursor*(keys: RunKeys): Cursor {.gcsafe.}

# ── HydCursor (M1/M6) — iterate a hydrated entry's flat CF-0 buffer ──────────

proc hydSeekFrom(hs: HydratedSet; e: HydratedEntry; target: openArray[byte]): int =
  ## First key index with key >= target (binary search over the flat buffer).
  hydSeek(hs, e, target)

proc hydKeyAt(hs: HydratedSet; e: HydratedEntry; i: int): seq[byte] =
  entryKeyCopy(e, i)

proc hydCursorSeek(hc: HydCursor; target: seq[byte]) =
  hc.pos = hydSeekFrom(hc.hs, hc.e, target)

proc hydCursorCurrent(hc: HydCursor): Option[seq[byte]] =
  if hc.pos >= entryKeyCount(hc.e): return none(seq[byte])
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
  # M1/M6 branch: a CF-0 seek anchored at a hydrated eid is served
  # exclusively by the entry's flat buffer (complete + current — the
  # batchWrite mirror keeps it read-your-writes).
  if mc.hyd != nil and mc.cf == 0 and target.len >= 8:
    let eid = decodeEid(beUint64(target, 0))
    if mc.hyd.probeComplete(eid):
      if not mc.hydMode:
        mc.baseSources = mc.sources
        mc.hydCursor = newHydCursor(mc.hyd, mc.hyd.entryAt(eid), target)
        mc.sources = @[mc.hydCursor]
        mc.hydMode = true
      mc.hydCursor.hc.pos = hydSeekFrom(mc.hyd, mc.hyd.entryAt(eid), target)
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
    if mc.hydMode:
      # Exit hyd mode: the seek anchors at a non-hydrated eid — restore the
      # parked base sources.
      mc.sources = mc.baseSources
      mc.hydMode = false
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
             draining: seq[Run]; active: seq[Run]; runGen: uint64) {.gcsafe.} =
  ## Update cursor in-place to reflect new roots. Same semantics as creating
  ## a new cursor: reset to initial state, ready to read first element.
  ## Caller must seek() before iterating. Zero allocations when roots unchanged.
  ## M8: os runs são congelados — fontes só são re-coletadas quando mt.gen
  ## muda; a PageStore atualiza in-place como antes.
  # In hyd mode the base sources are parked — update their roots so a later
  # exitHydMode resumes from current state.
  let src = if mc.hydMode: mc.baseSources else: mc.sources
  # Source 0: PageStore
  if src.len > 0 and src[0].kind == ckPageStore:
    if mc.psRootUuid != psRootUuid:
      src[0].ps.update(psRootUuid, psHeight)
      mc.psRootUuid = psRootUuid
      mc.psHeight = psHeight
  # Sources 1..: runs — re-coletadas apenas quando a geração muda
  if mc.runGen != runGen:
    mc.runGen = runGen
    var target = if mc.hydMode: mc.baseSources else: mc.sources
    if target.len > 1:
      target.setLen(1)            # solta os RunCursors antigos, mantém a ps
    for r in draining: target.add(runCursor(newRunCursor(r)))
    for r in active: target.add(runCursor(newRunCursor(r)))
    if mc.hydMode: mc.baseSources = target else: mc.sources = target
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
  of ckRun: not c.rc.atEnd
  of ckRunKv: not c.rckv.atEnd
  of ckMerged: not c.mc.atEnd
  of ckHyd: c.hc.pos < entryKeyCount(c.hc.e)
  of ckMock: c.mockPos < c.mockKeysRef.keys.len
  of ckInvalid: false

proc currentKey*(c: Cursor): Option[seq[byte]] {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.peek()
  of ckRun: c.rc.peek()
  of ckRunKv:
    let kvp = c.rckv.peekKv()
    if kvp.isSome: some(kvp.get[0]) else: none[seq[byte]]()
  of ckMerged: c.mc.peek()
  of ckHyd: hydCursorCurrent(c.hc)
  of ckMock:
    if c.mockPos < c.mockKeysRef.keys.len: some(c.mockKeysRef.keys[c.mockPos])
    else: none[seq[byte]]()
  of ckInvalid: none[seq[byte]]()

proc currentPair*(c: Cursor): Option[(seq[byte], seq[byte])] {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.peekKv()
  of ckRun: none((seq[byte], seq[byte]))
  of ckRunKv: c.rckv.peekKv()
  of ckMerged: c.mc.peekKv()
  of ckHyd: none((seq[byte], seq[byte]))
  of ckMock: none((seq[byte], seq[byte]))
  of ckInvalid: none((seq[byte], seq[byte]))

proc step*(c: Cursor) {.gcsafe.} =
  case c.kind
  of ckPageStore: discard c.ps.next()
  of ckRun: discard c.rc.next()
  of ckRunKv: discard c.rckv.nextKv()
  of ckMerged: discard c.mc.next()
  of ckHyd: inc c.hc.pos
  of ckMock: inc c.mockPos
  of ckInvalid: discard

proc seek*(c: Cursor; target: seq[byte]) {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.seek(target)
  of ckRun: c.rc.seek(target)
  of ckRunKv: c.rckv.seek(target)
  of ckMerged: c.mc.seek(target)
  of ckHyd: hydCursorSeek(c.hc, target)
  of ckMock:
    # Random-access seek (binary search): first key >= target under the
    # prefix-compare (k vs target up to target.len).  The scanner reuses one
    # cursor for outer and inner scans — the inner seek goes BACKWARD, so a
    # forward-only walk is wrong.
    var lo = 0
    var hi = c.mockKeysRef.keys.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      let k = c.mockKeysRef.keys[mid]
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
  of ckRun: c.rc.setAtEnd(true)
  of ckRunKv: c.rckv.setAtEnd(true)
  of ckMerged: c.mc.atEnd = true
  of ckHyd: c.hc.pos = entryKeyCount(c.hc.e)
  of ckMock: c.mockPos = c.mockKeysRef.keys.len
  of ckInvalid: discard

# ── Constructors ──

proc pageStoreCursor*(psc: PageStoreCursor): Cursor =
  Cursor(kind: ckPageStore, ps: psc)

proc runCursor*(rc: RunCursor): Cursor =
  Cursor(kind: ckRun, rc: rc)

proc runKvCursor*(rc: RunCursor): Cursor =
  ## Wrap a RunCursor for key-value scan, filtering tombstones.
  Cursor(kind: ckRunKv, rckv: rc)

proc mergedCursor*(mc: MergedCursor): Cursor =
  Cursor(kind: ckMerged, mc: mc)

proc mockCursor*(keys: RunKeys): Cursor {.gcsafe.} =
  ## O(1): shares the run through the ref (no per-element copy).
  result = Cursor(kind: ckMock, mockKeysRef: keys, mockPos: 0)

proc mockCursor*(keys: seq[seq[byte]]): Cursor {.gcsafe.} =
  ## Small key runs (per-eid deltas): wrapping cost is O(k), negligible.
  result = Cursor(kind: ckMock, mockKeysRef: RunKeys(keys: keys), mockPos: 0)

proc invalidCursor*(): Cursor =
  Cursor(kind: ckInvalid)
