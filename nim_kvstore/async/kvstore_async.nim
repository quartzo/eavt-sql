## kvstore_async.nim — async twin of kvstore's flush/GC: runs on the
## chronos event loop, all blob I/O (zstd + backend) through the BlobPool.
##
## Threading model: NO threads of its own. The server runs this on its
## single event loop; the pool's POD workers do the blocking I/O. Every GC
## ref stays loop-owned (house rule — see nim_blobstore/async).
##
## Structure mirrors the sync paths exactly (kvstore.flush / page_store
## commitMerge* / gcFull); the only differences are:
##   * blobPut/blobGet → pool awaits (workers do zstd + syscall);
##   * the treap drain is CHUNKED (≈256 KiB per slice, `await sleepAsync(chronos.milliseconds(0))`
##     between slices) so a large memtable never monopolises the loop;
##   * single-flight is a Future waiter queue (no atomics — one thread).
##
## Auto-GC: after every flush the runner does the cheap hasOldRootsAsync
## check and, when roots/blobs are past the retention window, a full pass —
## the original Rust poller semantics, minus the thread.

import std/[options, sets, tables]
import std/atomics
import chronos
import common
import blobstore_async
import page_store
import pages
import kvstore
import nim_memtable/treap_backend as mt_be
import treap_cursor

# ══════════════════════════════════════════════════════════════════════════════
# Pool-backed blob helpers
# ══════════════════════════════════════════════════════════════════════════════

proc putPageA(pool: BlobPool; s: ptr PageStoreInner;
              data: sink seq[byte]): Future[ByteArr16] =
  putPageAsync(pool, s[].blobs, data)

proc getPageA(pool: BlobPool; s: ptr PageStoreInner;
              id: ByteArr16): Future[seq[byte]] =
  getPageAsync(pool, s[].blobs, id)

# ══════════════════════════════════════════════════════════════════════════════
# Async commit (twin of page_store.commitMerge / commitMergeKv)
# ══════════════════════════════════════════════════════════════════════════════

type
  MergeState = ref object
    ## Shared cursor over the sorted new-key stream (the sync twin uses two
    ## `var` params; the async macro cannot capture var params across
    ## suspension points, so the state rides a loop-owned ref).
    newKeys: seq[seq[byte]]
    idx: int

proc mergeSubtreeA(pool: BlobPool; s: ptr PageStoreInner;
                   nodeUuid: array[16, byte]; height: uint8;
                   rangeEnd: Option[seq[byte]]; st: MergeState):
    Future[Option[seq[(seq[byte], array[16, byte])]]] {.async.}

proc writeIndexLevelA(pool: BlobPool; s: ptr PageStoreInner;
    entries: seq[(seq[byte], array[16, byte])]):
    Future[seq[(seq[byte], array[16, byte])]] {.async.} =
  let ser = serializeIndexPage(@entries)
  if ser.len <= IndexPageMaxSize or entries.len <= 1:
    let uuid = await putPageA(pool, s, ser)
    return @[(entries[0][0], uuid)]
  let pages = splitIndexEntries(s[], entries)
  for pageData in pages:
    let pageEntries = deserializeIndexPage(pageData)
    if pageEntries.len > 0:
      let uuid = await putPageA(pool, s, pageData)
      result.add (pageEntries[0][0], uuid)

