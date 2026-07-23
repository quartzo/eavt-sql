## tests.nim — Unit tests for nim-kvstore internals.
##
## Run with: nim c -r --mm:arc --threads:off --noNimblePath \
##   --path:../nim-blobstore tests.nim

import std/[unittest, options, tables, strutils, math, os, times]

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all
import ./abi
import ./pages
import ./backend
import ./kvstore
import ./scheme
import ./page_cursor

# Helper: collect keys from streaming merged cursor
proc scanKeys(kv: KVStore; cf: int; prefix: seq[byte] = @[]): seq[seq[byte]] =
  let mc = kv.openScanCursor(cf)
  while true:
    let k = mc.next()
    if k.isNone: break
    let key = k.get
    if prefix.len > 0 and (key.len < prefix.len or key[0..<prefix.len] != prefix): continue
    result.add key

# ═══════════════════════════════════════════════════════════════════════════════
# Page serialization tests
# ═══════════════════════════════════════════════════════════════════════════════

suite "page serialization":
  test "empty page":
    let keys: seq[seq[byte]] = @[]
    let pages = buildPages(keys)
    check pages.len == 0

  test "single key":
    let keys = @[@[byte 1, 2, 3]]
    let pages = buildPages(keys)
    check pages.len == 1
    let decoded = deserializePage(pages[0][1])
    check decoded == keys

  test "prefix compression":
    let keys = @[
      @[byte 0x65, 0x6e, 0x74, 0x69, 0x74, 0x79, 0x3a],  # "entity:"
      @[byte 0x65, 0x6e, 0x74, 0x69, 0x74, 0x79, 0x3b],  # "entity;"
    ]
    let pages = buildPages(keys)
    check pages.len == 1
    let decoded = deserializePage(pages[0][1])
    check decoded == keys

  test "varint round-trip":
    var buf: seq[byte] = @[]
    for v in [0, 1, 127, 128, 255, 256, 16383, 16384, 1000000]:
      writeVarint(buf, v)
    var offset = 0
    for expected in [0, 1, 127, 128, 255, 256, 16383, 16384, 1000000]:
      let (v, next) = readVarint(buf, offset)
      check v == expected
      offset = next

  test "large keys trigger page split":
    var keys: seq[seq[byte]] = @[]
    for i in 0..<100:
      var k: seq[byte] = @[]
      let b = byte(0x41 + (i mod 26))
      for _ in 0..<5000:
        k.add b
      keys.add k
    let pages = buildPages(keys)
    check pages.len > 1
    var all: seq[seq[byte]] = @[]
    for (_, data) in pages:
      all.add deserializePage(data)
    check all == keys

  test "binary keys with null bytes":
    let keys = @[
      @[byte 0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF],
      @[byte 0x00, 0x00, 0x00, 0x05, 0xFF, 0xFE],
      @[byte 0x00, 0x00, 0x00, 0x0A, 0x00, 0x01],
    ]
    let pages = buildPages(keys)
    let decoded = deserializePage(pages[0][1])
    check decoded == keys

# ═══════════════════════════════════════════════════════════════════════════════
# Root serialization tests
# ═══════════════════════════════════════════════════════════════════════════════

suite "root serialization":

  test "serialize/deserialize 4 CFs":
    var trees: seq[CfTree] = @[]
    for i in 0..<4:
      var uuid: array[16, byte]
      uuid[0] = byte(i + 1)
      trees.add CfTree(rootUuid: uuid, height: uint8(i), numLeaves: uint32(i * 10))
    let data = serializeRoot(trees)
    check data.len == 8 + 4 * 21  # header + 4 CFs
    let decoded = deserializeRoot(data)
    check decoded.len == 4
    for i in 0..<4:
      check decoded[i].rootUuid[0] == byte(i + 1)
      check decoded[i].height == uint8(i)
      check decoded[i].numLeaves == uint32(i * 10)

  test "empty root":
    let trees: seq[CfTree] = @[]
    let data = serializeRoot(trees)
    check data.len == 8  # just header
    let decoded = deserializeRoot(data)
    check decoded.len == 0

  test "makeRootName produces unsigned hex":
    let name = makeRootName()
    check name.startsWith("root_")
    let hex = name[5..^1]
    check hex.len == 16
    check not hex.startsWith("-")  # CRITICAL: no minus sign!
    # parseHexInt returns signed int64 for high-bit values — that's OK
    let val = cast[uint64](parseHexInt(hex))
    check val > 0'u64  # as unsigned, should be positive

