## test_page_store.nim — Unit tests for nim_page_store.

import std/[unittest, options, tables, strutils, math, os, times, random]
import pages
import page_store
import page_cursor
import blobstore

# ── Helpers ──

proc newMemStore(): ptr PageStoreInner =
  # tempdir-backed store (name kept: many call sites); closePageStore
  # removes the dir when ownsPath is set
  var cfg = {"backend": "file", "owns_path": "true"}.toTable
  cfg["path"] = getTempDir() / "eavt_ps_test_" & $getCurrentProcessId() & "_" &
                 $epochTime().uint64 & "_" & $rand(high(int))
  createDir(cfg["path"])
  result = newPageStore(cfg)
proc commitKeys(s: var PageStoreInner; cf: int; keys: seq[seq[byte]]) =
  s.commitMerge(@[(cf, keys)], true)

proc collectAll(c: PageStoreCursor): seq[seq[byte]] =
  while not c.atEnd:
    let k = c.next()
    if k.isNone: break
    result.add k.get

# Build keys that span multiple leaves. Each key is large enough that the
# serialized page exceeds MaxRawSize only after several keys, forcing the
# B-tree to grow height and multiple leaves.
proc bigKeys(n: int; prefix: byte = 0): seq[seq[byte]] =
  for i in 0..<n:
    var k = newSeq[byte](32)
    k[0] = prefix
    # big-endian i in bytes 1..4
    k[1] = byte((i shr 24) and 0xFF)
    k[2] = byte((i shr 16) and 0xFF)
    k[3] = byte((i shr 8) and 0xFF)
    k[4] = byte(i and 0xFF)
    for j in 5..<32: k[j] = byte('A'.ord + (i mod 26))
    result.add k

# ── Tests ──

suite "page_cursor: seek":
  test "empty tree → atEnd":
    let s = newMemStore()
    defer: closePageStore(s)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    check c.peek().isNone
    check c.atEnd
    c.seek(@[byte(5)])
    check c.atEnd

  test "single leaf seek to exact":
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(3))
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    let target = bigKeys(3)[1]
    c.seek(target)
    check not c.atEnd
    let k = c.peek()
    check k.isSome
    check k.get == target

  test "single leaf seek before all":
    let s = newMemStore()
    defer: closePageStore(s)
    let keys = bigKeys(3)
    commitKeys(s[], 0, keys)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    c.seek(@[byte(0), 0, 0, 0, 0])  # before first key
    check not c.atEnd
    let collected = collectAll(c)
    check collected.len == 3
    check collected[0] == keys[0]

  test "single leaf seek after all → atEnd":
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(3))
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    c.seek(@[byte(0xFF)])
    check c.atEnd

  test "multi-leaf seek to exact middle":
    # Enough keys to force multiple leaves.
    let n = 2000
    let keys = bigKeys(n)
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, keys)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    let target = keys[n div 2]
    c.seek(target)
    check not c.atEnd
    let k = c.peek()
    check k.isSome
    check k.get == target

  test "multi-leaf seek before all":
    let n = 2000
    let keys = bigKeys(n)
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, keys)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    c.seek(@[byte(0), 0, 0, 0, 0])
    check not c.atEnd
    let collected = collectAll(c)
    check collected.len == n
    check collected[0] == keys[0]
    check collected[^1] == keys[^1]

  test "multi-leaf seek after all → atEnd":
    let n = 2000
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(n))
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    c.seek(@[byte(0xFF)])
    check c.atEnd

  test "multi-leaf seek then full scan matches forward scan":
    let n = 2000
    let keys = bigKeys(n)
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, keys)
    # Forward scan from start
    let cFwd = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    let fwd = collectAll(cFwd)
    # Seek to middle, collect rest
    let cSeek = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    cSeek.seek(keys[n div 2])
    let rest = collectAll(cSeek)
    check fwd.len == n
    check rest.len == n - (n div 2)
    check rest == fwd[n div 2 .. ^1]

  test "repeated seeks stay consistent":
    let n = 2000
    let keys = bigKeys(n)
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, keys)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    # Seek to several points; each should land on key >= target.
    for idx in [0, 500, 100, 1500, 1999, 700, 1999, 0]:
      c.seek(keys[idx])
      check not c.atEnd
      let k = c.peek()
      check k.isSome
      check k.get == keys[idx]

  test "fast-path: seek within current leaf does not reload":
    # After a seek lands on a leaf, a second seek to a nearby key in the
    # same leaf should be served from leafKeys without descent.
    let n = 2000
    let keys = bigKeys(n)
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, keys)
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    # Land somewhere in the middle.
    c.seek(keys[1000])
    check not c.atEnd
    let leafBefore = c.flatKeys
    let idxBefore = c.leafIdx
    check idxBefore >= 0
    # Seek to a key that is within the same leaf (a few positions ahead).
    # We don't know the leaf boundary, so seek to the current key's
    # neighbor and assert we stayed on the same leaf object.
    c.seek(keys[1000])
    check c.flatKeys.buf == leafBefore.buf
    check c.flatKeys.offs == leafBefore.offs
    check not c.atEnd
    check c.peek().get == keys[1000]

  test "cursor pinned to old root sees old snapshot":
    # COW: a cursor opened before a commitMerge continues to see the
    # old tree, not the new one.
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(10, 0))
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    # Now add more keys (new root).
    commitKeys(s[], 0, bigKeys(10, 1))
    # Cursor should still see only the original 10 keys.
    let collected = collectAll(c)
    check collected.len == 10
    # A fresh cursor sees the merged tree.
    let c2 = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    let collected2 = collectAll(c2)
    check collected2.len == 20

