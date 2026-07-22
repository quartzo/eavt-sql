## backend.nim (memtable backend)
##
## In-memory write buffer built on a per-CF persistent treap (immutable nodes,
## path-copying updates). Snapshots are O(1): `snapshot` records the current
## per-CF roots in a versioned registry; `clear` swaps the live roots for empty
## ones while old roots stay alive as long as a snapshot references them.
##
## Rust never sees the structure -- it holds only opaque u64 ids (snapshot and
## cursor). Iteration is lazy via a cursor that yields one key per `cursorNext`.

import std/random
import std/algorithm
import std/sets
import abi
import spinlock

# ---------------------------------------------------------------------------
# Persistent treap node (immutable)
# ---------------------------------------------------------------------------

type
  Key = seq[byte]

  TreapNode = ref object
    key: Key
    prio: uint32
    left: TreapNode
    right: TreapNode

  SnapshotEntry = object
    roots: seq[TreapNode]   # one root per CF (nil = empty); empty seq = slot freed
    inUse: bool

  MemTableHandle = object
    numCf: cuint
    live: seq[TreapNode]        # current live root per CF
    cfSize: seq[int]            # total key bytes per CF (unique keys)
    snaps: seq[SnapshotEntry]    # versioned registry (slot index = snapshot id - 1)
    freeSnapSlots: seq[uint64]   # reclaimable snapshot slot ids (1-based)
    nextSnap: uint64             # monotonic; only used to seed when no free slot
    cursors: seq[CursorState]    # index = cursor id - 1
    freeCursorSlots: seq[uint64]
    nextCursor: uint64
    lock: SpinLock

  CursorState = object
    keys: seq[Key]                # materialized keys for this cursor (lazily drained)
    reverse: bool
    inUse: bool

# ---------------------------------------------------------------------------
# Treap helpers (pure, immutable)
# ---------------------------------------------------------------------------

proc cmpKey(a, b: Key): int =
  # lexicographic compare of byte sequences
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  return 0

proc newLeaf(key: Key): TreapNode =
  TreapNode(key: key, prio: cast[uint32](rand(int.high)), left: nil, right: nil)

proc contains(node: TreapNode, key: Key): bool =
  var n = node
  while n != nil:
    let c = cmpKey(key, n.key)
    if c == 0: return true
    elif c < 0: n = n.left
    else: n = n.right
  return false

proc countInRange(node: TreapNode, lo, hi: Key): int =
  # count keys k with lo <= k < hi (hi is exclusive upper bound)
  if node == nil: return 0
  let cl = cmpKey(node.key, lo)
  let ch = cmpKey(node.key, hi)
  result = 0
  if cl >= 0 and ch < 0:
    result += 1
  if cl > 0:
    result += countInRange(node.left, lo, hi)
  if ch < 0:
    result += countInRange(node.right, lo, hi)

# rotate right: returns new subtree root (immutable path copy)
proc rotateRight(n: TreapNode): TreapNode =
  let l = n.left
  result = l
  # n.left = l.right
  var nn = TreapNode(key: n.key, prio: n.prio, left: l.right, right: n.right)
  # l.right = nn
  result = TreapNode(key: l.key, prio: l.prio, left: l.left, right: nn)

proc rotateLeft(n: TreapNode): TreapNode =
  let r = n.right
  result = r
  var nn = TreapNode(key: n.key, prio: n.prio, left: n.left, right: r.left)
  result = TreapNode(key: r.key, prio: r.prio, left: nn, right: r.right)

# insert (immutable): returns new root; replaces existing key in place
proc insert(node: TreapNode, key: Key): TreapNode =
  if node == nil:
    return newLeaf(key)
  let c = cmpKey(key, node.key)
  if c < 0:
    let nl = insert(node.left, key)
    var nn = TreapNode(key: node.key, prio: node.prio, left: nl, right: node.right)
    if nn.left != nil and nn.left.prio > nn.prio:
      return rotateRight(nn)
    return nn
  elif c > 0:
    let nr = insert(node.right, key)
    var nn = TreapNode(key: node.key, prio: node.prio, left: node.left, right: nr)
    if nn.right != nil and nn.right.prio > nn.prio:
      return rotateLeft(nn)
    return nn
  else:
    # equal key: keep node as-is (dedup)
    return node

# ---------------------------------------------------------------------------
# In-order walk into a cursor via continuation-free explicit stack
# ---------------------------------------------------------------------------

