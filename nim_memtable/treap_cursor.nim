## treap_cursor.nim — Lazy in-order cursor over the persistent treap.
##
## Iterates all keys in order. No prefix filtering — the scanner handles
## that via seek(). Uses stack-based in-order traversal.
##
## When a cursor is created from a root, it increments root.readerCount.
## When the cursor is destroyed (ARC drops refcount to 0), the destructor
## decrements readerCount. This lets the insert path skip COW when
## readerCount == 0 (no active cursors).
##
## Key/value bytes are copied out of the arena into seq[byte] on demand.

import std/options
import treap_backend  # TreapNode, Key, Value, cmpKey

type
  KvPair* = tuple[key: Key, value: Option[Value]]

  ReaderGuard* = object
    ## Value-type wrapper that decrements readerCount on destruction and holds
    ## the arena alive (ARC) while the cursor references a root inside it.
    root*: TreapNode
    arena*: Arena

  TreapCursor* = ref object
    guard: ReaderGuard
    stack: seq[TreapNode]
    current: Option[Key]
    currentKv: Option[KvPair]
    atEnd*: bool

proc `=destroy`(g: ReaderGuard) =
  if g.root != nil:
    g.root.readerCount -= 1

# ── Internal: seek stack to first node >= target ──

proc seekStack(c: TreapCursor; target: Key) =
  c.stack = @[]
  var n = c.guard.root
  while n != nil:
    if cmpKey(n.keyPtr, n.keyLen.int, target) >= 0:
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
    var k = newSeq[byte](cur.keyLen.int)
    if cur.keyLen > 0: copyMem(addr k[0], cur.keyPtr, cur.keyLen.int)
    c.current = some(k)
    let val =
      if cur.deleted: none(Value)
      else:
        var v = newSeq[byte](cur.valueLen.int)
        if cur.valueLen > 0: copyMem(addr v[0], cur.valuePtr, cur.valueLen.int)
        some(v)
    c.currentKv = some((key: k, value: val))
    var r = cur.right
    while r != nil:
      c.stack.add(r); r = r.left
    return
  c.atEnd = true

proc ensure(c: TreapCursor) =
  if c.current.isNone and not c.atEnd:
    c.advance()

# ── Public API ──

proc newTreapCursor*(root: TreapNode; arena: Arena = nil): TreapCursor =
  result = TreapCursor(guard: ReaderGuard(root: root, arena: arena), atEnd: false)
  if root == nil:
    result.atEnd = true; return
  root.readerCount += 1
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

proc update*(c: TreapCursor; newRoot: TreapNode; newArena: Arena = nil) =
  ## Update cursor in-place to point at a new treap root. Transfers
  ## readerCount from old root to new root. Stack is cleared — caller
  ## must seek() before iterating.
  if c.guard.root != nil:
    c.guard.root.readerCount -= 1
  c.guard.root = newRoot
  c.guard.arena = newArena
  if newRoot != nil:
    newRoot.readerCount += 1
  c.stack.setLen(0)
  c.current = none(Key)
  c.currentKv = none(KvPair)
  c.atEnd = (newRoot == nil)

proc release*(c: TreapCursor) =
  ## Drop the reader hold on the current root (readerCount -= 1) and reset
  ## iteration state. Keeps readerCount at 0 between scans so inserts
  ## mutate in-place instead of path-copying. Re-acquired by update().
  if c.guard.root != nil:
    c.guard.root.readerCount -= 1
    c.guard.root = nil
  c.guard.arena = nil
  c.stack.setLen(0)
  c.current = none(Key)
  c.currentKv = none(KvPair)
  c.atEnd = true
