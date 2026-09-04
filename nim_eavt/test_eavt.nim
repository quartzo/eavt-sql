## nim_kvstore/eavt_test_eavt.nim
##
## Unit tests for the EAVT engine (Nim API, no C-ABI).

import std/[unittest, tables, os, times, options, algorithm]
import std/typedthreads
import eavt
import kvstore
import keys
import resolver
import hostfns
import engine
import scheme
import hydrated
import query/cursor  # mockCursor / mergedCursor (fontes do MergedCursor)
import nim_memtable/treap_backend  # cmpKeysByte

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

  test "re-declare UNIQUE persists db.unique across restart":
    # Regressão: eavtDeclareAttr só gravava db.unique dentro de `if isNew` —
    # redeclarar um attr existente com UNIQUE atualizava o resolver em
    # memória mas nunca persistia o datom (réplica não recebia, restart
    # perdia a flag).
    let path = "/tmp/eavttest_uniq_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      discard eng.eavtDeclareAttr("persist.u", DbTypeString, false)
      check not eng.isUnique(eng.lookupAttr("persist.u").get)
      discard eng.eavtDeclareAttr("persist.u", DbTypeString, false, true)
      check eng.isUnique(eng.lookupAttr("persist.u").get)
      eng.kv.flush()
      eng.kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      let aid = eng.lookupAttr("persist.u")
      check aid.isSome()
      check eng.isUnique(aid.get())
      eng.kv.close()
    removeDir(path)

# ══════════════════════════════════════════════════════════════════════════════
# Schema replication: WAL → resolver (corrida do ATTRIBUTE ... UNIQUE)
# ══════════════════════════════════════════════════════════════════════════════

proc walRecord(cf: uint8; key: seq[byte]): seq[byte] =
  ## Serializa uma key em registro journal/WAL — formato do sink em
  ## eavt_transactor_nim/wal.nim: [4B len BE (=1+klen)][cf][key][4B vlen][1B val].
  let fld = 1 + key.len
  result = @[byte((fld shr 24) and 0xFF), byte((fld shr 16) and 0xFF),
             byte((fld shr 8) and 0xFF), byte(fld and 0xFF)]
  result.add cf
  result.add key
  result.add @[byte(0), byte(0), byte(0), byte(1), byte(0)]  # vlen=1, value=0x00

