## nim-blobstore/file/tests.nim
##
## Unit tests for the file-backed blobstore backend.
## Tests `FileBlobStore` directly (the Nim API) — no C-ABI vtable.
##
## Build & run:
##   cd nim-blobstore/file && nimble test

import std/[unittest, os, times, options]
import backend      # FileBlobStore, newFileBlobStore, put, get, delete, list,
                    # putRoot, getRoot, listRoots, deleteRoot
import ../common    # ByteArr16

proc newTempDir(): string =
  result = "/tmp/fbtest_" & $getTime().toUnix() & "_" & $getTime().nanosecond
  createDir(result)

# ── helpers ──────────────────────────────────────────────────────────────────

proc `==`(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i] != b[i]: return false
  true

# ══════════════════════════════════════════════════════════════════════════════
# put + get
# ══════════════════════════════════════════════════════════════════════════════

suite "file: put + get":
  test "single blob round-trip":
    let s = newFileBlobStore(newTempDir())
    let data = @[byte(10), 20, 30]
    let id = s.put(data)
    let r = s.get(id)
    check r.isSome()
    check r.get() == data

  test "get missing id → none":
    let s = newFileBlobStore(newTempDir())
    var id: ByteArr16
    for i in 0..15: id[i] = 0xFF
    check s.get(id).isNone()

  test "empty blob (0 bytes)":
    let s = newFileBlobStore(newTempDir())
    let id = s.put(newSeq[byte]())
    let r = s.get(id)
    check r.isSome()
    check r.get().len == 0

  test "binary data with null bytes":
    let s = newFileBlobStore(newTempDir())
    let data = @[byte(0), 0, 1, 0, 2]
    let id = s.put(data)
    check s.get(id).get() == data

# ══════════════════════════════════════════════════════════════════════════════
# overwrite
# ══════════════════════════════════════════════════════════════════════════════

suite "file: overwrite":
  test "putAt replaces data at same id":
    let s = newFileBlobStore(newTempDir())
    var id: ByteArr16
    for i in 0..15: id[i] = byte(i)
    s.putAt(id, @[byte(1), 1, 1])
    s.putAt(id, @[byte(2), 2])
    check s.get(id).get() == @[byte(2), 2]

# ══════════════════════════════════════════════════════════════════════════════
# delete
# ══════════════════════════════════════════════════════════════════════════════

suite "file: delete":
  test "put → delete → gone":
    let s = newFileBlobStore(newTempDir())
    let data = @[byte(9)]
    let id = s.put(data)
    check s.get(id).isSome()
    s.delete(id)
    check s.get(id).isNone()

# ══════════════════════════════════════════════════════════════════════════════
# list
# ══════════════════════════════════════════════════════════════════════════════

suite "file: list":
  test "empty store → 0":
    let s = newFileBlobStore(newTempDir())
    check s.list().len == 0

  test "put 3 → list returns 3":
    let s = newFileBlobStore(newTempDir())
    let ids = [s.put(@[byte(1)]), s.put(@[byte(2)]), s.put(@[byte(3)])]
    let lst = s.list()
    check lst.len == 3
    # All 3 ids present (order undefined)
    var found: array[3, bool]
    for id in lst:
      for j, expected in ids:
        var eq = true
        for k in 0..15:
          if id[k] != expected[k]: eq = false; break
        if eq: found[j] = true
    check found == [true, true, true]

# ══════════════════════════════════════════════════════════════════════════════
# persistence (close + reopen)
# ══════════════════════════════════════════════════════════════════════════════

suite "file: persistence":
  test "blobs survive close + reopen":
    let td = newTempDir()
    var s1 = newFileBlobStore(td)
    let data = @[byte(0xAB), 0xCD, 0xEF]
    let id = s1.put(data)
    var s2 = newFileBlobStore(td)
    let r = s2.get(id)
    check r.isSome()
    check r.get() == data

# ══════════════════════════════════════════════════════════════════════════════
# roots (named blobs)
# ══════════════════════════════════════════════════════════════════════════════

suite "file: roots":
  test "putRoot + getRoot round-trip":
    let s = newFileBlobStore(newTempDir())
    s.putRoot("root_one", @[byte(7), 8, 9])
    let r = s.getRoot("root_one")
    check r.isSome()
    check r.get() == @[byte(7), 8, 9]

  test "getRoot missing → none":
    let s = newFileBlobStore(newTempDir())
    check s.getRoot("never_there").isNone()

  test "listRoots sorted":
    let s = newFileBlobStore(newTempDir())
    s.putRoot("root_c", @[])
    s.putRoot("root_a", @[])
    s.putRoot("root_b", @[])
    check s.listRoots() == @["root_a", "root_b", "root_c"]

  test "deleteRoot removes root":
    let s = newFileBlobStore(newTempDir())
    s.putRoot("temp", @[byte(1)])
    check s.getRoot("temp").isSome()
    s.deleteRoot("temp")
    check s.getRoot("temp").isNone()
