## flush_worker.nim — a dedicated thread runs the flush's hot path (key-only
## drain + commitMergeCore) off the event loop.
##
## Follows the blob pool's cross-thread pattern: the worker touches only the
## POD half of the job — and M8 keeps it STRICTLY POD: runs cross as raw
## views (ptr + len sobre o seq de ponteiros de registro do Run), NUNCA
## como refs GC — inc/dec de refcount do ORC em thread não-dona corrompe o
## heap do loop (crash do materialize sob carga).  O loop mantém os Run
## owners (runsByCfOwner) vivos e intocados até o done.  Todo GC value que
## o worker cria (keys, merged pages) nasce e morre no frame dele.
##
## KV CFs (>= 10) stay on the loop: the caller only routes a flush here when
## it is pure key-only (no live KV roots), so the worker's single root write is
## the only one for that generation.

import std/atomics
import std/locks
import std/algorithm
import chronos
import blobstore
import nim_memtable/memtypes
import nim_memtable/runs
import page_store

type
  RunView* = object
    ## POD view de um run congelado: o buffer de ponteiros de registro do
    ## Run (cada um aponta para [flags][klen][key] no arena compartilhado —
    ## memória crua, viva enquanto o loop segurar o Run).
    ptrs: ptr UncheckedArray[ptr UncheckedArray[byte]]
    n: int
    kv: bool

  FlushWorkerObj = object
    lock: Lock
    cond: Cond
    stopping: Atomic[bool]
    requested: Atomic[bool]
    done: Atomic[bool]
    # job input (POD; loop writes before request, worker reads)
    numCf: int
    trees: ptr UncheckedArray[CfTree]   ## worker writes new trees here
    blobs: BlobStore                    ## sync trait, plain pointer for worker
    views: ptr UncheckedArray[seq[RunView]]  ## views por CF (buffer do loop)
    numViews: int
    # result (POD; worker writes)
    rootNameBuf: array[128, char]
    rootNameLen: int
    maxT: int64             ## max datom t across the flushed keys (M6: the
                            ## commit watermark for write-through mirrors)
    ok: bool
    errBuf: array[96, char]
    errLen: int
    # loop-only (keep the GC owners alive + the thread handle)
    runsOwner: seq[seq[Run]]   ## os Run refs — só o loop toca
    viewsOwner: seq[seq[RunView]]
    treesSeq: seq[CfTree]
    thread: Thread[ptr FlushWorkerObj]

  FlushWorker* = ref object
    inner: ptr FlushWorkerObj

proc drainKeys(n: int; views: ptr UncheckedArray[RunView];
               keys: var seq[seq[byte]]) =
  ## K-way merge dos runs (ordenados) materializando as chaves — só memória
  ## crua; as seqs resultantes nascem e morrem no frame do worker.
  var heads = newSeq[int](n)
  var total = 0
  for v in 0 ..< n: total += views[v].n
  if total == 0: return
  keys = newSeqOfCap[seq[byte]](total)
  while true:
    var best = -1
    for v in 0 ..< n:
      if heads[v] >= views[v].n: continue
      if best < 0:
        best = v
        continue
      let c = cmpRec(views[v].ptrs[heads[v]], views[best].ptrs[heads[best]])
      if c < 0 or (c == 0 and v > best):
        best = v
    if best < 0: break
    let p = views[best].ptrs[heads[best]]
    let klen = recKlen(p)
    var k = newSeq[byte](klen)
    if klen > 0: copyMem(addr k[0], recKeyPtr(p), klen)
    keys.add(k)
    inc heads[best]
    for v in 0 ..< n:
      if v == best: continue
      while heads[v] < views[v].n and cmpRec(views[v].ptrs[heads[v]], p) == 0:
        inc heads[v]

