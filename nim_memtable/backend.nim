## backend.nim (memtable backend)
##
## Persistent treap (COW) per CF, with snapshot registry and cursor table.
## Nim-native MemTable type + C-ABI vtable bridge for transactor compat.

import std/[random, algorithm, sets]
import abi
import spinlock

# ══════════════════════════════════════════════════════════════════════════════
# Persistent treap node
# ══════════════════════════════════════════════════════════════════════════════

type
  Key = seq[byte]

  TreapNode* = ref object
    key*: Key
    prio*: uint32
    left*: TreapNode
    right*: TreapNode

  SnapshotEntry = object
    roots: seq[TreapNode]
    inUse: bool

  CursorState = object
    keys: seq[Key]
    inUse: bool

  MemTableHandle* = object
    numCf*: cuint
    live*: seq[TreapNode]
    cfSize*: seq[int]
    snaps: seq[SnapshotEntry]
    freeSnapSlots: seq[uint64]
    nextSnap: uint64
    cursors: seq[CursorState]
    freeCursorSlots: seq[uint64]
    nextCursor: uint64
    lock: SpinLock

# ══════════════════════════════════════════════════════════════════════════════
# Treap helpers
# ══════════════════════════════════════════════════════════════════════════════

proc cmpKey(a, b: Key): int =
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

proc collectReverse(node: TreapNode, prefix, upper: Key, acc: var seq[Key]) =
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
  acc.reverse()

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
    cursors: @[], freeCursorSlots: @[], nextCursor: 1,
    lock: SpinLock(),
  )
  initSpinLock(result.hnd.lock)
  randomize()

proc close*(mt: MemTable) =
  if mt == nil or mt.hnd == nil: return
  var h = mt.hnd
  h.live = @[]; h.cfSize = @[]
  for i in 0 ..< h.snaps.len:
    h.snaps[i].roots = @[]; h.snaps[i].inUse = false
  h.snaps = @[]; h.freeSnapSlots = @[]
  for i in 0 ..< h.cursors.len:
    h.cursors[i].keys = @[]; h.cursors[i].inUse = false
  h.cursors = @[]; h.freeCursorSlots = @[]
  deinitSpinLock(h.lock)
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

proc scanAll*(mt: MemTable; snapId: uint64; cf: int; prefix: openArray[byte];
              reverse = false): seq[seq[byte]] =
  if snapId == 0 or snapId.int > mt.hnd.snaps.len: return @[]
  let snap = addr mt.hnd.snaps[snapId.int - 1]
  if not snap.inUse or cf < 0 or cf >= snap.roots.len: return @[]
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  let upper = if pfx.len == 0: @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
              else: prefixUpperBound(pfx)
  var collected: seq[Key] = @[]
  mt.hnd.lock.withLock:
    let root = snap.roots[cf]
    if reverse: collectReverse(root, pfx, upper, collected)
    else: collectForward(root, pfx, upper, collected)
  for k in collected: result.add(k)

proc contains*(mt: MemTable; snapId: uint64; cf: int; key: openArray[byte]): bool =
  if snapId == 0 or snapId.int > mt.hnd.snaps.len: return false
  let snap = addr mt.hnd.snaps[snapId.int - 1]
  if not snap.inUse or cf < 0 or cf >= snap.roots.len: return false
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  mt.hnd.lock.withLock:
    result = contains(snap.roots[cf], k)

proc countPrefix*(mt: MemTable; snapId: uint64; cf: int; prefix: openArray[byte]): uint64 =
  if snapId == 0 or snapId.int > mt.hnd.snaps.len: return 0
  let snap = addr mt.hnd.snaps[snapId.int - 1]
  if not snap.inUse or cf < 0 or cf >= snap.roots.len: return 0
  var pfx = newSeq[byte](prefix.len)
  if prefix.len > 0: copyMem(addr pfx[0], unsafeAddr prefix[0], prefix.len)
  mt.hnd.lock.withLock:
    result = if pfx.len == 0: cast[uint64](countAll(snap.roots[cf]))
             else: cast[uint64](countInRange(snap.roots[cf], pfx, prefixUpperBound(pfx)))

proc debugCountNodes*(mt: MemTable): uint64 =
  var seen: HashSet[int] = initHashSet[int]()
  for r in mt.hnd.live: collectAddrs(r, seen)
  for entry in mt.hnd.snaps:
    if entry.inUse:
      for r in entry.roots: collectAddrs(r, seen)
  cast[uint64](seen.len)

# ══════════════════════════════════════════════════════════════════════════════
# C-ABI vtable bridge (for transactor.nim cursor compat)
# ══════════════════════════════════════════════════════════════════════════════