proc collectForward(node: TreapNode, prefix: Key, upper: Key, acc: var seq[Key]) =
  # gather keys in [prefix, upper) in ascending order
  var stack: seq[TreapNode] = @[]
  var n = node
  while n != nil:
    if cmpKey(n.key, prefix) >= 0:
      stack.add(n)
      n = n.left
    else:
      n = n.right
  while stack.len > 0:
    let cur = stack.pop()
    if cmpKey(cur.key, upper) < 0:
      acc.add(cur.key)
    var r = cur.right
    while r != nil:
      stack.add(r)
      r = r.left

proc collectReverse(node: TreapNode, prefix: Key, upper: Key, acc: var seq[Key]) =
  # gather keys in [prefix, upper) in DESCENDING order
  var stack: seq[TreapNode] = @[]
  var n = node
  while n != nil:
    if cmpKey(n.key, prefix) >= 0:
      stack.add(n)
      n = n.left
    else:
      n = n.right
  while stack.len > 0:
    let cur = stack.pop()
    if cmpKey(cur.key, upper) < 0:
      acc.add(cur.key)
    var r = cur.right
    while r != nil:
      stack.add(r)
      r = r.left
  acc.reverse()

proc countAll(node: TreapNode): int
proc prefixUpperBound(prefix: Key): Key
proc sumCfSizes(hnd: ptr MemTableHandle): int

# ---------------------------------------------------------------------------
# FFI implementation forward declarations (bodies below)
# ---------------------------------------------------------------------------
proc putImpl(h: pointer, cf: cuint, key: ptr Byte, klen: csize_t,
             outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}
proc batchImpl(h: pointer, ops: ptr Byte, olen: csize_t,
               outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}
proc clearImpl(h: pointer, errOut: ptr cint): cint {.cdecl.}
proc snapshotImpl(h: pointer, outId: ptr uint64, errOut: ptr cint): cint {.cdecl.}
proc snapshotFreeImpl(h: pointer, id: uint64) {.cdecl.}
proc scanImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
              reverse: cint, outCursor: ptr uint64, errOut: ptr cint): cint {.cdecl.}
proc cursorNextImpl(h: pointer, cursor: uint64,
                    outKey: ptr pointer, outLen: ptr csize_t,
                    outValid: ptr cint, errOut: ptr cint): cint {.cdecl.}
proc cursorSeekImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                    errOut: ptr cint): cint {.cdecl.}
proc cursorAdvanceToImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                         errOut: ptr cint): cint {.cdecl.}
proc cursorSkipGroupImpl(h: pointer, cursor: uint64, group: ptr Byte, glen: csize_t,
                         errOut: ptr cint): cint {.cdecl.}
proc cursorUpdateEndImpl(h: pointer, cursor: uint64, endp: ptr Byte, elen: csize_t,
                         errOut: ptr cint): cint {.cdecl.}
proc cursorFreeImpl(h: pointer, cursor: uint64) {.cdecl.}
proc containsImpl(h: pointer, id: uint64, cf: cuint, key: ptr Byte, klen: csize_t,
                  outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.}
proc countPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                     outCount: ptr uint64, errOut: ptr cint): cint {.cdecl.}
proc scanPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                    reverse: cint, outBuf: ptr pointer, outLen: ptr csize_t,
                    errOut: ptr cint): cint {.cdecl.}
proc debugCountNodesImpl(h: pointer, outCount: ptr uint64): cint {.cdecl.}

# ---------------------------------------------------------------------------
# Handle lifecycle
# ---------------------------------------------------------------------------

proc openMemTable*(numCf: cuint, errOut: ptr cint): NimMemTableVtablePtr =
  if numCf == 0:
    setErr(errOut, ErrInvalidArg)
    return nil
  var h = cast[ptr MemTableHandle](allocShared0(sizeof(MemTableHandle)))
  h[] = MemTableHandle(
    numCf: numCf,
    live: newSeq[TreapNode](numCf.int),
    cfSize: newSeq[int](numCf.int),
    snaps: @[],
    freeSnapSlots: @[],
    nextSnap: 1,
    cursors: @[],
    freeCursorSlots: @[],
    nextCursor: 1,
    lock: SpinLock(),
  )
  initSpinLock(h.lock)
  randomize()
  var vt = newVtable()
  vt.handle = h
  vt.put = putImpl
  vt.batch = batchImpl
  vt.clear = clearImpl
  vt.snapshot = snapshotImpl
  vt.snapshotFree = snapshotFreeImpl
  vt.scan = scanImpl
  vt.cursorNext = cursorNextImpl
  vt.cursorSeek = cursorSeekImpl
  vt.cursorAdvanceTo = cursorAdvanceToImpl
  vt.cursorSkipGroup = cursorSkipGroupImpl
  vt.cursorUpdateEnd = cursorUpdateEndImpl
  vt.cursorFree = cursorFreeImpl
  vt.contains = containsImpl
  vt.countPrefix = countPrefixImpl
  vt.scanPrefix = scanPrefixImpl
  vt.debugCountNodes = debugCountNodesImpl
  vt.freeBuf = freeShared
  return vt

