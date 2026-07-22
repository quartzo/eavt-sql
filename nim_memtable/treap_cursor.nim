## treap_cursor.nim — Lazy in-order cursor over the persistent treap.
##
## Iterates all keys in order. No prefix filtering — the scanner handles
## that via seek(). Uses stack-based in-order traversal.

import std/options
import backend  # TreapNode, Key, cmpKey

type
  TreapCursor* = ref object
    root: TreapNode
    stack: seq[TreapNode]
    current: Option[Key]
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
  if c.atEnd: return
  c.current = none(Key)
  while c.stack.len > 0:
    let cur = c.stack.pop()
    c.current = some(cur.key)
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

proc seek*(c: TreapCursor; target: Key) =
  c.atEnd = false
  c.seekStack(target)
  c.advance()