proc putImpl(h: pointer, cf: cuint, key: ptr Byte, klen: csize_t,
             outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  var k = newSeq[byte](klen)
  if klen > 0: copyMem(addr k[0], key, klen)
  try: outSize[] = mt[].put(cf.int, k); return 0
  except: setErr(errOut, ErrIo); return -1

proc batchImpl(h: pointer, ops: ptr Byte, olen: csize_t,
               outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  var data = newSeq[byte](olen)
  if olen > 0: copyMem(addr data[0], ops, olen)
  try: outSize[] = mt[].batch(data); return 0
  except: setErr(errOut, ErrIo); return -1

proc clearImpl(h: pointer, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  try: mt[].clear(); return 0
  except: setErr(errOut, ErrIo); return -1

proc snapshotImpl(h: pointer, outId: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  try: outId[] = mt[].snapshot(); return 0
  except: setErr(errOut, ErrIo); return -1

proc snapshotFreeImpl(h: pointer, id: uint64) {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt != nil and mt[] != nil: mt[].snapshotFree(id)

proc scanImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
              reverse: cint, outCursor: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  var hnd = cast[ptr MemTableHandle](h)
  if hnd == nil: setErr(errOut, ErrInvalidHandle); return -1
  # use internal MemTableHandle directly for cursor compat
  if cf >= hnd.numCf: setErr(errOut, ErrInvalidHandle); return -1
  var pfx = newSeq[byte](plen)
  if plen > 0: copyMem(addr pfx[0], prefix, plen)
  let upper = if pfx.len == 0: @[byte(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
              else: prefixUpperBound(pfx)
  var collected: seq[Key] = @[]
  hnd.lock.withLock:
    # scanImpl goes through the raw handle, accessing snaps directly
    let snapRoot = if id == 0 or id.int > hnd.snaps.len: nil
                   else: (if hnd.snaps[id.int-1].inUse: hnd.snaps[id.int-1].roots[cf.int] else: nil)
    # For live scan (id=0), use live roots
    let root = if id == 0: hnd.live[cf.int] else: snapRoot
    if root == nil: setErr(errOut, ErrNotFound); return -1
    if reverse != 0: collectReverse(root, pfx, upper, collected)
    else: collectForward(root, pfx, upper, collected)
  var st: CursorState
  st.keys = collected
  st.inUse = true
  hnd.lock.withLock:
    let cid = if hnd.freeCursorSlots.len > 0:
      hnd.freeCursorSlots.pop()
    else:
      let id = hnd.nextCursor; hnd.nextCursor += 1; hnd.cursors.add(st); id
    if cid.int <= hnd.cursors.len:
      hnd.cursors[cid.int - 1] = st
    outCursor[] = cid
  return 0

proc cursorNextImpl(h: pointer, cursor: uint64,
                    outKey: ptr pointer, outLen: ptr csize_t,
                    outValid: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  var hnd = cast[ptr MemTableHandle](h)
  if hnd == nil: setErr(errOut, ErrInvalidHandle); return -1
  hnd.lock.withLock:
    if cursor == 0 or cursor.int > hnd.cursors.len or not hnd.cursors[cursor.int-1].inUse:
      outValid[] = 0; outKey[] = nil; outLen[] = 0; return 0
    let cs = addr hnd.cursors[cursor.int-1]
    if cs.keys.len == 0:
      outValid[] = 0; outKey[] = nil; outLen[] = 0; return 0
    let k = cs.keys[0]; cs.keys.delete(0)
    let buf = allocByteBuf(k.len)
    if k.len > 0: copyMem(buf, addr k[0], k.len)
    outKey[] = buf; outLen[] = cast[csize_t](k.len); outValid[] = 1
  return 0

proc cursorFreeImpl(h: pointer, cursor: uint64) {.cdecl.} =
  if h == nil: return
  var hnd = cast[ptr MemTableHandle](h)
  hnd.lock.withLock:
    if cursor != 0 and cursor.int <= hnd.cursors.len and hnd.cursors[cursor.int-1].inUse:
      hnd.cursors[cursor.int-1].keys = @[]; hnd.cursors[cursor.int-1].inUse = false
      hnd.freeCursorSlots.add(cursor)

proc containsImpl(h: pointer, id: uint64, cf: cuint, key: ptr Byte, klen: csize_t,
                  outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  var k = newSeq[byte](klen)
  if klen > 0: copyMem(addr k[0], key, klen)
  try:
    outPresent[] = if mt[].contains(id, cf.int, k): 1 else: 0
    return 0
  except: setErr(errOut, ErrIo); return -1

proc countPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                     outCount: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  var pfx = newSeq[byte](plen)
  if plen > 0: copyMem(addr pfx[0], prefix, plen)
  try: outCount[] = mt[].countPrefix(id, cf.int, pfx); return 0
  except: setErr(errOut, ErrIo); return -1

proc scanPrefixImpl(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                    reverse: cint, outBuf: ptr pointer, outLen: ptr csize_t,
                    errOut: ptr cint): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: setErr(errOut, ErrInvalidHandle); return -1
  var pfx = newSeq[byte](plen)
  if plen > 0: copyMem(addr pfx[0], prefix, plen)
  try:
    let keys = mt[].scanAll(id, cf.int, pfx, reverse != 0)
    var packed = newSeq[byte](0)
    for k in keys:
      packed.add(cast[byte]((k.len shr 24) and 0xFF)); packed.add(cast[byte]((k.len shr 16) and 0xFF))
      packed.add(cast[byte]((k.len shr 8) and 0xFF)); packed.add(cast[byte](k.len and 0xFF))
      for b in k: packed.add(b)
    if packed.len == 0: outBuf[] = nil; outLen[] = 0
    else:
      let buf = allocByteBuf(packed.len); copyMem(buf, addr packed[0], packed.len)
      outBuf[] = buf; outLen[] = cast[csize_t](packed.len)
    return 0
  except: setErr(errOut, ErrIo); return -1

proc debugCountNodesImpl(h: pointer, outCount: ptr uint64): cint {.cdecl.} =
  let mt = cast[ptr MemTable](h)
  if mt == nil or mt[] == nil: outCount[] = 0; return -1
  try: outCount[] = mt[].debugCountNodes(); return 0
  except: return -1

proc cursorSeekImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                    errOut: ptr cint): cint {.cdecl.} =
  var hnd = cast[ptr MemTableHandle](h)
  if hnd == nil: setErr(errOut, ErrInvalidHandle); return -1
  var t = newSeq[byte](tlen)
  if tlen > 0: copyMem(addr t[0], target, tlen)
  hnd.lock.withLock:
    if cursor != 0 and cursor.int <= hnd.cursors.len and hnd.cursors[cursor.int-1].inUse:
      let cs = addr hnd.cursors[cursor.int-1]
      var i = 0
      while i < cs.keys.len:
        if cmpKey(cs.keys[i], t) >= 0: break
        i += 1
      cs.keys = cs.keys[i ..< cs.keys.len]
  return 0

proc cursorAdvanceToImpl(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                          errOut: ptr cint): cint {.cdecl.} =
  return cursorSeekImpl(h, cursor, target, tlen, errOut)

proc cursorSkipGroupImpl(h: pointer, cursor: uint64, group: ptr Byte, glen: csize_t,
                          errOut: ptr cint): cint {.cdecl.} =
  var hnd = cast[ptr MemTableHandle](h)
  if hnd == nil: setErr(errOut, ErrInvalidHandle); return -1
  var g = newSeq[byte](glen)
  if glen > 0: copyMem(addr g[0], group, glen)
  hnd.lock.withLock:
    if cursor != 0 and cursor.int <= hnd.cursors.len and hnd.cursors[cursor.int-1].inUse:
      let cs = addr hnd.cursors[cursor.int-1]
      var i = 0
      while i < cs.keys.len:
        let k = cs.keys[i]
        if k.len >= g.len and k[0 ..< g.len] == g: i += 1
        else: break
      cs.keys = cs.keys[i ..< cs.keys.len]
  return 0

proc cursorUpdateEndImpl(h: pointer, cursor: uint64, endp: ptr Byte, elen: csize_t,
                          errOut: ptr cint): cint {.cdecl.} =
  var hnd = cast[ptr MemTableHandle](h)
  if hnd == nil: setErr(errOut, ErrInvalidHandle); return -1
  var e = newSeq[byte](elen)
  if elen > 0: copyMem(addr e[0], endp, elen)
  hnd.lock.withLock:
    if cursor != 0 and cursor.int <= hnd.cursors.len and hnd.cursors[cursor.int-1].inUse:
      let cs = addr hnd.cursors[cursor.int-1]
      var i = 0
      while i < cs.keys.len:
        if cmpKey(cs.keys[i], e) < 0: i += 1
        else: break
      cs.keys = cs.keys[0 ..< i]
  return 0

# ══════════════════════════════════════════════════════════════════════════════
# open / close
# ══════════════════════════════════════════════════════════════════════════════

proc openMemTable*(numCf: cuint, errOut: ptr cint): NimMemTableVtablePtr =
  if numCf == 0: setErr(errOut, ErrInvalidArg); return nil
  let mt = newMemTable(numCf.int)
  let vt = newVtable()
  vt.handle = cast[pointer](mt)
  vt.put = putImpl; vt.batch = batchImpl; vt.clear = clearImpl
  vt.snapshot = snapshotImpl; vt.snapshotFree = snapshotFreeImpl
  vt.scan = scanImpl; vt.cursorNext = cursorNextImpl; vt.cursorFree = cursorFreeImpl
  vt.cursorSeek = cursorSeekImpl; vt.cursorAdvanceTo = cursorAdvanceToImpl
  vt.cursorSkipGroup = cursorSkipGroupImpl; vt.cursorUpdateEnd = cursorUpdateEndImpl
  vt.contains = containsImpl; vt.countPrefix = countPrefixImpl
  vt.scanPrefix = scanPrefixImpl; vt.debugCountNodes = debugCountNodesImpl
  vt.freeBuf = freeShared
  result = vt

proc closeMemTable*(vt: NimMemTableVtablePtr) =
  if vt == nil: return
  if vt.handle != nil:
    let mt = cast[ptr MemTable](vt.handle)
    mt[].close()
  freeVtable(vt)

proc closeVtable*(p: pointer) =
  closeMemTable(cast[NimMemTableVtablePtr](p))
