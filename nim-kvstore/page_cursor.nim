## page_cursor.nim — Lazy forward cursor over PageStore B-tree leaf pages.
## Each peek/next yields one key; pages are decompressed on demand via LRU cache.

import std/[options]
import ./backend

type
  IndexPos = object
    entries*: seq[(seq[byte], array[16, byte])]   ## index page children
    pos*: int                                      ## current child index within entries

  PageStoreCursor* = ref object
    s*: ptr PageStoreInner
    cf*: int
    prefix*: seq[byte]
    atEnd*: bool
    indexStack: seq[IndexPos]          ## path from root to current leaf's parent
    leafKeys: seq[seq[byte]]           ## decompressed keys of current leaf
    leafIdx: int                       ## 0-based position within leafKeys (next() increments this)
    curKey: Option[seq[byte]]          ## peeked key (consumed by next())

# ── Helpers ──

proc keyHasPrefix(key, prefix: openArray[byte]): bool =
  key.len >= prefix.len and key[0..<prefix.len] == prefix

proc loadIndexPage(s: var PageStoreInner; uuid: array[16, byte]): seq[(seq[byte], array[16, byte])] =
  let data = blobGet(s.blobs, uuid)
  if data.isNone:
    raise newException(IOError, "index blob not found")
  deserializeIndexPage(data.get)

# ── Forward descent: walk index tree → first leaf covering prefix ──

proc descendToFirstLeaf(c: PageStoreCursor; uuid: array[16, byte]; height: uint8) =
  var curUuid = uuid
  var h = height
  c.indexStack = @[]
  while h > 0:
    let entries = loadIndexPage(c.s[], curUuid)
    # Find first child whose key prefix can cover our prefix
    var idx = 0
    while idx < entries.len:
      let (k, _) = entries[idx]
      if cmpSeq(k, c.prefix) < 0:
        inc idx
      else:
        break
    if idx >= entries.len: idx = entries.len - 1
    c.indexStack.add IndexPos(entries: entries, pos: idx)
    curUuid = entries[idx][1]
    dec h
  # curUuid is now a leaf
  c.leafKeys = loadLeafKeys(c.s[], curUuid)
  c.leafIdx = -1

# ── Advance to next leaf ──

proc advanceToNextLeaf(c: PageStoreCursor) =
  while c.indexStack.len > 0:
    var top = addr c.indexStack[^1]
    inc top.pos
    if top.pos < top.entries.len:
      # Descend from this child to its first leaf
      var curUuid = top.entries[top.pos][1]
      var h = 1'u8
      # Keep descending through index pages until we hit a leaf
      while true:
        let entries = loadIndexPage(c.s[], curUuid)
        var idx = 0
        while idx < entries.len:
          let (k, _) = entries[idx]
          if cmpSeq(k, c.prefix) < 0:
            inc idx
          else:
            break
        if idx < entries.len:
          c.indexStack.add IndexPos(entries: entries, pos: idx)
          curUuid = entries[idx][1]
          inc h
        else:
          # This child is probably a leaf — stop descending
          break
      c.leafKeys = loadLeafKeys(c.s[], curUuid)
      c.leafIdx = -1
      return
    c.indexStack.setLen(c.indexStack.len - 1)
  c.atEnd = true

# ── Public API ──

proc newPageStoreCursor*(s: ptr PageStoreInner; cf: int; prefix: seq[byte]): PageStoreCursor =
  result = PageStoreCursor(
    s: s, cf: cf, prefix: prefix, atEnd: false, curKey: none(seq[byte]),
  )
  if cf < 0 or cf >= s[].numCf:
    result.atEnd = true; return
  let tree = s[].trees[cf]
  if tree.rootUuid == default(array[16, byte]):
    result.atEnd = true; return
  if tree.height == 0:
    result.leafKeys = loadLeafKeys(s[], tree.rootUuid)
    result.leafIdx = -1
  else:
    descendToFirstLeaf(result, tree.rootUuid, tree.height)

proc peek*(c: PageStoreCursor): Option[seq[byte]] =
  if c.atEnd: return none(seq[byte])
  if c.curKey.isSome: return c.curKey
  inc c.leafIdx
  if c.leafIdx < c.leafKeys.len:
    let k = c.leafKeys[c.leafIdx]
    if keyHasPrefix(k, c.prefix):
      c.curKey = some(k)
      return c.curKey
  # Exhausted current leaf, try next sibling
  if c.indexStack.len > 0:
    advanceToNextLeaf(c)
    if not c.atEnd: return c.peek()
  c.atEnd = true
  none(seq[byte])

proc next*(c: PageStoreCursor): Option[seq[byte]] =
  let k = c.peek()
  c.curKey = none(seq[byte])
  k

proc seek*(c: PageStoreCursor; target: seq[byte]) =
  ## Reposition cursor to first key >= target.
  if c.atEnd: return
  if cmpSeq(target, c.prefix) < 0: return
  # Skip forward within current leaf
  while c.leafIdx + 1 < c.leafKeys.len and
        cmpSeq(c.leafKeys[c.leafIdx + 1], target) < 0:
    inc c.leafIdx
  c.curKey = none(seq[byte])
  # Re-navigate from root for precise positioning (rare — leapfrog only)
  let tree = c.s[].trees[c.cf]
  if tree.rootUuid == default(array[16, byte]):
    c.atEnd = true; return
  if tree.height == 0:
    c.leafKeys = loadLeafKeys(c.s[], tree.rootUuid)
    c.leafIdx = -1
  else:
    descendToFirstLeaf(c, tree.rootUuid, tree.height)
  c.atEnd = false
  c.curKey = none(seq[byte])
  # Skip to target
  while not c.atEnd:
    let nk = c.next()
    if nk.isSome and cmpSeq(nk.get, target) >= 0:
      c.curKey = nk
      return
  c.atEnd = true
