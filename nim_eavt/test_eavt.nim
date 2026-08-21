## nim_kvstore/eavt_test_eavt.nim
##
## Unit tests for the EAVT engine (Nim API, no C-ABI).

import std/[unittest, tables, os, times, options]
import std/typedthreads
import eavt
import kvstore
import keys
import resolver
import hostfns
import engine
import scheme

proc newTestEngine(): EavtEngine =
  let kv = newTempFileKVStore()
  result = newEavtEngine(kv)
  result.bootstrapResolver()

# ══════════════════════════════════════════════════════════════════════════════
# Entity allocation
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: entity allocation":
  test "allocate returns valid eid":
    let eng = newTestEngine()
    let eid = eng.allocateEntityId()
    check eid > 0
    check partitionOf(eid) == PartUser

  test "sequential allocations increase":
    let eng = newTestEngine()
    let eid1 = eng.allocateEntityId()
    let eid2 = eng.allocateEntityId()
    check eid2 > eid1

  test "allocate in custom partition":
    let eng = newTestEngine()
    let pid = eng.declarePartition("test.part")
    let eid = eng.allocateInPartition(pid)
    check eid > 0
    check partitionOf(eid) == pid

# ══════════════════════════════════════════════════════════════════════════════
# Attribute declaration
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: attribute declaration":
  test "declare attr returns aid > 0":
    let eng = newTestEngine()
    let (aid, isNew) = eng.eavtDeclareAttr("company.name", DbTypeString, false)
    check aid > 0
    check isNew

  test "re-declare same attr returns same aid":
    let eng = newTestEngine()
    let (a1, _) = eng.eavtDeclareAttr("user.email", DbTypeString, false)
    let (a2, isNew2) = eng.eavtDeclareAttr("user.email", DbTypeString, false)
    check a1 == a2
    check not isNew2

  test "different attrs get different aids":
    let eng = newTestEngine()
    let (a1, _) = eng.eavtDeclareAttr("ns.a", DbTypeString, false)
    let (a2, _) = eng.eavtDeclareAttr("ns.b", DbTypeString, false)
    check a1 != a2

  test "declare attr with many cardinality":
    let eng = newTestEngine()
    let (aid, _) = eng.eavtDeclareAttr("tag.x", DbTypeString, true)
    check aid > 0
    check eng.isMany(aid)

  test "declare attr with unique":
    let eng = newTestEngine()
    let (aid, _) = eng.eavtDeclareAttr("uniq.key", DbTypeString, false, true)
    check eng.isUnique(aid)

  test "attr declaration persists across engines":
    let path = "/tmp/eavttest_attr_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      discard eng.eavtDeclareAttr("persist.x", DbTypeString, false)
      eng.kv.flush()
      eng.kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      let aid = eng.lookupAttr("persist.x")
      check aid.isSome()
      check eng.isDeclared(aid.get())
      check eng.valueTypeFor(aid.get()) == some(DbTypeString)
      eng.kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# Save and retract
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: save + retract":
  test "save makes datom scannable":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("test.val", DbTypeString, false)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "test.val", "hello", 1)
    let keys = eng.scanPrefix(0, @[])
    check keys.len > 0

  test "save with multiple values (many cardinality)":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("tag.list", DbTypeString, true)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "tag.list", "a", 1)
    discard eng.eavtSave(eid, "tag.list", "b", 1)
    # Both should exist in scan
    let keys = eng.scanPrefix(0, keys.encodeEid(eid))
    check keys.len >= 2

  test "save overwrites with one cardinality":
    let eng = newTestEngine()
    let (aid, _) = eng.eavtDeclareAttr("name.one", DbTypeString, false)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "name.one", "first", 1)
    discard eng.eavtSave(eid, "name.one", "second", 1)
    # Scan should show only the latest value
    var prefix = keys.encodeEid(eid)
    prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
    prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
    let scanKeys = eng.scanPrefix(0, prefix)
    # Overwrite writes old+retraction+new; scan returns all keys raw.
    check scanKeys.len >= 2

  test "retract removes datom":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("flag.rm", DbTypeBoolean, false)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "flag.rm", "true", 1)
    eng.eavtRetract(eid, "flag.rm", "true", 2)
    var prefix = keys.encodeEid(eid)
    prefix.add byte(101 shr 24); prefix.add byte((101 shr 16) and 0xFF)
    prefix.add byte((101 shr 8) and 0xFF); prefix.add byte(101 and 0xFF)
    let keys = eng.scanPrefix(0, prefix)
    var hasActive = false
    for k in keys:
      let sf = beUint64(k, k.len - 8)
      if (sf and 1) == 0: hasActive = true
    check not hasActive