# ── GC ──

proc u64le(b: seq[byte]; off: int): uint64 =
  for i in 0..7: result = result or (uint64(b[off + i]) shl uint64(8 * i))

suite "page_store: GC":
  test "gcFull removes orphan blobs":
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(50, 0))
    # Orphan blob: referenced by no root.
    discard s[].blobs.put(@[byte(1), 2, 3])
    let before = s[].blobs.list().len
    check before >= 2
    let rep = s[].gcFull(0, 0, false)  # keep only the latest root
    check u64le(rep, 16) == uint64(before)  # blobs_scanned
    check u64le(rep, 24) == 1'u64           # blobs_removed: just the orphan
    check u64le(rep, 0) >= 1'u64             # roots_scanned >= 1
    check s[].blobs.list().len == before - 1
    # Live keys survive.
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    check collectAll(c).len == 50

  test "gcFull dry run preserves everything":
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(10, 0))
    commitKeys(s[], 0, bigKeys(10, 1))
    discard s[].blobs.put(@[byte(9)])
    let rootsBefore = s[].blobs.listRoots().len
    let blobsBefore = s[].blobs.list().len
    let rep = s[].gcFull(0, 0, true)
    check rep[40] == 1                     # dryRun flag
    # 3 roots (initial + 2 commits); age 0 keeps only the latest → 2 removed.
    check u64le(rep, 0) == 3'u64
    check u64le(rep, 8) == 2'u64
    check s[].blobs.listRoots().len == rootsBefore
    check s[].blobs.list().len == blobsBefore

  test "count-based GC keeps N newest roots":
    let s = newMemStore()
    defer: closePageStore(s)
    for i in 0..<5: commitKeys(s[], 0, bigKeys(3, byte(i)))
    check s[].blobs.listRoots().len == 6  # initial root + 5 commits
    discard s[].gcFull(43200, 3, false)  # age off, keep 3
    check s[].blobs.listRoots().len == 3
    # Current tree intact: all 15 keys readable.
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: s[].trees[0].rootUuid, height: s[].trees[0].height)
    check collectAll(c).len == 15

  test "hasOldRoots: false within window, true past count or age":
    let s = newMemStore()
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(3, 0))
    check not s[].hasOldRoots(43200, 10)
    for i in 1..<11: commitKeys(s[], 0, bigKeys(3, byte(i)))
    check s[].blobs.listRoots().len == 12  # initial + 11 commits
    check s[].hasOldRoots(43200, 10)   # 12 roots > count window
    check not s[].hasOldRoots(43200, 0)  # 0 = unlimited count
    check s[].hasOldRoots(0, 0)        # age 0: any older-than-latest root

  test "gcFull fail-stop: unreadable kept root aborts pass without deletions":
    let dbPath = getTempDir() / "eavt_ps_test_" & $getCurrentProcessId() & "_" &
                   $epochTime().uint64 & "_" & $rand(high(int))
    createDir(dbPath)
    var cfg = {"backend": "file", "owns_path": "true", "path": dbPath}.toTable
    let s = newPageStore(cfg)
    defer: closePageStore(s)
    commitKeys(s[], 0, bigKeys(10, 0))
    commitKeys(s[], 0, bigKeys(10, 1))
    let roots = s[].blobs.listRoots()  # newest-first
    check roots.len == 3               # initial root + 2 commits
    let before = s[].blobs.list().len
    check before >= 2
    # Corrupt one KEPT root record (large age window keeps every listed
    # root): the live-set walk must fail loudly, not skip silently.
    writeFile(dbPath / "blobs" / roots[1], "\x00\x01\x02corrupt")
    var raised = false
    try:
      discard s[].gcFull(3_600'u64, 10, false)
    except CatchableError:
      raised = true
    check raised
    # Fail-stop contract: a hole in the live-set must never reach the delete
    # phase — zero blobs removed on an aborted pass.
    check s[].blobs.list().len == before

suite "page_store: fail-stop reads":
  test "prefix scan raises when a leaf blob is missing":
    let s = newMemStore()
    defer: closePageStore(s)
    # Enough keys to span multiple leaves (MaxRawSize = 256 KiB per page).
    commitKeys(s[], 0, bigKeys(12000, 7))
    let tree = s[].trees[0]
    check tree.height >= 1
    let dataOpt = blobGet(s[].blobs, tree.rootUuid)
    check dataOpt.isSome
    let entries = deserializeIndexPage(dataOpt.get)
    check entries.len >= 2
    # Remove the first leaf's blob — a silent scan would truncate results.
    s[].blobs.delete(entries[0][1])
    expect IOError:
      discard getKeysInPrefix(s[], 0, @[byte(7)])

# ── Regression: advanceToNextLeaf on height-1 trees ──────────────────────────
# Root is a single index whose children are leaves; crossing a leaf boundary
# used to load the SIBLING LEAF as an index page (phantom navigation or
# "truncated index entry" / "leaf blob not found").

suite "page_cursor: leaf-boundary crossing on h=1 tree":

  test "forward walk crosses every leaf boundary":
    let s = newMemStore()
    defer: closePageStore(s)
    var keys: seq[seq[byte]]
    # ~200-byte keys -> handful of keys per leaf -> multi-leaf at once
    for i in 0..<4000:
      var k = newSeq[byte](200)
      k[0] = byte((i shr 16) and 0xFF)
      k[1] = byte((i shr 8) and 0xFF)
      k[2] = byte(i and 0xFF)
      for j in 4..<200: k[j] = byte('x')
      keys.add k
    commitKeys(s[], 0, keys)
    let t = s[].trees[0]
    check t.height == 1          # precondition: single index over leaves
    check t.numLeaves > 2        # precondition: boundaries exist

    let c = PageStoreCursor(s: s, cf: 0, rootUuid: t.rootUuid,
                            height: t.height)
    c.seek(keys[0])
    var count = 0
    var prev = -1
    while not c.atEnd:
      let k = c.next()
      if k.isNone: break
      # keys are strictly ascending by construction
      let idx = (int(k.get[0]) shl 16) or (int(k.get[1]) shl 8) or int(k.get[2])
      check idx > prev
      prev = idx
      inc count
    check count == keys.len      # walked ALL leaves without error

  test "seek near end-of-leaf then cross forward":
    let s = newMemStore()
    defer: closePageStore(s)
    var keys: seq[seq[byte]]
    for i in 0..<4000:
      var k = newSeq[byte](200)
      k[0] = byte((i shr 16) and 0xFF)
      k[1] = byte((i shr 8) and 0xFF)
      k[2] = byte(i and 0xFF)
      for j in 4..<200: k[j] = byte('x')
      keys.add k
    commitKeys(s[], 0, keys)
    let t = s[].trees[0]
    # land on the LAST key of some leaf and walk past the boundary
    let boundary = 4000 div 2
    let c = PageStoreCursor(s: s, cf: 0, rootUuid: t.rootUuid,
                            height: t.height)
    c.seek(keys[boundary - 1])
    var seen = 0
    while not c.atEnd:
      discard c.next()
      inc seen
    check seen == keys.len - boundary + 1
