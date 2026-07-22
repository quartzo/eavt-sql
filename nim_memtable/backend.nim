## backend.nim (memtable backend)
##
## Persistent treap (COW) per CF, with snapshot registry and cursor table.
## Nim-native MemTable type + C-ABI vtable bridge for transactor compat.

import std/[random, algorithm, sets]
import std/locks

# ══════════════════════════════════════════════════════════════════════════════
# Persistent treap node
# ══════════════════════════════════════════════════════════════════════════════

type
  Key* = seq[byte]

  TreapNode* = ref object
    key*: Key
    prio*: uint32
    left*: TreapNode
    right*: TreapNode

  SnapshotEntry = object
    roots: seq[TreapNode]
    inUse: bool

  MemTableHandle* = object
    numCf*: cuint
    live*: seq[TreapNode]
    cfSize*: seq[int]
    snaps: seq[SnapshotEntry]
    freeSnapSlots: seq[uint64]
    nextSnap: uint64
    lock: Lock

# ══════════════════════════════════════════════════════════════════════════════
# Treap helpers
# ══════════════════════════════════════════════════════════════════════════════

proc cmpKey*(a, b: Key): int =
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  return 0

proc newLeaf(key: Key): TreapNode =
  TreapNode(key: key, prio: cast[uint32](rand(int.high)))

proc contains(node: TreapNode, key: Key): bool =
  var n = node
  while n != nil:
    let c = cmpKey(key, n.key)
    if c == 0: return true
    elif c < 0: n = n.left
    else: n = n.right
  return false

proc countInRange(node: TreapNode, lo, hi: Key): int =
  if node == nil: return 0
  let cl = cmpKey(node.key, lo)
  let ch = cmpKey(node.key, hi)
  result = 0
  if cl >= 0 and ch < 0: result += 1
  if cl > 0: result += countInRange(node.left, lo, hi)
  if ch < 0: result += countInRange(node.right, lo, hi)

proc countAll(node: TreapNode): int =
  if node == nil: return 0
  return 1 + countAll(node.left) + countAll(node.right)

proc prefixUpperBound(prefix: Key): Key =
  result = prefix & @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

proc rotateRight(n: TreapNode): TreapNode =
  let l = n.left
  result = l
  var nn = TreapNode(key: n.key, prio: n.prio, left: l.right, right: n.right)
  result = TreapNode(key: l.key, prio: l.prio, left: l.left, right: nn)

proc rotateLeft(n: TreapNode): TreapNode =
  let r = n.right
  result = r
  var nn = TreapNode(key: n.key, prio: n.prio, left: n.left, right: r.left)
  result = TreapNode(key: r.key, prio: r.prio, left: nn, right: r.right)

proc insert(node: TreapNode, key: Key): TreapNode =
  if node == nil: return newLeaf(key)
  let c = cmpKey(key, node.key)
  if c < 0:
    let nl = insert(node.left, key)
    var nn = TreapNode(key: node.key, prio: node.prio, left: nl, right: node.right)
    if nn.left != nil and nn.left.prio > nn.prio: return rotateRight(nn)
    return nn
  elif c > 0:
    let nr = insert(node.right, key)
    var nn = TreapNode(key: node.key, prio: node.prio, left: node.left, right: nr)
    if nn.right != nil and nn.right.prio > nn.prio: return rotateLeft(nn)
    return nn
  else:
    return node

# ══════════════════════════════════════════════════════════════════════════════
# In-order walk helpers
# ══════════════════════════════════════════════════════════════════════════════

proc collectForward(node: TreapNode, prefix, upper: Key, acc: var seq[Key]) =
  var stack: seq[TreapNode] = @[]
  var n = node
  while n != nil:
    if cmpKey(n.key, prefix) >= 0:
      stack.add(n); n = n.left
    else:
      n = n.right
  while stack.len > 0:
    let cur = stack.pop()
    if cmpKey(cur.key, upper) < 0: acc.add(cur.key)
    var r = cur.right
    while r != nil:
      stack.add(r); r = r.left

proc collectAddrs(node: TreapNode; seen: var HashSet[int]) =
  if node == nil or seen.contains(cast[int](node)): return
  seen.incl(cast[int](node))
  collectAddrs(node.left, seen)
  collectAddrs(node.right, seen)

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native MemTable
# ══════════════════════════════════════════════════════════════════════════════

type
  MemTable* = ref object
    hnd*: ptr MemTableHandle
    numCf*: int

proc newMemTable*(numCf: int): MemTable =
  if numCf <= 0: raise newException(ValueError, "numCf must be > 0")
  result = MemTable(numCf: numCf)
  result.hnd = cast[ptr MemTableHandle](allocShared0(sizeof(MemTableHandle)))
  result.hnd[] = MemTableHandle(
    numCf: numCf.cuint,
    live: newSeq[TreapNode](numCf),
    cfSize: newSeq[int](numCf),
    snaps: @[], freeSnapSlots: @[], nextSnap: 1,
    lock: Lock(),
  )
  initLock(result.hnd.lock)
  randomize()

