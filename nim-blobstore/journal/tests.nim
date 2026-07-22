## nim-blobstore/journal/tests.nim
##
## Unit tests for the journal backend.  Every test uses the C-ABI vtable
## directly — the same interface that the page store and KV store consume.
##
## Build & run (from the repo root):
##   nim c --mm:arc --threads:on -d:release --noNimblePath \
##     --path:nim-blobstore --path:. \
##     -r nim-blobstore/journal/tests.nim

import std/[unittest, os, times]
import backend        # openJournal / closeJournal
import abi            # Err* constants, NimJournalVtablePtr, Byte, etc.

# ── helpers ──────────────────────────────────────────────────────────────────

var gCounter = 0

proc newTempDir(): string =
  inc gCounter
  let t = getTime()
  result = "/tmp/jtest_" & $t.toUnix() & "_" & $t.nanosecond & "_" & $gCounter
  createDir(result)

proc `==`(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i] != b[i]: return false
  true

# ── unpack the packed buffer returned by vt.read ─────────────────────────────

proc unpack(buf: pointer, blen: int): seq[(seq[byte], seq[byte])] =
  if buf == nil: return
  var pos = 0
  let raw = cast[ptr UncheckedArray[byte]](buf)
  while pos + 4 <= blen:
    let klen = int(uint32(raw[pos]) shl 24 or uint32(raw[pos+1]) shl 16 or
                   uint32(raw[pos+2]) shl 8 or uint32(raw[pos+3]))
    pos += 4
    var k = newSeq[byte](klen)
    for i in 0..<klen: k[i] = raw[pos + i]
    pos += klen
    let vlen = int(uint32(raw[pos]) shl 24 or uint32(raw[pos+1]) shl 16 or
                   uint32(raw[pos+2]) shl 8 or uint32(raw[pos+3]))
    pos += 4
    var v = newSeq[byte](vlen)
    for i in 0..<vlen: v[i] = raw[pos + i]
    pos += vlen
    result.add (k, v)

# ── frame reader helper (returns unpacked frames, frees buf) ─────────────────

proc readAll(vt: NimJournalVtablePtr): seq[(seq[byte], seq[byte])] =
  var buf: pointer = nil
  var blen: csize_t = 0
  var err: cint
  check vt.read(vt.handle, addr buf, addr blen, addr err) == 0
  result = unpack(buf, blen.int)
  if buf != nil: vt.freeBuf(buf)

# ══════════════════════════════════════════════════════════════════════════════
# open / close
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: open/close":
  test "nil path → nil + ErrConfig":
    var err: cint = ErrOk
    let vt = openJournal(nil, addr err)
    check vt == nil
    check err == ErrConfig

  test "empty path → nil + ErrConfig":
    var err: cint = ErrOk
    let vt = openJournal("", addr err)
    check vt == nil
    check err == ErrConfig

  test "valid path → non-nil handle, close does not crash":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    check vt != nil
    check err == ErrOk
    closeJournal(vt)

  test "close nil is safe":
    closeJournal(nil)

# ══════════════════════════════════════════════════════════════════════════════
# append + read
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: append + read":
  test "single frame round-trip":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(1), 2, 3]
    let val = [byte(0xAA), 0xBB, 0xCC, 0xDD]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 3,
                     cast[ptr Byte](unsafeAddr val[0]), 4, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 1
    check frames[0][0] == key
    check frames[0][1] == val
    closeJournal(vt)

  test "three frames in insertion order":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    for i in 1..3:
      let k = @[byte(i)]
      let v = @[byte(i * 10)]
      check vt.append(vt.handle, cast[ptr Byte](unsafeAddr k[0]), 1,
                       cast[ptr Byte](unsafeAddr v[0]), 1, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 3
    check frames[0][0] == @[byte(1)]; check frames[0][1] == @[byte(10)]
    check frames[1][0] == @[byte(2)]; check frames[1][1] == @[byte(20)]
    check frames[2][0] == @[byte(3)]; check frames[2][1] == @[byte(30)]
    closeJournal(vt)

  test "zero-length key (klen=0)":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let val = [byte(7)]
    check vt.append(vt.handle, nil, 0,
                     cast[ptr Byte](unsafeAddr val[0]), 1, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 1
    check frames[0][0].len == 0
    check frames[0][1] == @[byte(7)]
    closeJournal(vt)

  test "zero-length value (vlen=0)":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(9), 8, 7]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 3,
                     nil, 0, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 1
    check frames[0][0] == @[byte(9), 8, 7]
    check frames[0][1].len == 0
    closeJournal(vt)

  test "binary data with null bytes":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(0), 0, 1, 0, 2]
    let val = [byte(0), 0, 0, 0, 0xFF, 0, 0]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 5,
                     cast[ptr Byte](unsafeAddr val[0]), 7, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 1
    check frames[0][0] == key
    check frames[0][1] == val
    closeJournal(vt)

  test "large payload (> 4 KiB)":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    var key = newSeq[byte](100)
    var val = newSeq[byte](5000)
    for i in 0..<key.len: key[i] = byte(i and 0xFF)
    for i in 0..<val.len: val[i] = byte((i * 7) and 0xFF)
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), key.len.csize_t,
                     cast[ptr Byte](unsafeAddr val[0]), val.len.csize_t, addr err) == 0
    let frames = readAll(vt)
    check frames.len == 1
    check frames[0][0] == key
    check frames[0][1] == val
    closeJournal(vt)

