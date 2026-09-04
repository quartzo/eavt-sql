## datoms.nim — the canonical volatile datom vector (M5).
##
## One append-only, chunked byte vector of canonical CF-0 datom keys
## ([eid 8B][aid 4B][val][sf 8B]) — the storage behind ALL CFs' write
## state: the hydrated entries reference slots here instead of owning key
## copies, and the flush drains the volatile window from here.
##
## Design (decided with user, session M5):
##   * chunks are immutable after seal; a slot (chunk, off, klen) is
##     stable forever — no readerCount, no path-copying: open cursors
##     hold chunk refs and see a frozen view;
##   * "volatile" = keys with t > publishedT (the flush's durability
##     watermark). [publishedT .. now) is the write window;
##   * pinning: a hydrated entry pins the chunks its slots reference, so
##     publish cannot release data a cache entry still needs. A pinned
##     chunk is released whole when its pin count drops and it is fully
##     below the watermark (fragmentation = chunk granularity, 256 KiB);
##   * generation bumps per append — the run cache (sorted snapshots in
##     the cursor layer) revalidates against it, paying the sort once per
##     "epoch" of writes instead of per cursor open;
##   * single-threaded by construction (event loop owner), like hydrated.nim.
##
## Why a vector beats the per-entry flat buffer: ~3-4× less RAM per datom
## (one copy of val instead of 4 index encodings), O(1) appends (no
## insertKeyAt memmove), and the flush drain reads a contiguous suffix.

import keys

const
  DefaultChunkBytes* = 256 * 1024   ## sealed chunk granularity (pin unit)
  DefaultVectorMaxBytes* = 1 shl 30 ## 1 GiB — cfg `datom_vector_max_bytes`

type
  DatomSlot* = object
    chunk*: int32      ## index into chunks[] (released chunks stay, nil'd)
    off*: int32        ## key start within the chunk buffer
    klen*: int32       ## key length (CF-0 canonical: ≥ 20)

  DatomChunk* = ref object
    buf*: seq[byte]        ## keys; immutable after `sealed`
    offs*: seq[int32]      ## key start offsets (parallel to lens)
    lens*: seq[int32]      ## key lengths (parallel to offs)
    minT*: int64           ## min t across keys (0 when empty)
    maxT*: int64           ## max t across keys
    pinned*: int           ## pin count (hydrated entries / open cursors)
    sealed*: bool
    volatileBytes*: int    ## bytes of keys with t > publishedT

  DatomVector* = ref object
    chunks: seq[DatomChunk]   ## nil holes mark released chunks
    cur: DatomChunk           ## open (mutable) chunk
    generation*: uint64       ## bumps per append (run-cache validation)
    publishedT*: int64        ## durability watermark (flush publish)
    volatileBytes*: int       ## bytes with t > publishedT — flush feed
    maxBytes*: int
    chunkBytes: int

proc newDatomVector*(maxBytes: int = DefaultVectorMaxBytes;
                     chunkBytes: int = DefaultChunkBytes): DatomVector =
  result = DatomVector(maxBytes: maxBytes, chunkBytes: chunkBytes)
  result.chunks = @[]
  result.cur = nil  # opened lazily by the first append (registered in chunks)

proc chunkAt*(v: DatomVector; s: DatomSlot): DatomChunk =
  ## The chunk holding the slot's key (nil when released). Callers holding
  ## byte views must hold the chunk ref too — ARC keeps the bytes alive.
  if s.chunk < 0 or s.chunk >= v.chunks.len: return nil
  result = v.chunks[s.chunk]

proc volatileBytes*(v: DatomVector): int {.inline.} = v.volatileBytes

proc numChunks*(v: DatomVector): int =
  for c in v.chunks:
    if c != nil: inc result

proc append*(v: DatomVector; key: openArray[byte]; t: int64): DatomSlot =
  ## Append one canonical CF-0 key. O(1) amortized (chunk fill); the key is
  ## copied into the chunk — the caller's buffer may be reused immediately.
  if v.cur == nil or v.cur.sealed or
     v.cur.buf.len + key.len > v.chunkBytes:
    if v.cur != nil and not v.cur.sealed:
      v.cur.sealed = true  # rolled over: the previous chunk becomes immutable
    v.chunks.add DatomChunk(buf: newSeqOfCap[byte](v.chunkBytes),
                            offs: newSeqOfCap[int32](1024),
                            lens: newSeqOfCap[int32](1024),
                            minT: t, maxT: t, pinned: 0,
                            sealed: false, volatileBytes: 0)
    v.cur = v.chunks[^1]
  let slot = DatomSlot(chunk: int32(v.chunks.len - 1),
                       off: int32(v.cur.buf.len), klen: int32(key.len))
  v.cur.buf.add key
  v.cur.offs.add int32(slot.off)
  v.cur.lens.add int32(key.len)
  if v.cur.minT == 0 or t < v.cur.minT: v.cur.minT = t
  if t > v.cur.maxT: v.cur.maxT = t
  inc v.cur.volatileBytes, key.len
  inc v.volatileBytes, key.len
  inc v.generation
  result = slot

