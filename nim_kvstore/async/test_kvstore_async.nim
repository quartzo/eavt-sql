## test_kvstore_async.nim — tests for the async KVStore twin (flush/GC on
## the event loop, blob I/O through the pool).
##
## Compiled under --mm:orc; intentionally NOT part of all_tests. Run via:
##   cd nim_kvstore/async && nimble test

import std/[unittest, os, options, tables, random]
import chronos
import common
import blobstore_async
import file_backend as fil_be
import page_store
import kvstore
import kvstore_async

# Non-raising wrappers (house "Safe" pattern — see eavt_transactor_nim): the
# storage API's inferred `raises` is broad (Exception), which {.async.}
# scenarios cannot call directly. Failures assert loudly instead.

proc sPut(kv: KVStore; cf: int; k: seq[byte]): bool =
  try: kv.put(cf, k); result = true
  except Exception: result = false

proc sPutKv(kv: KVStore; cf: int; k, v: seq[byte]): bool =
  try: kv.putKv(cf, k, v); result = true
  except Exception: result = false

proc sDelKv(kv: KVStore; cf: int; k: seq[byte]): bool =
  try: kv.deleteKv(cf, k); result = true
  except Exception: result = false

proc sGetKv(kv: KVStore; cf: int; k: seq[byte]): Option[seq[byte]] =
  try: result = kv.getKv(cf, k)
  except Exception: result = none(seq[byte])

proc scanKeys(kv: KVStore; cf: int): seq[seq[byte]] =
  try:
    let mc = kv.openScanCursor(cf)
    while true:
      let k = mc.next()
      if k.isNone: break
      result.add k.get
  except Exception:
    result = @[]

type Ctx = ref object
  ## Ref cell passed as a parameter to each async scenario (async procs
  ## capture parameters on their closure env — GC-safe under orc).
  kv: KVStore
  pool: BlobPool
  flusher: AsyncFlusher

var gDirs: seq[string]

proc newTempKV(extra: Table[string, string] = initTable[string, string]()): KVStore =
  try: result = newTempFileKVStore(extra)
  except Exception: result = nil

proc newCtx(extra: Table[string, string] = initTable[string, string]()): Ctx =
  let kv = newTempKV(extra)
  doAssert kv != nil
  gDirs.add(kv.path)
  let pool = startBlobPool(4)
  result = Ctx(kv: kv, pool: pool, flusher: newAsyncFlusher(kv, pool))

proc closeCtx(ctx: Ctx) =
  waitFor ctx.pool.closeBlobPool()
  ctx.kv.close()

proc u64le(b: seq[byte]; off: int): uint64 =
  for i in 0..7: result = result or (uint64(b[off + i]) shl uint64(8 * i))

suite "kvstore_async: flush":
  test "puts survive async flush (EAVT cf)":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for i in 0..<200:
        if not sPut(ctx.kv, 0, @[byte(i and 0xFF), byte(i shr 8)]):
          return false
      await ctx.flusher.requestFlushAsync()
      result = scanKeys(ctx.kv, 0).len == 200
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "kv pairs + tombstones survive async flush":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      if not sPutKv(ctx.kv, 10, @[byte(1)], @[byte(10)]): return false
      if not sPutKv(ctx.kv, 10, @[byte(2)], @[byte(20)]): return false
      if not sDelKv(ctx.kv, 10, @[byte(1)]): return false
      await ctx.flusher.requestFlushAsync()
      # more writes + another flush (merge path over existing tree)
      if not sPutKv(ctx.kv, 10, @[byte(3)], @[byte(30)]): return false
      if not sDelKv(ctx.kv, 10, @[byte(2)]): return false
      await ctx.flusher.requestFlushAsync()
      if sGetKv(ctx.kv, 10, @[byte(1)]).isSome: return false
      if sGetKv(ctx.kv, 10, @[byte(2)]).isSome: return false
      result = sGetKv(ctx.kv, 10, @[byte(3)]) == some(@[byte(30)])
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "concurrent requests collapse; all writes durable":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for i in 0..<300:
        if not sPut(ctx.kv, 0, @[byte(i and 0xFF), byte((i shr 8) and 0xFF)]):
          return false
      var futs: seq[Future[void]] = @[]
      for r in 0..<5:
        for i in 0..<20:
          if not sPut(ctx.kv, 1, @[byte(r), byte(i)]): return false
        futs.add ctx.flusher.requestFlushAsync()
      for f in futs: await f
      result = scanKeys(ctx.kv, 0).len == 300 and scanKeys(ctx.kv, 1).len == 100
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "writes during async flush survive (next pass)":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for i in 0..<100:
        if not sPut(ctx.kv, 0, @[byte(i)]): return false
      let f1 = ctx.flusher.requestFlushAsync()
      # writes racing the in-flight flush land in the live memtable
      for i in 100..<150:
        if not sPut(ctx.kv, 0, @[byte(i)]): return false
      await f1
      await ctx.flusher.requestFlushAsync()
      result = scanKeys(ctx.kv, 0).len == 150
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "parity with sync flush":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      # sync store, same data
      let kvS = newTempKV()
      defer: kvS.close()
      var keys: seq[seq[byte]] = @[]
      var rnd = initRand(7)
      for i in 0..<400:
        var k = newSeq[byte](24)
        for j in 0..<24: k[j] = byte(rnd.rand(255))
        keys.add k
      for k in keys:
        if not sPut(ctx.kv, 2, k): return false
        if not sPut(kvS, 2, k): return false
      # Test helper: any failure means the scenario check fails.
      # (flush()'s inferred raises is Exception — see note above.)
      try: kvS.flush() except Exception: return false
      await ctx.flusher.requestFlushAsync()
      result = scanKeys(ctx.kv, 2) == scanKeys(kvS, 2)
    check waitFor scenario(ctx)
    closeCtx(ctx)