# ══════════════════════════════════════════════════════════════════════════════
# size
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: size":
  test "empty journal → 0":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    var sz: uint64
    check vt.size(vt.handle, addr sz, addr err) == 0
    check sz == 0
    closeJournal(vt)

  test "appends increase size":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    var sz: uint64
    let key = [byte(1)]
    let val = [byte(2), 3]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 1,
                     cast[ptr Byte](unsafeAddr val[0]), 2, addr err) == 0
    check vt.size(vt.handle, addr sz, addr err) == 0
    check sz == 11   # 4 + 1 + 4 + 2 = 11 bytes on disk
    closeJournal(vt)

# ══════════════════════════════════════════════════════════════════════════════
# truncate
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: truncate":
  test "after truncate, read is empty and size is 0":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(1)]
    let val = [byte(2)]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 1,
                     cast[ptr Byte](unsafeAddr val[0]), 1, addr err) == 0
    check readAll(vt).len == 1
    check vt.truncate(vt.handle, addr err) == 0
    check readAll(vt).len == 0
    var sz: uint64
    check vt.size(vt.handle, addr sz, addr err) == 0
    check sz == 0
    closeJournal(vt)

# ══════════════════════════════════════════════════════════════════════════════
# persistence (close + reopen)
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: persistence":
  test "frames survive close + reopen":
    let td = newTempDir()
    var err: cint
    # Write via first handle
    var vt1 = openJournal(td.cstring, addr err)
    let key = [byte(9), 9]
    let val = [byte(8), 8, 8]
    check vt1.append(vt1.handle, cast[ptr Byte](unsafeAddr key[0]), 2,
                      cast[ptr Byte](unsafeAddr val[0]), 3, addr err) == 0
    closeJournal(vt1)
    # Reopen — data must still be there
    var vt2 = openJournal(td.cstring, addr err)
    let frames = readAll(vt2)
    check frames.len == 1
    check frames[0][0] == key
    check frames[0][1] == val
    closeJournal(vt2)

# ══════════════════════════════════════════════════════════════════════════════
# corruption — the read must ERROR, not silently discard
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: corruption → error":
  test "trailing garbage after valid frames → ErrIo":
    let td = newTempDir()
    var err: cint
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(1)]
    let val = [byte(2)]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 1,
                     cast[ptr Byte](unsafeAddr val[0]), 1, addr err) == 0
    closeJournal(vt)

    # Manually append 3 garbage bytes to the journal file
    let filePath = td / "journal" / "journal"
    var f = open(filePath, fmAppend)
    f.write("XXX")
    f.close()

    var vt2 = openJournal(td.cstring, addr err)
    var buf: pointer = nil
    var blen: csize_t = 0
    let rc = vt2.read(vt2.handle, addr buf, addr blen, addr err)
    check rc == -1
    check err == ErrIo
    closeJournal(vt2)

  test "truncated frame (file ends mid-value) → ErrIo":
    let td = newTempDir()
    var err: cint
    # Write a valid frame, then overwrite the file to cut it short
    let vt = openJournal(td.cstring, addr err)
    let key = [byte(0xAB), 0xCD, 0xEF, 0x12]
    let val = [byte(1), 2, 3, 4, 5, 6]
    check vt.append(vt.handle, cast[ptr Byte](unsafeAddr key[0]), 4,
                     cast[ptr Byte](unsafeAddr val[0]), 6, addr err) == 0
    closeJournal(vt)

    let filePath = td / "journal" / "journal"
    let good = readFile(filePath)
    # Frame bytes: [4B klen=4][4B key][4B vlen=6][6B val] = 4+4+4+6 = 18 bytes
    # Cut to 14 bytes: klen+key+vlen = 12, plus 2 bytes of value → truncated
    writeFile(filePath, good[0..13])

    var vt2 = openJournal(td.cstring, addr err)
    var buf: pointer = nil
    var blen: csize_t = 0
    let rc = vt2.read(vt2.handle, addr buf, addr blen, addr err)
    check rc == -1
    check err == ErrIo
    closeJournal(vt2)