# ═══════════════════════════════════════════════════════════════════════════════
# seq[byte] comparison tests
# ═══════════════════════════════════════════════════════════════════════════════

suite "seq[byte] comparison":

  test "cmpSeq basic":
    check cmpSeq(@[byte 1], @[byte 2]) < 0
    check cmpSeq(@[byte 2], @[byte 1]) > 0
    check cmpSeq(@[byte 1], @[byte 1]) == 0

  test "cmpSeq different lengths":
    check cmpSeq(@[byte 1, 2], @[byte 1]) > 0
    check cmpSeq(@[byte 1], @[byte 1, 2]) < 0

  test "cmpSeq empty":
    check cmpSeq(@[], @[byte 1]) < 0
    check cmpSeq(@[byte 1], @[]) > 0
    check cmpSeq(@[], @[]) == 0

  test "cmpSeq binary with null bytes":
    let a = @[byte 0x00, 0x00, 0x00, 0x05]
    let b = @[byte 0x00, 0x00, 0x00, 0x0A]
    check cmpSeq(a, b) < 0
    check cmpSeq(b, a) > 0

# ═══════════════════════════════════════════════════════════════════════════════
# Config parsing tests
# ═══════════════════════════════════════════════════════════════════════════════

suite "config parsing":

  test "parseConfig basic":
    let keys = cast[CStringArr](allocShared0(2 * sizeof(cstring)))
    let vals = cast[CStringArr](allocShared0(2 * sizeof(cstring)))
    keys[0] = "backend"
    vals[0] = "memory"
    keys[1] = "path"
    vals[1] = "/tmp/db"
    let config = parseConfig(keys, vals, 2.csize_t)
    check config["backend"] == "memory"
    check config["path"] == "/tmp/db"
    deallocShared(keys)
    deallocShared(vals)

  test "parseConfig empty":
    let config = parseConfig(nil, nil, 0.csize_t)
    check config.len == 0

  test "parseConfig with nil entries":
    let keys = cast[CStringArr](allocShared0(2 * sizeof(cstring)))
    let vals = cast[CStringArr](allocShared0(2 * sizeof(cstring)))
    keys[0] = "backend"
    vals[0] = nil
    keys[1] = nil
    vals[1] = "value"
    let config = parseConfig(keys, vals, 2.csize_t)
    check config.len == 0  # nil entries skipped
    deallocShared(keys)
    deallocShared(vals)

# ═══════════════════════════════════════════════════════════════════════════════
# Lifecycle tests — isolate open/close use-after-free
# ═══════════════════════════════════════════════════════════════════════════════

proc makeConfig(t: Table[string, string]): tuple[keys: CStringArr, vals: CStringArr, count: cint] =
  let n = t.len
  result.keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  result.vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  result.count = n.cint
  var i = 0
  for k, v in t:
    result.keys[i] = k.cstring
    result.vals[i] = v.cstring
    inc i

proc freeConfig(cfg: tuple[keys: CStringArr, vals: CStringArr, count: cint]) =
  deallocShared(cfg.keys)
  deallocShared(cfg.vals)

suite "lifecycle: page-store open/close":
  test "single open/close memory":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    var vt = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    check err == ErrOk
    if vt != nil:
      closePageStore(vt)
    freeConfig(cfg)

  test "5 open/close cycles memory":
    for i in 0..<5:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      var vt = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check vt != nil
      if vt != nil:
        closePageStore(vt)
      freeConfig(cfg)

  test "3 open/write/scan/close cycles memory":
    for i in 0..<3:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      var vt = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check vt != nil
      if vt != nil:
        let keys = getKeysInPrefix(vt[], 0, newSeq[byte]())
        check keys.len == 0
        closePageStore(vt)
      freeConfig(cfg)

suite "lifecycle: blobstore memory alone":
  test "10 open/close cycles":
    for i in 0..<10:
      let bs = newMemBlobStore()
      check bs != nil

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore integration tests — put, get, scan, flush end-to-end
# ═══════════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════════
# Scheme evaluator tests
# ═══════════════════════════════════════════════════════════════════════════════

