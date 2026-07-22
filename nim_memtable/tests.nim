## nim_memtable/tests.nim
##
## Unit tests for the persistent treap MemTable (COW snapshots).
## Tests the Nim API directly — no C-ABI vtable.

import std/[unittest]
import backend  # MemTable, newMemTable, put, batch, clear, snapshot, etc.

# ══════════════════════════════════════════════════════════════════════════════
# basic put + size
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: put + size":
  test "single put increases size":
    let mt = newMemTable(2)
    let sz = mt.put(0, @[byte(1), 2, 3])
    check sz == 3
    mt.close()

  test "duplicate key does not increase size":
    let mt = newMemTable(2)
    discard mt.put(0, @[byte(1), 2, 3])
    let sz = mt.put(0, @[byte(1), 2, 3])
    check sz == 3
    mt.close()

  test "different keys accumulate size":
    let mt = newMemTable(2)
    discard mt.put(0, @[byte(1)])
    let sz = mt.put(0, @[byte(2), 3])
    check sz == 3
    mt.close()

  test "separate CFs are independent":
    let mt = newMemTable(3)
    discard mt.put(0, @[byte(10)])
    discard mt.put(1, @[byte(20), 30])
    discard mt.put(2, @[byte(40)])
    check mt.size() == 4  # 1 + 2 + 1 = 4 bytes
    mt.close()

  test "empty key counts":
    let mt = newMemTable(1)
    discard mt.put(0, @[])
    check mt.size() == 0
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# batch
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: batch":
  test "batch of 3 keys increases size":
    let mt = newMemTable(2)
    # cf(1) + klen(4) + key(1) × 3
    var ops = newSeq[byte](0)
    for i in 1..3:
      ops.add(0'u8)  # cf
      ops.add(0'u8); ops.add(0'u8); ops.add(0'u8); ops.add(1'u8)  # klen=1
      ops.add(byte(i))
    let sz = mt.batch(ops)
    check sz == 3
    mt.close()

  test "batch with duplicate key is idempotent":
    let mt = newMemTable(1)
    var ops: seq[byte] = @[0, 0, 0, 0, 2, 10, 20]  # cf0, klen2, key "10 20"
    discard mt.batch(ops)
    let sz = mt.batch(ops)  # same key — size unchanged
    check sz == 2
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# snapshot + scan
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: snapshot + scan":
  test "scan on snapshot returns inserted keys":
    let mt = newMemTable(2)
    discard mt.put(0, @[byte(3)])
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    let snap = mt.snapshot()
    let keys = mt.scanAll(snap, 0, @[], false)
    check keys.len == 3
    check keys[0] == @[byte(1)]
    check keys[1] == @[byte(2)]
    check keys[2] == @[byte(3)]
    mt.snapshotFree(snap)
    mt.close()

  test "scan with prefix returns only matching keys":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(0), 10])
    discard mt.put(0, @[byte(0), 20])
    discard mt.put(0, @[byte(1), 30])
    let snap = mt.snapshot()
    let keys = mt.scanAll(snap, 0, @[byte(0)], false)
    check keys.len == 2
    check keys[0] == @[byte(0), 10]
    check keys[1] == @[byte(0), 20]
    mt.snapshotFree(snap)
    mt.close()

  test "scan empty prefix returns all keys":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(9)])
    discard mt.put(0, @[byte(1)])
    let snap = mt.snapshot()
    let keys = mt.scanAll(snap, 0, @[], false)
    check keys.len == 2
    mt.snapshotFree(snap)
    mt.close()

  test "scan after clear returns empty":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    let snap = mt.snapshot()
    mt.clear()
    check mt.scanAll(snap, 0, @[], false).len == 1  # snapshot still sees old data
    check mt.scanAll(0, 0, @[], false).len == 0      # live scan (id=0) sees nothing
    mt.snapshotFree(snap)
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# contains
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: contains":
  test "contains finds inserted key":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(5), 6, 7])
    let snap = mt.snapshot()
    check mt.contains(snap, 0, @[byte(5), 6, 7])
    check not mt.contains(snap, 0, @[byte(5)])
    check not mt.contains(snap, 0, newSeq[byte]())
    mt.snapshotFree(snap)
    mt.close()

  test "contains after clear returns false":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    let snap = mt.snapshot()
    mt.clear()
    let snap2 = mt.snapshot()
    check mt.contains(snap, 0, @[byte(1)])     # old snapshot: true
    check not mt.contains(snap2, 0, @[byte(1)]) # new snapshot: false
    mt.snapshotFree(snap)
    mt.snapshotFree(snap2)
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# countPrefix
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: countPrefix":
  test "count prefix returns correct count":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(0), 1])
    discard mt.put(0, @[byte(0), 2])
    discard mt.put(0, @[byte(1), 3])
    let snap = mt.snapshot()
    check mt.countPrefix(snap, 0, @[byte(0)]) == 2
    check mt.countPrefix(snap, 0, @[byte(1)]) == 1
    check mt.countPrefix(snap, 0, @[]) == 3
    mt.snapshotFree(snap)
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# COW snapshot isolation (the core feature)
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: COW isolation":
  test "put after snapshot not visible in snapshot":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    let snap = mt.snapshot()
    discard mt.put(0, @[byte(2)])
    let keys = mt.scanAll(snap, 0, @[], false)
    check keys.len == 1
    check keys[0] == @[byte(1)]
    mt.snapshotFree(snap)
    mt.close()

  test "clear after snapshot does not affect snapshot":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    let snap = mt.snapshot()
    mt.clear()
    check mt.scanAll(snap, 0, @[], false).len == 2
    mt.snapshotFree(snap)
    mt.close()

# ══════════════════════════════════════════════════════════════════════════════
# GC: snapshotFree releases nodes
# ══════════════════════════════════════════════════════════════════════════════

suite "memtable: GC (snapshotFree)":
  test "freeing snapshot after mutation releases old COW nodes":
    let mt = newMemTable(1)
    # Insert keys to create a treap with some nodes
    for i in 1..5:
      discard mt.put(0, @[byte(i)])
    let beforeSnap = mt.debugCountNodes()
    # Take a snapshot, then mutate — this creates new COW nodes
    let snap = mt.snapshot()
    for i in 6..10:
      discard mt.put(0, @[byte(i)])
    let afterMutate = mt.debugCountNodes()
    check afterMutate > beforeSnap  # mutation added new nodes (path-copying)
    # Free the snapshot.  Old path nodes only held by the snapshot are released.
    mt.snapshotFree(snap)
    let afterFree = mt.debugCountNodes()
    check afterFree < afterMutate
    mt.close()

  test "1000 snapshot/drop cycles do not leak":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    let base = mt.debugCountNodes()
    for i in 1..1000:
      let s = mt.snapshot()
      mt.snapshotFree(s)
    check mt.debugCountNodes() == base
    mt.close()
