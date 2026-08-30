## backend.nim (memtable backend)
##
## Persistent treap (COW) per CF. Nodes and key/value bytes live in a
## per-memtable arena (bulk allocation, freed once per flush generation).
## No snapshot registry — cursors hold TreapNode pointers directly. No lock —
## KVStore serializes all writes.

import std/[random, algorithm, sets, options]

# ══════════════════════════════════════════════════════════════════════════════
# Arena allocation (nodes + key/value bytes)
# ══════════════════════════════════════════════════════════════════════════════

const
  NodeBlockSize* = 1000                ## nodes per node-arena block
  KeyBlockSize* = 16 * 1024            ## bytes per key-arena block

type
  TreapNodeObj* = object
    keyPtr*: ptr UncheckedArray[byte]      ## inline key bytes (key arena)
    valuePtr*: ptr UncheckedArray[byte]    ## inline value bytes (key arena); nil = none
    left*: ptr TreapNodeObj
    right*: ptr TreapNodeObj
    readerCount*: int                      ## cursors holding a ref to this root; 0 = mutate in-place
    keyLen*: uint32
    valueLen*: uint32
    prio*: uint32
    deleted*: bool                         ## tombstone marker (all CFs)

  TreapNode* = ptr TreapNodeObj

  ArenaObj* = object
    nodeBlocks*: seq[ptr UncheckedArray[TreapNodeObj]]
    nodeBump*: int
    keyBlocks*: seq[ptr UncheckedArray[byte]]
    keyBump*: int
    large*: seq[ptr UncheckedArray[byte]]  ## keys larger than KeyBlockSize

  Arena* = ref ArenaObj

  Key* = seq[byte]
  Value* = seq[byte]

  KeyRef* = object
    ## Borrowed key bytes: pointer + length. Points into the arena (hot path,
    ## written by buildEavtEntries) or into a caller-owned buffer (journal
    ## replay, which copies into the arena immediately).
    p*: ptr UncheckedArray[byte]
    len*: int

  CfKey* = object
    ## Write command: column family + key bytes.
    cf*: uint8
    key*: KeyRef

  MemTableHandle* = object
    live*: seq[TreapNode]
    cfSize*: seq[int]             ## key bytes per CF
    arena*: Arena                 ## current generation's arena (all CFs share it)

  MemTable* = ref object
    hnd*: MemTableHandle
    numCf*: int

proc `=destroy`(a: var ArenaObj) =
  ## Free every block owned by the arena when its refcount drops to zero.
  ## Coarse lifetime: no per-node free — the whole generation dies at once.
  for b in a.nodeBlocks: deallocShared(b)
  for b in a.keyBlocks: deallocShared(b)
  for b in a.large: deallocShared(b)
  a.nodeBlocks = @[]; a.keyBlocks = @[]; a.large = @[]

# ── Arena allocator ──

proc allocNode*(a: Arena): TreapNode =
  if a.nodeBlocks.len == 0 or a.nodeBump >= NodeBlockSize:
    let b = cast[ptr UncheckedArray[TreapNodeObj]](
      allocShared0(NodeBlockSize * sizeof(TreapNodeObj)))
    a.nodeBlocks.add(b)
    a.nodeBump = 0
  result = cast[TreapNode](addr a.nodeBlocks[^1][a.nodeBump])
  zeroMem(result, sizeof(TreapNodeObj))
  inc a.nodeBump

proc allocKeyBytes*(a: Arena; len: int): ptr UncheckedArray[byte] =
  ## Reserve `len` bytes in the key arena. Keys larger than a block get their
  ## own allocation (tracked in `large`, freed with the arena).
  if len <= 0: return nil
  if len > KeyBlockSize:
    let p = cast[ptr UncheckedArray[byte]](allocShared0(len))
    a.large.add(p)
    return p
  if a.keyBlocks.len == 0 or a.keyBump + len > KeyBlockSize:
    let b = cast[ptr UncheckedArray[byte]](allocShared0(KeyBlockSize))
    a.keyBlocks.add(b)
    a.keyBump = 0
  result = cast[ptr UncheckedArray[byte]](addr a.keyBlocks[^1][a.keyBump])
  inc a.keyBump, len

proc newArena*(): Arena =
  Arena(nodeBlocks: @[], nodeBump: 0, keyBlocks: @[], keyBump: 0, large: @[])

# ══════════════════════════════════════════════════════════════════════════════
# Treap helpers
# ══════════════════════════════════════════════════════════════════════════════

proc cmpKey*(np: ptr UncheckedArray[byte]; nlen: int; other: openArray[byte]): int =
  ## Compare a node's inline key (ptr, len) with `other`. -1/0/1.
  let n = min(nlen, other.len)
  for i in 0 ..< n:
    if np[i] < other[i]: return -1
    if np[i] > other[i]: return 1
  if nlen < other.len: return -1
  if nlen > other.len: return 1
  0

