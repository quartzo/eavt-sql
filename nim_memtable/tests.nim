## nim_memtable/tests.nim
##
## Unit tests for the persistent treap MemTable (COW snapshots via ARC).

import std/[unittest, options]
import backend
import treap_cursor

# ══════════════════════════════════════════════════════════════════════════════
# basic put + size
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: put + size":
  test "single put increases size":
    let mt = newMemTable(2)
    let sz = mt.put(0, @[byte(1), 2, 3])
    check sz > 0

  test "duplicate key does not increase size":
    let mt = newMemTable(1)
    let sz1 = mt.put(0, @[byte(1), 2, 3])
    let sz2 = mt.put(0, @[byte(1), 2, 3])
    check sz1 == sz2

  test "different keys accumulate size":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2), 3])
    discard mt.put(0, @[byte(4)])
    check mt.size() == 4  # 1 + 2 + 1 = 4 bytes

  test "separate CFs are independent":
    let mt = newMemTable(3)
    discard mt.put(0, @[byte(10)])
    discard mt.put(1, @[byte(20), 30])
    discard mt.put(2, @[byte(40)])
    check mt.size() > 0

  test "empty key has zero-byte size":
    let mt = newMemTable(1)
    let sz0 = mt.size()
    discard mt.put(0, @[])
    check mt.size() == sz0  # empty key adds 0 bytes

# ══════════════════════════════════════════════════════════════════════════════
# batch
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: batch":
  test "batch of 3 keys increases size":
    let mt = newMemTable(1)
    var ops = newSeq[byte](0)
    ops.add(byte(0)); ops.add(0); ops.add(0); ops.add(0); ops.add(1)
    ops.add(byte(1))
    ops.add(byte(0)); ops.add(0); ops.add(0); ops.add(0); ops.add(1)
    ops.add(byte(2))
    ops.add(byte(0)); ops.add(0); ops.add(0); ops.add(0); ops.add(1)
    ops.add(byte(3))
    let sz = mt.batch(ops)
    check sz > 0

  test "batch with duplicate key is idempotent":
    let mt = newMemTable(1)
    var ops = newSeq[byte](0)
    ops.add(byte(0)); ops.add(0); ops.add(0); ops.add(0); ops.add(1)
    ops.add(byte(7))
    let sz1 = mt.batch(ops)
    let sz2 = mt.batch(ops)
    check sz1 == sz2

# ══════════════════════════════════════════════════════════════════════════════
# cursor scan
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: cursor scan":
  test "cursor iterates inserted keys in order":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(3)])
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    let c = newTreapCursor(mt.hnd.live[0])
    check c.next().get == @[byte(1)]
    check c.next().get == @[byte(2)]
    check c.next().get == @[byte(3)]
    check c.next().isNone

  test "cursor sees data after put, not before put":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(5)])
    discard mt.put(0, @[byte(3)])
    let rootAfterInsert = mt.hnd.live[0]  # capture ref
    discard mt.put(0, @[byte(7)])         # new root
    let c = newTreapCursor(rootAfterInsert)
    check c.next().get == @[byte(3)]
    check c.next().get == @[byte(5)]
    check c.next().isNone  # 7 is NOT visible (COW isolation)

  test "clear does not affect captured root":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    let root = mt.hnd.live[0]  # capture
    mt.clear()                  # clear live
    let c = newTreapCursor(root)
    check c.next().get == @[byte(1)]
    check c.next().get == @[byte(2)]
    check c.next().isNone
    check mt.hnd.live[0] == nil  # live is cleared

# ══════════════════════════════════════════════════════════════════════════════
# contains / countPrefix
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: contains":
  test "contains finds inserted key":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(7)])
    check mt.contains(0, @[byte(7)])
    check not mt.contains(0, @[byte(8)])

  test "contains after clear returns false":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(7)])
    mt.clear()
    check not mt.contains(0, @[byte(7)])

suite "memtable: countPrefix":
  test "count prefix returns correct count":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 0])
    discard mt.put(0, @[byte(1), 1])
    check mt.countPrefix(0, @[byte(1)]) == 2

# ══════════════════════════════════════════════════════════════════════════════
# TreapCursor tests
# ══════════════════════════════════════════════════════════════════════════════

suite "treap_cursor: forward scan":
  test "empty treap → atEnd":
    let c = newTreapCursor(nil)
    check c.atEnd

  test "single key → peek/next":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 2, 3])
    let c = newTreapCursor(mt.hnd.live[0])
    check not c.atEnd
    check c.peek().get == @[byte(1), 2, 3]
    check c.peek() == c.peek()  # idempotent
    check c.next().get == @[byte(1), 2, 3]
    check c.next().isNone
    check c.atEnd

  test "iterate all keys in order":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 0])
    discard mt.put(0, @[byte(1), 5])
    discard mt.put(0, @[byte(2), 0])
    let c = newTreapCursor(mt.hnd.live[0])
    check c.next().get == @[byte(1), 0]
    check c.next().get == @[byte(1), 5]
    check c.next().get == @[byte(2), 0]
    check c.next().isNone

  test "seek advances to target":
    let mt = newMemTable(1)
    for i in 1..50:
      discard mt.put(0, @[byte(i)])
    let c = newTreapCursor(mt.hnd.live[0])
    c.seek(@[byte(30)])
    let k = c.peek()
    check k.isSome
    check k.get[0] >= 30

  test "seek past last key returns none":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 0])
    discard mt.put(0, @[byte(1), 5])
    let c = newTreapCursor(mt.hnd.live[0])
    c.seek(@[byte(9), 9])
    check c.peek().isNone
    check c.atEnd