type
  NilHost = ref object of HostFns
  AddHost = ref object of HostFns

method call(h: NilHost; n: string; a: seq[SExpr]): EvalStep = done(newVoid())
method isNative(h: NilHost; n: string): bool = false

method call(h: AddHost; n: string; a: seq[SExpr]): EvalStep =
  if a.len == 2 and a[0].kind == sInt and a[1].kind == sInt:
    done(SExpr(kind: sInt, ival: a[0].ival + a[1].ival))
  else: done(newVoid())
method isNative(h: AddHost; n: string): bool = n == "add"

proc se(expr: SExpr; host: HostFns = nil): SExpr =
  var env = newEnvironment()
  eval(SchemeProgram(body: expr), env, if host == nil: NilHost() else: host)

proc ses(expr: SExpr; host: HostFns = nil): string = $(se(expr, host))

suite "scheme.literals":
  test "void":       check ses(newVoid()) == "#void"
  test "bool true":  check ses(newBool(true)) == "#t"
  test "bool false": check ses(newBool(false)) == "#f"
  test "int":        check ses(SExpr(kind: sInt, ival: 42)) == "42"

suite "scheme.begin":
  test "int":        check ses(parse"(begin 42)") == "42"
  test "last":       check ses(parse"(begin 1 2 3)") == "3"
  test "empty":      check ses(parse"(begin)") == "#void"
  test "multiple":   check ses(parse"(begin 1 2 3 4 5)") == "5"

suite "scheme.when":
  test "true":       check ses(parse"(when #t 42)") == "42"
  test "false":      check ses(parse"(when #f 42)") == "#void"
  test "true body":  check ses(parse"(when #t 1 2 3)") == "3"

suite "scheme.if":
  test "true":       check ses(parse"(if #t 42 99)") == "42"
  test "false":      check ses(parse"(if #f 42 99)") == "99"
  test "no else":    check ses(parse"(if #f 42)") == "#void"

suite "scheme.set":
  test "with when":  check ses(parse"(begin (set! x 10) (when #t x))") == "10"
  test "overwrite":  check ses(parse"(begin (set! x 1) (set! x 2) x)") == "2"

suite "scheme.not":
  test "true":       check ses(parse"(not #t)") == "#f"
  test "false":      check ses(parse"(not #f)") == "#t"

suite "scheme.and":
  test "both true":  check ses(parse"(and #t #t)") == "#t"
  test "true false": check ses(parse"(and #t #f)") == "#f"
  test "single":     check ses(parse"(and #t)") == "#t"
  test "zero":       check ses(parse"(and)") == "#t"
  test "three":      check ses(parse"(and #t #t #t)") == "#t"
  test "short circuit": check ses(parse"(and #t #f #t)") == "#f"

suite "scheme.or":
  test "both true":  check ses(parse"(or #t #t)") == "#t"
  test "true false": check ses(parse"(or #t #f)") == "#t"
  test "both false": check ses(parse"(or #f #f)") == "#f"
  test "single":     check ses(parse"(or #t)") == "#t"
  test "zero":       check ses(parse"(or)") == "#f"
  test "three":      check ses(parse"(or #f #f #t)") == "#t"

suite "scheme.let":
  test "simple":     check ses(parse"(let ((x 42)) x)") == "42"
  test "multiple":   check ses(parse"(let ((a 1) (b 2) (c 3)) c)") == "3"
  test "star seq":   check ses(parse"(let* ((a 10) (b a)) b)") == "10"
  test "star chain": check ses(parse"(let* ((a 1) (b a) (c b)) c)") == "1"

suite "scheme.host":
  test "call add":   check ses(parse"(add 2 3)", AddHost()) == "5"
  test "nested":     check ses(parse"(add (add 1 2) (add 3 4))", AddHost()) == "10"

suite "scheme.nested":
  test "when when":  check ses(parse"(when #t (when #t 42))") == "42"
  test "if if":      check ses(parse"(if (if #f #t #f) 42 99)") == "99"
  test "when if":    check ses(parse"(when #t (if #t 1 2))") == "1"

suite "scheme.assert":
  test "pass":       check ses(parse"(begin (assert #t) 42)") == "42"
  test "fail":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse("(assert #f \"boom\")")), env, NilHost())

proc Q(s: string): string = "\"" & s & "\""