proc close*(mt: MemTable) =
  if mt == nil or mt.hnd == nil: return
  var h = mt.hnd
  h.live = @[]; h.cfSize = @[]
  for i in 0 ..< h.snaps.len:
    h.snaps[i].roots = @[]; h.snaps[i].inUse = false
  h.snaps = @[]; h.freeSnapSlots = @[]
  deinitLock(h.lock)
  deallocShared(h)
  mt.hnd = nil

proc size*(mt: MemTable): uint64 =
  var sz = 0
  for s in mt.hnd.cfSize: sz += s
  cast[uint64](sz)

proc put*(mt: MemTable; cf: int; key: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  mt.hnd.lock.withLock:
    let wasNew = not contains(mt.hnd.live[cf], k)
    mt.hnd.live[cf] = insert(mt.hnd.live[cf], k)
    if wasNew: mt.hnd.cfSize[cf] += k.len
  mt.size()

proc batch*(mt: MemTable; ops: openArray[byte]): uint64 =
  mt.hnd.lock.withLock:
    var pos = 0
    while pos + 5 <= ops.len:
      let cf = ops[pos].int
      let klen = int(uint32(ops[pos+1]) shl 24 or uint32(ops[pos+2]) shl 16 or
                     uint32(ops[pos+3]) shl 8 or uint32(ops[pos+4]))
      if pos + 5 + klen > ops.len or cf < 0 or cf >= mt.numCf: break
      let k = ops[pos+5 ..< pos+5+klen]
      let wasNew = not contains(mt.hnd.live[cf], k)
      mt.hnd.live[cf] = insert(mt.hnd.live[cf], k)
      if wasNew: mt.hnd.cfSize[cf] += k.len
      pos += 5 + klen
  mt.size()

proc clear*(mt: MemTable) =
  mt.hnd.lock.withLock:
    for i in 0 ..< mt.hnd.live.len:
      mt.hnd.live[i] = nil
      mt.hnd.cfSize[i] = 0

proc snapshot*(mt: MemTable): uint64 =
  mt.hnd.lock.withLock:
    var entry: SnapshotEntry
    entry.roots = mt.hnd.live
    entry.inUse = true
    if mt.hnd.freeSnapSlots.len > 0:
      result = mt.hnd.freeSnapSlots.pop()
      mt.hnd.snaps[result.int - 1] = entry
    else:
      result = mt.hnd.nextSnap
      mt.hnd.nextSnap += 1
      mt.hnd.snaps.add(entry)

proc snapshotFree*(mt: MemTable; id: uint64) =
  mt.hnd.lock.withLock:
    if id != 0 and id.int <= mt.hnd.snaps.len and mt.hnd.snaps[id.int - 1].inUse:
      mt.hnd.snaps[id.int - 1].roots = @[]
      mt.hnd.snaps[id.int - 1].inUse = false
      mt.hnd.freeSnapSlots.add(id)

proc scanAll*(mt: MemTable; snapId: uint64; cf: int; prefix: openArray[byte]): seq[seq[byte]] =
  if cf < 0 or cf >= mt.hnd.live.len: return @[]
  let root =
    if snapId == 0: mt.hnd.live[cf]
    elif snapId.int <= mt.hnd.snaps.len and mt.hnd.snaps[snapId.int - 1].inUse:
      mt.hnd.snaps[snapId.int - 1].roots[cf]
    else: nil
  if root == nil: return @[]
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  let upper = if pfx.len == 0: @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
              else: prefixUpperBound(pfx)
  var collected: seq[Key] = @[]
  mt.hnd.lock.withLock:
    collectForward(root, pfx, upper, collected)
  for k in collected: result.add(k)

proc contains*(mt: MemTable; snapId: uint64; cf: int; key: openArray[byte]): bool =
  if cf < 0 or cf >= mt.hnd.live.len: return false
  let root =
    if snapId == 0: mt.hnd.live[cf]
    elif snapId.int <= mt.hnd.snaps.len and mt.hnd.snaps[snapId.int - 1].inUse:
      mt.hnd.snaps[snapId.int - 1].roots[cf]
    else: nil
  if root == nil: return false
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  mt.hnd.lock.withLock:
    result = contains(root, k)

proc countPrefix*(mt: MemTable; snapId: uint64; cf: int; prefix: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.hnd.live.len: return 0
  let root =
    if snapId == 0: mt.hnd.live[cf]
    elif snapId.int <= mt.hnd.snaps.len and mt.hnd.snaps[snapId.int - 1].inUse:
      mt.hnd.snaps[snapId.int - 1].roots[cf]
    else: nil
  if root == nil: return 0
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  mt.hnd.lock.withLock:
    result = if pfx.len == 0: cast[uint64](countAll(root))
             else: cast[uint64](countInRange(root, pfx, prefixUpperBound(pfx)))

proc debugCountNodes*(mt: MemTable): uint64 =
  var seen: HashSet[int] = initHashSet[int]()
  for r in mt.hnd.live: collectAddrs(r, seen)
  for entry in mt.hnd.snaps:
    if entry.inUse:
      for r in entry.roots: collectAddrs(r, seen)
  cast[uint64](seen.len)

