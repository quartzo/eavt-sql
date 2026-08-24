## page_cursor.nim — Lazy forward cursor over PageStore B-tree leaf pages.
##
## Iterates all keys in a CF in order. No prefix filtering — the scanner
## handles that via seek() and classifyKey. Loads one leaf at a time.
##
## The cursor is pinned to the tree root captured at construction time.
## Because the PageStore is COW, that root (and the whole subtree it
## references) is immutable for the cursor's lifetime — a concurrent
## flush/commitMerge installs a new root in trees[cf] but does not mutate
## the old one, so this cursor continues to see a consistent snapshot.

import std/[options, strutils, sequtils, monotimes]
import page_store
import logutil
import pages

type
  IndexPos = object
    entries*: seq[(seq[byte], array[16, byte])]
    pos*: int

  PageStoreSnapshot* = object
    rootUuid*: array[16, byte]
    height*: uint8

  PageStoreCursor* = ref object
    s*: ptr PageStoreInner
    cf*: int
    atEnd*: bool
    indexStack: seq[IndexPos]
    flatKeys*: FlatLeafKeys                    ## cf < 10 (arena plana)
    flatKV*: FlatLeafKV                        ## cf >= 10 (arena plana)
    leafIdx*: int
    curKey*: Option[seq[byte]]
    curPair*: Option[(seq[byte], seq[byte])]
    rootUuid*: array[16, byte]
    height*: uint8
    isKv*: bool  ## true if this cursor reads key-value leaf pages
    when defined(eavtSeekDiag):
      lastSeekDescendNs*: int64
      lastSeekCrossNs*: int64

# ── Helpers ──

proc loadIndexPage(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], array[16, byte])] =
  ## Parsed-index cache: pages are immutable under COW, so the expensive
  ## deserialize happens once per uuid (seeks repeat it otherwise — hot on
  ## goc/lookup-entity workloads after the first flush publishes CF roots).
  let cached = s.cache.getIndex(uuid)
  if cached.isSome:
    return cached.get
  inc s.indexPageLoads
  let raw = loadLeafRaw(s, uuid)
  try:
    result = deserializeIndexPage(raw)
  except ValueError as e:
    var hex = ""
    for b in uuid: hex.add toHex(b)
    stderr.writeLine("pagestore: bad index page uuid=" & hex &
      " rawLen=" & $raw.len & " err=" & e.msg)
    try:
      for cf, t in s.trees:
        if t.rootUuid == default(array[16, byte]): continue
        var rh = ""
        for b in t.rootUuid: rh.add toHex(b)
        let mark = if cmpIgnoreCase(rh, hex) == 0:
          "  <<< requested uuid IS this root" else: ""
        stderr.writeLine("trees[", cf, "] h=", t.height,
                         " leaves=", t.numLeaves, " root=", rh, mark)
    except CatchableError:
      discard
    try:
      var dump = "/tmp/opencode/receita_bench/badpage_" & hex & ".bin"
      writeFile(dump, raw)
      stderr.writeLine("pagestore: dumped raw to " & dump)
    except CatchableError as e:
      # Diagnostic dump only — the real error is re-raised below.
      logDebug("pagestore", "bad-page dump failed (" & excMsg(e) & ")")
    raise
  s.cache.putIndex(uuid, result)

proc loadLeaf(c: PageStoreCursor; uuid: array[16, byte]) =
  ## Pega a folha MATERIALIZADA (arena plana) direto do cache — sem passar
  ## pela API aninhada, que reconstrói seq[seq[byte]] e devolve o churn.
  if c.isKv:
    let cached = c.s[].cache.getLeafKV(uuid)
    if cached.isSome: c.flatKV = cached.get
    else:
      let raw = loadLeafRaw(c.s[], uuid)
      c.flatKV = toFlat(deserializePageKv(raw))
  else:
    let cached = c.s[].cache.getLeafKeys(uuid)
    if cached.isSome: c.flatKeys = cached.get
    else:
      let raw = loadLeafRaw(c.s[], uuid)
      c.flatKeys = toFlat(deserializePage(raw))
      c.s[].cache.putLeafKeys(uuid, c.flatKeys)
  c.leafIdx = -1

proc keyCount(c: PageStoreCursor): int {.inline.} =
  if c.isKv: flatCount(c.flatKV) else: flatCount(c.flatKeys)

