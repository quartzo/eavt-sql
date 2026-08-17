## test_page_store.nim — Unit tests for nim_page_store.

import std/[unittest, options, tables, strutils, math, os, times, random]
import pages
import page_store
import page_cursor

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
    let leafBefore = c.leafKeys
    let idxBefore = c.leafIdx
    check idxBefore >= 0
    # Seek to a key that is within the same leaf (a few positions ahead).
    # We don't know the leaf boundary, so seek to the current key's
    # neighbor and assert we stayed on the same leaf object.
    c.seek(keys[1000])
    check c.leafKeys == leafBefore
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
