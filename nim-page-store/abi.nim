## abi.nim (page-store backend)
##
## C-ABI definitions for the page-store engine (COW B-tree on blobstore).
## Compiled with: nim c --mm:arc --threads:off -d:release --panics:on
##
## Error protocol: every function returns 0 on success or -1 on failure.
## On failure the caller-provided `errOut: ptr cint` receives one of the
## `Err*` codes below.

const
  ErrOk* = 0.cint
  ErrInvalidHandle* = 1.cint
  ErrInvalidArg* = 2.cint
  ErrIo* = 3.cint
  ErrReadOnly* = 4.cint
  ErrNoMem* = 5.cint
  ErrNotFound* = 6.cint
  ErrConflict* = 7.cint
  ErrConfig* = 8.cint

type
  Byte* = uint8
  ByteArr16* = array[16, Byte]
  BytePtr* = ptr UncheckedArray[Byte]
  CStringArr* = ptr UncheckedArray[cstring]

  # ── PageStore VTable ──

  GetKeysInPrefixFn* = proc(h: pointer; cf: cuint; prefix: ptr Byte; plen: csize_t;
                             outBuf: ptr pointer; outLen: ptr csize_t; errOut: ptr cint): cint {.cdecl.}
  KeyExistsFn* = proc(h: pointer; cf: cuint; key: ptr Byte; klen: csize_t;
                       outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.}
  PageCountFn* = proc(h: pointer; cf: cuint; outCount: ptr uint64; errOut: ptr cint): cint {.cdecl.}
  PageCountInRangeFn* = proc(h: pointer; cf: cuint;
                              start: ptr Byte; slen: csize_t;
                              endp: ptr Byte; elen: csize_t;
                              outCount: ptr uint64; errOut: ptr cint): cint {.cdecl.}

  CommitMergeFn* = proc(h: pointer; data: ptr Byte; dlen: csize_t;
                         clearJournal: cint; errOut: ptr cint): cint {.cdecl.}
  CommitFn* = proc(h: pointer; data: ptr Byte; dlen: csize_t;
                    clearJournal: cint; errOut: ptr cint): cint {.cdecl.}

  JournalPutFn* = proc(h: pointer; key: ptr Byte; klen: csize_t;
                        val: ptr Byte; vlen: csize_t; errOut: ptr cint): cint {.cdecl.}
  JournalScanFn* = proc(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                         errOut: ptr cint): cint {.cdecl.}
  JournalSizeFn* = proc(h: pointer; outSize: ptr uint64; errOut: ptr cint): cint {.cdecl.}

  GcFullFn* = proc(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
                    dryRun: cint; outBuf: ptr pointer; outLen: ptr csize_t;
                    errOut: ptr cint): cint {.cdecl.}

  CfStatsFn* = proc(h: pointer; cf: cuint; outBuf: ptr pointer; outLen: ptr csize_t;
                     errOut: ptr cint): cint {.cdecl.}
  DbStatsFn* = proc(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                     errOut: ptr cint): cint {.cdecl.}
  InternalStatusFn* = proc(h: pointer; target: cstring;
                             outStr: ptr pointer; outLen: ptr csize_t;
                             errOut: ptr cint): cint {.cdecl.}
  CollectLiveUuidsFn* = proc(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                               errOut: ptr cint): cint {.cdecl.}

  HasOldRootsFn* = proc(h: pointer; maxAgeSecs: uint64; maxRootCount: cuint;
                          outResult: ptr cint; errOut: ptr cint): cint {.cdecl.}
  RootCountFn* = proc(h: pointer; outCount: ptr uint64; errOut: ptr cint): cint {.cdecl.}
  CurrentRootFn* = proc(h: pointer; outStr: ptr pointer; outLen: ptr csize_t;
                         errOut: ptr cint): cint {.cdecl.}

  CloseFn* = proc(h: pointer) {.cdecl.}
  FreeBufFn* = proc(p: pointer) {.cdecl.}

  NimPageStoreVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    getKeysInPrefix*: GetKeysInPrefixFn
    keyExists*: KeyExistsFn
    pageCount*: PageCountFn
    pageCountInRange*: PageCountInRangeFn
    commitMerge*: CommitMergeFn
    commit*: CommitFn
    journalPut*: JournalPutFn
    journalScan*: JournalScanFn
    journalSize*: JournalSizeFn
    gcFull*: GcFullFn
    cfStats*: CfStatsFn
    dbStats*: DbStatsFn
    internalStatus*: InternalStatusFn
    collectLiveUuids*: CollectLiveUuidsFn
    hasOldRoots*: HasOldRootsFn
    rootCount*: RootCountFn
    currentRoot*: CurrentRootFn
    close*: CloseFn
    freeBuf*: FreeBufFn

  NimPageStoreVtablePtr* = ptr NimPageStoreVtableObj

  ## BlobStore vtable mirror (to call blobstore functions from page-store)
  NimBlobVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    put*: proc(h: pointer; data: ptr Byte; len: csize_t;
               idOut: ptr Byte; errOut: ptr cint): cint {.cdecl.}
    putAt*: proc(h: pointer; id: ptr Byte; data: ptr Byte; len: csize_t;
                 errOut: ptr cint): cint {.cdecl.}
    delete*: proc(h: pointer; id: ptr Byte; errOut: ptr cint): cint {.cdecl.}
    get*: proc(h: pointer; id: ptr Byte;
               outBuf: ptr pointer; outLen: ptr csize_t;
               outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.}
    list*: proc(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.}
    putRoot*: proc(h: pointer; name: cstring; data: ptr Byte; len: csize_t;
                   errOut: ptr cint): cint {.cdecl.}
    getRoot*: proc(h: pointer; name: cstring;
                   outBuf: ptr pointer; outLen: ptr csize_t;
                   outPresent: ptr cint; errOut: ptr cint): cint {.cdecl.}
    listRoots*: proc(h: pointer; outArr: ptr pointer; outCount: ptr csize_t;
                     errOut: ptr cint): cint {.cdecl.}
    deleteRoot*: proc(h: pointer; name: cstring; errOut: ptr cint): cint {.cdecl.}
    freeBuf*: proc(p: pointer) {.cdecl.}
    freeStrs*: proc(arr: CStringArr; count: csize_t) {.cdecl.}

  NimBlobVtablePtr* = ptr NimBlobVtableObj

  ## Journal vtable mirror
  NimJournalVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    append*: proc(h: pointer; key: ptr Byte; klen: csize_t;
                   val: ptr Byte; vlen: csize_t; errOut: ptr cint): cint {.cdecl.}
    read*: proc(h: pointer; outBuf: ptr pointer; outLen: ptr csize_t;
                errOut: ptr cint): cint {.cdecl.}
    truncate*: proc(h: pointer; errOut: ptr cint): cint {.cdecl.}
    size*: proc(h: pointer; outSize: ptr uint64; errOut: ptr cint): cint {.cdecl.}
    freeBuf*: proc(p: pointer) {.cdecl.}

  NimJournalVtablePtr* = ptr NimJournalVtableObj

proc newVtable*(): NimPageStoreVtablePtr =
  result = cast[NimPageStoreVtablePtr](allocShared0(sizeof(NimPageStoreVtableObj)))

proc freeVtable*(vt: NimPageStoreVtablePtr) =
  if vt != nil: deallocShared(vt)

template setErr*(errOut: ptr cint; code: cint) =
  if errOut != nil: errOut[] = code

proc allocByteBuf*(n: Natural): ptr Byte =
  if n == 0:
    result = cast[ptr Byte](allocShared0(1))
  else:
    result = cast[ptr Byte](allocShared(n))

proc freeShared*(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)

import std/tables

proc parseConfig*(keys, vals: CStringArr; n: csize_t): Table[string, string] =
  result = initTable[string, string](if n.int > 0: n.int else: 1)
  for i in 0 ..< n.int:
    if keys[i] != nil and vals[i] != nil:
      result[$keys[i]] = $vals[i]