proc cmpKeyOpen*(key: openArray[byte]; np: ptr UncheckedArray[byte]; nlen: int): int =
  ## Compare `key` (openArray) with a node's inline key (ptr, len). -1/0/1.
  let n = min(key.len, nlen)
  for i in 0 ..< n:
    if key[i] < np[i]: return -1
    if key[i] > np[i]: return 1
  if key.len < nlen: return -1
  if key.len > nlen: return 1
  0

proc cmpKeyRef*(key: KeyRef; np: ptr UncheckedArray[byte]; nlen: int): int =
  ## Compare `key` (KeyRef) with a node's inline key (ptr, len). -1/0/1.
  let n = min(key.len, nlen)
  for i in 0 ..< n:
    if key.p[i] < np[i]: return -1
    if key.p[i] > np[i]: return 1
  if key.len < nlen: return -1
  if key.len > nlen: return 1
  0

proc toKeyRef*(key: openArray[byte]): KeyRef =
  if key.len > 0:
    KeyRef(p: cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), len: key.len)
  else:
    KeyRef(p: nil, len: 0)

proc toSeq*(k: KeyRef): seq[byte] =
  ## Owned copy of a borrowed key (journal replay, hydrated set, etc.).
  if k.len > 0:
    result = newSeqOfCap[byte](k.len)
    result.setLen(k.len)
    copyMem(addr result[0], k.p, k.len)
  else:
    result = @[]

proc newLeaf(a: Arena; key: KeyRef; value: Option[Value] = none(Value);
             deleted: bool = false; copyKey: bool = false): TreapNode =
  result = allocNode(a)
  result.keyLen = key.len.uint32
  if key.len > 0:
    if copyKey:
      result.keyPtr = allocKeyBytes(a, key.len)
      copyMem(result.keyPtr, key.p, key.len)
    else:
      result.keyPtr = key.p
  result.deleted = deleted
  result.prio = cast[uint32](rand(int.high))
  if value.isSome:
    let v = value.get
    result.valueLen = v.len.uint32
    if v.len > 0:
      result.valuePtr = allocKeyBytes(a, v.len)
      copyMem(result.valuePtr, unsafeAddr v[0], v.len)

proc copyNode(a: Arena; n: TreapNode): TreapNode =
  ## Path-copy clone: shares key/value bytes (same arena ptrs), fresh node.
  result = allocNode(a)
  result.keyPtr = n.keyPtr
  result.keyLen = n.keyLen
  result.valuePtr = n.valuePtr
  result.valueLen = n.valueLen
  result.deleted = n.deleted
  result.prio = n.prio
  result.left = n.left
  result.right = n.right

proc setNodeValue(a: Arena; n: TreapNode; v: Value) =
  n.valueLen = v.len.uint32
  if v.len > 0:
    n.valuePtr = allocKeyBytes(a, v.len)
    copyMem(n.valuePtr, unsafeAddr v[0], v.len)
  else:
    n.valuePtr = nil

proc clearNodeValue(n: TreapNode) =
  n.valuePtr = nil
  n.valueLen = 0

proc containsKey*(node: TreapNode; key: openArray[byte]): bool =
  var n = node
  while n != nil:
    let c = cmpKeyOpen(key, n.keyPtr, n.keyLen.int)
    if c == 0: return not n.deleted
    elif c < 0: n = n.left
    else: n = n.right
  return false

proc countInRange(node: TreapNode, lo, hi: Key): int =
  if node == nil: return 0
  let cl = cmpKey(node.keyPtr, node.keyLen.int, lo)
  let ch = cmpKey(node.keyPtr, node.keyLen.int, hi)
  result = 0
  if cl >= 0 and ch < 0: result += 1
  if cl > 0: result += countInRange(node.left, lo, hi)
  if ch < 0: result += countInRange(node.right, lo, hi)

proc countAll(node: TreapNode): int =
  if node == nil: return 0
  return 1 + countAll(node.left) + countAll(node.right)

proc prefixUpperBound(prefix: Key): Key =
  result = prefix & @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

proc rotateRight(a: Arena; n: TreapNode): TreapNode =
  let l = n.left
  var nn = copyNode(a, n)
  nn.left = l.right
  nn.right = n.right
  result = copyNode(a, l)
  result.left = l.left
  result.right = nn

proc rotateLeft(a: Arena; n: TreapNode): TreapNode =
  let r = n.right
  var nn = copyNode(a, n)
  nn.left = n.left
  nn.right = r.left
  result = copyNode(a, r)
  result.left = nn
  result.right = r.right

proc rotateRightMut(n: TreapNode): TreapNode =
  ## In-place right rotation. Returns new root (the left child).
  let l = n.left
  n.left = l.right
  l.right = n
  return l

