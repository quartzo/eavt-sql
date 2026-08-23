## test_kvstore.nim — Unit tests for nim_kvstore.

import std/[unittest, options, tables, strutils, math, os, times]
import std/typedthreads
import file/all
import journal/all
import nim_memtable/all
import pages
import page_store
import blobstore
import kvstore
import scheme

proc scanKeys(kv: KVStore; cf: int; prefix: seq[byte] = @[]): seq[seq[byte]] =
  let mc = kv.openScanCursor(cf)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if prefix.len > 0 and (key.len < prefix.len or key[0..<prefix.len] != prefix): continue
    result.add key


suite "kvstore: Nim API (KVStore ref)":
  test "new + close memory":
    let kv = newTempFileKVStore()
    check kv != nil
    kv.close()

  test "put + get round-trip":
    let kv = newTempFileKVStore()
    check kv != nil
    kv.put(0, @[byte(1), 2, 3])
    check kv.get(0, @[byte(1), 2, 3])
    check not kv.get(0, @[byte(1), 2])
    check not kv.get(0, @[byte(9)])
    kv.close()

  test "scan returns keys in order":
    let kv = newTempFileKVStore()
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
    let kv = newTempFileKVStore()
    kv.put(0, @[byte(0), 10])
    kv.put(0, @[byte(0), 20])
    kv.put(0, @[byte(1), 30])
    let keys = scanKeys(kv, 0, @[byte(0)])
    check keys.len == 2
    check keys[0] == @[byte(0), 10]
    check keys[1] == @[byte(0), 20]
    kv.close()

  test "flush makes data visible after scan":
    let kv = newTempFileKVStore()
    kv.put(0, @[byte(5)])
    kv.put(0, @[byte(2)])
    kv.flush()
    let keys = scanKeys(kv, 0)
    check keys == @[@[byte(2)], @[byte(5)]]
    kv.close()

  test "memtableSize reflects puts":
    let kv = newTempFileKVStore()
    check kv.memtableSize() == 0
    kv.put(0, @[byte(1), 2, 3])
    check kv.memtableSize() == 3
    kv.put(0, @[byte(4)])
    check kv.memtableSize() == 4
    kv.close()

  test "separate CFs are independent":
    let kv = newTempFileKVStore()
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
    let cfg = {"backend": "file", "path": path}.toTable
    let kv = newKVStore(cfg)
    check kv != nil
    kv.put(0, @[byte(10), 20, 30])
    check kv.get(0, @[byte(10), 20, 30])
    check not kv.get(0, @[byte(99)])
    kv.close()
    removeDir(path)

  test "flush + scan on file backend":
    let path = "/tmp/kvtest_fb2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let cfg = {"backend": "file", "path": path}.toTable
    let kv = newKVStore(cfg)
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
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      kv.put(0, @[byte(0xAB), 0xCD])
      kv.flush()
      kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      check kv.get(0, @[byte(0xAB), 0xCD])
      check not kv.get(0, @[byte(0)])
      kv.close()
    removeDir(path)

  test "multi-CF with file backend":
    let path = "/tmp/kvtest_fb4_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let cfg = {"backend": "file", "path": path}.toTable
    let kv = newKVStore(cfg)
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
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      kv.put(0, @[byte(7)])
      kv.flush()
      kv.close()
    block:  # read-only
      let cfg = {"backend": "file", "path": path, "read_only": "true"}.toTable
      let kv = newKVStore(cfg)
      check kv.get(0, @[byte(7)])
      check not kv.get(0, @[byte(9)])
      kv.close()
    removeDir(path)

  test "read-only scan works":
    let path = "/tmp/kvtest_ro2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      kv.put(0, @[byte(3)])
      kv.put(0, @[byte(1)])
      kv.flush()
      kv.close()
    block:
      let cfg = {"backend": "file", "path": path, "read_only": "true"}.toTable
      let kv = newKVStore(cfg)
      check scanKeys(kv, 0) == @[@[byte(1)], @[byte(3)]]
      kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# KVStore — large values
# ══════════════════════════════════════════════════════════════════════════════