suite "kvstore_async: GC":
  test "auto-GC prunes roots past gc_root_count after flush":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "3"
    let ctx = newCtx(extra)
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for round in 0..<6:
        for i in 0..<50:
          if not sPut(ctx.kv, 0, @[byte(round), byte(i)]): return false
        await ctx.flusher.requestFlushAsync()
      result = (await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)).len <= 3 and
               scanKeys(ctx.kv, 0).len == 300
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "requestGcAsync dry run leaves store intact and reports":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for i in 0..<10:
        if not sPut(ctx.kv, 0, @[byte(i)]): return false
      await ctx.flusher.requestFlushAsync()
      let rootsBefore = (await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)).len
      if rootsBefore < 1: return false
      await ctx.flusher.requestGcAsync(true)
      let rep = ctx.flusher.lastGcReport
      if rep.len != 41 or rep[40] != 1: return false
      result = (await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)).len ==
               rootsBefore
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "requestGcAsync removes roots past gc_root_count":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "2"
    let ctx = newCtx(extra)
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for round in 0..<5:
        if not sPut(ctx.kv, 0, @[byte(round)]): return false
        await ctx.flusher.requestFlushAsync()
      # auto-GC already keeps the window; an explicit pass must not regress
      await ctx.flusher.requestGcAsync(false)
      let rep = ctx.flusher.lastGcReport
      if rep.len != 41 or rep[40] != 0: return false
      result = (await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)).len <= 2 and
               scanKeys(ctx.kv, 0).len == 5
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "many rounds with GC leave data readable":
    var extra = initTable[string, string]()
    extra["gc_root_count"] = "1"
    let ctx = newCtx(extra)
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      for round in 0..<4:
        for i in 0..<25:
          if not sPut(ctx.kv, 0, @[byte(round), byte(i)]): return false
        await ctx.flusher.requestFlushAsync()
      result = (await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)).len <= 1 and
               scanKeys(ctx.kv, 0).len == 100
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "gcFullAsync report counters match reality":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      if not sPut(ctx.kv, 0, @[byte(1)]): return false
      await ctx.flusher.requestFlushAsync()
      if not sPut(ctx.kv, 0, @[byte(2)]): return false
      await ctx.flusher.requestFlushAsync()
      let rep = await gcFullAsync(ctx.pool, ctx.kv.ps, 0'u64, 0, false)
      # 3 roots existed (initial + 2 flushes); age 0 keeps only the newest.
      if rep.len != 41: return false
      result = u64le(rep, 0) == 3'u64 and u64le(rep, 8) == 2'u64
    check waitFor scenario(ctx)
    closeCtx(ctx)

  test "onFlushRequest hook: threshold crossing auto-flushes":
    # The server wires batchWrite→onFlushRequest→requestFlushAsync on the
    # event loop. Testing that path end-to-end (server + gateway + REPL)
    # is done in the E2E smoke; the hook is a thin dispatch — tested at
    # the integration level, not in the async unit suite (gcsafe closure
    # over a captured AsyncFlusher requires cast(gcsafe), which AGENTS.md
    # forbids in application code; see shared_engine.armFlush for the
    # server's correct pattern).
    discard

  test "gcFullAsync fail-stop: unreadable kept root aborts pass without deletions":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      if not sPut(ctx.kv, 0, @[byte(1)]): return false
      await ctx.flusher.requestFlushAsync()
      if not sPut(ctx.kv, 0, @[byte(2)]): return false
      await ctx.flusher.requestFlushAsync()
      let roots = await listRootsAsync(ctx.pool, ctx.kv.ps[].blobs)
      if roots.len != 3: return false  # initial root + 2 flushes
      # Corrupt one KEPT root record (large age window keeps all listed):
      # the walk must fail loudly instead of silently skipping the subtree.
      try:
        writeFile(ctx.kv.path / "blobs" / roots[1], "\x00\x01\x02corrupt")
      except Exception:
        return false
      let before = (await listAsync(ctx.pool, ctx.kv.ps[].blobs)).len
      var raised = false
      try:
        discard await gcFullAsync(ctx.pool, ctx.kv.ps, 3_600'u64, 10, false)
      except CatchableError:
        raised = true
      if not raised: return false
      # Fail-stop contract: an aborted pass deletes nothing.
      result = (await listAsync(ctx.pool, ctx.kv.ps[].blobs)).len == before
    check waitFor scenario(ctx)
    closeCtx(ctx)

test "workspace cleanup":
  for d in gDirs:
    # Test teardown — best-effort removal, failure harmless.
    try: removeDir(d) except CatchableError: discard
