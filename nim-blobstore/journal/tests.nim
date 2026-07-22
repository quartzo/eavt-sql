## nim-blobstore/journal/tests.nim
##
## Unit tests for the file-backed journal backend.
## Tests the Nim API (`Journal` ref, not C-ABI vtables).
##
## Build & run:
##   cd nim-blobstore/journal && nimble test

import std/[unittest, os, times]
import backend   # Journal, newJournal, append, readAll, truncate, len, close

var gCounter = 0

proc newTempDir(): string =
  inc gCounter
  let t = getTime()
  result = "/tmp/jtest_" & $t.toUnix() & "_" & $t.nanosecond & "_" & $gCounter
  createDir(result)

# ── Helpers ──────────────────────────────────────────────────────────────────

proc `==`(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i] != b[i]: return false
  true

proc mustOpen(path: string): Journal =
  result = newJournal(path)

# ══════════════════════════════════════════════════════════════════════════════
# open / close
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: open/close":
  test "nil path raises IOError":
    expect IOError:
      discard newJournal("")

  test "valid path opens, close does not crash":
    let td = newTempDir()
    let j = mustOpen(td)
    j.close()

  test "close nil is safe":
    var j: Journal = nil
    j.close()

  test "double close is safe":
    let td = newTempDir()
    var j = mustOpen(td)
    j.close()
    j.close()

# ══════════════════════════════════════════════════════════════════════════════
# append + read
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: append + read":
  test "single frame round-trip":
    let j = mustOpen(newTempDir())
    j.append([byte(1), 2, 3], [byte(0xAA), 0xBB, 0xCC, 0xDD])
    let frames = j.readAll()
    check frames.len == 1
    check frames[0][0] == @[byte(1), 2, 3]
    check frames[0][1] == @[byte(0xAA), 0xBB, 0xCC, 0xDD]
    j.close()

  test "three frames in insertion order":
    let j = mustOpen(newTempDir())
    for i in 1..3:
      j.append([byte(i)], [byte(i * 10)])
    let frames = j.readAll()
    check frames.len == 3
    check frames[0][0] == @[byte(1)]; check frames[0][1] == @[byte(10)]
    check frames[1][0] == @[byte(2)]; check frames[1][1] == @[byte(20)]
    check frames[2][0] == @[byte(3)]; check frames[2][1] == @[byte(30)]
    j.close()

  test "zero-length key (klen=0)":
    let j = mustOpen(newTempDir())
    j.append(newSeq[byte](), @[byte(7)])
    let frames = j.readAll()
    check frames.len == 1
    check frames[0][0].len == 0
    check frames[0][1] == @[byte(7)]
    j.close()

  test "zero-length value (vlen=0)":
    let j = mustOpen(newTempDir())
    j.append(@[byte(9), 8, 7], newSeq[byte]())
    let frames = j.readAll()
    check frames.len == 1
    check frames[0][0] == @[byte(9), 8, 7]
    check frames[0][1].len == 0
    j.close()

  test "binary data with null bytes":
    let j = mustOpen(newTempDir())
    j.append(@[byte(0), 0, 1, 0, 2], @[byte(0), 0, 0, 0, 0xFF, 0, 0])
    let frames = j.readAll()
    check frames[0][0] == @[byte(0), 0, 1, 0, 2]
    check frames[0][1] == @[byte(0), 0, 0, 0, 0xFF, 0, 0]
    j.close()

  test "large payload (> 4 KiB)":
    let j = mustOpen(newTempDir())
    var key = newSeq[byte](100)
    var val = newSeq[byte](5000)
    for i in 0..<key.len: key[i] = byte(i and 0xFF)
    for i in 0..<val.len: val[i] = byte((i * 7) and 0xFF)
    j.append(key, val)
    let frames = j.readAll()
    check frames.len == 1
    check frames[0][0] == key
    check frames[0][1] == val
    j.close()

# ══════════════════════════════════════════════════════════════════════════════
# size
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: len":
  test "empty journal → 0":
    let j = mustOpen(newTempDir())
    check j.len() == 0
    j.close()

  test "appends increase len":
    let j = mustOpen(newTempDir())
    j.append([byte(1)], [byte(2), 3])
    check j.len() == 11   # 4 + 1 + 4 + 2
    j.close()

# ══════════════════════════════════════════════════════════════════════════════
# truncate
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: truncate":
  test "after truncate, read is empty and len is 0":
    let j = mustOpen(newTempDir())
    j.append([byte(1)], [byte(2)])
    check j.readAll().len == 1
    j.truncate()
    check j.readAll().len == 0
    check j.len() == 0
    j.close()

# ══════════════════════════════════════════════════════════════════════════════
# persistence (close + reopen)
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: persistence":
  test "frames survive close + reopen":
    let td = newTempDir()
    var j1 = mustOpen(td)
    j1.append(@[byte(9), 9], @[byte(8), 8, 8])
    j1.close()
    var j2 = mustOpen(td)
    let frames = j2.readAll()
    check frames.len == 1
    check frames[0][0] == @[byte(9), 9]
    check frames[0][1] == @[byte(8), 8, 8]
    j2.close()

# ══════════════════════════════════════════════════════════════════════════════
# corruption → error (strict read)
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: corruption → error":
  test "trailing garbage after valid frames → IOError":
    let td = newTempDir()
    var j = mustOpen(td)
    j.append([byte(1)], [byte(2)])
    j.close()
    # Append garbage to the raw file
    let fpath = td / "journal" / "journal"
    var f = open(fpath, fmAppend)
    f.write("XXX")
    f.close()
    j = mustOpen(td)
    expect IOError:
      discard j.readAll()
    j.close()

  test "truncated frame (file ends mid-value) → IOError":
    let td = newTempDir()
    var j = mustOpen(td)
    j.append(@[byte(0xAB), 0xCD, 0xEF, 0x12], @[byte(1), 2, 3, 4, 5, 6])
    j.close()
    let fpath = td / "journal" / "journal"
    let good = readFile(fpath)
    # Cut to 14 bytes: [4B klen][4B key][4B vlen][2B of value] → truncated
    writeFile(fpath, good[0..13])
    j = mustOpen(td)
    expect IOError:
      discard j.readAll()
    j.close()

# ══════════════════════════════════════════════════════════════════════════════
# empty journal
# ══════════════════════════════════════════════════════════════════════════════

suite "journal: empty":
  test "brand new journal reads empty":
    let j = mustOpen(newTempDir())
    check j.readAll().len == 0
    j.close()

suite "journal: binary format":
  test "raw file contains expected framing bytes":
    let td = newTempDir()
    var j = mustOpen(td)
    j.append(@[byte(1), 2], @[byte(3), 4, 5])
    j.close()
    # Read raw file: [u32 klen=2][key 01 02][u32 vlen=3][val 03 04 05]
    let raw = readFile(td / "journal" / "journal")
    check raw.len == 13
    check ord(raw[0]) == 0; check ord(raw[1]) == 0; check ord(raw[2]) == 0; check ord(raw[3]) == 2
    check ord(raw[4]) == 1; check ord(raw[5]) == 2
    check ord(raw[6]) == 0; check ord(raw[7]) == 0; check ord(raw[8]) == 0; check ord(raw[9]) == 3
    check ord(raw[10]) == 3; check ord(raw[11]) == 4; check ord(raw[12]) == 5
    removeDir(td)

