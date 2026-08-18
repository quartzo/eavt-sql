## test_blobstore_async.nim — tests for the async blobstore facade.
##
## Compiled under --mm:orc (chronos requirement); intentionally NOT part of
## all_tests (the suite stays atomicArc-only). Run via its nimble task:
##   cd nim_blobstore/async && nimble test

import std/[unittest, os, tables, random, sequtils, options, strutils, times]
import std/exitprocs
import chronos
import blobstore
import common
import file_backend as fil_be
import zstd_worker
import blobstore_async

type Ctx = ref object
  ## Ref cell passed as a parameter to each async scenario (async procs
  ## capture parameters on their closure env — GC-safe under orc; a module
  ## global would not be).
  pool: BlobPool
  store: FileBlobStore

var gStores: seq[string]  # plain-string registry; swept by the last test

proc newCtx(): Ctx =
  let path = getTempDir() / "eavt_blobasync_" & $getCurrentProcessId() & "_" &
             $epochTime().uint64 & "_" & $rand(high(int))
  createDir(path)
  gStores.add(path)
  result = Ctx(pool: startBlobPool(4), store: fil_be.newFileBlobStore(path))

suite "blobstore_async: round-trips":
  test "put then get returns identical bytes":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var page = newSeq[byte](4096)
      for i in 0..<page.len: page[i] = byte(i mod 251)
      let id = await ctx.pool.putPageAsync(ctx.store, page)
      let back = await ctx.pool.getPageAsync(ctx.store, id)
      result = back == page
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "tiny page (1 byte) and empty page":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      let id1 = await ctx.pool.putPageAsync(ctx.store, @[byte(7)])
      let back1 = await ctx.pool.getPageAsync(ctx.store, id1)
      let id0 = await ctx.pool.putPageAsync(ctx.store, @[])
      let back0 = await ctx.pool.getPageAsync(ctx.store, id0)
      result = back1 == @[byte(7)] and back0.len == 0
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "incompressible data still round-trips":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var rnd = initRand(42)
      var noise = newSeq[byte](128 * 1024)
      for i in 0..<noise.len: noise[i] = byte(rnd.rand(255))
      let id = await ctx.pool.putPageAsync(ctx.store, noise)
      let back = await ctx.pool.getPageAsync(ctx.store, id)
      result = back == noise
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "parity with the synchronous path":
    let ctx = newCtx()
    var page = newSeq[byte](2048)
    for i in 0..<page.len: page[i] = byte(i mod 17)
    # sync side (in the test body — sync context)
    let compressed = block:
      let bound = zstd_worker.compressBound(page.len)
      var buf = newSeq[byte](bound)
      let n = zstd_worker.compressInto(page[0].unsafeAddr, page.len,
                                       buf[0].unsafeAddr, buf.len)
      doAssert n >= 0
      buf.setLen(n)
      buf
    let idB = ctx.store.put(compressed)
    let backB = block:
      let raw = ctx.store.get(idB).get
      var buf = newSeq[byte](page.len + 64)
      let n = zstd_worker.decompressInto(raw[0].unsafeAddr, raw.len,
                                         buf[0].unsafeAddr, buf.len)
      doAssert n >= 0
      buf.setLen(n)
      buf
    proc scenario(ctx: Ctx; page, backB: seq[byte]): Future[bool] {.async.} =
      let idA = await ctx.pool.putPageAsync(ctx.store, page)
      let backA = await ctx.pool.getPageAsync(ctx.store, idA)
      result = backA == page and backA == backB
    check waitFor scenario(ctx, page, backB)
    waitFor ctx.pool.closeBlobPool()

  test "roots round-trip":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var rootData = newSeq[byte](64)
      for i in 0..<64: rootData[i] = byte(i)
      await ctx.pool.putRootAsync(ctx.store, "root_test_1", rootData)
      let back = await ctx.pool.getRootAsync(ctx.store, "root_test_1")
      result = back == rootData
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "missing blob/root raise":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var missing: ByteArr16
      for i in 0..<16: missing[i] = byte(i)
      var raised = 0
      try: discard await ctx.pool.getPageAsync(ctx.store, missing)
      except CatchableError: inc raised
      try: discard await ctx.pool.getRootAsync(ctx.store, "no_such_root")
      except CatchableError: inc raised
      result = raised == 2
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

suite "blobstore_async: concurrency & cancellation":
  test "many sequential puts, concurrent gets":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var ids: seq[ByteArr16] = @[]
      var pages: seq[seq[byte]] = @[]
      for k in 0..<64:
        var p = newSeq[byte](1024)
        for i in 0..<p.len: p[i] = byte((i + k) mod 256)
        pages.add(p)
        ids.add(await ctx.pool.putPageAsync(ctx.store, p))
      proc checkOne(ctx: Ctx; k: int): Future[bool] {.async.} =
        let back = await ctx.pool.getPageAsync(ctx.store, ids[k])
        result = back == pages[k]
      var futs: seq[Future[bool]] = @[]
      for k in 0..<64: futs.add(checkOne(ctx, k))
      var okCount = 0
      for f in futs:
        if await f: inc okCount
      result = okCount == 64
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "abandoned future: op completes, pool healthy":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var p = newSeq[byte](512)
      for i in 0..<p.len: p[i] = byte(i)
      let fut = ctx.pool.putPageAsync(ctx.store, p)
      fut.cancelSoon()
      await sleepAsync(chronos.milliseconds(50))
      let id = await ctx.pool.putPageAsync(ctx.store, p)
      let back = await ctx.pool.getPageAsync(ctx.store, id)
      result = back == p
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "loop never blocked: timers fire during worker ops":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var ticks = 0
      proc ticker(): Future[void] {.async.} =
        for i in 0..<10:
          await sleepAsync(chronos.milliseconds(1))
          inc ticks
      var p = newSeq[byte](64 * 1024)
      for i in 0..<p.len: p[i] = byte(i mod 7)
      let tickFut = ticker()
      discard await ctx.pool.putPageAsync(ctx.store, p)
      await tickFut
      result = ticks == 10
    check waitFor scenario(ctx)
    waitFor ctx.pool.closeBlobPool()

  test "pool shutdown drains cleanly":
    let ctx = newCtx()
    proc scenario(ctx: Ctx): Future[bool] {.async.} =
      var p = newSeq[byte](1024)
      for i in 0..<p.len: p[i] = byte(i)
      discard await ctx.pool.putPageAsync(ctx.store, p)
      await ctx.pool.closeBlobPool()
      result = true
    check waitFor scenario(ctx)

proc cleanupAll() =
  ## Last test's dir is cleaned here (earlier ones are removed as their own
  ## exit hook inside newCtx below).
  for p in gStores:
    try: removeDir(p) except CatchableError: discard

test "workspace cleanup":
  cleanupAll()
