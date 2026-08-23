## repro_merge.nim — hammer successive commitMerge + interleaved scans
## hunting for "truncated index entry" / leaf-as-index type confusion.

import std/[random, os, times, strutils, tables]
import pages
import page_store
import page_cursor
import blobstore

proc newMemStore(): ptr PageStoreInner =
  var cfg = {"backend": "file", "owns_path": "true"}.toTable
  cfg["path"] = getTempDir() / "eavt_ps_repro_" & $getCurrentProcessId() & "_" &
                 $epochTime().uint64 & "_" & $rand(high(int))
  createDir(cfg["path"])
  result = newPageStore(cfg)

# EAVT-like key: [eid 8][aid 4][value var][suffix 8] — variable length strings
proc eavtKey(eid: int; aid: uint32; val: string; suffix: uint64): seq[byte] =
  result = newSeq[byte](12)
  let e = cast[uint64](eid)
  for j in 0..<8: result[j] = byte((e shr ((7 - j) * 8)) and 0xFF)
  result[8] = byte((aid shr 24) and 0xFF)
  result[9] = byte((aid shr 16) and 0xFF)
  result[10] = byte((aid shr 8) and 0xFF)
  result[11] = byte(aid and 0xFF)
  for ch in val: result.add byte(ch)
  let sf = suffix
  for j in 0..<8: result.add byte((sf shr ((7 - j) * 8)) and 0xFF)

proc main() =
  var rng = initRand(20260823)
  let s = newMemStore()
  defer: closePageStore(s)

  # Simulate the transactor workload: N rounds ("flushes"), each adding a
  # batch of new datoms across CFs 0-3, then scans via cursors (seek+iterate).
  # EIDs are drawn from a BOUNDED space so successive rounds overwrite the
  # same eid+attr prefixes — exercising mergeLeaf splicing into existing
  # leaves (the real upsert pattern: simples re-saves, socio gocs).
  const Rounds = 40
  const PerRound = 25_000
  const EidSpace = 60_000
  var allEids: seq[int] = @[]

  for round in 0..<Rounds:
    var byCf: array[4, seq[seq[byte]]]
    for i in 0..<PerRound:
      let eid = rng.rand(0..<EidSpace)
      if round == 0 or i mod 5 == 0: allEids.add eid
      let aid = uint32(rng.rand(1..<40))
      let vlen = rng.rand(4..<60)
      var v = ""
      for j in 0..<vlen: v.add char(rng.rand(33..<127))
      let t = uint64(round * PerRound + i) shl 1
      let k = eavtKey(eid, aid, v, t)
      byCf[0].add k                       # eavt
      var ae: seq[byte] = @[]
      ae.add byte((aid shr 24) and 0xFF); ae.add byte((aid shr 16) and 0xFF)
      ae.add byte((aid shr 8) and 0xFF); ae.add byte(aid and 0xFF)
      for b in k[8..^1]: ae.add b         # crude aevt variant
      byCf[1].add ae
      # avet: aid + value + eid + suffix
      var av: seq[byte] = @[]
      av.add byte((aid shr 24) and 0xFF); av.add byte((aid shr 16) and 0xFF)
      av.add byte((aid shr 8) and 0xFF); av.add byte(aid and 0xFF)
      for ch in v: av.add byte(ch)
      for b in k[0..<8]: av.add b
      for b in k[^8..^1]: av.add b
      byCf[2].add av

    for cf in 0..<4:
      if byCf[cf].len > 0:
        s[].commitMerge(@[(cf, byCf[cf])], true)

    # Interleaved point-scan storm like goc()/lookup-entity bursts
    for probe in 0..<200:
      let cf = rng.rand(0..<4)
      let tree = s[].trees[cf]
      if tree.rootUuid == default(array[16, byte]): continue
      let c = PageStoreCursor(s: s, cf: cf, rootUuid: tree.rootUuid,
                              height: tree.height)
      var target = eavtKey(rng.rand(0..<EidSpace), uint32(rng.rand(1..<40)),
                           "", 0)
      c.seek(target)
      var steps = 0
      while steps < 50 and not c.atEnd:
        discard c.next()
        inc steps
      # reuse-in-place pattern like scanPrefixActive: update + seek again
      c.update(tree.rootUuid, tree.height)
      c.seek(target)
      discard c.next()

    if (round + 1) mod 10 == 0:
      echo "round ", round + 1, "/", Rounds, " ok"

  echo "REPRO COMPLETE without error"

when isMainModule:
  main()
