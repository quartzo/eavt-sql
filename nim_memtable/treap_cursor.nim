## treap_cursor.nim — Lazy in-order cursor over the persistent treap.
##
## Uses the same stack-based algorithm as collectForward, but yields one key
## per peek/next instead of materializing all keys into an array.

import std/options
import backend  # TreapNode, Key, cmpKey

type
  TreapCursor* = ref object
    root: TreapNode
    stack: seq[TreapNode]
    prefix, upper: Key       ## prefix filter: keys must be in [prefix, upper)
    current: Option[Key]     ## peeked key (consumed by next())
    atEnd*: bool

# ── prefix upper bound ──

proc makeUpper(prefix: Key): Key =
  if prefix.len == 0:
    result = newSeq[byte](64)
    for i in 0..<64: result[i] = 0xFF
  else:
    result = prefix & @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

# ── Internal: seek stack to first node >= target ──

proc seekStack(c: TreapCursor; target: Key) =
  c.stack = @[]
  var n = c.root
  while n != nil:
    if cmpKey(n.key, target) >= 0:
      c.stack.add(n); n = n.left
    else:
      n = n.right

# ── Internal: advance to next key, populate `current` ──

proc advance(c: TreapCursor): bool =
  ## Pop next key from the stack and push right child's left chain.
  ## Returns true if a valid key was found (within prefix range).
  if c.atEnd: return false
  if c.current.isSome: return true   # already have a key peeking

  while c.stack.len > 0:
    let cur = c.stack.pop()
    if cmpKey(cur.key, c.upper) >= 0:
      # Past end of prefix range — stop
      c.stack = @[]
      c.atEnd = true
      return false
    # Valid key found
    c.current = some(cur.key)
    # Push right child's left chain for subsequent iterations
    var r = cur.right
    while r != nil:
      c.stack.add(r); r = r.left
    return true

  c.atEnd = true
  return false

# ── Public API ──

proc newTreapCursor*(root: TreapNode, prefix: seq[byte]): TreapCursor =
  let pfx = if prefix.len > 0: @prefix else: newSeq[byte](0)
  result = TreapCursor(
    root: root, prefix: pfx, upper: makeUpper(pfx), atEnd: false,
  )
  if root == nil:
    result.atEnd = true; return
  result.seekStack(pfx)
  discard result.advance()

proc peek*(c: TreapCursor): Option[Key] =
  if c.advance(): c.current else: none(Key)

proc next*(c: TreapCursor): Option[Key] =
  result = c.current
  c.current = none(Key)
  discard c.advance()
  return result

proc seek*(c: TreapCursor; target: Key) =
  ## Reposition cursor to first key >= max(target, prefix).
  let t = if cmpKey(target, c.prefix) < 0: c.prefix else: target
  c.atEnd = false
  c.current = none(Key)
  c.seekStack(t)
  discard c.advance()
