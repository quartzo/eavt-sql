## test_datoms.nim — unit tests for the M5 datom vector (nim_eavt/datoms.nim).
import std/[unittest, options, strutils]
import datoms
import keys
import nim_memtable/treap_backend  # cmpKeysByte

proc mkKey(eid: int64; aid: uint32; val: string; t: int64; retracted = false): seq[byte] =
  ## Canonical CF-0 key via buildEavtKey (the real encoder).
  buildEavtKey(eid, aid, encodeVariable(val), t, retracted)

proc keyT(k: seq[byte]): int64 =
  let (t, _) = decodeSuffix(beUint64(k, k.len - 8))
  t

suite "datoms: append + slot stability":
  test "slot survives appends; keyCopy round-trips":
    let v = newDatomVector(maxBytes = 1 shl 20, chunkBytes = 256)
    let k1 = mkKey(100, 1, "alice", 10)
    let s1 = v.append(k1, 10)
    let k2 = mkKey(100, 2, "bob", 11)
    let s2 = v.append(k2, 11)
    check v.keyCopy(s1) == k1
    check v.keyCopy(s2) == k2
    check v.generation == 2

  test "chunk seal + fresh chunk on capacity (multi-chunk)":
    let v = newDatomVector(maxBytes = 1 shl 20, chunkBytes = 128)
    var slots: seq[DatomSlot] = @[]
    for i in 1 .. 10:
      slots.add v.append(mkKey(100, 1, "v" & $i, i.int64), i.int64)
    check v.numChunks >= 2
    for i, s in slots:
      check v.keyCopy(s) == mkKey(100, 1, "v" & $(i + 1), (i + 1).int64)

suite "datoms: publish + volatile window":
  test "publish releases unpinned fully-durable chunks":
    let v = newDatomVector(maxBytes = 1 shl 20, chunkBytes = 96)
    for i in 1 .. 12:
      discard v.append(mkKey(100, 1, "v" & $i, i.int64), i.int64)
    check v.numChunks >= 2
    check v.volatileBytes > 0
    v.publish(8)
    check v.publishedT == 8
    let drained = v.drainVolatile()
    check drained.len >= 4
    for k in drained:
      check keyT(k) > 8

  test "pinned chunks survive publish; unpin releases them later":
    let v = newDatomVector(maxBytes = 1 shl 20, chunkBytes = 96)
    discard v.append(mkKey(100, 1, "only", 5), 5)
    let s = v.append(mkKey(200, 1, "other", 6), 6)
    v.pin(s)
    v.sealCurrent()  # flush capture boundary — chunks become publishable
    v.publish(10)
    check v.chunkAt(s) != nil
    check v.keyCopy(s) == mkKey(200, 1, "other", 6)
    v.unpin(s)
    v.publish(10)
    check v.chunkAt(s) == nil
    check v.volatileBytes == 0

  test "tombstone keys are plain volatile datoms":
    let v = newDatomVector()
    let k = mkKey(100, 3, "x", 20, retracted = true)
    discard v.append(k, 20)
    let drained = v.drainVolatile()
    check drained.len == 1
    let (_, ret) = decodeSuffix(beUint64(drained[0], drained[0].len - 8))
    check ret

suite "datoms: cmpSlotKey":
  test "zero-alloc compare matches cmpKeysByte":
    let v = newDatomVector()
    let ka = mkKey(100, 1, "a", 1)
    let kb = mkKey(100, 1, "b", 2)
    let sa = v.append(ka, 1)
    let sb = v.append(kb, 2)
    check v.cmpSlotKey(sa, ka) == 0
    check v.cmpSlotKey(sb, kb) == 0
    check v.cmpSlotKey(sa, kb) < 0
    check cmpKeysByte(v.keyCopy(sa), v.keyCopy(sb)) < 0
