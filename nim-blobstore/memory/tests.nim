## nim-blobstore/memory/tests.nim
##
## Unit tests for the in-memory blobstore backend.
## Tests `MemBlobStore` directly (Nim trait) — no C-ABI vtables.
##
## Build & run:
##   cd nim-blobstore/memory && nimble test

import std/[unittest, tables]
import backend     # MemBlobStore
import ../common   # ByteArr16, newUuidBytes

proc `==`(a, b: ByteArr16): bool =
  for i in 0..15:
    if a[i] != b[i]: return false
  true

proc `==`(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i] != b[i]: return false
  true

# ══════════════════════════════════════════════════════════════════════════════
# basic CRUD
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: put + get":
  test "single blob round-trip":
    let b = newMemBlobStore()
    var id: ByteArr16
    newUuidBytes(addr id[0])
    let data = [byte(10), 20, 30]
    b.blobs[id] = @data
    check b.blobs.hasKey(id)
    check b.blobs[id] == @data

  test "get missing id":
    let b = newMemBlobStore()
    var id: ByteArr16
    for i in 0..15: id[i] = 0xFF
    check not b.blobs.hasKey(id)

  test "empty blob (0 bytes)":
    let b = newMemBlobStore()
    var id: ByteArr16
    newUuidBytes(addr id[0])
    b.blobs[id] = newSeq[byte]()
    check b.blobs.hasKey(id)
    check b.blobs[id] == newSeq[byte]()

  test "large payload (> 4 KiB)":
    let b = newMemBlobStore()
    var data = newSeq[byte](5000)
    for i in 0..<data.len: data[i] = byte((i * 7) and 0xFF)
    var id: ByteArr16
    newUuidBytes(addr id[0])
    b.blobs[id] = data
    check b.blobs[id] == data

  test "binary data with null bytes":
    let b = newMemBlobStore()
    let data = @[byte(0), 0, 1, 0, 2]
    var id: ByteArr16
    newUuidBytes(addr id[0])
    b.blobs[id] = data
    check b.blobs[id] == data

# ══════════════════════════════════════════════════════════════════════════════
# overwrite
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: overwrite":
  test "write then replace at same id":
    let b = newMemBlobStore()
    var id: ByteArr16
    for i in 0..15: id[i] = byte(i)
    b.blobs[id] = @[byte(1), 1, 1]
    b.blobs[id] = @[byte(2), 2]
    check b.blobs[id] == @[byte(2), 2]

# ══════════════════════════════════════════════════════════════════════════════
# delete
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: delete":
  test "put → delete → gone":
    let b = newMemBlobStore()
    var id: ByteArr16
    newUuidBytes(addr id[0])
    b.blobs[id] = @[byte(9)]
    check b.blobs.hasKey(id)
    b.blobs.del(id)
    check not b.blobs.hasKey(id)

  test "delete of non-existent id is harmless":
    let b = newMemBlobStore()
    var id: ByteArr16
    for i in 0..15: id[i] = 0xFF
    b.blobs.del(id)
    check not b.blobs.hasKey(id)

# ══════════════════════════════════════════════════════════════════════════════
# list
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: list":
  test "empty store → 0 keys":
    let b = newMemBlobStore()
    check b.blobs.len == 0

  test "put 3 → 3 keys, delete 1 → 2 keys":
    let b = newMemBlobStore()
    var ids: array[3, ByteArr16]
    for j in 0..2:
      newUuidBytes(addr ids[j][0])
      b.blobs[ids[j]] = @[byte(j)]
    check b.blobs.len == 3
    b.blobs.del(ids[1])
    check b.blobs.len == 2

# ══════════════════════════════════════════════════════════════════════════════
# roots (named blobs)
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: roots":
  test "putRoot + getRoot round-trip":
    let b = newMemBlobStore()
    b.roots["root_1"] = @[byte(0xAA), 0xBB]
    check b.roots.hasKey("root_1")
    check b.roots["root_1"] == @[byte(0xAA), 0xBB]

  test "getRoot missing":
    let b = newMemBlobStore()
    check not b.roots.hasKey("nonexistent")

  test "listRoots empty":
    let b = newMemBlobStore()
    check b.roots.len == 0

  test "deleteRoot removes root":
    let b = newMemBlobStore()
    b.roots["to_delete"] = @[]
    check b.roots.hasKey("to_delete")
    b.roots.del("to_delete")
    check not b.roots.hasKey("to_delete")

# ══════════════════════════════════════════════════════════════════════════════
# isolation — trivially correct with Nim refs (different heap objects)
# ══════════════════════════════════════════════════════════════════════════════

suite "memory: isolation":
  test "two handles are independent":
    let b1 = newMemBlobStore()
    let b2 = newMemBlobStore()
    var id: ByteArr16
    newUuidBytes(addr id[0])
    b1.blobs[id] = @[byte(1)]
    check b1.blobs.hasKey(id)       # present in b1
    check not b2.blobs.hasKey(id)   # NOT present in b2 (separate tables)