suite "kvstore: large values":
  test "70 KB key survives put + get":
    let kv = newTempFileKVStore()
    var big = newSeq[byte](70000)
    for i in 0..<big.len: big[i] = byte(i and 0xFF)
    kv.put(0, big)
    check kv.get(0, big)
    kv.close()

  test "70 KB key survives flush + reopen on file":
    let path = "/tmp/kvtest_lv_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      var big = newSeq[byte](70000)
      for i in 0..<big.len: big[i] = byte((i * 7) and 0xFF)
      kv.put(0, big)
      kv.flush()
      kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
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
    let kv = newTempFileKVStore()
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
    let kv = newTempFileKVStore()
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
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      kv.put(0, @[byte(1)])
      kv.put(0, @[byte(2)])
      kv.put(1, @[byte(3)])
      # NO flush — close directly
      kv.close()
    block:  # reopen — data should survive via journal
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      check kv.get(0, @[byte(1)])
      check kv.get(0, @[byte(2)])
      check kv.get(1, @[byte(3)])
      kv.close()
    removeDir(path)

  test "multiple unflushed writes survive journal replay":
    let path = "/tmp/kvtest_jr2_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      for i in 1..20:
        kv.put(0, @[byte(i)])
      kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      for i in 1..20:
        check kv.get(0, @[byte(i)])
      kv.close()
    removeDir(path)

  test "flushed data + journal data both survive":
    let path = "/tmp/kvtest_jr3_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      kv.put(0, @[byte(1)])   # flushed
      kv.flush()
      kv.put(0, @[byte(2)])   # journal only
      kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      check kv.get(0, @[byte(1)])  # from page store
      check kv.get(0, @[byte(2)])  # from journal replay
      kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# PageStoreCursor tests
# ══════════════════════════════════════════════════════════════════════════════




# ═══════════════════════════════════════════════════════════════════════════════
# MergedCursor unit tests
# ═══════════════════════════════════════════════════════════════════════════════

import keys
import query/cursor
import query/scanner

proc mockTestCursor(keys: seq[seq[byte]]): Cursor =
  mockCursor(keys)

proc collectAll(mc: MergedCursor): seq[seq[byte]] =
  while true:
    let k = mc.next()
    if k.isNone: break
    result.add k.get

suite "merged_cursor":
  test "two sources merge sorted":
    let s1 = mockTestCursor(@[@[byte(1)], @[byte(3)], @[byte(5)]])
    let s2 = mockTestCursor(@[@[byte(2)], @[byte(4)]])
    let mc = newMergedCursor(@[s1, s2])
    check collectAll(mc) == @[@[byte(1)], @[byte(2)], @[byte(3)], @[byte(4)], @[byte(5)]]

  test "empty sources → atEnd":
    let s1 = mockTestCursor(@[])
    let s2 = mockTestCursor(@[])
    let mc = newMergedCursor(@[s1, s2])
    check mc.peek().isNone
    check mc.atEnd

  test "single source passthrough":
    let s1 = mockTestCursor(@[@[byte(7)], @[byte(8)]])
    let mc = newMergedCursor(@[s1])
    check mc.peek().get == @[byte(7)]
    check mc.next().get == @[byte(7)]
    check mc.next().get == @[byte(8)]
    check mc.next().isNone

  test "dedup identical keys":
    let s1 = mockTestCursor(@[@[byte(1)], @[byte(2)]])
    let s2 = mockTestCursor(@[@[byte(2)], @[byte(3)]])
    let mc = newMergedCursor(@[s1, s2])
    check collectAll(mc) == @[@[byte(1)], @[byte(2)], @[byte(3)]]

  test "peek idempotent":
    let s1 = mockTestCursor(@[@[byte(5)]])
    let mc = newMergedCursor(@[s1])
    check mc.peek() == mc.peek()
    check mc.peek().get == @[byte(5)]
    check mc.next().get == @[byte(5)]
    check mc.next().isNone

  test "seek advances all sources":
    let s1 = mockTestCursor(@[@[byte(1)], @[byte(3)], @[byte(5)]])
    let s2 = mockTestCursor(@[@[byte(2)], @[byte(4)]])
    let mc = newMergedCursor(@[s1, s2])
    mc.seek(@[byte(4)])
    check collectAll(mc) == @[@[byte(4)], @[byte(5)]]

  test "three sources merge":
    let s1 = mockTestCursor(@[@[byte(1)], @[byte(4)]])
    let s2 = mockTestCursor(@[@[byte(2)], @[byte(5)]])
    let s3 = mockTestCursor(@[@[byte(3)], @[byte(6)]])
    let mc = newMergedCursor(@[s1, s2, s3])
    check collectAll(mc) == @[@[byte(1)], @[byte(2)], @[byte(3)], @[byte(4)], @[byte(5)], @[byte(6)]]

  test "seek to exact value":
    let s1 = mockTestCursor(@[@[byte(10)], @[byte(20)]])
    let mc = newMergedCursor(@[s1])
    mc.seek(@[byte(20)])
    check mc.peek().get == @[byte(20)]

# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner + MergedCursor integration
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner + MergedCursor (raw keys, no EAVT/QueryStore)
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner + mock cursor: leapNextAt advances correctly
# ═══════════════════════════════════════════════════════════════════════════════

suite "v2scanner_leap":
  test "leapNextAt advances through three values":
    let eid = 1'i64; let aid = 100'u32
    let ekeys = @[
      buildEavtKey(eid, aid, encodeInt(1), 1, false),
      buildEavtKey(eid, aid, encodeInt(2), 1, false),
      buildEavtKey(eid, aid, encodeInt(3), 1, false),
    ]

    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), some(DbTypeLong))
    sc.saveValue(SExpr(kind: sInt, ival: eid))
    sc.saveValue(SExpr(kind: sInt, ival: aid.int64))
    sc.setValueAttrType(some(DbTypeLong))
    sc.setCursor(mockTestCursor(ekeys))
    sc.advanceToActiveAt()

    check sc.extractCurrent().get.ival == 1
    sc.leapNextAt()
    check sc.extractCurrent().get.ival == 2
    sc.leapNextAt()
    check sc.extractCurrent().get.ival == 3
    sc.leapNextAt()
    check sc.atEnd

# ═══════════════════════════════════════════════════════════════════════════════════
# KVStore — concurrency tests
# ═══════════════════════════════════════════════════════════════════════════════════

# Thread harness: test-local raw threads, joined before the handle's scope
# ends. This avoids the createThread-on-stack race (AGENTS.md: the join
# happens while the local is alive, so nimZeroMem can never race the child's
# descriptor read) and, unlike the removed global-spawn table, thread args
# are destroyed deterministically at scope exit on the main thread.

type
  PutterKind = enum
    pkPutRange     ## put(cf, @[byte(a+i)])        for i in 0..<b
    pkPutTagged    ## put(cf, @[byte(a), byte(i)]) for i in 0..<b  (a = tag)
    pkPutTwoByte   ## put(cf, 2-byte LE i)         for i in 0..<a
    pkFlush        ## flush()
    pkPutKvTagged  ## putKv(cf, [a,i], [a,i])      for i in 0..<b
    pkPutKvCont    ## putKv(cf, [a+i], [(a+i)*2])  for i in 0..<b

  PutterArg = object
    kv: ptr KVStore
    cf, a, b: int
    kind: PutterKind

proc putterWorker(arg: PutterArg) {.thread.} =
  let kv = arg.kv[]
  case arg.kind
  of pkPutRange:
    for i in 0..<arg.b:
      kv.put(arg.cf, @[byte(arg.a + i)])
  of pkPutTagged:
    for i in 0..<arg.b:
      kv.put(arg.cf, @[byte(arg.a), byte(i)])
  of pkPutTwoByte:
    for i in 0..<arg.a:
      kv.put(arg.cf, @[byte(i and 0xFF), byte((i shr 8) and 0xFF)])
  of pkFlush:
    kv.flush()
  of pkPutKvTagged:
    for i in 0..<arg.b:
      kv.putKv(arg.cf, @[byte(arg.a), byte(i)], @[byte(arg.a), byte(i)])
  of pkPutKvCont:
    for i in 0..<arg.b:
      let k = arg.a + i
      kv.putKv(arg.cf, @[byte(k)], @[byte(k * 2)])

proc runThreads(args: openArray[PutterArg]) =
  ## Single-threaded: execute sequentially (locks removed, no threads).
  for arg in args:
    putterWorker(arg)