## Comparação sem alocação da chave i da folha vs alvo.
proc cmpKeyAt(c: PageStoreCursor; i: int; target: openArray[byte]): int {.
    inline.} =
  if c.isKv:
    cmpSlice(c.flatKV.kbuf, c.flatKV.koffs[i].int,
             c.flatKV.koffs[i + 1].int, target)
  else:
    cmpSlice(c.flatKeys.buf, c.flatKeys.offs[i].int,
             c.flatKeys.offs[i + 1].int, target)

proc firstKeyAt(c: PageStoreCursor; i: int): seq[byte] {.inline.} =
  if c.isKv: c.flatKV.kbuf[c.flatKV.koffs[i].int ..< c.flatKV.koffs[i + 1].int]
  else: c.flatKeys.buf[c.flatKeys.offs[i].int ..< c.flatKeys.offs[i + 1].int]

# ── Navigation ──

var gDiagIdxNs* = 0'i64      # loadIndexPage acumulado
var gDiagBinNs* = 0'i64      # busca binária acumulada
var gDiagLeafNs* = 0'i64     # loadLeaf acumulado
var gDiagDescends* = 0'i64

proc descendToFirstLeaf(c: PageStoreCursor; uuid: array[16, byte]; height: uint8) =
  var curUuid = uuid
  var h = height
  c.indexStack = @[]
  while h > 0:
    let entries = loadIndexPage(c.s[], curUuid)
    c.indexStack.add IndexPos(entries: entries, pos: 0)
    curUuid = entries[0][1]
    dec h
  loadLeaf(c, curUuid)

# Descend the B-tree using binary search at each index level to find the
# leaf whose first key is the largest key <= target. Populates indexStack
# with the chosen position at each level so advanceToNextLeaf can continue
# forward from there. O(log n) page reads vs. O(n) leaf scans.
proc descendToLeafAt(c: PageStoreCursor; uuid: array[16, byte]; height: uint8;
                     target: seq[byte]) =
  var curUuid = uuid
  var h = height
  c.indexStack = @[]
  inc gDiagDescends
  while h > 0:
    let t0 = getMonoTime().ticks
    let entries = loadIndexPage(c.s[], curUuid)
    gDiagIdxNs += getMonoTime().ticks - t0
    # Rightmost entry whose boundary key is <= target.
    let t1 = getMonoTime().ticks
    var lo = 0
    var hi = entries.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if cmpSeq(entries[mid][0], target) <= 0: lo = mid + 1
      else: hi = mid
    let pos = if lo > 0: lo - 1 else: 0
    gDiagBinNs += getMonoTime().ticks - t1
    c.indexStack.add IndexPos(entries: entries, pos: pos)
    curUuid = entries[pos][1]
    dec h
  let t2 = getMonoTime().ticks
  loadLeaf(c, curUuid)
  gDiagLeafNs += getMonoTime().ticks - t2

proc advanceToNextLeaf(c: PageStoreCursor) =
  while c.indexStack.len > 0:
    var top = addr c.indexStack[^1]
    inc top.pos
    if top.pos < top.entries.len:
      var curUuid = top.entries[top.pos][1]
      if c.height == 1 and c.indexStack.len == 1:
        # Root is a single index whose DIRECT children are leaves — the
        # sibling is a leaf, not a subtree. Loading it as an index either
        # raises "truncated index entry" or (worse) misparses leaf bytes as
        # bogus entries and navigates into phantom pointers.
        loadLeaf(c, curUuid)
      else:
        while true:
          let entries = loadIndexPage(c.s[], curUuid)
          if entries.len > 0:
            c.indexStack.add IndexPos(entries: entries, pos: 0)
            curUuid = entries[0][1]
          else: break
        loadLeaf(c, curUuid)
      return
    c.indexStack.setLen(c.indexStack.len - 1)
  c.atEnd = true

# ── Internal ──

proc advance(c: PageStoreCursor) =
  if c.atEnd: return
  c.curKey = none(seq[byte])
  c.curPair = none((seq[byte], seq[byte]))
  while true:
    inc c.leafIdx
    if c.isKv:
      if c.leafIdx < flatCount(c.flatKV):
        let (k, v) = flatKVAt(c.flatKV, c.leafIdx)
        c.curPair = some((k, v))
        c.curKey = some(k)
        return
    else:
      if c.leafIdx < flatCount(c.flatKeys):
        c.curKey = some(flatKey(c.flatKeys, c.leafIdx))
        return
    if c.indexStack.len > 0:
      advanceToNextLeaf(c)
      if c.atEnd: return
      continue
    c.atEnd = true
    return