proc collectSchemaWal(eng: EavtEngine): seq[byte] =
  ## Extrai as keys db.* (cf 1, AEVT) do engine e monta os bytes wal.
  ## M5: db.* CF-1 pendentes são DERIVADOS do vetor de datoms.
  for aid in [DbIdentAid, DbValueTypeAid, DbCardinalityAid, DbUniqueAid]:
    for k in eng.scanPrefix(1, @[0'u8, 0'u8, 0'u8, byte(aid)]):
      result.add walRecord(1'u8, k)
    for d in eng.dvec.drainFromT(0):
      if d.len >= 12 and beUint32(d, 8) == aid:
        # derive CF-1 [aid][eid][val][sf] from the canonical datom
        var k1 = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
                  byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
        k1.add d[0 ..< 8]
        k1.add d[12 ..< d.len]
        result.add walRecord(1'u8, k1)

proc schemaAids(): array[4, uint32] =
  [DbIdentAid, DbCardinalityAid, DbValueTypeAid, DbUniqueAid]

suite "eavt: schema replication (WAL → resolver)":
  test "journalHasSchemaRecords detecta schema e ignora dados":
    var schemaBytes: seq[byte]
    block:
      let eng = newTestEngine()
      discard eng.eavtDeclareAttr("wal.detect", DbTypeString, false, true)
      schemaBytes = collectSchemaWal(eng)
    check schemaBytes.len > 0
    check journalHasSchemaRecords(schemaBytes, schemaAids())

    # Registro de dados (aid de usuário, fora do conjunto de schema)
    var dataKey = @[byte(0), byte(0), byte(0), byte(42)]
    dataKey.add @[byte(1), byte(2), byte(3)]
    let dataOnly = walRecord(1'u8, dataKey)
    check not journalHasSchemaRecords(dataOnly, schemaAids())

    # Framing inválido (len maior que o buffer) — falso, sem travar
    var bad = @[byte(0), byte(0), byte(0), byte(200), byte(1)]
    check not journalHasSchemaRecords(bad, schemaAids())

  test "schema wal aplicado à réplica torna attr UNIQUE visível no resolver":
    var walBytes: seq[byte]
    block:
      let eng = newTestEngine()
      discard eng.eavtDeclareAttr("wal.email", DbTypeString, false, true)
      check eng.isUnique(eng.lookupAttr("wal.email").get)
      walBytes = collectSchemaWal(eng)
    check journalHasSchemaRecords(walBytes, schemaAids())

    # "Réplica": engine fresco recebe os datoms via WAL e re-bootstrapa.
    let engB = newTestEngine()
    check engB.lookupAttr("wal.email").isNone  # ainda stale
    engB.kv.applyJournalRecords(walBytes)
    engB.bootstrapResolver()
    let aid = engB.lookupAttr("wal.email")
    check aid.isSome
    check engB.isUnique(aid.get)

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
    check eng.attrName(aid) == "named/attr"

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

# ══════════════════════════════════════════════════════════════════════════════
# Hydrated-eid source (CF 0 fast path)
# ══════════════════════════════════════════════════════════════════════════════

suite "eavt: cursor semantics under concurrent writes":
  ## F0 regression lock (M5 pre-work): the HydCursor holds a LIVE entry ref
  ## and resolves buf/offs at read time. A write to the SAME eid between
  ## cursor steps mutates offs/buf under the cursor. This test documents
  ## the CURRENT behavior so M5 (immutable datom chunks + stable slots)
  ## can be judged against it: today the mid-iteration write MUST NOT
  ## corrupt the iteration's remaining keys.
  test "cursor over hydrated entry survives write to same eid mid-scan":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("cur.attr", DbTypeString, true)  # MANY
    let eid = eng.allocateEntityId()
    for i in 1..8:
      discard eng.eavtSave(eid, "cur.attr", "v" & $i, i.int64)
    check eng.hyd.probeComplete(eid)

    # open a full-range CF-0 cursor (hyd mock source joins the merge)
    var mc = eng.kv.openScanCursor(0)
    mc.hyd = eng.hyd
    var all = eng.hyd.allKeys()
    all.sort(cmpKeysByte)
    mc.addSource(mockCursor(all))
    discard mergedCursor(mc)
    mc.seek(@[])

    # drain the first half through the cursor
    var seen: seq[seq[byte]] = @[]
    for i in 0 ..< 4:
      let k = mc.next()
      check k.isSome
      seen.add(k.get)

    # concurrent write to the SAME eid while the cursor is open
    discard eng.eavtSave(eid, "cur.attr", "v9", 9)

    # the cursor must keep yielding valid, correctly-ordered keys
    var after: seq[seq[byte]] = @[]
    while true:
      let k = mc.next()
      if k.isNone: break
      after.add(k.get)
    for i in 1 ..< after.len:
      check cmpKeysByte(after[i-1], after[i]) < 0
    # every key is a well-formed datom of this eid (no garbage from
    # shifted offsets)
    for k in after:
      check decodeEid(beUint64(k, 0)) == eid
    # nothing lost: 8 pre-write keys total seen across both halves
    check seen.len + after.len >= 8

  test "eid-anchored HydCursor survives write to same eid mid-scan":
    ## The dangerous route: probeComplete → HydCursor holds the LIVE entry
    ## (not a snapshot) and resolves buf/offs at read time.
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("cur3.attr", DbTypeString, true)  # MANY
    let eid = eng.allocateEntityId()
    for i in 1..8:
      discard eng.eavtSave(eid, "cur3.attr", "v" & $i, i)

    let qe = newQueryStore(eng.kv)
    qe.eavt = eng  # cursor opens through the engine's hyd
    let mc = qe.openCursor(0, encodeEid(eid))
    mc.seek(encodeEid(eid))  # probeComplete → hydMode (live entry ref)

    var seen: seq[seq[byte]] = @[]
    for i in 0 ..< 4:
      let k = mc.currentKey()
      check k.isSome
      seen.add(k.get)
      mc.step()

    # write to the SAME eid while the HydCursor is open — a key that sorts
    # BEFORE the remaining ones (forces offs shift under the cursor)
    discard eng.eavtSave(eid, "cur3.attr", "a-mid", 10)

    var after: seq[seq[byte]] = @[]
    while mc.isValid():
      let k = mc.currentKey()
      if k.isNone: break
      after.add(k.get)
      mc.step()
    # no garbage: every key well-formed, this eid, strictly ordered
    for i in 1 ..< after.len:
      check cmpKeysByte(after[i-1], after[i]) < 0
    for k in after:
      check decodeEid(beUint64(k, 0)) == eid
    check seen.len + after.len >= 8

  test "HydCursor survives tombstone mid-scan (removeKeyAt shift)":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("cur4.attr", DbTypeString, true)  # MANY
    let eid = eng.allocateEntityId()
    for i in 1..8:
      discard eng.eavtSave(eid, "cur4.attr", "t" & $i, i)

    let qe = newQueryStore(eng.kv)
    qe.eavt = eng
    let mc = qe.openCursor(0, encodeEid(eid))
    mc.seek(encodeEid(eid))
    var seen = 0
    for i in 0 ..< 4:
      check mc.currentKey().isSome
      mc.step(); inc seen

    # retract a key that sorts AFTER the cursor position (mid-buf removal)
    eng.eavtRetract(eid, "cur4.attr", "t2", 100)

    var after: seq[seq[byte]] = @[]
    while mc.isValid():
      let k = mc.currentKey()
      if k.isNone: break
      after.add(k.get)
      mc.step()
    for i in 1 ..< after.len:
      check cmpKeysByte(after[i-1], after[i]) < 0
    for k in after:
      check decodeEid(beUint64(k, 0)) == eid
    check seen + after.len >= 6

  test "eid-anchored seek route unaffected by mid-scan write":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("cur2.attr", DbTypeString, true)  # MANY
    let eid = eng.allocateEntityId()
    for i in 1..6:
      discard eng.eavtSave(eid, "cur2.attr", "w" & $i, i)
    let pfx = encodeEid(eid)

    # route through probeComplete: seek + partial drain, then write, then drain
    let first = eng.scanPrefixActive(0, pfx)
    check first.len == 6
    discard eng.eavtSave(eid, "cur2.attr", "w7", 7)
    let second = eng.scanPrefixActive(0, pfx)
    check second.len == 7
    # all keys well-formed and of this eid
    for k in second:
      check decodeEid(beUint64(k, 0)) == eid

suite "eavt: replica stale-hydration invariant (M5 F3 acceptance)":
  ## F0-b: the latent replica bug. The replica's applyWal writes CF-0 into
  ## the TREAP while the primary's read path treats a hydrated entry as
  ## AUTHORITATIVE (probeComplete → exclusive). If a replica read ever
  ## hydrates an eid (lookup-value hostfn), subsequent WAL datoms for that
  ## eid are invisible and retracts resurrect. Unreachable through the
  ## datalog surface today (scanners never hydrate; exec routes to the
  ## transactor) — but structural. After M5-F3 (applyWal → batchWrite)
  ## this test MUST stay green on the same code path.
  proc collectCf0Keys(eng: EavtEngine; fromPrefix: seq[byte] = @[]): seq[seq[byte]] =
    ## The WAL payload equivalent: the CF-0 keys of A's memtable (hyd is the
    ## CF-0 memtable under M1..M4 — the treap is recovery staging only).
    ## Returns OWNED keys — the caller materializes CfKey/KeyRef at the call
    ## site (a KeyRef into a local that dies at return dangles: the bug
    ## genre deriveFromCf0 had).
    result = @[]
    for k in eng.hyd.allKeys():
      if fromPrefix.len == 0 or (k.len >= fromPrefix.len and
                                 k[0 ..< fromPrefix.len] == fromPrefix):
        result.add k

  test "replica flow: hydrate → wal write same eid → read sees wal datom":
    let kvA = newTempFileKVStore()
    let engA = newEavtEngine(kvA)
    engA.bootstrapResolver()
    discard engA.eavtDeclareAttr("rep.attr", DbTypeString, true)  # MANY
    let eid = engA.allocateEntityId()
    discard engA.eavtSave(eid, "rep.attr", "V1", 1)

    # engine B = replica: apply CF-0 records from A's memtable into B's
    # treap (what replica applyWal / applyJournalRecordsExpanded does)
    let kvB = newTempFileKVStore()
    let engB = newEavtEngine(kvB)
    engB.bootstrapResolver()
    block:
      # the returned seq must be NAMED — its element seqs own the bytes the
      # KeyRefs borrow; a loop over the temporary dangles at loop end
      let keysA = engA.collectCf0Keys()
      var recs: seq[CfKey] = @[]
      for k in keysA: recs.add CfKey(cf: 0, key: toKeyRef(k))
      discard engB.kv.mt.batch(recs)

    # first read on B hydrates the eid (lookup-value hostfn path)
    engB.hydrateEid(eid)
    check engB.hyd.probeComplete(eid)
    let v1 = engB.scanPrefixActive(0, encodeEid(eid))
    check v1.len == 1

    # A writes again (new t); WAL delivers the CF-0 key to B's treap —
    # exactly what replica applyWal phase 1 does (treap only, no hyd)
    discard engA.eavtSave(eid, "rep.attr", "V2", 2)
    block:
      let keysA2 = engA.collectCf0Keys(encodeEid(eid))
      var recs2: seq[CfKey] = @[]
      for k in keysA2: recs2.add CfKey(cf: 0, key: toKeyRef(k))
      discard engB.kv.mt.batch(recs2)

    # post-WAL read on B: the WAL datom is INVISIBLE today — the hydrated
    # entry is probed complete and answers exclusively. M5 F3 (applyWal →
    # batchWrite) flips this check to == 2.
    let v2 = engB.scanPrefixActive(0, encodeEid(eid))
    check v2.len == 1  # STALE by design today — F3 must make this 2
    for k in v2:
      check k.len >= 20 and decodeEid(beUint64(k, 0)) == eid

suite "eavt: hydrated eid source":

  test "allocateInPartition marks the entity hydrated":
    let eng = newTestEngine()
    let eid = eng.allocateEntityId()
    check eng.hyd.contains(eid)
    check eng.hyd.probe(eid)

  test "save mirrors into hydrated entry (read-your-writes)":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("hyd.name", DbTypeString, false)
    let eid = eng.allocateEntityId()
    # allocate marked it; save must mirror through batchWrite
    discard eng.eavtSave(eid, "hyd.name", "alice", 10)
    check eng.hyd.probe(eid)
    let ks = eng.scanPrefixActive(0, encodeEid(eid))
    check ks.len == 1            # served from RAM, complete

  test "retract via eavtRetract removes from hydrated entry":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("hyd.flag", DbTypeString, false)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "hyd.flag", "on", 1)
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 1
    eng.eavtRetract(eid, "hyd.flag", "on", 2)
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 0

  test "hydrateEid on first read installs the full set":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("hyd.late", DbTypeString, true)  # MANY
    # bypass allocation marking: simulate pre-existing entity
    let eid = eng.allocateInPartition(4)
    eng.hyd.evictEid(eid)
    check not eng.hyd.contains(eid)
    discard eng.eavtSave(eid, "hyd.late", "x", 1)
    discard eng.eavtSave(eid, "hyd.late", "y", 2)
    eng.hydrateEid(eid)
    check eng.hyd.contains(eid)
    check eng.hyd.lookupRange(eid, encodeEid(eid)).len == 2
    # subsequent scans are served from the fast path and stay correct
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 2

  test "flush between save and lookup keeps hydrated view consistent":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("hyd.persist", DbTypeString, true)  # MANY
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "hyd.persist", "survives", 5)
    eng.kv.flush()               # live treap → pagestore; hydrated untouched
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 1
    # write AFTER flush: mirror still lands in the hydrated entry
    discard eng.eavtSave(eid, "hyd.persist", "v2", 6)
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 2

  test "eviction falls back to slow path with correct results":
    let eng = newTestEngine()
    discard eng.eavtDeclareAttr("hyd.evict", DbTypeString, false)
    let eid = eng.allocateEntityId()
    discard eng.eavtSave(eid, "hyd.evict", "data", 1)
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 1
    # M1: a dirty entry IS the memtable for its eid — pinned until drained.
    eng.hyd.evictEid(eid)
    check eng.hyd.contains(eid)
    # flush drains hyd → pagestore (self-installed hooks) → entry clean
    eng.kv.flush()
    check not eng.hyd.contains(eid) or not eng.hyd.isDirty(eid)
    eng.hyd.evictEid(eid)
    check not eng.hyd.contains(eid)
    # slow path answers identically from the pagestore
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 1
    # re-hydration on demand restores membership
    eng.hydrateEid(eid)
    check eng.hyd.contains(eid)

  test "disabled hydration never populates the set":
    let kv = newTempFileKVStore()
    var cfg = initTable[string, string]()
    cfg["hydrated_enabled"] = "false"
    let eng = newEavtEngine(kv, cfg)
    eng.bootstrapResolver()
    let eid = eng.allocateEntityId()
    check not eng.hyd.contains(eid)
    check eng.scanPrefixActive(0, encodeEid(eid)).len == 0

suite "eavt: recovery CF-0-only (sem flush)":
  test "write → close sem flush → reopen: resolver + leituras + escrita":
    let path = "/tmp/eavttest_rec_" & $getTime().toUnix() & "_" & $getTime().nanosecond
    createDir(path)
    let eid1 = block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      discard eng.eavtDeclareAttr("rec.email", DbTypeString, false, true)
      let e = eng.allocateEntityId()
      discard eng.eavtSave(e, "rec.email", "a@b.c", 1)
      # SEM flush — fecha direto: o journal carrega só CF-0 (WAL CF-0-only)
      eng.kv.close()
      e
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      eng.recoverWriteState()
      check eng.lookupAttr("rec.email").isSome()
      # a leitura merge resíduo treap + base
      check eng.lookupValueStr(eid1, "rec.email") == some("a@b.c")
      # a hash reconstruída resolve a âncora (lookup pós-recovery reusa)
      check eng.lookupEntityByValue("rec.email", "a@b.c") == some(eid1)
      # escrita pós-recovery visível
      let e2 = eng.allocateEntityId()
      discard eng.eavtSave(e2, "rec.email", "x@y.z", 9)
      check eng.lookupValueStr(e2, "rec.email") == some("x@y.z")
      eng.kv.flush()
      eng.kv.close()
    block:
      let cfg = {"backend": "file", "path": path}.toTable
      let kv = newKVStore(cfg)
      let eng = newEavtEngine(kv)
      eng.bootstrapResolver()
      eng.recoverWriteState()
      check eng.lookupValueStr(eid1, "rec.email").isSome
      check eng.lookupValueStr(70368744177666'i64, "rec.email") == some("x@y.z")
      eng.kv.close()
    removeDir(path)
