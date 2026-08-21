## cursor.nim — Cursor variant type + MergedCursor (heap merge).
##
## Replaces the closure-based NimCursor with a tagged union.
## MergedCursor and MinHeap live here to avoid circular imports.

import std/options
import page_store    # cmpSeq
import page_cursor   # PageStoreCursor, PageStoreSnapshot
import treap_cursor  # TreapCursor
import nim_memtable/treap_backend  # TreapNode

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
    ckMock
    ckInvalid

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
             flushRoot, liveRoot: TreapNode) {.gcsafe.} =
  ## Update cursor in-place to reflect new roots. Same semantics as creating
  ## a new cursor: reset to initial state, ready to read first element.
  ## Caller must seek() before iterating. Zero allocations when roots unchanged.
  # Source 0: PageStore
  if mc.sources.len > 0 and mc.sources[0].kind == ckPageStore:
    if mc.psRootUuid != psRootUuid:
      mc.sources[0].ps.update(psRootUuid, psHeight)
      mc.psRootUuid = psRootUuid
      mc.psHeight = psHeight
  # Source 1: flush treap
  if mc.sources.len > 1 and mc.sources[1].kind == ckTreap:
    if mc.flushRoot != flushRoot:
      mc.sources[1].tc.update(flushRoot)
      mc.flushRoot = flushRoot
  # Source 2: live treap — always changes (new datoms written)
  if mc.sources.len > 2 and mc.sources[2].kind == ckTreap:
    mc.sources[2].tc.update(liveRoot)
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
  of ckMock: none((seq[byte], seq[byte]))
  of ckInvalid: none((seq[byte], seq[byte]))

proc step*(c: Cursor) {.gcsafe.} =
  case c.kind
  of ckPageStore: discard c.ps.next()
  of ckTreap: discard c.tc.next()
  of ckTreapKv: discard c.tckv.nextKv()
  of ckMerged: discard c.mc.next()
  of ckMock: inc c.mockPos
  of ckInvalid: discard

proc seek*(c: Cursor; target: seq[byte]) {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.seek(target)
  of ckTreap: c.tc.seek(target)
  of ckTreapKv: c.tckv.seek(target)
  of ckMerged: c.mc.seek(target)
  of ckMock:
    while c.mockPos < c.mockKeys.len:
      let k = c.mockKeys[c.mockPos]
      if k.len >= target.len:
        var ge = true
        for i in 0..<target.len:
          if k[i] < target[i]: ge = false; break
          if k[i] > target[i]: break
        if ge: return
      inc c.mockPos
  of ckInvalid: discard

proc invalidate*(c: Cursor) {.gcsafe.} =
  case c.kind
  of ckPageStore: c.ps.atEnd = true
  of ckTreap: c.tc.atEnd = true
  of ckTreapKv: c.tckv.atEnd = true
  of ckMerged: c.mc.atEnd = true
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

proc mockCursor*(keys: seq[seq[byte]]): Cursor =
  Cursor(kind: ckMock, mockKeys: keys, mockPos: 0)

proc invalidCursor*(): Cursor =
  Cursor(kind: ckInvalid)
