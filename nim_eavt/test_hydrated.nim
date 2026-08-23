## test_hydrated.nim — Unit tests for the hydrated-eid source (nim_eavt).

import std/[unittest, options]
import keys
import hydrated

proc k(eid: int64; attr: uint32; v: string; t: int64; ret = false): seq[byte] =
  buildEavtKey(eid, attr, cast[seq[byte]](v), t, ret)

suite "hydrated: probe / membership":

  test "empty set probes miss":
    let h = newHydratedSet()
    check not h.probe(42)
    check h.misses == 1
    check h.hits == 0

  test "hydrateEmpty marks membership with no keys":
    let h = newHydratedSet()
    h.hydrateEmpty(42)
    check h.probe(42)
    check h.len == 1
    check h.lookupRange(42, encodeEid(42)).len == 0

  test "hydrate installs full key set and probe hits":
    let h = newHydratedSet()
    let ks = @[k(7, 100, "aa", 1), k(7, 101, "bb", 2)]
    h.hydrate(7, ks)
    check h.probe(7)
    check h.hydrations == 1
    check h.entryBytes(7) == ks[0].len + ks[1].len

suite "hydrated: lookupRange":

  setup:
    let h = newHydratedSet()
    # eid 7: attrs 100 ("aa"@1), 101 ("bb"@2), 102 ("cc"@3)
    h.hydrate(7, @[k(7, 100, "aa", 1), k(7, 101, "bb", 2), k(7, 102, "cc", 3)])
    # unrelated entity
    h.hydrate(9, @[k(9, 100, "zz", 5)])

  test "full-eid prefix returns all datoms":
    let got = h.lookupRange(7, encodeEid(7))
    check got.len == 3

  test "eid+attr prefix narrows to one":
    var p = encodeEid(7)
    p.add byte(0); p.add byte(0); p.add byte(0); p.add byte(101)
    let got = h.lookupRange(7, p)
    check got.len == 1
    check got[0] == k(7, 101, "bb", 2)

  test "prefix of another eid is empty within this entry":
    let got = h.lookupRange(7, encodeEid(9))
    check got.len == 0

  test "unknown eid returns empty":
    check h.lookupRange(1234, encodeEid(1234)).len == 0

suite "hydrated: applyKey mirror":

  test "active key upserts into hydrated entry (sorted)":
    let h = newHydratedSet()
    h.hydrateEmpty(42)
    h.applyKey(k(42, 200, "late", 10))
    h.applyKey(k(42, 100, "early", 11))
    let got = h.lookupRange(42, encodeEid(42))
    check got.len == 2
    # ascending order by full key: attr 100 before 200
    check got[0] == k(42, 100, "early", 11)
    check got[1] == k(42, 200, "late", 10)

  test "same datom re-saved with newer t replaces in place":
    let h = newHydratedSet()
    h.hydrateEmpty(42)
    h.applyKey(k(42, 100, "v", 1))
    h.applyKey(k(42, 100, "v", 5))
    let got = h.lookupRange(42, encodeEid(42))
    check got.len == 1
    check got[0] == k(42, 100, "v", 5)

  test "different values are distinct datoms (card-MANY semantics)":
    # Datom identity is (e,a,v,t): two values coexist until retracted.
    # Card-ONE replacement happens upstream (retract-scan writes the
    # retract entry through batchWrite before the new save).
    let h = newHydratedSet()
    h.hydrateEmpty(42)
    h.applyKey(k(42, 100, "old-value-longer", 1))
    h.applyKey(k(42, 100, "new", 2))
    check h.lookupRange(42, encodeEid(42)).len == 2

  test "retract removes the active key":
    let h = newHydratedSet()
    h.hydrateEmpty(42)
    h.applyKey(k(42, 300, "gone", 1))
    check h.lookupRange(42, encodeEid(42)).len == 1
    h.applyKey(k(42, 300, "gone", 2, ret = true))
    check h.lookupRange(42, encodeEid(42)).len == 0
    check h.curBytes == 0

  test "applyKey ignores non-member eids":
    let h = newHydratedSet()
    h.applyKey(k(55, 1, "x", 1))
    check h.len == 0

suite "hydrated: LRU eviction / budget":

  test "inserting over budget evicts least-recently-used first":
    # tiny budget: each key is 21 bytes; two fit, the third must evict
    let h = newHydratedSet(maxBytes = 50)
    h.hydrate(1, @[k(1, 100, "a", 1)])
    h.hydrate(2, @[k(2, 100, "b", 1)])
    discard h.probe(1)              # touch 1 → 2 is now LRU
    h.hydrate(3, @[k(3, 100, "c", 1)])   # should evict 2
    check not h.contains(2)
    check h.contains(1)
    check h.contains(3)
    check h.evictions >= 1

  test "eviction never evicts the incoming entry itself":
    # 21-byte resident + 50-byte incoming over a 60-byte budget:
    # fitting requires evicting the resident, never the incoming.
    let h = newHydratedSet(maxBytes = 60)
    h.hydrate(5, @[k(5, 100, "r", 1)])
    let big = @[k(9, 100, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 1)]
    check big[0].len == 50
    h.hydrate(9, big)
    check h.contains(9)
    check not h.contains(5)

  test "entry larger than the whole budget is rejected":
    let h = newHydratedSet(maxBytes = 16)
    let before = h.rejected
    h.hydrate(8, @[k(8, 100, "this-key-is-far-too-big-for-the-budget", 1)])
    check h.rejected == before + 1
    check not h.contains(8)

  test "touch on probe protects hot entries":
    let h = newHydratedSet(maxBytes = 50)
    h.hydrate(1, @[k(1, 100, "a", 1)])
    h.hydrate(2, @[k(2, 100, "b", 1)])
    for i in 0..<5: discard h.probe(1)   # hammer 1
    h.hydrate(3, @[k(3, 100, "c", 1)])   # must evict 2 (LRU), keep 1
    check h.contains(1)
    check not h.contains(2)
    check h.contains(3)

suite "hydrated: explicit removal / reset":

  test "evictEid drops exactly one entry":
    let h = newHydratedSet()
    h.hydrate(1, @[k(1, 100, "a", 1)])
    h.hydrate(2, @[k(2, 100, "b", 1)])
    h.evictEid(1)
    check not h.contains(1)
    check h.contains(2)

  test "clear resets everything":
    let h = newHydratedSet()
    h.hydrate(1, @[k(1, 100, "a", 1)])
    h.clear()
    check h.len == 0
    check h.curBytes == 0
