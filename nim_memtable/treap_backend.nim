## backend.nim (memtable backend)
##
## Persistent treap (COW) per CF. No snapshot registry — cursors hold
## TreapNode refs directly (ARC manages lifetime). No lock — KVStore
## serializes all writes.

import std/[random, algorithm, sets, options]

# ══════════════════════════════════════════════════════════════════════════════
# Persistent treap node
# ══════════════════════════════════════════════════════════════════════════════

type
  Key* = seq[byte]
  Value* = seq[byte]

  CfKey* = object
    ## Write command: column family + key bytes.
    cf*: uint8
    key*: seq[byte]

  TreapNode* {.acyclic.} = ref object
    key*: Key
    value*: Option[Value]   ## none for key-only CFs (0-3), some for key-value CFs (>=10)
    deleted*: bool          ## tombstone marker (all CFs)
    prio*: uint32
    left*: TreapNode
    right*: TreapNode
    readerCount*: int       ## cursors holding a ref to this root; 0 = safe to mutate in-place

  MemTableHandle* = object
    live*: seq[TreapNode]
    cfSize: seq[int]           ## key bytes per CF

# ══════════════════════════════════════════════════════════════════════════════
# Treap helpers
# ══════════════════════════════════════════════════════════════════════════════

proc cmpKey*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  return 0

proc newLeaf(key: Key; value: Option[Value] = none(Value); deleted: bool = false): TreapNode =
  TreapNode(key: key, value: value, deleted: deleted, prio: cast[uint32](rand(int.high)))

proc containsKey*(node: TreapNode; key: openArray[byte]): bool =
  var n = node
  while n != nil:
    let c = cmpKey(key, n.key)
    if c == 0: return not n.deleted
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
  var nn = TreapNode(key: n.key, value: n.value, deleted: n.deleted, prio: n.prio, left: l.right, right: n.right)
  result = TreapNode(key: l.key, value: l.value, deleted: l.deleted, prio: l.prio, left: l.left, right: nn)

proc rotateLeft(n: TreapNode): TreapNode =
  let r = n.right
  result = r
  var nn = TreapNode(key: n.key, value: n.value, deleted: n.deleted, prio: n.prio, left: n.left, right: r.left)
  result = TreapNode(key: r.key, value: r.value, deleted: r.deleted, prio: r.prio, left: nn, right: r.right)

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