proc rotateLeftMut(n: TreapNode): TreapNode =
  ## In-place left rotation. Returns new root (the right child).
  let r = n.right
  n.right = r.left
  r.left = n
  return r

proc insert(a: Arena; node: TreapNode; key: KeyRef;
            value: Option[Value] = none(Value);
            deleted: bool = false; mutable: bool = false): (TreapNode, bool) =
  if node == nil:
    return (newLeaf(a, key, value, deleted, copyKey=true), true)
  let c = cmpKeyRef(key, node.keyPtr, node.keyLen.int)
  if c < 0:
    let (nl, wasNew) = insert(a, node.left, key, value, deleted, mutable)
    if mutable:
      node.left = nl
      if node.left != nil and node.left.prio > node.prio:
        return (rotateRightMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = copyNode(a, node)
      nn.left = nl
      if nn.left != nil and nn.left.prio > nn.prio:
        return (rotateRight(a, nn), wasNew)
      return (nn, wasNew)
  elif c > 0:
    let (nr, wasNew) = insert(a, node.right, key, value, deleted, mutable)
    if mutable:
      node.right = nr
      if node.right != nil and node.right.prio > node.prio:
        return (rotateLeftMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = copyNode(a, node)
      nn.right = nr
      if nn.right != nil and nn.right.prio > nn.prio:
        return (rotateLeft(a, nn), wasNew)
      return (nn, wasNew)
  else:
    # Key exists: update value and/or deleted flag.
    # When deleted, clear the value so tombstone detection works.
    if mutable:
      if deleted:
        clearNodeValue(node)
        node.deleted = true
      elif value.isSome:
        setNodeValue(a, node, value.get)
        node.deleted = false
      return (node, false)
    else:
      var nn = copyNode(a, node)
      if deleted:
        clearNodeValue(nn)
      elif value.isSome:
        setNodeValue(a, nn, value.get)
      nn.deleted = deleted
      return (nn, false)

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native MemTable
# ══════════════════════════════════════════════════════════════════════════════

proc newMemTable*(numCf: int): MemTable =
  if numCf <= 0: raise newException(ValueError, "numCf must be > 0")
  result = MemTable(numCf: numCf)
  result.hnd = MemTableHandle(
    live: newSeq[TreapNode](numCf),
    cfSize: newSeq[int](numCf),
    arena: newArena(),
  )
  randomize()

proc size*(mt: MemTable): uint64 =
  var sz = 0
  for s in mt.hnd.cfSize: sz += s
  cast[uint64](sz)

proc put*(mt: MemTable; cf: int; key: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  let root = mt.hnd.live[cf]
  let mutable = root == nil or root.readerCount == 0
  let kref = toKeyRef(key)
  let (newRoot, wasNew) = insert(mt.hnd.arena, root, kref, mutable = mutable)
  mt.hnd.live[cf] = newRoot
  if wasNew: mt.hnd.cfSize[cf] += key.len
  mt.size()

proc putKv*(mt: MemTable; cf: int; key, value: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  var v = newSeq[byte](value.len)
  if value.len > 0: copyMem(addr v[0], unsafeAddr value[0], value.len)
  let root = mt.hnd.live[cf]
  let mutable = root == nil or root.readerCount == 0
  let kref = toKeyRef(key)
  let (newRoot, wasNew) = insert(mt.hnd.arena, root, kref, some(v), mutable = mutable)
  mt.hnd.live[cf] = newRoot
  if wasNew: mt.hnd.cfSize[cf] += key.len + v.len
  mt.size()

proc deleteKv*(mt: MemTable; cf: int; key: openArray[byte]) =
  ## Mark a key as deleted (tombstone). If the key doesn't exist, create a
  ## tombstone node so the deletion is persisted through flush.
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  let root = mt.hnd.live[cf]
  let mutable = root == nil or root.readerCount == 0
  let kref = toKeyRef(key)
  mt.hnd.live[cf] = insert(mt.hnd.arena, root, kref, none(Value), deleted=true, mutable = mutable)[0]

proc getValue*(mt: MemTable; cf: int; key: openArray[byte]): Option[Value] =
  if cf < 0 or cf >= mt.hnd.live.len: return none(Value)
  var n = mt.hnd.live[cf]
  while n != nil:
    let c = cmpKeyOpen(key, n.keyPtr, n.keyLen.int)
    if c == 0:
      if n.deleted: return none(Value)
      var v = newSeq[byte](n.valueLen.int)
      if n.valueLen > 0: copyMem(addr v[0], n.valuePtr, n.valueLen.int)
      return some(v)
    elif c < 0: n = n.left
    else: n = n.right
  return none(Value)

proc getValue*(node: TreapNode; key: openArray[byte]): Option[Value] =
  ## Search a specific TreapNode root for a key, returning its value.
  var n = node
  while n != nil:
    let c = cmpKeyOpen(key, n.keyPtr, n.keyLen.int)
    if c == 0:
      if n.deleted: return none(Value)
      var v = newSeq[byte](n.valueLen.int)
      if n.valueLen > 0: copyMem(addr v[0], n.valuePtr, n.valueLen.int)
      return some(v)
    elif c < 0: n = n.left
    else: n = n.right
  return none(Value)

# Contadores de diagnóstico do insert (custo ~0; print periódico em batchMove).
var gInsNew* = 0'i64
var gInsExisting* = 0'i64
var gInsKeyBytes* = 0'i64

proc insertOwned(a: Arena; node: TreapNode; key: KeyRef;
                 value: Option[Value] = none(Value);
                 deleted: bool = false; mutable: bool = false): (TreapNode, bool) =
  ## Load-path variant: the key is ALREADY in the arena (written by
  ## buildEavtEntries), so the leaf references it — no copy.
  if node == nil:
    inc gInsNew; gInsKeyBytes += key.len
    return (newLeaf(a, key, value, deleted, copyKey=false), true)
  let c = cmpKeyRef(key, node.keyPtr, node.keyLen.int)
  if c < 0:
    let (nl, wasNew) = insertOwned(a, node.left, key, value, deleted, mutable)
    if mutable:
      node.left = nl
      if node.left != nil and node.left.prio > node.prio:
        return (rotateRightMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = copyNode(a, node)
      nn.left = nl
      if nn.left != nil and nn.left.prio > nn.prio:
        return (rotateRight(a, nn), wasNew)
      return (nn, wasNew)
  elif c > 0:
    let (nr, wasNew) = insertOwned(a, node.right, key, value, deleted, mutable)
    if mutable:
      node.right = nr
      if node.right != nil and node.right.prio > node.prio:
        return (rotateLeftMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = copyNode(a, node)
      nn.right = nr
      if nn.right != nil and nn.right.prio > nn.prio:
        return (rotateLeft(a, nn), wasNew)
      return (nn, wasNew)
  else:
    inc gInsExisting
    if mutable and not node.deleted:
      if value.isSome: setNodeValue(a, node, value.get)
      else: clearNodeValue(node)
      node.deleted = deleted
    return (node, false)

proc printInsertDiag() =
    stderr.writeLine("insdiag: new=", gInsNew, " existing=", gInsExisting,
                     " keyBytes=", gInsKeyBytes,
                     " bytes/new=", (if gInsNew > 0: gInsKeyBytes div gInsNew else: 0))

proc batchMove*(mt: MemTable; entries: var seq[CfKey]): uint64 =
  if entries.len > 0 and gInsNew mod 100_000 < entries.len:
    printInsertDiag()
  ## References the key bytes (already in the arena, written by the caller).
  for i in 0 ..< entries.len:
    let cf = entries[i].cf.int
    if cf < 0 or cf >= mt.numCf: continue
    let root = mt.hnd.live[cf]
    let mutable = root == nil or root.readerCount == 0
    let klen = entries[i].key.len
    let (newRoot, wasNew) = insertOwned(mt.hnd.arena, root, entries[i].key, none(Value), false, mutable)
    mt.hnd.live[cf] = newRoot
    if wasNew: mt.hnd.cfSize[cf] += klen
  mt.size()

proc batch*(mt: MemTable; entries: seq[CfKey]): uint64 =
  for e in entries:
    let cf = e.cf.int
    if cf < 0 or cf >= mt.numCf: continue
    let root = mt.hnd.live[cf]
    let mutable = root == nil or root.readerCount == 0
    let (newRoot, wasNew) = insert(mt.hnd.arena, root, e.key, mutable = mutable)
    mt.hnd.live[cf] = newRoot
    if wasNew: mt.hnd.cfSize[cf] += e.key.len
  mt.size()

proc clear*(mt: MemTable) =
  ## Nil the live roots. The arena is NOT freed here — it is freed once by
  ## the flush after the captured roots have been drained (see freeArena).
  for i in 0 ..< mt.hnd.live.len:
    mt.hnd.live[i] = nil
    mt.hnd.cfSize[i] = 0

proc contains*(mt: MemTable; cf: int; key: openArray[byte]): bool =
  if cf < 0 or cf >= mt.hnd.live.len: return false
  let root = mt.hnd.live[cf]
  if root == nil: return false
  result = containsKey(root, key)

proc countPrefix*(mt: MemTable; cf: int; prefix: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.hnd.live.len: return 0
  let root = mt.hnd.live[cf]
  if root == nil: return 0
  if prefix.len == 0:
    return cast[uint64](countAll(root))
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  result = cast[uint64](countInRange(root, pfx, prefixUpperBound(pfx)))