proc keyCopy*(v: DatomVector; s: DatomSlot): seq[byte] =
  ## Owned copy of the slot's key (safe across publish — the canonical way
  ## to hand keys to the flush worker / cursors that outlive the epoch).
  let c = v.chunkAt(s)
  if c == nil: return @[]
  result = newSeq[byte](s.klen)
  if s.klen > 0:
    copyMem(addr result[0], addr c.buf[s.off], s.klen)

proc cmpSlotKey*(v: DatomVector; s: DatomSlot; target: openArray[byte]): int =
  ## Zero-alloc comparison of the slot's key against a target byte seq.
  let c = v.chunkAt(s)
  if c == nil: return -1
  let n = min(s.klen.int, target.len)
  for i in 0 ..< n:
    let a = c.buf[s.off + i]
    if a != target[i]:
      return (if a < target[i]: -1 else: 1)
  cmp(s.klen.int, target.len)

proc pin*(v: DatomVector; s: DatomSlot) =
  ## Retain the chunk (hydrated entry / open cursor holding views).
  let c = v.chunkAt(s)
  if c != nil: inc c.pinned

proc unpin*(v: DatomVector; s: DatomSlot) =
  let c = v.chunkAt(s)
  if c != nil and c.pinned > 0: dec c.pinned

proc walkChunkVolatile(c: DatomChunk; publishedT: int64): int =
  ## Exact volatile byte count of one chunk (per-key t check; only used for
  ## the straddling chunk — chunk-sized, rare).
  for i in 0 ..< c.offs.len:
    let off = c.offs[i].int
    let klen = c.lens[i].int
    let t = (beUint64(c.buf, off + klen - 8) shr 1).int64
    if t > publishedT: inc result, klen

proc publish*(v: DatomVector; watermarkT: int64) =
  ## Advance the durability watermark; release sealed chunks that are
  ## fully durable (maxT <= watermark) and unpinned. Pinned chunks keep
  ## their bytes (cache entries own them) — when the last pin drops, the
  ## next publish reclaims. Recomputes volatileBytes.
  v.publishedT = max(v.publishedT, watermarkT)
  var vb = 0
  for i in 0 ..< v.chunks.len:
    let c = v.chunks[i]
    if c == nil: continue
    if c.sealed and c.maxT <= v.publishedT and c.pinned == 0:
      v.chunks[i] = nil               # fully durable, unpinned → release
      continue
    if not c.sealed or c.minT > v.publishedT:
      discard  # fully volatile (open chunk or above watermark)
      vb += c.volatileBytes
    else:
      c.volatileBytes = c.walkChunkVolatile(v.publishedT)
      vb += c.volatileBytes
  v.volatileBytes = vb

proc sealCurrent*(v: DatomVector) =
  ## Seal the open chunk (flush capture boundary): its bytes become
  ## immutable and publishable. The next append opens a fresh chunk.
  if v.cur != nil and not v.cur.sealed: v.cur.sealed = true

proc drainVolatile*(v: DatomVector): seq[seq[byte]] =
  ## All volatile keys (t > publishedT), unsorted (the flush worker sorts).
  ## Owned copies — the caller (worker thread) outlives the epoch.
  for c in v.chunks:
    if c == nil: continue
    if c.sealed and c.minT > v.publishedT:
      for i in 0 ..< c.offs.len:
        result.add c.buf[c.offs[i].int ..< c.offs[i].int + c.lens[i].int]
    else:
      for i in 0 ..< c.offs.len:
        let off = c.offs[i].int
        let klen = c.lens[i].int
        let sf = beUint64(c.buf, off + klen - 8)
        if (sf shr 1).int64 > v.publishedT:
          result.add c.buf[off ..< off + klen]

proc chunkKeyCount*(c: DatomChunk): int = c.offs.len
