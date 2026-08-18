## zstd_worker.nim — raw-pointer zstd bindings for worker threads.
##
## Worker-safe: takes/returns raw pointers and lengths only — no GC types,
## no refcounts. Used by blobstore_async's worker half; page_store keeps its
## own seq-based wrappers.

proc ZSTD_compressBound*(srcSize: csize_t): csize_t
    {.importc: "ZSTD_compressBound", cdecl.}

proc ZSTD_compress*(dst: pointer; dstCapacity: csize_t;
                    src: pointer; srcSize: csize_t;
                    compressionLevel: cint): csize_t
    {.importc: "ZSTD_compress", cdecl.}

proc ZSTD_decompress*(dst: pointer; dstCapacity: csize_t;
                      src: pointer; srcSize: csize_t): csize_t
    {.importc: "ZSTD_decompress", cdecl.}

proc ZSTD_isError*(code: csize_t): cuint
    {.importc: "ZSTD_isError", cdecl.}

const
  zstdLevel = 1.cint
    ## Matches page_store's compress level.

proc compressInto*(src: pointer; srcLen: int; dst: pointer; dstCap: int): int {.
    gcsafe, raises: [].} =
  ## Compress src into dst (pre-sized by the caller). Returns the compressed
  ## length, or -1 on zstd failure. No raise, no GC: worker-safe.
  let rc = ZSTD_compress(dst, dstCap.csize_t, src, srcLen.csize_t, zstdLevel)
  if ZSTD_isError(rc) != 0: return -1
  int(rc)

proc compressBound*(srcLen: int): int {.gcsafe, inline.} =
  int(ZSTD_compressBound(srcLen.csize_t))

proc isZstd*(src: pointer; srcLen: int): bool {.gcsafe, inline.} =
  srcLen >= 4 and
    (cast[ptr UncheckedArray[byte]](src))[0] == 0x28 and
    (cast[ptr UncheckedArray[byte]](src))[1] == 0xB5 and
    (cast[ptr UncheckedArray[byte]](src))[2] == 0x2F and
    (cast[ptr UncheckedArray[byte]](src))[3] == 0xFD

proc decompressInto*(src: pointer; srcLen: int; dst: pointer; dstCap: int): int {.
    gcsafe, raises: [].} =
  ## Decompress src into dst. Pass-through for non-zstd payloads (matches
  ## page_store.decompress semantics). Returns written length, or -1 on
  ## failure or insufficient capacity (no raise: worker-safe).
  if not isZstd(src, srcLen):
    if srcLen <= dstCap:
      if srcLen > 0: copyMem(dst, src, srcLen)
      return srcLen
    return -1
  let rc = ZSTD_decompress(dst, dstCap.csize_t, src, srcLen.csize_t)
  if ZSTD_isError(rc) != 0: return -1
  int(rc)

proc zstdDecompressBound*(): int {.gcsafe, inline.} =
  ## Conservative output capacity for a ≤256 KiB page (mirrors
  ## page_store.decompress sizing: bound*4 with a 256 KiB floor).
  max(int(ZSTD_compressBound(262144.csize_t)) * 4, 262144)
