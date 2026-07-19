## tests.nim — Unit tests for nim-page-store internals.
##
## Run with: nim c -r --mm:arc --threads:off --noNimblePath \
##   --path:../nim-blobstore tests.nim

import std/[unittest, options, tables, strutils]

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all
import ./abi
import ./pages
import ./spinlock
import ./backend
import ./kvstore

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

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore integration tests — put, get, scan, flush end-to-end
# ═══════════════════════════════════════════════════════════════════════════════

suite "kvstore: open/close":
  test "open memory and close":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    check err == ErrOk
    if vt != nil:
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

suite "kvstore: put + get":
  test "put and get key in CF 0":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      let key = @[byte 1, 2, 3, 4]
      check vt.put(vt.handle, 0'u32, addr key[0], key.len.csize_t, addr err) == 0
      var present: cint = 0
      check vt.get(vt.handle, 0'u32, addr key[0], key.len.csize_t, addr present, addr err) == 0
      check present == 1
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

  test "put and get in all CFs":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      for cf in 0'u32 .. 3'u32:
        let key = @[byte cf, 0xAA, 0xBB]
        check vt.put(vt.handle, cf, addr key[0], key.len.csize_t, addr err) == 0
        var present: cint = 0
        check vt.get(vt.handle, cf, addr key[0], key.len.csize_t, addr present, addr err) == 0
        check present == 1
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

  test "get non-existent returns false":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      let key = @[byte 0xFF, 0xFF]
      var present: cint = 0
      check vt.get(vt.handle, 0'u32, addr key[0], key.len.csize_t, addr present, addr err) == 0
      check present == 0
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

suite "kvstore: scan":
  test "scan CF 0 with empty prefix finds inserted keys":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      # Insert 3 keys
      for i in 0'u32 .. 2'u32:
        let key = @[byte 0xAA, 0xBB, byte(i)]
        check vt.put(vt.handle, 0'u32, addr key[0], key.len.csize_t, addr err) == 0
      # Scan CF 0
      var outBuf: pointer = nil
      var outLen: csize_t = 0
      check vt.scan(vt.handle, 0'u32, nil, 0.csize_t, addr outBuf, addr outLen, addr err) == 0
      # Unpack: [u32 klen][key]
      var count = 0
      var pos = 0
      while pos + 4 <= outLen.int:
        let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
        pos += 4 + klen
        inc count
      if outBuf != nil: vt.freeBuf(outBuf)
      check count >= 3  # bootstrap also writes keys, so may be > 3
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

  test "scan with binary prefix filters correctly":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      # Insert matching keys
      let prefixSeq = @[byte 0x00, 0x00, 0x00, 0x05]
      for i in 0'u32 .. 2'u32:
        var k = prefixSeq
        k.add @[byte byte(i)]
        check vt.put(vt.handle, 0'u32, addr k[0], k.len.csize_t, addr err) == 0
      # Insert non-matching key
      var nk = @[byte 0xFF, 0xFF]
      check vt.put(vt.handle, 0'u32, addr nk[0], 2.csize_t, addr err) == 0
      # Scan with prefix
      var outBuf: pointer = nil
      var outLen: csize_t = 0
      check vt.scan(vt.handle, 0'u32, addr prefixSeq[0], prefixSeq.len.csize_t,
                     addr outBuf, addr outLen, addr err) == 0
      var count = 0
      var pos = 0
      while pos + 4 <= outLen.int:
        let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
        pos += 4 + klen
        inc count
      if outBuf != nil: vt.freeBuf(outBuf)
      check count == 3  # exactly 3 matching keys
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)


suite "kvstore: flush":
  test "put 3 keys, flush, scan finds all":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      let prefix = @[byte 0xCC, 0xDD]
      for i in 0'u32 .. 2'u32:
        var key = prefix
        key.add byte(i)
        check vt.put(vt.handle, 0'u32, addr key[0], key.len.csize_t, addr err) == 0
      # Scan before flush
      var outBuf: pointer = nil; var outLen: csize_t = 0
      check vt.scan(vt.handle, 0'u32, addr prefix[0], prefix.len.csize_t,
                     addr outBuf, addr outLen, addr err) == 0
      var before = 0; var pos = 0
      while pos + 4 <= outLen.int:
        let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
        pos += 4 + klen; inc before
      if outBuf != nil: vt.freeBuf(outBuf)
      check before == 3
      # Flush
      check vt.flush(vt.handle, addr err) == 0
      # Scan after flush
      outBuf = nil; outLen = 0
      check vt.scan(vt.handle, 0'u32, addr prefix[0], prefix.len.csize_t,
                     addr outBuf, addr outLen, addr err) == 0
      var after = 0; pos = 0
      while pos + 4 <= outLen.int:
        let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
        pos += 4 + klen; inc after
      if outBuf != nil: vt.freeBuf(outBuf)
      check after == 3
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

  test "put in CFs 0-3, flush, scan all CFs finds keys":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      for cf in 0'u32 .. 3'u32:
        for i in 0'u32 .. 1'u32:
          var key = @[byte cf, byte(i)]
          check vt.put(vt.handle, cf, addr key[0], key.len.csize_t, addr err) == 0
      check vt.flush(vt.handle, addr err) == 0
      for cf in 0'u32 .. 3'u32:
        var outBuf: pointer = nil; var outLen: csize_t = 0
        var cfb = @[byte cf]
        check vt.scan(vt.handle, cf, addr cfb[0], 1.csize_t,
                       addr outBuf, addr outLen, addr err) == 0
        var count = 0; var pos = 0
        while pos + 4 <= outLen.int:
          let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                       uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                       uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                       uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
          pos += 4 + klen; inc count
        if outBuf != nil: vt.freeBuf(outBuf)
        check count == 2
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)

  test "batch_write + flush + scan":
    var err: cint
    let cfg = makeConfig({"backend": "memory"}.toTable)
    let vt = openKvStore(cfg.keys, cfg.vals, cfg.count, addr err)
    check vt != nil
    if vt != nil:
      var ops: seq[byte] = @[]
      for i in 0'u32 .. 4'u32:
        let key = @[byte 0xEE, byte(i)]
        ops.add 0'u8
        let kl = key.len.uint32
        ops.add byte(kl shr 24); ops.add byte((kl shr 16) and 0xFF)
        ops.add byte((kl shr 8) and 0xFF); ops.add byte(kl and 0xFF)
        ops.add key[0]; ops.add key[1]
      check vt.batchWrite(vt.handle, addr ops[0], ops.len.csize_t, addr err) == 0
      check vt.flush(vt.handle, addr err) == 0
      var outBuf: pointer = nil; var outLen: csize_t = 0
      var pfx = @[byte 0xEE]
      check vt.scan(vt.handle, 0'u32, addr pfx[0], pfx.len.csize_t,
                     addr outBuf, addr outLen, addr err) == 0
      var count = 0; var pos = 0
      while pos + 4 <= outLen.int:
        let klen = (uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos]) shl 24 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+1]) shl 16 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+2]) shl 8 or
                     uint32(cast[ptr UncheckedArray[byte]](outBuf)[pos+3])).int
        pos += 4 + klen; inc count
      if outBuf != nil: vt.freeBuf(outBuf)
      check count == 5
      discard vt.close(vt.handle, addr err)
      freeKVVtable(vt)
    freeConfig(cfg)
