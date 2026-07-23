## tests.nim — Unit tests for nim-kvstore.

import std/[unittest, options, tables, strutils, math, os, times]
import memory/all
import file/all
import journal/all
import nim_memtable/all
import abi
import pages
import page_store
import kvstore
import scheme
import page_cursor

proc scanKeys(kv: KVStore; cf: int; prefix: seq[byte] = @[]): seq[seq[byte]] =
  let mc = kv.openScanCursor(cf)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if prefix.len > 0 and (key.len < prefix.len or key[0..<prefix.len] != prefix): continue
    result.add key


proc makeConfig(t: Table[string, string]): tuple[keys: CStringArr, vals: CStringArr, count: cint] =
  let n = t.len
  result.keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  result.vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var i = 0
  for k, v in t.pairs:
    result.keys[i] = k.cstring
    result.vals[i] = v.cstring
    inc i
  result.count = n.cint

proc freeConfig(cfg: tuple[keys: CStringArr, vals: CStringArr, count: cint]) =
  deallocShared(cfg.keys)
  deallocShared(cfg.vals)


suite "kvstore: Nim API (KVStore ref)":
  test "new + close memory":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check kv != nil
    kv.close()

  test "put + get round-trip":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check kv != nil
    kv.put(0, @[byte(1), 2, 3])
    check kv.get(0, @[byte(1), 2, 3])
    check not kv.get(0, @[byte(1), 2])
    check not kv.get(0, @[byte(9)])
    kv.close()

  test "scan returns keys in order":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(3)])
    kv.put(0, @[byte(1)])
    kv.put(0, @[byte(2)])
    let keys = scanKeys(kv, 0)
    check keys.len == 3
    check keys[0] == @[byte(1)]
    check keys[1] == @[byte(2)]
    check keys[2] == @[byte(3)]
    kv.close()

  test "scan with prefix":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(0), 10])
    kv.put(0, @[byte(0), 20])
    kv.put(0, @[byte(1), 30])
    let keys = scanKeys(kv, 0, @[byte(0)])
    check keys.len == 2
    check keys[0] == @[byte(0), 10]
    check keys[1] == @[byte(0), 20]
    kv.close()

  test "flush makes data visible after scan":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(5)])
    kv.put(0, @[byte(2)])
    kv.flush()
    let keys = scanKeys(kv, 0)
    check keys == @[@[byte(2)], @[byte(5)]]
    kv.close()

  test "memtableSize reflects puts":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check kv.memtableSize() == 0
    kv.put(0, @[byte(1), 2, 3])
    check kv.memtableSize() == 3
    kv.put(0, @[byte(4)])
    check kv.memtableSize() == 4
    kv.close()

  test "separate CFs are independent":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(1)])
    kv.put(1, @[byte(2)])
    check kv.get(0, @[byte(1)])
    check kv.get(1, @[byte(2)])
    check not kv.get(0, @[byte(2)])
    check not kv.get(1, @[byte(1)])
    kv.close()

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — file backend integration tests
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: file backend":
  test "put + get with file backend":
    let path = "/tmp/kvtest_fb_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let cfg = makeConfig({"backend": "file", "path": path}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check kv != nil
    kv.put(0, @[byte(10), 20, 30])
    check kv.get(0, @[byte(10), 20, 30])
    check not kv.get(0, @[byte(99)])
    kv.close()
    removeDir(path)

  test "flush + scan on file backend":
    let path = "/tmp/kvtest_fb2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let cfg = makeConfig({"backend": "file", "path": path}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(5)])
    kv.put(0, @[byte(1)])
    kv.put(0, @[byte(9)])
    kv.flush()
    let keys = scanKeys(kv, 0)
    check keys == @[@[byte(1)], @[byte(5)], @[byte(9)]]
    kv.close()
    removeDir(path)

  test "data survives close + reopen on file":
    let path = "/tmp/kvtest_fb3_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      kv.put(0, @[byte(0xAB), 0xCD])
      kv.flush()
      kv.close()
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check kv.get(0, @[byte(0xAB), 0xCD])
      check not kv.get(0, @[byte(0)])
      kv.close()
    removeDir(path)

  test "multi-CF with file backend":
    let path = "/tmp/kvtest_fb4_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let cfg = makeConfig({"backend": "file", "path": path}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(1)])
    kv.put(1, @[byte(2)])
    kv.put(2, @[byte(3)])
    check kv.get(0, @[byte(1)])
    check kv.get(1, @[byte(2)])
    check kv.get(2, @[byte(3)])
    check not kv.get(0, @[byte(2)])
    kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — read-only mode tests
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: read-only":
  test "read-only get works after prior write + close":
    let path = "/tmp/kvtest_ro_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:  # write
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      kv.put(0, @[byte(7)])
      kv.flush()
      kv.close()
    block:  # read-only
      let cfg = makeConfig({"backend": "file", "path": path, "read_only": "true"}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check kv.get(0, @[byte(7)])
      check not kv.get(0, @[byte(9)])
      kv.close()
    removeDir(path)

  test "read-only scan works":
    let path = "/tmp/kvtest_ro2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      kv.put(0, @[byte(3)])
      kv.put(0, @[byte(1)])
      kv.flush()
      kv.close()
    block:
      let cfg = makeConfig({"backend": "file", "path": path, "read_only": "true"}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check scanKeys(kv, 0) == @[@[byte(1)], @[byte(3)]]
      kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — large values
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: large values":
  test "70 KB key survives put + get":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    var big = newSeq[byte](70000)
    for i in 0..<big.len: big[i] = byte(i and 0xFF)
    kv.put(0, big)
    check kv.get(0, big)
    kv.close()

  test "70 KB key survives flush + reopen on file":
    let path = "/tmp/kvtest_lv_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      var big = newSeq[byte](70000)
      for i in 0..<big.len: big[i] = byte((i * 7) and 0xFF)
      kv.put(0, big)
      kv.flush()
      kv.close()
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      var big = newSeq[byte](70000)
      for i in 0..<big.len: big[i] = byte((i * 7) and 0xFF)
      check kv.get(0, big)
      kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — reverse scan
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: reverse scan":
  test "reverse scan returns keys descending":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(3)])
    kv.put(0, @[byte(1)])
    kv.put(0, @[byte(2)])
    let keys = scanKeys(kv, 0)
    var rev = keys
    var i = 0
    var j = rev.len - 1
    while i < j:
      swap(rev[i], rev[j])
      inc i; dec j
    check rev == @[@[byte(3)], @[byte(2)], @[byte(1)]]
    kv.close()

  test "reverse scan after flush still correct":
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var err: cint
    let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
    kv.put(0, @[byte(5)])
    kv.put(0, @[byte(1)])
    kv.flush()
    kv.put(0, @[byte(3)])  # live memtable
    let keys2 = scanKeys(kv, 0)
    var rev2 = keys2
    var a = 0
    var b = rev2.len - 1
    while a < b:
      swap(rev2[a], rev2[b])
      inc a; dec b
    check rev2 == @[@[byte(5)], @[byte(3)], @[byte(1)]]
    kv.close()

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — journal recovery (crash simulation)
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: journal recovery":
  test "unflushed data survives close + reopen via journal replay":
    let path = "/tmp/kvtest_jr_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:  # write without flush
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      kv.put(0, @[byte(1)])
      kv.put(0, @[byte(2)])
      kv.put(1, @[byte(3)])
      # NO flush — close directly
      kv.close()
    block:  # reopen — data should survive via journal
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check kv.get(0, @[byte(1)])
      check kv.get(0, @[byte(2)])
      check kv.get(1, @[byte(3)])
      kv.close()
    removeDir(path)

  test "multiple unflushed writes survive journal replay":
    let path = "/tmp/kvtest_jr2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      for i in 1..20:
        kv.put(0, @[byte(i)])
      kv.close()
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      for i in 1..20:
        check kv.get(0, @[byte(i)])
      kv.close()
    removeDir(path)

  test "flushed data + journal data both survive":
    let path = "/tmp/kvtest_jr3_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      kv.put(0, @[byte(1)])   # flushed
      kv.flush()
      kv.put(0, @[byte(2)])   # journal only
      kv.close()
    block:
      let cfg = makeConfig({"backend": "file", "path": path}.toTable)
      var err: cint
      let kv = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check kv.get(0, @[byte(1)])  # from page store
      check kv.get(0, @[byte(2)])  # from journal replay
      kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# PageStoreCursor tests
# ══════════════════════════════════════════════════════════════════════════════