proc buildIndexTreeA(pool: BlobPool; s: ptr PageStoreInner;
                     entries: seq[(seq[byte], array[16, byte])];
                     childHeight: uint8): Future[(array[16, byte], uint8)] {.
    async.} =
  if entries.len == 0: return (default(array[16, byte]), 0'u8)
  let ser = serializeIndexPage(entries)
  if ser.len <= IndexPageMaxSize:
    let uuid = await putPageA(pool, s, ser)
    return (uuid, childHeight + 1)
  let pages = splitIndexEntries(s[], entries)
  if pages.len == 1:
    let uuid = await putPageA(pool, s, pages[0])
    return (uuid, childHeight + 1)
  var levelEntries: seq[(seq[byte], array[16, byte])] = @[]
  for pageData in pages:
    let pageEntries = deserializeIndexPage(pageData)
    if pageEntries.len > 0:
      let uuid = await putPageA(pool, s, pageData)
      levelEntries.add (pageEntries[0][0], uuid)
  var height = childHeight + 2
  while true:
    let ser2 = serializeIndexPage(levelEntries)
    if ser2.len <= IndexPageMaxSize:
      let uuid = await putPageA(pool, s, ser2)
      return (uuid, height)
    let pages2 = splitIndexEntries(s[], levelEntries)
    if pages2.len == levelEntries.len:
      let uuid = await putPageA(pool, s, ser2)
      return (uuid, height)
    var nextLevel: seq[(seq[byte], array[16, byte])] = @[]
    for pageData in pages2:
      let pageEntries = deserializeIndexPage(pageData)
      if pageEntries.len > 0:
        let uuid = await putPageA(pool, s, pageData)
        nextLevel.add (pageEntries[0][0], uuid)
    levelEntries = nextLevel
    inc height

proc mergeLeafA(pool: BlobPool; s: ptr PageStoreInner;
                leafUuid: array[16, byte]; rangeEnd: Option[seq[byte]];
                st: MergeState):
    Future[Option[seq[(seq[byte], array[16, byte])]]] {.async.} =
  let raw = await getPageA(pool, s, leafUuid)
  let existing = deserializePage(raw)
  var toMerge: seq[seq[byte]] = @[]
  while st.idx < st.newKeys.len:
    if rangeEnd.isSome and cmpSeq(st.newKeys[st.idx], rangeEnd.get) >= 0:
      break
    toMerge.add st.newKeys[st.idx]
    inc st.idx
  if toMerge.len == 0: return none(seq[(seq[byte], array[16, byte])])
  var merged: seq[seq[byte]]
  var ei, mi = 0
  while ei < existing.len or mi < toMerge.len:
    if ei >= existing.len:
      merged.add toMerge[mi]; inc mi
    elif mi >= toMerge.len:
      merged.add existing[ei]; inc ei
    elif cmpSeq(existing[ei], toMerge[mi]) < 0:
      merged.add existing[ei]; inc ei
    elif cmpSeq(toMerge[mi], existing[ei]) < 0:
      merged.add toMerge[mi]; inc mi
    else:
      merged.add existing[ei]; inc ei; inc mi
  let pageList = buildPages(merged)
  var entries: seq[(seq[byte], array[16, byte])] = @[]
  for (boundary, pageData) in pageList:
    discard deserializePage(pageData)  # round-trip validation (parity)
    let uuid = await putPageA(pool, s, pageData)
    entries.add (boundary, uuid)
  return some(entries)

proc mergeSubtreeA(pool: BlobPool; s: ptr PageStoreInner;
                   nodeUuid: array[16, byte]; height: uint8;
                   rangeEnd: Option[seq[byte]]; st: MergeState):
    Future[Option[seq[(seq[byte], array[16, byte])]]] {.async.} =
  if height == 0:
    return await mergeLeafA(pool, s, nodeUuid, rangeEnd, st)
  let data = await getPageA(pool, s, nodeUuid)
  let entries = deserializeIndexPage(data)
  var newEntries: seq[(seq[byte], array[16, byte])] = @[]
  var changed = false
  for i, (boundary, childUuid) in entries:
    let childEnd = if i + 1 < entries.len: some(entries[i+1][0]) else: rangeEnd
    let hasKeys = st.idx < st.newKeys.len and
                  (if childEnd.isSome:
                     cmpSeq(st.newKeys[st.idx], childEnd.get) < 0
                   else: true)
    if not hasKeys:
      newEntries.add (boundary, childUuid)
      continue
    let childResult = await mergeSubtreeA(pool, s, childUuid, height - 1,
                                          childEnd, st)
    if childResult.isNone:
      newEntries.add (boundary, childUuid)
    else:
      changed = true
      newEntries.add childResult.get
  if not changed: return none(seq[(seq[byte], array[16, byte])])
  return some(await writeIndexLevelA(pool, s, newEntries))

proc countSubtreeLeavesA(pool: BlobPool; s: ptr PageStoreInner;
                         uuid: array[16, byte]; height: uint8): Future[uint32] {.
    async.} =
  if height == 0: return 1
  let data = await getPageA(pool, s, uuid)
  let entries = deserializeIndexPage(data)
  for (_, childUuid) in entries:
    result += await countSubtreeLeavesA(pool, s, childUuid, height - 1)

proc commitMergeAsync*(pool: BlobPool; s: ptr PageStoreInner;
                       keysByCf: seq[(int, seq[seq[byte]])];
                       clearJournal: bool) {.async.} =
  ## Async twin of commitMerge (key-only CFs). CPU work (page build, merge)
  ## runs on the loop in page-granular slices; every blob write awaits the
  ## pool.
  if s[].readOnly:
    raise newException(IOError, "read-only")
  for (cf, sortedKeysIn) in keysByCf:
    if cf >= s[].numCf or sortedKeysIn.len == 0: continue
    let st = MergeState(newKeys: sortedKeysIn)
    let tree = s[].trees[cf]
    let newTree: CfTree =
      if tree.rootUuid == default(array[16, byte]):
        let pageList = buildPages(st.newKeys)
        var entries: seq[(seq[byte], array[16, byte])] = @[]
        for (boundary, pageData) in pageList:
          discard deserializePage(pageData)
          let uuid = await putPageA(pool, s, pageData)
          entries.add (boundary, uuid)
        let numLeaves = entries.len.uint32
        var (root, height) = await buildIndexTreeA(pool, s, entries, 0)
        if height == 0:
          CfTree(rootUuid: root, height: height, numLeaves: 0)
        else:
          CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
      else:
        let mergeRes = await mergeSubtreeA(pool, s, tree.rootUuid,
                                           tree.height, none(seq[byte]), st)
        if mergeRes.isNone:
          tree
        elif mergeRes.get.len == 1:
          let newUuid = mergeRes.get[0][1]
          let numLeaves = if tree.height == 0: 1'u32
                          else: await countSubtreeLeavesA(pool, s, newUuid,
                                                          tree.height)
          CfTree(rootUuid: newUuid, height: tree.height, numLeaves: numLeaves)
        else:
          var (root, height) = await buildIndexTreeA(pool, s, mergeRes.get,
                                                     tree.height)
          let numLeaves = await countSubtreeLeavesA(pool, s, root, height)
          CfTree(rootUuid: root, height: height, numLeaves: numLeaves)
    s[].trees[cf] = newTree
  let newRoot = makeRootName()
  let rootData = serializeRoot(s[].trees)
  await putRootAsync(pool, s[].blobs, newRoot, rootData)
  s[].currentRoot = newRoot
  if clearJournal:
    journalTruncate(s[])

proc getPairsFullA(pool: BlobPool; s: ptr PageStoreInner;
                   tree: CfTree): Future[seq[(seq[byte], seq[byte])]] {.async.} =
  ## Async twin of getPairsInPrefix(cf, @[]) — full-CF pair scan (the
  ## commitMergeKv read set), leaf by leaf through the pool.
  if tree.rootUuid == default(array[16, byte]): return
  if tree.height == 0:
    let raw = await getPageA(pool, s, tree.rootUuid)
    return deserializePageKv(raw)
  var stack: seq[(array[16, byte], uint8)] = @[(tree.rootUuid, tree.height)]
  while stack.len > 0:
    let (uuid, h) = stack.pop()
    let d = await getPageA(pool, s, uuid)
    let ents = deserializeIndexPage(d)
    for (_, cu) in ents:
      if h == 1:
        let raw = await getPageA(pool, s, cu)
        let pairs = deserializePageKv(raw)
        for p in pairs: result.add p
      else:
        stack.add (cu, h - 1)

proc commitMergeKvAsync*(pool: BlobPool; s: ptr PageStoreInner;
                         pairsByCf: seq[(int, seq[(seq[byte], seq[byte])])];
                         deletedByCf: seq[(int, seq[seq[byte]])] = @[];
                         clearJournal: bool = true) {.async.} =
  ## Async twin of commitMergeKv (CFs >= 10): read-modify-write of each CF
  ## (full pair scan + merge + rebuild), tombstones applied.
  if s[].readOnly:
    raise newException(IOError, "read-only")

  var deletedKeys: Table[int, HashSet[seq[byte]]]
  for (cf, keys) in deletedByCf:
    deletedKeys[cf] = initHashSet[seq[byte]]()
    for k in keys: deletedKeys[cf].incl(k)

  var pairCfs: HashSet[int]
  for (cf, _) in pairsByCf: pairCfs.incl(cf)

  for (cf, delKeys) in deletedByCf:
    if cf in pairCfs: continue
    if cf >= s[].numCf: continue
    let tree = s[].trees[cf]
    if tree.rootUuid == default(array[16, byte]): continue
    let allPairs = await getPairsFullA(pool, s, tree)
    var livePairs: seq[(seq[byte], seq[byte])] = @[]
    let delSet = deletedKeys.getOrDefault(cf, initHashSet[seq[byte]]())
    for (k, v) in allPairs:
      if k notin delSet: livePairs.add((k, v))
    if livePairs.len == 0:
      s[].trees[cf] = CfTree(rootUuid: default(array[16, byte]), height: 0,
                               numLeaves: 0)
      continue
    let pageList = buildPagesKv(livePairs)
    var entries: seq[(seq[byte], array[16, byte])] = @[]
    for (boundary, pageData) in pageList:
      discard deserializePageKv(pageData)
      let uuid = await putPageA(pool, s, pageData)
      entries.add (boundary, uuid)
    let numLeaves = entries.len.uint32
    var (root, height) = await buildIndexTreeA(pool, s, entries, 0)
    if height == 0:
      s[].trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
    else:
      s[].trees[cf] = CfTree(rootUuid: root, height: height,
                             numLeaves: numLeaves)

  for (cf, sortedPairs) in pairsByCf:
    if cf >= s[].numCf or sortedPairs.len == 0: continue
    let tree = s[].trees[cf]
    let delSet = deletedKeys.getOrDefault(cf, initHashSet[seq[byte]]())

    if tree.rootUuid == default(array[16, byte]):
      var filtered: seq[(seq[byte], seq[byte])] = @[]
      for (k, v) in sortedPairs:
        if k notin delSet: filtered.add((k, v))
      if filtered.len == 0: continue
      let pageList = buildPagesKv(filtered)
      var entries: seq[(seq[byte], array[16, byte])] = @[]
      for (boundary, pageData) in pageList:
        discard deserializePageKv(pageData)
        let uuid = await putPageA(pool, s, pageData)
        entries.add (boundary, uuid)
      let numLeaves = entries.len.uint32
      var (root, height) = await buildIndexTreeA(pool, s, entries, 0)
      if height == 0:
        s[].trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
      else:
        s[].trees[cf] = CfTree(rootUuid: root, height: height,
                               numLeaves: numLeaves)
    else:
      let allPairs = await getPairsFullA(pool, s, tree)
      var livePairs: seq[(seq[byte], seq[byte])] = @[]
      for (k, v) in allPairs:
        if k notin delSet: livePairs.add((k, v))
      var merged: seq[(seq[byte], seq[byte])] = @[]
      var ai = 0; var bi = 0
      while ai < livePairs.len and bi < sortedPairs.len:
        let c = cmpSeq(livePairs[ai][0], sortedPairs[bi][0])
        if c < 0:
          if livePairs[ai][0] notin delSet: merged.add livePairs[ai]
          inc ai
        elif c > 0:
          if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
          inc bi
        else:
          if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
          inc ai; inc bi
      while ai < livePairs.len:
        if livePairs[ai][0] notin delSet: merged.add livePairs[ai]
        inc ai
      while bi < sortedPairs.len:
        if sortedPairs[bi][0] notin delSet: merged.add sortedPairs[bi]
        inc bi
      if merged.len == 0:
        s[].trees[cf] = CfTree(rootUuid: default(array[16, byte]), height: 0,
                               numLeaves: 0)
        continue
      let pageList = buildPagesKv(merged)
      var entries: seq[(seq[byte], array[16, byte])] = @[]
      for (boundary, pageData) in pageList:
        discard deserializePageKv(pageData)
        let uuid = await putPageA(pool, s, pageData)
        entries.add (boundary, uuid)
      let numLeaves = entries.len.uint32
      var (root, height) = await buildIndexTreeA(pool, s, entries, 0)
      if height == 0:
        s[].trees[cf] = CfTree(rootUuid: root, height: height, numLeaves: 0)
      else:
        s[].trees[cf] = CfTree(rootUuid: root, height: height,
                               numLeaves: numLeaves)
  let newRoot = makeRootName()
  let rootData = serializeRoot(s[].trees)
  await putRootAsync(pool, s[].blobs, newRoot, rootData)
  s[].currentRoot = newRoot
  if clearJournal:
    journalTruncate(s[])

# ══════════════════════════════════════════════════════════════════════════════
# Chunked treap drain
# ══════════════════════════════════════════════════════════════════════════════

const DrainChunkBytes = 256 * 1024
  ## Slice budget for the materialisation pass. The COW roots are frozen at
  ## capture; the ONLY reason to slice is loop fairness: each slice is
  ## ~1-2 ms of pointer-chasing, comparable to a VM query batch.

type
  DrainOut = tuple
    keysByCf: seq[(int, seq[seq[byte]])]
    pairsByCf: seq[(int, seq[(seq[byte], seq[byte])])]
    deletedByCf: seq[(int, seq[seq[byte]])]

proc drainTreapAsync(kv: KVStore;
                     roots: seq[mt_be.TreapNode]): Future[DrainOut] {.async.} =
  var res: DrainOut
  for cf in 0..<kv.numCf:
    if roots[cf] == nil: continue
    if cf >= 10:
      var pairs: seq[(seq[byte], seq[byte])] = @[]
      var deleted: seq[seq[byte]] = @[]
      var budget = 0
      let tc = newTreapCursor(roots[cf])
      while not tc.atEnd:
        let kvp = tc.nextKv()
        if kvp.isSome:
          let (key, val) = kvp.get
          pairs.add (key, val)
          budget += key.len + val.len
          if budget >= DrainChunkBytes:
            budget = 0
            await sleepAsync(chronos.milliseconds(0))
      let tc2 = newTreapCursor(roots[cf])
      while not tc2.atEnd:
        let dk = tc2.nextDeleted()
        if dk.isSome:
          deleted.add(dk.get)
          budget += dk.get.len
          if budget >= DrainChunkBytes:
            budget = 0
            await sleepAsync(chronos.milliseconds(0))
      if pairs.len > 0: res.pairsByCf.add (cf, pairs)
      if deleted.len > 0: res.deletedByCf.add (cf, deleted)
    else:
      var keys: seq[seq[byte]] = @[]
      var budget = 0
      let tc = newTreapCursor(roots[cf])
      while not tc.atEnd:
        let k = tc.next()
        if k.isSome:
          keys.add(k.get)
          budget += k.get.len
          if budget >= DrainChunkBytes:
            budget = 0
            await sleepAsync(chronos.milliseconds(0))
      if keys.len > 0: res.keysByCf.add (cf, keys)
  return res

# ══════════════════════════════════════════════════════════════════════════════
# Async GC (twin of page_store.gcFull / hasOldRoots)
# ══════════════════════════════════════════════════════════════════════════════

proc collectTreeUuidsA(pool: BlobPool; s: ptr PageStoreInner; tree: CfTree;
                       live: ref HashSet[array[16, byte]]): Future[void] {.
    async.}

proc collectTreeUuidsA(pool: BlobPool; s: ptr PageStoreInner; tree: CfTree;
                       live: ref HashSet[array[16, byte]]): Future[void] {.
    async.} =
  if tree.rootUuid == default(array[16, byte]): return
  live[].incl tree.rootUuid
  if tree.height == 0: return
  let data = await getPageA(pool, s, tree.rootUuid)
  let entries = deserializeIndexPage(data)
  for (_, childUuid) in entries:
    live[].incl childUuid
    if tree.height > 1:
      await collectTreeUuidsA(pool, s,
          CfTree(rootUuid: childUuid, height: tree.height - 1, numLeaves: 0),
          live)

proc hasOldRootsAsync*(pool: BlobPool; s: ptr PageStoreInner;
                       maxAgeSecs: uint64;
                       maxRootCount: int): Future[bool] {.async.} =
  ## Cheap GC-candidate check: one listRoots through the pool.
  let roots = await listRootsAsync(pool, s[].blobs)
  if roots.len == 0: return false
  result = classifyRoots(roots, maxAgeSecs, maxRootCount).remove.len > 0

proc gcFullAsync*(pool: BlobPool; s: ptr PageStoreInner; maxAgeSecs: uint64;
                  maxRootCount: int; dryRun: bool): Future[seq[byte]] {.async.} =
  ## Async twin of gcFull. Same 41-byte report (5×u64 LE + dryRun flag).
  if s[].readOnly:
    raise newException(IOError, "read-only")
  let roots = await listRootsAsync(pool, s[].blobs)
  if roots.len == 0: return @[]
  let rootsScanned = roots.len
  let (rootsToKeep, rootsToRemove) = classifyRoots(roots, maxAgeSecs,
                                                   maxRootCount)
  let live = new(HashSet[array[16, byte]])
  live[] = initHashSet[array[16, byte]]()
  for name in rootsToKeep:
    try:
      let data = await getRootAsync(pool, s[].blobs, name)
      for tree in deserializeRoot(data):
        await collectTreeUuidsA(pool, s, tree, live)
    except CatchableError:
      continue
  let rootsRemoved = rootsToRemove.len
  if not dryRun:
    for name in rootsToRemove:
      try: await deleteRootAsync(pool, s[].blobs, name)
      except CatchableError: discard
  let allBlobs = await listAsync(pool, s[].blobs)
  let blobsScanned = allBlobs.len
  var blobsRemoved = 0
  for id in allBlobs:
    if id notin live[]:
      if not dryRun:
        try: await deleteAsync(pool, s[].blobs, id)
        except CatchableError: discard
      inc blobsRemoved
  let liveCount = live[].len
  result = newSeqOfCap[byte](41)
  let rs = cast[uint64](rootsScanned)
  let rr = cast[uint64](rootsRemoved)
  let bs = cast[uint64](blobsScanned)
  let br = cast[uint64](blobsRemoved)
  let lc = cast[uint64](liveCount)
  for i in 0..7: result.add byte((rs shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((rr shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((bs shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((br shr (i*8)) and 0xFF)
  for i in 0..7: result.add byte((lc shr (i*8)) and 0xFF)
  result.add byte(if dryRun: 1 else: 0)

# ══════════════════════════════════════════════════════════════════════════════
# AsyncFlusher — single-flight flush + GC on the loop
# ══════════════════════════════════════════════════════════════════════════════

type
  AsyncFlusher* = ref object
    kv*: KVStore
    pool*: BlobPool
    ## Waiter queue: loop-thread only (no atomics — exactly one thread).
    waiters: seq[Future[void]]
    active: bool
    ## Explicit GC request flags (requestGcAsync); consumed by the runner.
    gcPending: bool
    gcDryRun: bool
    gcWaiters: seq[Future[void]]
    ## Report of the last completed GC pass (41 bytes or empty).
    lastGcReport*: seq[byte]

proc flushNowAsync*(f: AsyncFlusher): Future[void] {.async.} =
  ## One flush pass: capture → chunked drain → async commit → publish.
  ## Same capture/publish semantics as kvstore.flush().
  let kv = f.kv
  if kv.readOnly: return
  var roots: seq[mt_be.TreapNode]
  var sealBoundary: int64 = -1
  var captured = false
  if kv.flushRoots.len == 0:
    roots = kv.mt.hnd.live
    kv.mt.clear(); kv.mtSize = 0
    kv.flushRoots = roots
    captured = true
    # Seal the WAL segment at the capture boundary (same contract as the
    # sync flush).
    if kv.journalSeal != nil:
      sealBoundary = kv.journalSeal()
  if not captured:
    # Another flush holds the captured window (sync flush() ran mid-flight).
    # It publishes our writes only if they were captured by it; writes after
    # ITS capture need another pass — the runner re-iterates, so just return.
    return
  let drained = await drainTreapAsync(kv, roots)
  if drained.keysByCf.len > 0:
    await commitMergeAsync(f.pool, kv.ps, drained.keysByCf, true)
  if drained.pairsByCf.len > 0 or drained.deletedByCf.len > 0:
    await commitMergeKvAsync(f.pool, kv.ps, drained.pairsByCf,
                             drained.deletedByCf, true)
  # Single-threaded publish.
  kv.flushRoots = @[]; kv.mtSize = 0
  # Publish done: everything before the seal boundary is durable in the
  # PageStore — the sealed WAL segment may be deleted on the next WAL cycle.
  if sealBoundary >= 0:
    kv.walDurableUpTo.store(sealBoundary, moRelease)

proc runner(f: AsyncFlusher) {.async: (raises: []).} =
  ## Drives flush/GC passes while work is requested. Each iteration:
  ## flush (if flush waiters) → auto-GC candidate check (cheap) → explicit
  ## GC (if requested) → settle waiters. One thread, so no atomics needed.
  while true:
    let batch = f.waiters
    f.waiters = @[]
    let gcBatch = f.gcWaiters
    f.gcWaiters = @[]
    let doGc = f.gcPending
    let dryRun = f.gcDryRun
    f.gcPending = false
    var err: ref CatchableError = nil
    if batch.len > 0:
      try:
        await f.flushNowAsync()
      except CatchableError as e:
        err = e
    # Auto-GC after flush (Rust-poller semantics): cheap check first; the
    # blob walk runs only when candidates exist.
    if batch.len > 0 and err == nil and not f.kv.readOnly and f.kv.ps != nil:
      try:
        if await hasOldRootsAsync(f.pool, f.kv.ps, f.kv.gcMaxAgeSecs,
                                  f.kv.gcMaxRootCount):
          f.lastGcReport = await gcFullAsync(f.pool, f.kv.ps,
                                             f.kv.gcMaxAgeSecs,
                                             f.kv.gcMaxRootCount, false)
      except CatchableError:
        discard
    if doGc:
      try:
        f.lastGcReport = await gcFullAsync(f.pool, f.kv.ps,
                                           f.kv.gcMaxAgeSecs,
                                           f.kv.gcMaxRootCount, dryRun)
      except CatchableError as e:
        err = e
    if batch.len > 0 or gcBatch.len > 0:
      if err != nil:
        for w in batch:
          if not w.finished: w.fail(err)
        for w in gcBatch:
          if not w.finished: w.fail(err)
      else:
        for w in batch: w.complete()
        for w in gcBatch: w.complete()
    if f.waiters.len == 0 and f.gcWaiters.len == 0 and not f.gcPending:
      f.active = false
      break

proc requestFlushAsync*(f: AsyncFlusher): Future[void] =
  ## Fire-and-forget flush with a completion handle. Concurrent requests
  ## collapse; when the returned future completes, every write issued
  ## before the request is durable.
  let w = newFuture[void]("kv.flushRequest")
  f.waiters.add(w)
  if not f.active:
    f.active = true
    asyncSpawn f.runner()
  w

proc requestGcAsync*(f: AsyncFlusher; dryRun: bool): Future[void] =
  ## Explicit GC pass. Serialized with flushes through the same runner (a
  ## GC concurrent with a commit could delete blobs the commit just wrote —
  ## their root is not yet in the keep-set). When the returned future
  ## completes, f.lastGcReport holds the 41-byte report.
  let w = newFuture[void]("kv.gcRequest")
  f.gcDryRun = dryRun
  f.gcPending = true
  f.gcWaiters.add(w)
  if not f.active:
    f.active = true
    asyncSpawn f.runner()
  w

proc newAsyncFlusher*(kv: KVStore; pool: BlobPool): AsyncFlusher =
  AsyncFlusher(kv: kv, pool: pool)