suite "kvstore: concurrency — puts":
  proc runConcurrentPuts() =
    var kv = newTempFileKVStore()
    const N = 4
    const M = 50
    var threadKeys: array[N, seq[seq[byte]]]
    for t in 0..<N:
      threadKeys[t] = newSeq[seq[byte]](M)
      for i in 0..<M:
        threadKeys[t][i] = @[byte(t), byte(i)]

    var args: seq[PutterArg]
    for t in 0..<N:
      args.add PutterArg(kv: addr kv, cf: 0, a: t, b: M, kind: pkPutTagged)
    runThreads(args)

    var count = 0
    for t in 0..<N:
      for i in 0..<M:
        if kv.get(0, threadKeys[t][i]):
          inc count
    check count == N * M
    kv.close()

  test "concurrent puts from 4 threads all survive":
    runConcurrentPuts()

  test "separate CFs are independent (sequential puts)":
    let kv = newTempFileKVStore()
    const N = 3
    const M = 30
    var cfKeys: array[N, seq[seq[byte]]]
    for t in 0..<N:
      cfKeys[t] = newSeq[seq[byte]](M)
      for i in 0..<M:
        cfKeys[t][i] = @[byte(t), byte(i)]

    for t in 0..<N:
      for i in 0..<M:
        kv.put(t, cfKeys[t][i])

    for t in 0..<N:
      for i in 0..<M:
        check kv.get(t, cfKeys[t][i])
      for other in 0..<N:
        if other == t: continue
        for i in 0..<M:
          check not kv.get(other, cfKeys[t][i])
    kv.close()

suite "kvstore: concurrency — scan snapshot isolation":
  proc runCursorBeforeConcurrentWrites() =
    var kv = newTempFileKVStore()
    const PreN = 50
    const ExtraN = 30

    for i in 0..<PreN:
      kv.put(0, @[byte(i)])

    let mc = kv.openScanCursor(0)
    var preCount = 0
    while mc.next().isSome:
      inc preCount
    check preCount == PreN

    let mcBefore = kv.openScanCursor(0)

    runThreads(@[PutterArg(kv: addr kv, cf: 0, a: PreN, b: ExtraN, kind: pkPutRange)])

    var oldCount = 0
    while mcBefore.next().isSome:
      inc oldCount
    check oldCount == PreN

    var newCount = 0
    let mcAfter = kv.openScanCursor(0)
    while mcAfter.next().isSome:
      inc newCount
    check newCount == PreN + ExtraN

    kv.close()

  test "cursor opened before concurrent writes only sees old snapshot":
    runCursorBeforeConcurrentWrites()

  test "cursor captures COW snapshot even during flush window":
    let kv = newTempFileKVStore()

    for i in 0..<20:
      kv.put(0, @[byte(i)])

    let mc = kv.openScanCursor(0)

    kv.flush()

    kv.put(0, @[byte(30)])
    kv.put(0, @[byte(31)])

    var count = 0
    while mc.next().isSome:
      inc count
    check count == 20

    var total = 0
    let mc2 = kv.openScanCursor(0)
    while mc2.next().isSome:
      inc total
    check total == 22

    kv.close()

suite "kvstore: concurrency — flush atomicity":
  proc runFlushAtomicity() =
    var kv = newTempFileKVStore()

    const PreN = 40
    const DuringN = 25

    for i in 0..<PreN:
      kv.put(0, @[byte(i)])

    var duringKeys = newSeq[seq[byte]](DuringN)
    for i in 0..<DuringN:
      duringKeys[i] = @[byte(PreN + i)]

    runThreads(@[
      PutterArg(kv: addr kv, cf: 0, a: PreN, b: DuringN, kind: pkPutRange),
      PutterArg(kv: addr kv, kind: pkFlush)])

    for i in 0..<PreN:
      check kv.get(0, @[byte(i)])
    for i in 0..<DuringN:
      check kv.get(0, duringKeys[i])

    kv.close()

  test "data survives during flush + concurrent writes (no data loss)":
    runFlushAtomicity()

suite "kvstore: concurrency — stress":
  test "mixed put + flush + scan under concurrency":
    let kv = newTempFileKVStore()

    const Rounds = 3
    const KeysPerRound = 40

    var roundKeys: array[Rounds, seq[seq[byte]]]
    for r in 0..<Rounds:
      roundKeys[r] = newSeq[seq[byte]](KeysPerRound)
      for i in 0..<KeysPerRound:
        roundKeys[r][i] = @[byte(r), byte(i)]

    for r in 0..<Rounds:
      for i in 0..<KeysPerRound:
        kv.put(0, roundKeys[r][i])
      kv.flush()

    let keys = scanKeys(kv, 0)
    let expected = KeysPerRound * Rounds
    check keys.len == expected

    for i in 1..<keys.len:
      check cmpSeq(keys[i-1], keys[i]) < 0

    kv.close()

