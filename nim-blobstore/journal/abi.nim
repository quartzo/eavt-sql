## abi.nim (journal backend)
##
## C-ABI definitions for the file-backed Journal engine.
## Compiled with: nim c --mm:arc --threads:off -d:release --panics:on
##
## Error protocol: every function returns 0 on success or -1 on failure.
## On failure the caller-provided `errOut: ptr cint` receives one of the
## `Err*` codes below. Rust maps the code to a static message -- no string
## allocation crosses the FFI boundary.

import spinlock

const
  ErrOk* = 0.cint
  ErrInvalidHandle* = 1.cint   ## nil / unknown backend handle
  ErrInvalidArg* = 2.cint      ## malformed key/value or config
  ErrIo* = 3.cint              ## I/O failure (disk)
  ErrReadOnly* = 4.cint        ## write attempted on read-only backend
  ErrNoMem* = 5.cint           ## allocation failure
  ErrNotFound* = 6.cint        ## file not present
  ErrConflict* = 7.cint        ## unique-constraint violation (unused)
  ErrConfig* = 8.cint          ## missing / invalid config key

type
  Byte* = uint8
  BytePtr* = ptr UncheckedArray[Byte]

  ## Journal VTable: one function pointer per JournalEngine trait method,
  ## plus freeBuf for releasing the buffer returned by `read`.
  AppendFn* = proc(h: pointer, key: ptr Byte, klen: csize_t,
                   `val`: ptr Byte, vlen: csize_t,
                   errOut: ptr cint): cint {.cdecl.}
  ReadFn* = proc(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
                 errOut: ptr cint): cint {.cdecl.}
  TruncateFn* = proc(h: pointer, errOut: ptr cint): cint {.cdecl.}
  SizeFn* = proc(h: pointer, outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}
  FreeBufFn* = proc(p: pointer) {.cdecl.}

  NimJournalVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    append*: AppendFn
    read*: ReadFn
    truncate*: TruncateFn
    size*: SizeFn
    freeBuf*: FreeBufFn

  NimJournalVtablePtr* = ptr NimJournalVtableObj

proc newVtable*(): NimJournalVtablePtr =
  result = cast[NimJournalVtablePtr](allocShared0(sizeof(NimJournalVtableObj)))

proc freeVtable*(vt: NimJournalVtablePtr) =
  if vt != nil: deallocShared(vt)

## Set `errOut` to a code if the pointer is non-nil. Idempotent -- safe to
## call unconditionally before an early `return`.
template setErr*(errOut: ptr cint, code: cint) =
  if errOut != nil: errOut[] = code

proc allocByteBuf*(n: Natural): ptr Byte =
  if n == 0:
    result = cast[ptr Byte](allocShared0(1))
  else:
    result = cast[ptr Byte](allocShared(n))

proc freeShared*(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)
