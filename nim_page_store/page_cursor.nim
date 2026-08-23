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

import std/[options, strutils, sequtils]
import page_store
import logutil

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
    leafKeys*: seq[seq[byte]]
    leafPairs*: seq[(seq[byte], seq[byte])]  ## used when cf >= 10
    leafIdx*: int
    curKey*: Option[seq[byte]]
    curPair*: Option[(seq[byte], seq[byte])]
    rootUuid*: array[16, byte]
    height*: uint8
    isKv*: bool  ## true if this cursor reads key-value leaf pages

# ── Helpers ──

proc loadIndexPage(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], array[16, byte])] =
  let raw = loadLeafRaw(s, uuid)
  try:
    result = deserializeIndexPage(raw)
  except ValueError as e:
    var hex = ""
    for b in uuid: hex.add toHex(b)
    stderr.writeLine("pagestore: bad index page uuid=" & hex &
      " rawLen=" & $raw.len & " err=" & e.msg)
    try:
      var dump = "/tmp/opencode/receita_bench/badpage_" & hex & ".bin"
      writeFile(dump, raw)
      stderr.writeLine("pagestore: dumped raw to " & dump)
    except CatchableError as e:
      # Diagnostic dump only — the real error is re-raised below.
      logDebug("pagestore", "bad-page dump failed (" & excMsg(e) & ")")
    raise

proc loadLeaf(c: PageStoreCursor; uuid: array[16, byte]) =
  if c.isKv:
    c.leafPairs = loadLeafPairs(c.s[], uuid)
  else:
    c.leafKeys = loadLeafKeys(c.s[], uuid)
  c.leafIdx = -1

# ── Navigation ──

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
  while h > 0:
    let entries = loadIndexPage(c.s[], curUuid)
    # Rightmost entry whose boundary key is <= target.
    var lo = 0
    var hi = entries.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if cmpSeq(entries[mid][0], target) <= 0: lo = mid + 1
      else: hi = mid
    let pos = if lo > 0: lo - 1 else: 0
    c.indexStack.add IndexPos(entries: entries, pos: pos)
    curUuid = entries[pos][1]
    dec h
  loadLeaf(c, curUuid)

proc advanceToNextLeaf(c: PageStoreCursor) =
  while c.indexStack.len > 0:
    var top = addr c.indexStack[^1]
    inc top.pos
    if top.pos < top.entries.len:
      var curUuid = top.entries[top.pos][1]
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
      if c.leafIdx < c.leafPairs.len:
        c.curPair = some(c.leafPairs[c.leafIdx])
        c.curKey = some(c.leafPairs[c.leafIdx][0])
        return
    else:
      if c.leafIdx < c.leafKeys.len:
        c.curKey = some(c.leafKeys[c.leafIdx])
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
    if c.leafKeys.len == 0 and c.indexStack.len == 0:
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

  # Fast-path: if the current leaf already contains target (its first key
  # <= target <= its last key), binary-search within leafKeys/leafPairs — no descent,
  # no page loads.
  let keyCount = if c.isKv: c.leafPairs.len else: c.leafKeys.len
  if keyCount > 0:
    let firstKey = if c.isKv: c.leafPairs[0][0] else: c.leafKeys[0]
    let lastKey = if c.isKv: c.leafPairs[^1][0] else: c.leafKeys[^1]
    if cmpSeq(firstKey, target) <= 0 and cmpSeq(lastKey, target) >= 0:
      var lo = 0
      var hi = keyCount
      while lo < hi:
        let mid = (lo + hi) shr 1
        let midKey = if c.isKv: c.leafPairs[mid][0] else: c.leafKeys[mid]
        if cmpSeq(midKey, target) < 0: lo = mid + 1
        else: hi = mid
      c.leafIdx = lo - 1
      c.curKey = none(seq[byte])
      c.curPair = none((seq[byte], seq[byte]))
      c.atEnd = false
      c.advance()
      return

  # Slow path: descend from the pinned root to the leaf that should hold
  # target (binary search per index level), then scan forward within the
  # leaf (and across subsequent leaves) until key >= target.
  if c.height == 0: loadLeaf(c, c.rootUuid)
  else: descendToLeafAt(c, c.rootUuid, c.height, target)
  c.atEnd = false
  while not c.atEnd:
    c.advance()
    if c.curKey.isSome and cmpSeq(c.curKey.get, target) >= 0: return
  c.atEnd = true

proc update*(c: PageStoreCursor; rootUuid: array[16, byte]; height: uint8) =
  ## Update cursor in-place to point at a new B-tree root. Clears internal
  ## state so the next seek/ensure will re-descend from the new root.
  c.rootUuid = rootUuid
  c.height = height
  c.indexStack.setLen(0)
  c.leafKeys.setLen(0)
  c.leafPairs.setLen(0)
  c.leafIdx = 0
  c.curKey = none(seq[byte])
  c.curPair = none((seq[byte], seq[byte]))
  c.atEnd = (rootUuid == default(array[16, byte]))