proc closeMemTable*(vt: NimMemTableVtablePtr) =
  if vt == nil: return
  if vt.handle != nil:
    var h = cast[ptr MemTableHandle](vt.handle)
    # Manually clear all owned seq/ref fields so ARC releases the TreapNode
    # graph before the raw `deallocShared` frees the handle struct. ARC does
    # NOT run finalizers on a raw free, so without this the whole treap and
    # every retained snapshot/cursor would leak on close.
    h.live = @[]
    h.cfSize = @[]
    for i in 0 ..< h.snaps.len:
      h.snaps[i].roots = @[]
      h.snaps[i].inUse = false
    h.snaps = @[]
    h.freeSnapSlots = @[]
    for i in 0 ..< h.cursors.len:
      h.cursors[i].keys = @[]
      h.cursors[i].inUse = false
    h.cursors = @[]
    h.freeCursorSlots = @[]
    deinitSpinLock(h.lock)
    deallocShared(h)
  freeVtable(vt)

# ---------------------------------------------------------------------------
# FFI implementations
# ---------------------------------------------------------------------------

proc putImpl(h: pointer, cf: cuint, key: ptr Byte, klen: csize_t,
             outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil or cf >= cast[ptr MemTableHandle](h).numCf:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  var k = newSeq[byte](klen)
  if klen > 0:
    copyMem(addr k[0], key, klen)
  hnd.lock.withLock:
    let wasNew = not contains(hnd.live[cf.int], k)
    hnd.live[cf.int] = insert(hnd.live[cf.int], k)
    if wasNew:
      hnd.cfSize[cf.int] += k.len
    outSize[] = cast[uint64](sumCfSizes(hnd))
  return 0

proc batchImpl(h: pointer, ops: ptr Byte, olen: csize_t,
               outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  var data = newSeq[byte](olen)
  if olen > 0:
    copyMem(addr data[0], ops, olen)
  hnd.lock.withLock:
    var pos = 0
    while pos + 5 <= data.len:
      let cf = data[pos]
      let klen = cast[int](uint32(data[pos+1]) shl 24 or uint32(data[pos+2]) shl 16 or
                           uint32(data[pos+3]) shl 8 or uint32(data[pos+4]))
      if pos + 5 + klen > data.len:
        break
      let k = data[pos+5 ..< pos+5+klen]
      let wasNew = not contains(hnd.live[cf.int], k)
      hnd.live[cf.int] = insert(hnd.live[cf.int], k)
      if wasNew:
        hnd.cfSize[cf.int] += k.len
      pos += 5 + klen
    outSize[] = cast[uint64](sumCfSizes(hnd))
  return 0

proc sumCfSizes(hnd: ptr MemTableHandle): int =
  for s in hnd.cfSize:
    result += s

proc clearImpl(h: pointer, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    for i in 0 ..< hnd.live.len:
      hnd.live[i] = nil
      hnd.cfSize[i] = 0
  return 0

proc getSnap(hnd: ptr MemTableHandle, id: uint64): ptr SnapshotEntry =
  if id == 0 or id.int > hnd.snaps.len:
    return nil
  if not hnd.snaps[id.int - 1].inUse:
    return nil
  return addr hnd.snaps[id.int - 1]

proc getCursor(hnd: ptr MemTableHandle, cursor: uint64): ptr CursorState =
  if cursor == 0 or cursor.int > hnd.cursors.len:
    return nil
  if not hnd.cursors[cursor.int - 1].inUse:
    return nil
  return addr hnd.cursors[cursor.int - 1]

proc snapshotImpl(h: pointer, outId: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    var entry: SnapshotEntry
    entry.roots = hnd.live  # seq assignment is a shallow copy of the refs
    entry.inUse = true
    let id = if hnd.freeSnapSlots.len > 0:
      hnd.freeSnapSlots.pop()
    else:
      let id = hnd.nextSnap
      hnd.nextSnap += 1
      hnd.snaps.add(entry)
      id
    if id.int <= hnd.snaps.len:
      hnd.snaps[id.int - 1] = entry
    outId[] = id
  return 0

proc snapshotFreeImpl(h: pointer, id: uint64) {.cdecl.} =
  if h == nil: return
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    if id != 0 and id.int <= hnd.snaps.len and hnd.snaps[id.int - 1].inUse:
      # Release the captured roots: ARC decrements the TreapNode refs and
      # collects any node no longer reachable from a live root or another
      # outstanding snapshot. Return the slot to the free-list so the
      # registry does not grow monotonically across the process lifetime.
      hnd.snaps[id.int - 1].roots = @[]
      hnd.snaps[id.int - 1].inUse = false
      hnd.freeSnapSlots.add(id)

proc scanImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
              reverse: cint, outCursor: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  let snap = getSnap(hnd, id)
  if snap == nil or cf >= snap.roots.len.cuint:
    setErr(errOut, ErrNotFound)
    return -1
  var pfx = newSeq[byte](plen)
  if plen > 0:
    copyMem(addr pfx[0], prefix, plen)
  let upper = if pfx.len == 0: @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] else: prefixUpperBound(pfx)
  var collected: seq[Key] = @[]
  hnd.lock.withLock:
    let root = snap.roots[cf.int]
    if reverse != 0:
      collectReverse(root, pfx, upper, collected)
    else:
      collectForward(root, pfx, upper, collected)
  # store collected keys in a per-handle cursor state; iteration pops from the front
  hnd.lock.withLock:
    var st: CursorState
    st.keys = collected
    st.reverse = reverse != 0
    st.inUse = true
    let cid = if hnd.freeCursorSlots.len > 0:
      hnd.freeCursorSlots.pop()
    else:
      let id = hnd.nextCursor
      hnd.nextCursor += 1
      hnd.cursors.add(st)
      id
    if cid.int <= hnd.cursors.len:
      hnd.cursors[cid.int - 1] = st
    outCursor[] = cid
  return 0

proc cursorNextImpl(h: pointer, cursor: uint64,
                    outKey: ptr pointer, outLen: ptr csize_t,
                    outValid: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    let cs = getCursor(hnd, cursor)
    if cs == nil or cs.keys.len == 0:
      outValid[] = 0
      outKey[] = nil
      outLen[] = 0
      return 0
    let k = cs.keys[0]
    cs.keys.delete(0)
    let buf = allocByteBuf(k.len)
    if k.len > 0:
      copyMem(buf, addr k[0], k.len)
    outKey[] = buf
    outLen[] = cast[csize_t](k.len)
    outValid[] = 1
  return 0

proc findLower(collected: seq[Key], target: Key): int =
  # first index with key >= target
  for i in 0 ..< collected.len:
    if cmpKey(collected[i], target) >= 0:
      return i
  return collected.len

proc cursorSeekImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                    errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  var t = newSeq[byte](tlen)
  if tlen > 0:
    copyMem(addr t[0], target, tlen)
  hnd.lock.withLock:
    let cs = getCursor(hnd, cursor)
    if cs != nil:
      let i = findLower(cs.keys, t)
      cs.keys = cs.keys[i ..< cs.keys.len]
  return 0

proc cursorAdvanceToImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                         errOut: ptr cint): cint {.cdecl.} =
  # identical to seek (inclusive lower bound)
  return cursorSeekImpl(h, cursor, target, tlen, errOut)

proc cursorSkipGroupImpl(h: pointer, cursor: uint64, group: ptr Byte, glen: csize_t,
                         errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  var g = newSeq[byte](glen)
  if glen > 0:
    copyMem(addr g[0], group, glen)
  hnd.lock.withLock:
    let cs = getCursor(hnd, cursor)
    if cs != nil:
      var i = 0
      while i < cs.keys.len:
        let k = cs.keys[i]
        if k.len >= g.len and k[0 ..< g.len] == g:
          i += 1
        else:
          break
      cs.keys = cs.keys[i ..< cs.keys.len]
  return 0

proc cursorUpdateEndImpl(h: pointer, cursor: uint64, endp: ptr Byte, elen: csize_t,
                         errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  var e = newSeq[byte](elen)
  if elen > 0:
    copyMem(addr e[0], endp, elen)
  hnd.lock.withLock:
    let cs = getCursor(hnd, cursor)
    if cs != nil:
      # keep only keys < e (e is exclusive upper bound)
      var i = 0
      while i < cs.keys.len:
        if cmpKey(cs.keys[i], e) < 0:
          i += 1
        else:
          break
      cs.keys = cs.keys[0 ..< i]
  return 0

proc cursorFreeImpl(h: pointer, cursor: uint64) {.cdecl.} =
  if h == nil: return
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    if cursor != 0 and cursor.int <= hnd.cursors.len and hnd.cursors[cursor.int - 1].inUse:
      hnd.cursors[cursor.int - 1].keys = @[]
      hnd.cursors[cursor.int - 1].inUse = false
      hnd.freeCursorSlots.add(cursor)

proc containsImpl(h: pointer, id: uint64, cf: cuint, key: ptr Byte, klen: csize_t,
                  outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  let snap = getSnap(hnd, id)
  if snap == nil or cf >= snap.roots.len.cuint:
    setErr(errOut, ErrNotFound)
    return -1
  var k = newSeq[byte](klen)
  if klen > 0:
    copyMem(addr k[0], key, klen)
  hnd.lock.withLock:
    outPresent[] = if contains(snap.roots[cf.int], k): 1 else: 0
  return 0

proc countPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                     outCount: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  let snap = getSnap(hnd, id)
  if snap == nil or cf >= snap.roots.len.cuint:
    setErr(errOut, ErrNotFound)
    return -1
  var pfx = newSeq[byte](plen)
  if plen > 0:
    copyMem(addr pfx[0], prefix, plen)
  hnd.lock.withLock:
    if pfx.len == 0:
      # count all: walk the tree
      outCount[] = cast[uint64](countAll(snap.roots[cf.int]))
    else:
      let hi = prefixUpperBound(pfx)
      outCount[] = cast[uint64](countInRange(snap.roots[cf.int], pfx, hi))
  return 0

proc countAll(node: TreapNode): int =
  if node == nil: return 0
  return 1 + countAll(node.left) + countAll(node.right)

proc prefixUpperBound(prefix: Key): Key =
  result = prefix & @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

proc collectAddrs(node: TreapNode; seen: var HashSet[int]) =
  if node == nil or seen.contains(cast[int](node)): return
  seen.incl(cast[int](node))
  collectAddrs(node.left, seen)
  collectAddrs(node.right, seen)

## Debug-only helper: total number of UNIQUE treap nodes reachable from any live
## root or any in-use snapshot root. Used by the Rust-side GC tests to assert
## that releasing snapshots actually lets ARC collect old COW nodes.
proc debugCountUniqueNodes*(hnd: ptr MemTableHandle): uint64 =
  var seen: HashSet[int] = initHashSet[int]()
  for r in hnd.live:
    collectAddrs(r, seen)
  for entry in hnd.snaps:
    if entry.inUse:
      for r in entry.roots:
        collectAddrs(r, seen)
  result = cast[uint64](seen.len)

proc scanPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                    reverse: cint, outBuf: ptr pointer, outLen: ptr csize_t,
                    errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  let snap = getSnap(hnd, id)
  if snap == nil or cf >= snap.roots.len.cuint:
    setErr(errOut, ErrNotFound)
    return -1
  var pfx = newSeq[byte](plen)
  if plen > 0:
    copyMem(addr pfx[0], prefix, plen)
  let upper = if pfx.len == 0: @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] else: prefixUpperBound(pfx)
  var collected: seq[Key] = @[]
  hnd.lock.withLock:
    let root = snap.roots[cf.int]
    if reverse != 0:
      collectReverse(root, pfx, upper, collected)
    else:
      collectForward(root, pfx, upper, collected)
  # pack [u32 klen][key]...
  var packed = newSeq[byte](0)
  for k in collected:
    packed.add(cast[byte]((k.len shr 24) and 0xFF))
    packed.add(cast[byte]((k.len shr 16) and 0xFF))
    packed.add(cast[byte]((k.len shr 8) and 0xFF))
    packed.add(cast[byte](k.len and 0xFF))
    for b in k: packed.add(b)
  if packed.len == 0:
    outBuf[] = nil
    outLen[] = 0
  else:
    let buf = allocByteBuf(packed.len)
    copyMem(buf, addr packed[0], packed.len)
    outBuf[] = buf
    outLen[] = cast[csize_t](packed.len)
  return 0

proc debugCountNodesImpl(h: pointer, outCount: ptr uint64): cint {.cdecl.} =
  if h == nil:
    outCount[] = cast[uint64](-1)
    return -1
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    outCount[] = debugCountUniqueNodes(hnd)
  return 0