proc ensure(c: PageStoreCursor) =
  if c.curKey.isNone and not c.atEnd:
    if c.rootUuid == default(array[16, byte]):
      c.atEnd = true; return
    if c.keyCount() == 0 and c.indexStack.len == 0:
      if c.height == 0: loadLeaf(c, c.rootUuid)
      else: descendToFirstLeaf(c, c.rootUuid, c.height)
    c.advance()

# ── Public API ──

proc peek*(c: PageStoreCursor): Option[seq[byte]] =
  c.ensure()
  if c.atEnd: none(seq[byte]) else: c.curKey

proc next*(c: PageStoreCursor): Option[seq[byte]] =
  c.ensure()
  result = c.curKey
  c.advance()

proc peekKv*(c: PageStoreCursor): Option[(seq[byte], seq[byte])] =
  c.ensure()
  if c.atEnd: none((seq[byte], seq[byte])) else: c.curPair

proc nextKv*(c: PageStoreCursor): Option[(seq[byte], seq[byte])] =
  c.ensure()
  result = c.curPair
  c.advance()

proc seek*(c: PageStoreCursor; target: seq[byte]) =
  if c.rootUuid == default(array[16, byte]): c.atEnd = true; return
  when defined(eavtSeekDiag):
    let tDesc0 = getMonoTime().ticks

  # Fast-path: se a folha corrente já contém o alvo (primeira <= alvo <=
  # última), busca binária por fatias da arena — sem descida, sem página.
  let keyCount = c.keyCount()
  if keyCount > 0:
    if c.cmpKeyAt(0, target) <= 0 and c.cmpKeyAt(keyCount - 1, target) >= 0:
      var lo = 0
      var hi = keyCount
      while lo < hi:
        let mid = (lo + hi) shr 1
        if c.cmpKeyAt(mid, target) < 0: lo = mid + 1
        else: hi = mid
      c.leafIdx = lo - 1
      c.curKey = none(seq[byte])
      c.curPair = none((seq[byte], seq[byte]))
      c.atEnd = false
      c.advance()
      return

  # Slow path: descend from the pinned root to the leaf that should hold
  # target, POSITION directly via binary search inside that leaf (a linear
  # advance() walk from the leaf start cost up to a full leaf — ~ms when the
  # target sat near its end), then cross forward only while keys < target.
  if c.height == 0: loadLeaf(c, c.rootUuid)
  else: descendToLeafAt(c, c.rootUuid, c.height, target)
  when defined(eavtSeekDiag):
    c.lastSeekDescendNs = getMonoTime().ticks - tDesc0
    let tCross0 = getMonoTime().ticks
  block positionInLeaf:
    let keyCount = c.keyCount()
    var lo = 0
    var hi = keyCount
    while lo < hi:
      let mid = (lo + hi) shr 1
      if c.cmpKeyAt(mid, target) < 0: lo = mid + 1
      else: hi = mid
    c.leafIdx = lo - 1          # primeira chave >= target fica em lo
  c.curKey = none(seq[byte])
  c.curPair = none((seq[byte], seq[byte]))
  c.atEnd = false
  while not c.atEnd:
    c.advance()
    if c.curKey.isSome and cmpSeq(c.curKey.get, target) >= 0:
      when defined(eavtSeekDiag):
        c.lastSeekCrossNs = getMonoTime().ticks - tCross0
      return
  when defined(eavtSeekDiag):
    c.lastSeekCrossNs = getMonoTime().ticks - tCross0
  c.atEnd = true

proc update*(c: PageStoreCursor; rootUuid: array[16, byte]; height: uint8) =
  ## Update cursor in-place to point at a new B-tree root. Clears internal
  ## state so the next seek/ensure will re-descend from the new root.
  c.rootUuid = rootUuid
  c.height = height
  c.indexStack.setLen(0)
  c.flatKeys = default(FlatLeafKeys)
  c.flatKV = default(FlatLeafKV)
  c.leafIdx = 0
  c.curKey = none(seq[byte])
  c.curPair = none((seq[byte], seq[byte]))
  c.atEnd = (rootUuid == default(array[16, byte]))