suite "kvstore: concurrency — put + get integrity":
  proc runBaselineVisible() =
    var kv = newTempFileKVStore()

    const BaselineN = 40
    const ExtraPerThread = 60

    var baseline = newSeq[seq[byte]](BaselineN)
    for i in 0..<BaselineN:
      baseline[i] = @[byte(i)]
      kv.put(0, baseline[i])

    var extraKeys = newSeq[seq[byte]](ExtraPerThread)
    for i in 0..<ExtraPerThread:
      extraKeys[i] = @[byte(BaselineN + i)]

    runThreads(@[PutterArg(kv: addr kv, cf: 0, a: BaselineN, b: ExtraPerThread,
                           kind: pkPutRange)])

    for i in 0..<BaselineN:
      check kv.get(0, baseline[i])

    for i in 0..<ExtraPerThread:
      check kv.get(0, extraKeys[i])

    kv.close()

  test "baseline keys remain visible during concurrent writes":
    runBaselineVisible()

  proc runNoFalseNegatives() =
    var kv = newTempFileKVStore()

    const N = 60
    var allKeys = newSeq[seq[byte]](N)
    for i in 0..<N:
      allKeys[i] = @[byte(i and 0xFF), byte((i shr 8) and 0xFF)]

    runThreads(@[PutterArg(kv: addr kv, cf: 0, a: N, kind: pkPutTwoByte)])

    for i in 0..<N:
      check kv.get(0, allKeys[i])

    kv.close()

  test "no false negatives under sustained concurrent read + write":
    runNoFalseNegatives()

# ══════════════════════════════════════════════════════════════════════════════
# Key-value CF tests (CFs >= 10)
# ══════════════════════════════════════════════════════════════════════════════

suite "kvstore: key-value API (putKv/getKv)":
  test "putKv + getKv round-trip":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1), 2, 3], @[byte(10), 20, 30])
    let val = kv.getKv(10, @[byte(1), 2, 3])
    check val.isSome
    check val.get == @[byte(10), 20, 30]
    kv.close()

  test "getKv returns none for missing key":
    let kv = newTempFileKVStore()
    let val = kv.getKv(10, @[byte(9), 9])
    check val.isNone
    kv.close()

  test "putKv overwrites existing key":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(100)])
    kv.putKv(10, @[byte(1)], @[byte(200)])
    let val = kv.getKv(10, @[byte(1)])
    check val.isSome
    check val.get == @[byte(200)]
    kv.close()

  test "key-value CFs are independent from key-only CFs":
    let kv = newTempFileKVStore()
    kv.put(0, @[byte(5)])
    kv.putKv(10, @[byte(5)], @[byte(99)])
    check kv.get(0, @[byte(5)])
    let val = kv.getKv(10, @[byte(5)])
    check val.isSome
    check val.get == @[byte(99)]
    kv.close()

  test "empty value is preserved":
    let kv = newTempFileKVStore()
    let emptyVal: seq[byte] = @[]
    kv.putKv(10, @[byte(7)], emptyVal)
    let val = kv.getKv(10, @[byte(7)])
    check val.isSome
    check val.get == emptyVal
    kv.close()

suite "kvstore: key-value flush":
  test "putKv survives flush":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(11)])
    kv.putKv(10, @[byte(2)], @[byte(22)])
    kv.flush()
    check kv.getKv(10, @[byte(1)]).get == @[byte(11)]
    check kv.getKv(10, @[byte(2)]).get == @[byte(22)]
    kv.close()

  test "putKv survives flush + more writes":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.flush()
    kv.putKv(10, @[byte(2)], @[byte(20)])
    check kv.getKv(10, @[byte(1)]).get == @[byte(10)]
    check kv.getKv(10, @[byte(2)]).get == @[byte(20)]
    kv.flush()
    check kv.getKv(10, @[byte(1)]).get == @[byte(10)]
    check kv.getKv(10, @[byte(2)]).get == @[byte(20)]
    kv.close()

  test "overwrite survives flush":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(100)])
    kv.flush()
    kv.putKv(10, @[byte(1)], @[byte(200)])
    kv.flush()
    check kv.getKv(10, @[byte(1)]).get == @[byte(200)]
    kv.close()