suite "scheme.parse":
  test "negative int": check ses(parse"-7") == "-7"
  test "string":       check ses(parse(Q("hello"))) == Q("hello")
  test "empty string": check ses(parse(Q(""))) == Q("")
  test "float":
    let r = se(parse"3.14")
    check r.kind == sFloat and abs(r.fval - 3.14) < 0.001

suite "scheme.errors":
  test "unbound variable":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse"x"), env, NilHost())
  test "unknown function":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse"(nope 1 2)"), env, NilHost())

# ══════════════════════════════════════════════════════════════════════════════
# PageStore Nim API tests (newPageStore → ptr PageStoreInner directly)
# ══════════════════════════════════════════════════════════════════════════════

suite "pagestore: Nim API (newPageStore)":
  test "single open/close memory":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check ps != nil
    check err == ErrOk
    closePageStore(ps)

  test "getKeysInPrefix on empty store returns empty":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check ps != nil
    check getKeysInPrefix(ps[], 0, newSeq[byte]()).len == 0
    closePageStore(ps)

  test "put blob + getKeysInPrefix finds key":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check ps != nil
    # Write a key via blobPut + commitMerge
    let keys = @[@[byte(1), 2, 3], @[byte(4), 5]]
    commitMerge(ps[], @[(0, keys)], false)
    let scanned = getKeysInPrefix(ps[], 0, newSeq[byte]())
    check scanned.len == 2
    check scanned[0] == @[byte(1), 2, 3]
    check scanned[1] == @[byte(4), 5]
    closePageStore(ps)

  test "commitMerge + keyExists round-trip":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    let keys = @[@[byte(7), 8]]
    commitMerge(ps[], @[(0, keys)], false)
    check keyExists(ps[], 0, @[byte(7), 8])
    check not keyExists(ps[], 0, @[byte(7)])
    closePageStore(ps)

  test "5 open/close cycles via newPageStore":
    for i in 0..<5:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check ps != nil
      closePageStore(ps)

# ══════════════════════════════════════════════════════════════════════════════
# KVStore Nim API tests (KVStore ref directly)
# ══════════════════════════════════════════════════════════════════════════════

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

suite "page_cursor: forward scan":
  test "empty page store → atEnd":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check ps != nil
    let c = newPageStoreCursor(ps, 0)
    check c != nil
    check c.atEnd
    closePageStore(ps)

  test "single leaf with keys → peek/next":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    let keys = @[@[byte(1), 2, 3], @[byte(4), 5], @[byte(6)]]
    commitMerge(ps[], @[(0, keys)], false)

    let c = newPageStoreCursor(ps, 0)
    check not c.atEnd

    let k1 = c.next()
    check k1.isSome
    check k1.get == @[byte(1), 2, 3]

    let k2 = c.next()
    check k2.isSome
    check k2.get == @[byte(4), 5]

    let k3 = c.next()
    check k3.isSome
    check k3.get == @[byte(6)]

    check c.next().isNone
    check c.atEnd
    closePageStore(ps)

  test "iterate all keys":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    let keys = @[@[byte(1), 1], @[byte(1), 2], @[byte(2), 1]]
    commitMerge(ps[], @[(0, keys)], false)

    let c = newPageStoreCursor(ps, 0)
    check c.peek().get == @[byte(1), 1]
    check c.next().get == @[byte(1), 1]
    check c.next().get == @[byte(1), 2]
    check c.next().get == @[byte(2), 1]
    check c.next().isNone
    closePageStore(ps)

  test "peek returns same key":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    let keys = @[@[byte(5), 0]]
    commitMerge(ps[], @[(0, keys)], false)

    let c = newPageStoreCursor(ps, 0)
    let p1 = c.peek()
    let p2 = c.peek()
    check p1.isSome and p2.isSome
    check p1.get == p2.get
    check p1.get == @[byte(5), 0]
    closePageStore(ps)

  test "seek advances position":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let ps = newPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    var keys = newSeq[seq[byte]]()
    for i in 1..50:
      keys.add @[byte(i), 0]
    commitMerge(ps[], @[(0, keys)], false)

    let c = newPageStoreCursor(ps, 0)
    c.seek(@[byte(30), 0])
    let k = c.peek()
    check k.isSome
    check k.get[0] >= 30
    closePageStore(ps)
