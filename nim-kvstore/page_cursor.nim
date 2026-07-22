## page_cursor.nim — Lazy forward cursor over PageStore B-tree leaf pages.
##
## Iterates all keys in a CF in order. No prefix filtering — the scanner
## handles that via seek() and classifyKey. Loads one leaf at a time.

import std/[options]
import ./backend

type
  IndexPos = object
    entries*: seq[(seq[byte], array[16, byte])]
    pos*: int

  PageStoreCursor* = ref object
    s*: ptr PageStoreInner
    cf*: int
    atEnd*: bool
    indexStack: seq[IndexPos]
    leafKeys: seq[seq[byte]]
    leafIdx: int
    curKey: Option[seq[byte]]

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
  let tree = c.s[].trees[c.cf]
  if tree.rootUuid == default(array[16, byte]): c.atEnd = true; return
  if tree.height == 0: loadLeaf(c, tree.rootUuid)
  else: descendToFirstLeaf(c, tree.rootUuid, tree.height)
  c.atEnd = false
  while not c.atEnd:
    c.advance()
    if c.curKey.isSome and cmpSeq(c.curKey.get, target) >= 0: return
  c.atEnd = true
