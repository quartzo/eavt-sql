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

import std/[options]
import page_store

type
  IndexPos = object
    entries*: seq[(seq[byte], array[16, byte])]
    pos*: int

  PageStoreCursor* = ref object
    s*: ptr PageStoreInner
    cf*: int
    atEnd*: bool
    indexStack: seq[IndexPos]
    leafKeys*: seq[seq[byte]]
    leafIdx*: int
    curKey*: Option[seq[byte]]
    ## Snapshot of the tree root pinned at construction. COW guarantees
    ## the referenced subtree is immutable; a flush may replace
    ## trees[cf].rootUuid but cannot mutate this root.
    rootUuid*: array[16, byte]
    height*: uint8

# ── Helpers ──

proc loadIndexPage(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], array[16, byte])] =
  let data = blobGet(s.blobs, uuid)
  if data.isNone:
    raise newException(IOError, "index blob not found")
  deserializeIndexPage(data.get)

proc loadLeaf(c: PageStoreCursor; uuid: array[16, byte]) =
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
  while true:
    inc c.leafIdx
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
    c.advance()

# ── Public API ──

proc newPageStoreCursor*(s: ptr PageStoreInner; cf: int): PageStoreCursor =
  result = PageStoreCursor(s: s, cf: cf, atEnd: false)
  if cf < 0 or cf >= s[].numCf: result.atEnd = true; return
  let tree = s[].trees[cf]
  if tree.rootUuid == default(array[16, byte]): result.atEnd = true; return
  result.rootUuid = tree.rootUuid
  result.height = tree.height
  if tree.height == 0: loadLeaf(result, tree.rootUuid)
  else: descendToFirstLeaf(result, tree.rootUuid, tree.height)

proc peek*(c: PageStoreCursor): Option[seq[byte]] =
  c.ensure()
  if c.atEnd: none(seq[byte]) else: c.curKey

proc next*(c: PageStoreCursor): Option[seq[byte]] =
  c.ensure()
  result = c.curKey
  c.advance()

proc seek*(c: PageStoreCursor; target: seq[byte]) =
  if c.rootUuid == default(array[16, byte]): c.atEnd = true; return

  # Fast-path: if the current leaf already contains target (its first key
  # <= target <= its last key), binary-search within leafKeys — no descent,
  # no page loads. This is the hot case in leapfrog triejoin, where
  # seekPastValueAt/seekToValue issue many seeks that stay within the same
  # leaf. Safe because the cursor is pinned to an immutable COW root, so
  # the cached leafKeys cannot be invalidated by a concurrent flush.
  if c.leafKeys.len > 0 and
     cmpSeq(c.leafKeys[0], target) <= 0 and
     cmpSeq(c.leafKeys[^1], target) >= 0:
    var lo = 0
    var hi = c.leafKeys.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if cmpSeq(c.leafKeys[mid], target) < 0: lo = mid + 1
      else: hi = mid
    c.leafIdx = lo - 1
    c.curKey = none(seq[byte])
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