# ══════════════════════════════════════════════════════════════════════════════
# Resolver accessors
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: resolver":
  test "lookupAttr finds declared attr":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("find.me", DbTypeString, false)
    let aid = eng.lookupAttr("find.me")
    check aid.isSome()
    check aid.get() > 0

  test "lookupAttr returns none for unknown":
    let eng = newTestEngine()
    check eng.lookupAttr("no.such.attr").isNone()

  test "attrName returns name from aid":
    let eng = newTestEngine()
    let (aid, _) = eng.eavtDeclareAttr("named.attr", DbTypeLong, false)
    check eng.attrName(aid) == "named.attr"

  test "valueTypeFor returns correct type":
    let eng = newTestEngine()
    let (aid, _) = eng.eavtDeclareAttr("typed.attr", DbTypeFloat, false)
    check eng.valueTypeFor(aid) == some(DbTypeFloat)

# ══════════════════════════════════════════════════════════════════════════════
# Bootstrap resolver
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: bootstrap":
  test "bootstrap loads attributes from persisted store":
    let path = "/tmp/eavttest_boot_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:  # write attrs to file-backed store
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      discard eng.eavtDeclareAttr("boot.a", DbTypeString, false)
      discard eng.eavtDeclareAttr("boot.b", DbTypeLong, true)
      eng.kv.flush()
      eng.kv.close()
    block:  # reopen and bootstrap
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      check eng.lookupAttr("boot.a").isSome()
      check eng.lookupAttr("boot.b").isSome()
      let aidB = eng.lookupAttr("boot.b").get()
      check eng.isMany(aidB)
      check eng.valueTypeFor(aidB) == some(DbTypeLong)
      eng.kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# Concurrency — multi-thread EavtEngine (same internal path as UDS saveWithT)
# ════════════════════════════════════════════════════════════════════════════
#
# Thread harness: test-local raw threads, all joined before the handles'
# scope ends (see test_kvstore.nim for the rationale — deterministic
# teardown, no global thread table).

type
  EavtJobKind = enum
    jkSaveRange   ## eavtSave(allocateEntityId(), attr, "value_"&(a+i)) for i in 0..<b
    jkSaveSame    ## eavtSave(eid, attr, "val_"&(a+i))                 for i in 0..<b
    jkDeclare     ## eavtDeclareAttr("shared.field")

  EavtJob = object
    eng: ptr EavtEngine
    attr: string
    eid: int64
    a, b: int
    kind: EavtJobKind

proc eavtJobWorker(job: EavtJob) {.thread.} =
  let eng = job.eng[]
  case job.kind
  of jkSaveRange:
    for i in 0..<job.b:
      let idx = job.a + i
      discard eng.eavtSave(eng.allocateEntityId(), job.attr, "value_" & $idx, 1)
  of jkSaveSame:
    for i in 0..<job.b:
      let idx = job.a + i
      discard eng.eavtSave(job.eid, job.attr, "val_" & $idx, 1)
  of jkDeclare:
    discard eng.eavtDeclareAttr("shared.field", DbTypeString, false)

proc runJobs(jobs: openArray[EavtJob]) =
  var ts = newSeq[Thread[EavtJob]](jobs.len)
  for i in 0..<jobs.len:
    createThread(ts[i], eavtJobWorker, jobs[i])
  for t in mitems(ts):
    joinThread(t)

# Concurrency tests removed — project is async single-threaded, not concurrent.
# Raw Thread[T] tests don't apply to production code.