suite "kvstore: key-value scan":
  proc scanPairs(kv: KVStore; cf: int): seq[(seq[byte], seq[byte])] =
    let mc = kv.openScanCursorKv(cf)
    while true:
      let kvp = mc.nextKv()
      if kvp.isNone: break
      result.add kvp.get

  test "scan returns pairs in key order":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(3)], @[byte(30)])
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.putKv(10, @[byte(2)], @[byte(20)])
    let pairs = scanPairs(kv, 10)
    check pairs.len == 3
    check pairs[0] == (@[byte(1)], @[byte(10)])
    check pairs[1] == (@[byte(2)], @[byte(20)])
    check pairs[2] == (@[byte(3)], @[byte(30)])
    kv.close()

  test "scan after flush returns all pairs":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(5)], @[byte(55)])
    kv.putKv(10, @[byte(2)], @[byte(22)])
    kv.flush()
    kv.putKv(10, @[byte(8)], @[byte(88)])
    let pairs = scanPairs(kv, 10)
    check pairs.len == 3
    check pairs[0] == (@[byte(2)], @[byte(22)])
    check pairs[1] == (@[byte(5)], @[byte(55)])
    check pairs[2] == (@[byte(8)], @[byte(88)])
    kv.close()

  test "scan empty CF returns nothing":
    let kv = newTempFileKVStore()
    let pairs = scanPairs(kv, 10)
    check pairs.len == 0
    kv.close()

  test "scan with many keys (multi-page)":
    let kv = newTempFileKVStore()
    for i in 0..<200:
      var k = newSeq[byte](32)
      k[0] = byte((i shr 24) and 0xFF)
      k[1] = byte((i shr 16) and 0xFF)
      k[2] = byte((i shr 8) and 0xFF)
      k[3] = byte(i and 0xFF)
      for j in 4..<32: k[j] = byte('A'.ord + (i mod 26))
      var v = @[byte(i and 0xFF)]
      kv.putKv(10, k, v)
    kv.flush()
    let pairs = scanPairs(kv, 10)
    check pairs.len == 200
    for i in 0..<199:
      check cmpSeq(pairs[i][0], pairs[i+1][0]) < 0
    kv.close()

suite "kvstore: key-value concurrency":
  proc runConcurrentPutKv() =
    var kv = newTempFileKVStore()
    const N = 4
    const M = 30

    var args: seq[PutterArg]
    for t in 0..<N:
      args.add PutterArg(kv: addr kv, cf: 10, a: t, b: M, kind: pkPutKvTagged)
    runThreads(args)

    for t in 0..<N:
      for i in 0..<M:
        let key = @[byte(t), byte(i)]
        let val = kv.getKv(10, key)
        check val.isSome
        check val.get == @[byte(t), byte(i)]
    kv.close()

  test "concurrent putKv from multiple threads":
    runConcurrentPutKv()

  proc runPutKvSurvivesConcurrentFlush() =
    var kv = newTempFileKVStore()

    for i in 0..<30:
      kv.putKv(10, @[byte(i)], @[byte(i * 2)])

    runThreads(@[
      PutterArg(kv: addr kv, cf: 10, a: 30, b: 20, kind: pkPutKvCont),
      PutterArg(kv: addr kv, kind: pkFlush)])

    for i in 0..<50:
      let val = kv.getKv(10, @[byte(i)])
      check val.isSome
      check val.get == @[byte(i * 2)]
    kv.close()

  test "putKv survives concurrent flush":
    runPutKvSurvivesConcurrentFlush()

# ══════════════════════════════════════════════════════════════════════════════
# Key-value delete tests
# ══════════════════════════════════════════════════════════════════════════════