proc insert(node: TreapNode, key: openArray[byte]; value: Option[Value] = none(Value);
             deleted: bool = false; mutable: bool = false): (TreapNode, bool) =
  if node == nil:
    # Copy key into owned seq[byte] for storage in the node
    var k = newSeq[byte](key.len)
    if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
    return (newLeaf(k, value, deleted), true)
  let c = cmpKey(key, node.key)
  if c < 0:
    let (nl, wasNew) = insert(node.left, key, value, deleted, mutable)
    if mutable:
      node.left = nl
      if node.left != nil and node.left.prio > node.prio:
        return (rotateRightMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = TreapNode(key: node.key, value: node.value, deleted: node.deleted,
                         prio: node.prio, left: nl, right: node.right)
      if nn.left != nil and nn.left.prio > nn.prio: return (rotateRight(nn), wasNew)
      return (nn, wasNew)
  elif c > 0:
    let (nr, wasNew) = insert(node.right, key, value, deleted, mutable)
    if mutable:
      node.right = nr
      if node.right != nil and node.right.prio > node.prio:
        return (rotateLeftMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = TreapNode(key: node.key, value: node.value, deleted: node.deleted,
                         prio: node.prio, left: node.left, right: nr)
      if nn.right != nil and nn.right.prio > nn.prio: return (rotateLeft(nn), wasNew)
      return (nn, wasNew)
  else:
    # Key exists: update value and/or deleted flag.
    # When deleted, clear the value so tombstone detection works.
    if mutable:
      if deleted:
        node.value = none(Value)
        node.deleted = true
      elif value.isSome:
        node.value = value
        node.deleted = false
      return (node, false)
    else:
      let newVal = if deleted: none(Value)
                   elif value.isSome: value
                   else: node.value
      return (TreapNode(key: node.key, value: newVal, deleted: deleted,
                        prio: node.prio, left: node.left, right: node.right), false)

# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════════════════════
# Nim-native MemTable
# ══════════════════════════════════════════════════════════════════════════════

type
  MemTable* = ref object
    hnd*: MemTableHandle
    numCf*: int

proc newMemTable*(numCf: int): MemTable =
  if numCf <= 0: raise newException(ValueError, "numCf must be > 0")
  result = MemTable(numCf: numCf)
  result.hnd = MemTableHandle(
    live: newSeq[TreapNode](numCf),
    cfSize: newSeq[int](numCf),
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
  let (newRoot, wasNew) = insert(root, key, mutable = mutable)
  mt.hnd.live[cf] = newRoot
  if wasNew: mt.hnd.cfSize[cf] += key.len
  mt.size()

proc putKv*(mt: MemTable; cf: int; key, value: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  var v = newSeq[byte](value.len)
  if value.len > 0: copyMem(addr v[0], unsafeAddr value[0], value.len)
  let root = mt.hnd.live[cf]
  let mutable = root == nil or root.readerCount == 0
  let (newRoot, wasNew) = insert(root, key, some(v), mutable = mutable)
  mt.hnd.live[cf] = newRoot
  if wasNew: mt.hnd.cfSize[cf] += key.len + v.len
  mt.size()

proc deleteKv*(mt: MemTable; cf: int; key: openArray[byte]) =
  ## Mark a key as deleted (tombstone). If the key doesn't exist, create a
  ## tombstone node so the deletion is persisted through flush.
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  let root = mt.hnd.live[cf]
  let mutable = root == nil or root.readerCount == 0
  mt.hnd.live[cf] = insert(root, key, none(Value), deleted=true, mutable = mutable)[0]

proc getValue*(mt: MemTable; cf: int; key: openArray[byte]): Option[Value] =
  if cf < 0 or cf >= mt.hnd.live.len: return none(Value)
  var n = mt.hnd.live[cf]
  while n != nil:
    let c = cmpKey(key, n.key)
    if c == 0: return if n.deleted: none(Value) else: n.value
    elif c < 0: n = n.left
    else: n = n.right
  return none(Value)

proc getValue*(node: TreapNode; key: openArray[byte]): Option[Value] =
  ## Search a specific TreapNode root for a key, returning its value.
  var n = node
  while n != nil:
    let c = cmpKey(key, n.key)
    if c == 0: return if n.deleted: none(Value) else: n.value
    elif c < 0: n = n.left
    else: n = n.right
  return none(Value)

# Contadores de diagnóstico do insert (custo ~0; print periódico em batchMove).
var gInsNew* = 0'i64
var gInsExisting* = 0'i64
var gInsKeyBytes* = 0'i64

proc insertOwned(node: TreapNode, key: var seq[byte];
                 value: Option[Value] = none(Value);
                 deleted: bool = false; mutable: bool = false): (TreapNode, bool) =
  ## Variante zero-copy: a chave é CONSUMIDA na criação da folha (move),
  ## eliminando a cópia por inserção do caminho de carga.
  if node == nil:
    inc gInsNew; gInsKeyBytes += key.len
    return (newLeaf(system.move(key), value, deleted), true)
  let c = cmpKey(key, node.key)
  if c < 0:
    let (nl, wasNew) = insertOwned(node.left, key, value, deleted, mutable)
    if mutable:
      node.left = nl
      if node.left != nil and node.left.prio > node.prio:
        return (rotateRightMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = TreapNode(key: node.key, value: node.value, deleted: node.deleted,
                         prio: node.prio, left: nl, right: node.right)
      if nn.left != nil and nn.left.prio > node.prio:
        return (rotateRight(nn), wasNew)
      return (nn, wasNew)
  elif c > 0:
    let (nr, wasNew) = insertOwned(node.right, key, value, deleted, mutable)
    if mutable:
      node.right = nr
      if node.right != nil and node.right.prio > node.prio:
        return (rotateLeftMut(node), wasNew)
      return (node, wasNew)
    else:
      var nn = TreapNode(key: node.key, value: node.value, deleted: node.deleted,
                         prio: node.prio, left: node.left, right: nr)
      if nn.right != nil and nn.right.prio > node.prio:
        return (rotateLeft(nn), wasNew)
      return (nn, wasNew)
  else:
    inc gInsExisting
    # chave existente: atualiza valor em-place quando mutável
    if mutable and not node.deleted:
      node.value = value
      node.deleted = deleted
    return (node, false)

proc printInsertDiag() =
    stderr.writeLine("insdiag: new=", gInsNew, " existing=", gInsExisting,
                     " keyBytes=", gInsKeyBytes,
                     " bytes/new=", (if gInsNew > 0: gInsKeyBytes div gInsNew else: 0))

proc batchMove*(mt: MemTable; entries: var seq[CfKey]): uint64 =
  if entries.len > 0 and gInsNew mod 100_000 < entries.len:
    printInsertDiag()
  ## Consome as chaves de `entries` (move até o nó) — chamador não reutiliza.
  for i in 0 ..< entries.len:
    let cf = entries[i].cf.int
    if cf < 0 or cf >= mt.numCf: continue
    let root = mt.hnd.live[cf]
    let mutable = root == nil or root.readerCount == 0
    var k = system.move(entries[i].key)
    let (newRoot, wasNew) = insertOwned(root, k, none(Value), false, mutable)
    mt.hnd.live[cf] = newRoot
    if wasNew: mt.hnd.cfSize[cf] += k.len
  mt.size()

proc batch*(mt: MemTable; entries: seq[CfKey]): uint64 =
  for e in entries:
    let cf = e.cf.int
    if cf < 0 or cf >= mt.numCf: continue
    let root = mt.hnd.live[cf]
    let mutable = root == nil or root.readerCount == 0
    let (newRoot, wasNew) = insert(root, e.key, mutable = mutable)
    mt.hnd.live[cf] = newRoot
    if wasNew: mt.hnd.cfSize[cf] += e.key.len
  mt.size()

proc clear*(mt: MemTable) =
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
  # Build upper bound from prefix for range count
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  result = cast[uint64](countInRange(root, pfx, prefixUpperBound(pfx)))