proc flushWorkerMain(w: ptr FlushWorkerObj) {.thread.} =
  while true:
    acquire(w.lock)
    while not w.requested.load(moAcquire) and not w.stopping.load(moAcquire):
      wait(w.cond, w.lock)
    let doWork = w.requested.load(moAcquire) and not w.stopping.load(moAcquire)
    w.requested.store(false, moRelease)
    release(w.lock)
    if not doWork:
      break
    try:
      var keysByCf: seq[(int, seq[seq[byte]])] = @[]
      for cf in 0 ..< w.numCf:
        if cf >= 10: break  # key-only CFs only
        var keys: seq[seq[byte]] = @[]
        if cf < w.numViews:
          drainKeys(w.views[cf].len,
                    cast[ptr UncheckedArray[RunView]](
                      if w.views[cf].len > 0: addr w.views[cf][0] else: nil),
                    keys)
        if keys.len > 0: keysByCf.add (cf, keys)
      var maxT: int64 = -1
      for (cf, ks) in keysByCf:
        for k in ks:
          if k.len < 8: continue
          var sf = 0'u64
          for b in k[k.len - 8 ..< k.len]: sf = (sf shl 8) or uint64(b)
          let kt = (sf shr 1).int64
          if kt > maxT: maxT = kt
      w.maxT = maxT
      let rootName = commitMergeCore(w.blobs, w.trees, w.numCf, keysByCf)
      let n = min(rootName.len, w.rootNameBuf.len)
      if n > 0: copyMem(addr w.rootNameBuf[0], unsafeAddr rootName[0], n)
      w.rootNameLen = n
      w.ok = true
    except CatchableError as e:
      let msg = e.msg
      let n = min(msg.len, w.errBuf.len - 1)
      if n > 0: copyMem(addr w.errBuf[0], unsafeAddr msg[0], n)
      w.errLen = n
      w.maxT = -1
      w.ok = false
    w.done.store(true, moRelease)

proc startFlushWorker*(): FlushWorker =
  result = FlushWorker(inner:
    cast[ptr FlushWorkerObj](allocShared0(sizeof(FlushWorkerObj))))
  let w = result.inner
  initLock(w.lock)
  initCond(w.cond)
  createThread(w.thread, flushWorkerMain, w)

proc closeFlushWorker*(fw: FlushWorker) {.async.} =
  ## Stop the worker and release its resources. Must run on the loop, after
  ## the flusher drained (no in-flight flush).
  let w = fw.inner
  w.stopping.store(true, moRelease)
  acquire(w.lock)
  w.cond.broadcast()
  release(w.lock)
  joinThread(w.thread)
  deinitCond(w.cond)
  deinitLock(w.lock)
  deallocShared(w)

proc runFlush*(fw: FlushWorker; numCf: int; runsByCf: seq[seq[Run]];
               trees: seq[CfTree]; blobs: BlobStore):
    Future[tuple[rootName: string, trees: seq[CfTree], maxT: int64, ok: bool]] {.async.} =
  ## Submit a pure key-only flush, wait for completion, return the result.
  ## M8: os Run refs cruzam como VIEWS POD — o loop materializa os buffers
  ## de ponteiros crus antes do request e mantém `runsByCf` (os Run refs)
  ## vivos e intocados até o done; a thread nunca toca refcount do loop.
  let w = fw.inner
  w.runsOwner = runsByCf
  w.viewsOwner = newSeq[seq[RunView]](numCf)
  for cf in 0 ..< min(numCf, runsByCf.len):
    let runs = runsByCf[cf]
    if runs.len == 0: continue
    var vs = newSeq[RunView](runs.len)
    for i, r in runs:
      if r.ptrs.len == 0: continue
      vs[i] = RunView(ptrs: cast[ptr UncheckedArray[ptr UncheckedArray[byte]]](
                        addr r.ptrs[0]),
                      n: r.ptrs.len, kv: r.kv)
    w.viewsOwner[cf] = vs
  w.views = (if w.viewsOwner.len > 0:
    cast[ptr UncheckedArray[seq[RunView]]](addr w.viewsOwner[0]) else: nil)
  w.numViews = w.viewsOwner.len
  w.treesSeq = newSeq[CfTree](trees.len)
  if trees.len > 0:
    copyMem(addr w.treesSeq[0], unsafeAddr trees[0],
            trees.len * sizeof(CfTree))
  w.numCf = numCf
  w.trees = (if w.treesSeq.len > 0:
    cast[ptr UncheckedArray[CfTree]](addr w.treesSeq[0]) else: nil)
  w.blobs = blobs
  w.done.store(false, moRelease)
  w.requested.store(true, moRelease)
  acquire(w.lock)
  w.cond.signal()
  release(w.lock)
  while not w.done.load(moAcquire):
    await sleepAsync(1.milliseconds)
  if w.ok:
    # NOTA: `$` sobre slice de array[char] produz o REPR (@['r', ...]) —
    # foi exatamente o bug que corrompia o rootName broadcastado à réplica
    # (publishRoot falhava, réplica presa na geração 0, db.* perdidos no
    # seal seguinte → "attribute resolution failed" em todo SQL). Construir
    # string explicitamente.
    var rn = newString(w.rootNameLen)
    if w.rootNameLen > 0:
      copyMem(addr rn[0], addr w.rootNameBuf[0], w.rootNameLen)
    result = (rootName: rn, trees: w.treesSeq, maxT: w.maxT, ok: true)
  else:
    result = (rootName: "", trees: @[], maxT: -1, ok: false)