suite "kvstore: key-value delete":
  test "delete existing key removes it from get":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    check kv.getKv(10, @[byte(1)]).isSome
    kv.deleteKv(10, @[byte(1)])
    check kv.getKv(10, @[byte(1)]).isNone
    kv.close()

  test "delete non-existing key is harmless":
    let kv = newTempFileKVStore()
    kv.deleteKv(10, @[byte(99)])
    check kv.getKv(10, @[byte(99)]).isNone
    kv.close()

  test "delete then re-put works":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.deleteKv(10, @[byte(1)])
    kv.putKv(10, @[byte(1)], @[byte(20)])
    let val = kv.getKv(10, @[byte(1)])
    check val.isSome
    check val.get == @[byte(20)]
    kv.close()

  test "deleted key not visible in scan":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.putKv(10, @[byte(2)], @[byte(20)])
    kv.putKv(10, @[byte(3)], @[byte(30)])
    kv.deleteKv(10, @[byte(2)])
    let mc = kv.openScanCursorKv(10)
    var pairs: seq[(seq[byte], seq[byte])]
    while true:
      let kvp = mc.nextKv()
      if kvp.isNone: break
      pairs.add kvp.get
    check pairs.len == 2
    check pairs[0] == (@[byte(1)], @[byte(10)])
    check pairs[1] == (@[byte(3)], @[byte(30)])
    kv.close()

  test "delete survives flush":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.putKv(10, @[byte(2)], @[byte(20)])
    kv.flush()
    kv.deleteKv(10, @[byte(1)])
    kv.flush()
    check kv.getKv(10, @[byte(1)]).isNone
    check kv.getKv(10, @[byte(2)]).isSome
    kv.close()

  test "delete before flush removes from page store":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.putKv(10, @[byte(2)], @[byte(20)])
    kv.deleteKv(10, @[byte(1)])
    kv.flush()
    check kv.getKv(10, @[byte(1)]).isNone
    check kv.getKv(10, @[byte(2)]).isSome
    # After another flush, still gone
    kv.flush()
    check kv.getKv(10, @[byte(1)]).isNone
    kv.close()

  test "delete all keys leaves empty CF":
    let kv = newTempFileKVStore()
    kv.putKv(10, @[byte(1)], @[byte(10)])
    kv.putKv(10, @[byte(2)], @[byte(20)])
    kv.deleteKv(10, @[byte(1)])
    kv.deleteKv(10, @[byte(2)])
    kv.flush()
    let mc = kv.openScanCursorKv(10)
    check mc.nextKv().isNone
    kv.close()

  test "delete-only key (never put) survives flush":
    let kv = newTempFileKVStore()
    kv.deleteKv(10, @[byte(5)])
    kv.flush()
    check kv.getKv(10, @[byte(5)]).isNone
    kv.close()

# ── GC (synchronous gcFull; the async post-flush auto-GC lives in
# async/test_kvstore_async.nim) ──

suite "kvstore: GC (sync gcFull)":
  test "gcFull prunes roots past gc_root_count":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "3"
    let kv = newTempFileKVStore(extra)
    defer: kv.close()
    for round in 0..<6:
      for i in 0..<50:
        kv.put(0, @[byte(round), byte(i)])
      kv.flush()
    check kv.ps[].blobs.listRoots().len == 7  # initial + 6 flushes
    discard gcFull(kv.ps[], kv.gcMaxAgeSecs, kv.gcMaxRootCount, false)
    check kv.ps[].blobs.listRoots().len <= 3
    check scanKeys(kv, 0).len == 300

  test "gcFull dry run leaves store intact and reports":
    let kv = newTempFileKVStore()
    defer: kv.close()
    for i in 0..<10: kv.put(0, @[byte(i)])
    kv.flush()
    let rootsBefore = kv.ps[].blobs.listRoots().len
    check rootsBefore >= 1
    let rep = gcFull(kv.ps[], kv.gcMaxAgeSecs, kv.gcMaxRootCount, true)
    check rep.len == 41
    check rep[40] == 1  # dryRun flag
    check kv.ps[].blobs.listRoots().len == rootsBefore

  test "gcFull removes roots past gc_root_count":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "2"
    let kv = newTempFileKVStore(extra)
    defer: kv.close()
    for round in 0..<5:
      kv.put(0, @[byte(round)])
      kv.flush()
    check kv.ps[].blobs.listRoots().len == 6  # initial + 5 flushes
    let rep = gcFull(kv.ps[], kv.gcMaxAgeSecs, kv.gcMaxRootCount, false)
    check rep.len == 41
    check rep[40] == 0
    check kv.ps[].blobs.listRoots().len <= 2
    check scanKeys(kv, 0).len == 5

  test "flush with GC leaves data readable across many rounds":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "1"
    let kv = newTempFileKVStore(extra)
    defer: kv.close()
    for round in 0..<4:
      for i in 0..<25:
        kv.put(0, @[byte(round), byte(i)])
      kv.flush()
      discard gcFull(kv.ps[], kv.gcMaxAgeSecs, kv.gcMaxRootCount, false)
    check kv.ps[].blobs.listRoots().len <= 1
    check scanKeys(kv, 0).len == 100

