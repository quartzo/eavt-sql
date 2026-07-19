## tests.nim — Unit tests for nim-page-store internals.
##
## Run with: nim c -r --mm:arc --threads:off --noNimblePath \
##   --path:../nim-blobstore tests.nim

import std/[unittest, options, tables, strutils]

import memory/all
import file/all
import s3/all
import journal/all
import ./abi
import ./pages
import ./spinlock
import ./backend

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
    var vt = openPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    check err == ErrOk
    if vt != nil:
      psClose(vt.handle)
      freeVtable(vt)
    freeConfig(cfg)

  test "5 open/close cycles memory":
    for i in 0..<5:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      var vt = openPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check vt != nil
      if vt != nil:
        psClose(vt.handle)
        freeVtable(vt)
      freeConfig(cfg)

  test "3 open/write/scan/close cycles memory":
    for i in 0..<3:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      var vt = openPageStore(cfg.keys, cfg.vals, cfg.count, addr err)
      check vt != nil
      if vt != nil:
        if vt.getKeysInPrefix != nil:
          var outBuf: pointer = nil
          var outLen: csize_t = 0
          discard vt.getKeysInPrefix(vt.handle, 0'u32, nil, 0.csize_t, addr outBuf, addr outLen, addr err)
          if outBuf != nil: vt.freeBuf(outBuf)
        psClose(vt.handle)
        freeVtable(vt)
      freeConfig(cfg)

suite "lifecycle: blobstore memory alone":
  test "10 open/close cycles":
    for i in 0..<10:
      var err: cint
      let cfg = makeConfig({"backend": "memory"}.toTable)
      let bs = nim_blob_memory_open(cfg.keys, cfg.vals, cfg.count, addr err)
      check bs != nil
      if bs != nil:
        var outBuf: pointer = nil
        var outLen: csize_t = 0
