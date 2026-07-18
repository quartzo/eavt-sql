## abi.nim (memtable backend)
##
## C-ABI definitions for the file-backed MemTable engine (persistent treap,
## COW snapshots). Compiled with: nim c --mm:arc --threads:off -d:release --panics:on
##
## Error protocol: every function returns 0 on success or -1 on failure.
## On failure the caller-provided `errOut: ptr cint` receives one of the
## `Err*` codes below. Rust maps the code to a static message -- no string
## allocation crosses the FFI boundary.

import spinlock

const
  ErrOk* = 0.cint
  ErrInvalidHandle* = 1.cint   ## nil / unknown backend handle
  ErrInvalidArg* = 2.cint      ## malformed key or config
  ErrIo* = 3.cint              ## I/O failure (unused for memtable)
  ErrReadOnly* = 4.cint        ## write attempted on read-only backend
  ErrNoMem* = 5.cint           ## allocation failure
  ErrNotFound* = 6.cint        ## key / id not present
  ErrConflict* = 7.cint        ## unique-constraint violation (unused)
  ErrConfig* = 8.cint          ## missing / invalid config key

type
  Byte* = uint8
  BytePtr* = ptr UncheckedArray[Byte]

  ## MemTable VTable. The snapshot/cursor FFI is what lets Rust iterate the
  ## Nim-resident ordered structure lazily: Rust holds only opaque u64 ids,
  ## never a reference to the structure itself.
  PutFn* = proc(h: pointer, cf: cuint, key: ptr Byte, klen: csize_t,
                 outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  BatchFn* = proc(h: pointer, ops: ptr Byte, olen: csize_t,
                  outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  ClearFn* = proc(h: pointer, errOut: ptr cint): cint {.cdecl.}
  SnapshotFn* = proc(h: pointer, outId: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  SnapshotFreeFn* = proc(h: pointer, id: uint64) {.cdecl.}
  ScanFn* = proc(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                reverse: cint, outCursor: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  CursorNextFn* = proc(h: pointer, cursor: uint64,
                       outKey: ptr pointer, outLen: ptr csize_t,
                       outValid: ptr cint, errOut: ptr cint): cint {.cdecl.}
  CursorSeekFn* = proc(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                       errOut: ptr cint): cint {.cdecl.}
  CursorAdvanceToFn* = proc(h: pointer, cursor: uint64, target: ptr Byte, tlen: csize_t,
                            errOut: ptr cint): cint {.cdecl.}
  CursorSkipGroupFn* = proc(h: pointer, cursor: uint64, group: ptr Byte, glen: csize_t,
                            errOut: ptr cint): cint {.cdecl.}
  CursorUpdateEndFn* = proc(h: pointer, cursor: uint64, endp: ptr Byte, elen: csize_t,
                            errOut: ptr cint): cint {.cdecl.}
  CursorFreeFn* = proc(h: pointer, cursor: uint64) {.cdecl.}
  ContainsFn* = proc(h: pointer, id: uint64, cf: cuint, key: ptr Byte, klen: csize_t,
                    outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.}
  CountPrefixFn* = proc(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                        outCount: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  ScanPrefixFn* = proc(h: pointer, id: uint64, cf: cuint, prefix: ptr Byte, plen: csize_t,
                       reverse: cint, outBuf: ptr pointer, outLen: ptr csize_t,
                       errOut: ptr cint): cint {.cdecl.}
  FreeBufFn* = proc(p: pointer) {.cdecl.}

  NimMemTableVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    put*: PutFn
    batch*: BatchFn
    clear*: ClearFn
    snapshot*: SnapshotFn
    snapshotFree*: SnapshotFreeFn
    scan*: ScanFn
    cursorNext*: CursorNextFn
    cursorSeek*: CursorSeekFn
    cursorAdvanceTo*: CursorAdvanceToFn
    cursorSkipGroup*: CursorSkipGroupFn
    cursorUpdateEnd*: CursorUpdateEndFn
    cursorFree*: CursorFreeFn
    contains*: ContainsFn
    countPrefix*: CountPrefixFn
    scanPrefix*: ScanPrefixFn
    freeBuf*: FreeBufFn

  NimMemTableVtablePtr* = ptr NimMemTableVtableObj

proc newVtable*(): NimMemTableVtablePtr =
  result = cast[NimMemTableVtablePtr](allocShared0(sizeof(NimMemTableVtableObj)))

proc freeVtable*(vt: NimMemTableVtablePtr) =
  if vt != nil: deallocShared(vt)

template setErr*(errOut: ptr cint, code: cint) =
  if errOut != nil: errOut[] = code

proc allocByteBuf*(n: Natural): ptr Byte =
  if n == 0:
    result = cast[ptr Byte](allocShared0(1))
  else:
    result = cast[ptr Byte](allocShared(n))

proc freeShared*(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)
