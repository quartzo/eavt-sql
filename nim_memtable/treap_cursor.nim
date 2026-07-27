## treap_cursor.nim — Lazy in-order cursor over the persistent treap.
##
## Iterates all keys in order. No prefix filtering — the scanner handles
## that via seek(). Uses stack-based in-order traversal.

import std/options
import treap_backend  # TreapNode, Key, cmpKey

type
  KvPair* = tuple[key: Key, value: Option[Value]]

  TreapCursor* = ref object
    root: TreapNode
    stack: seq[TreapNode]
    current: Option[Key]
    currentKv: Option[KvPair]
    atEnd*: bool

# ── Internal: seek stack to first node >= target ──

proc seekStack(c: TreapCursor; target: Key) =
  c.stack = @[]
  var n = c.root
  while n != nil:
    if cmpKey(n.key, target) >= 0:
      c.stack.add(n); n = n.left
    else:
      n = n.right

# ── Internal: advance to next key ──

proc advance(c: TreapCursor) =
  ## Advance to next node (including tombstones). Callers that need to
  ## skip deleted nodes should use peekKv/nextKv (which filter).
  if c.atEnd: return
  c.current = none(Key)
  c.currentKv = none(KvPair)
  while c.stack.len > 0:
    let cur = c.stack.pop()
    c.current = some(cur.key)
    c.currentKv = some((key: cur.key, value: cur.value))
    var r = cur.right
    while r != nil:
      c.stack.add(r); r = r.left
    return
  c.atEnd = true

proc ensure(c: TreapCursor) =
  if c.current.isNone and not c.atEnd:
    c.advance()

# ── Public API ──

proc newTreapCursor*(root: TreapNode): TreapCursor =
  result = TreapCursor(root: root, atEnd: false)
  if root == nil:
    result.atEnd = true; return
  result.seekStack(newSeq[byte](0))  # start from first key

proc peek*(c: TreapCursor): Option[Key] =
  c.ensure()
  if c.atEnd: none(Key) else: c.current

proc next*(c: TreapCursor): Option[Key] =
  c.ensure()
  result = c.current
  c.advance()

proc peekKv*(c: TreapCursor): Option[(seq[byte], seq[byte])] =
  ## Peek next non-deleted key-value pair. Skips tombstones.
  while true:
    c.ensure()
    if c.atEnd: return none((seq[byte], seq[byte]))
    if c.currentKv.isSome:
      let (key, val) = c.currentKv.get
      if val.isSome:
        return some((key, val.get(@[])))
      # Tombstone — skip
      c.advance()
      continue
    return none((seq[byte], seq[byte]))

proc nextKv*(c: TreapCursor): Option[(seq[byte], seq[byte])] =
  ## Return next non-deleted key-value pair and advance. Skips tombstones.
  while true:
    c.ensure()
    if c.atEnd: return none((seq[byte], seq[byte]))
    if c.currentKv.isSome:
      let (key, val) = c.currentKv.get
      if val.isSome:
        result = some((key, val.get(@[])))
        c.advance()
        return
      # Tombstone — skip
      c.advance()
      continue
    return none((seq[byte], seq[byte]))

proc nextDeleted*(c: TreapCursor): Option[seq[byte]] =
  ## Return next deleted key (tombstone) and advance. Skips non-deleted.
  while true:
    c.ensure()
    if c.atEnd: return none(seq[byte])
    if c.currentKv.isSome:
      let (key, val) = c.currentKv.get
      # A node is a tombstone if value is none (CF >= 10) or explicitly deleted
      if val.isNone:
        result = some(key)
        c.advance()
        return
      # Non-deleted — skip
      c.advance()
      continue
    return none(seq[byte])

proc seek*(c: TreapCursor; target: Key) =
  c.atEnd = false
  c.seekStack(target)
  c.advance()
