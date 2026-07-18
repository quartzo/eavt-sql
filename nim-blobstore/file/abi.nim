## abi.nim (memory backend)
##
## C-ABI definitions for the memory BlobStore backend.
## Compiled with: nim c --mm:arc --threads:off -d:release --panics:on
##
## Error protocol: every function returns 0 on success or -1 on failure.
## On failure the caller-provided `errOut: ptr cint` receives one of the
## `Err*` codes below. Rust maps the code to a static message — no string
## allocation crosses the FFI boundary.

import std/sysrand
import std/random
import spinlock

const
  ErrOk* = 0.cint
  ErrInvalidHandle* = 1.cint   ## nil / unknown backend handle
  ErrInvalidArg* = 2.cint      ## malformed key, name, or config
  ErrIo* = 3.cint              ## I/O failure (disk, network, S3)
  ErrReadOnly* = 4.cint        ## write attempted on read-only backend
  ErrNoMem* = 5.cint           ## allocation failure
  ErrNotFound* = 6.cint        ## id / root not present
  ErrConflict* = 7.cint        ## unique-constraint violation
  ErrConfig* = 8.cint          ## missing / invalid config key

type
  Byte* = uint8
  ByteArr16* = array[16, Byte]
  BytePtr* = ptr UncheckedArray[Byte]
  CStringArr* = ptr UncheckedArray[cstring]

  PutFn* = proc(h: pointer, data: ptr Byte, len: csize_t,
                idOut: ptr Byte, errOut: ptr cint): cint {.cdecl.}
  PutAtFn* = proc(h: pointer, id: ptr Byte, data: ptr Byte, len: csize_t,
                  errOut: ptr cint): cint {.cdecl.}
  DeleteFn* = proc(h: pointer, id: ptr Byte,
                   errOut: ptr cint): cint {.cdecl.}
  GetFn* = proc(h: pointer, id: ptr Byte,
                outBuf: ptr pointer, outLen: ptr csize_t,
                outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.}
  ListFn* = proc(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
                 errOut: ptr cint): cint {.cdecl.}
  PutRootFn* = proc(h: pointer, name: cstring, data: ptr Byte, len: csize_t,
                    errOut: ptr cint): cint {.cdecl.}
  GetRootFn* = proc(h: pointer, name: cstring,
                    outBuf: ptr pointer, outLen: ptr csize_t,
                    outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.}
  ListRootsFn* = proc(h: pointer, outBuf: ptr pointer, outCount: ptr csize_t,
                      errOut: ptr cint): cint {.cdecl.}
  DeleteRootFn* = proc(h: pointer, name: cstring,
                       errOut: ptr cint): cint {.cdecl.}
  FreeBufFn* = proc(p: pointer) {.cdecl.}
  FreeStrsFn* = proc(arr: CStringArr, count: csize_t) {.cdecl.}

  NimBlobVtableObj* {.pure, bycopy.} = object
    handle*: pointer
    put*: PutFn
    putAt*: PutAtFn
    delete*: DeleteFn
    get*: GetFn
    list*: ListFn
    putRoot*: PutRootFn
    getRoot*: GetRootFn
    listRoots*: ListRootsFn
    deleteRoot*: DeleteRootFn
    freeBuf*: FreeBufFn
    freeStrs*: FreeStrsFn

  NimBlobVtablePtr* = ptr NimBlobVtableObj

proc newVtable*(): NimBlobVtablePtr =
  result = cast[NimBlobVtablePtr](allocShared0(sizeof(NimBlobVtableObj)))

proc freeVtable*(vt: NimBlobVtablePtr) =
  if vt != nil: deallocShared(vt)

## Set `errOut` to a code if the pointer is non-nil. Idempotent — safe to
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

var uuidSeeded: bool = false
var uuidSeedLock: SpinLock
initSpinLock(uuidSeedLock)

proc newUuidBytes*(outBuf: ptr Byte) =
  var b: ByteArr16
  if not urandom(b):
    uuidSeedLock.acquire()
    try:
      if not uuidSeeded:
        randomize()
        uuidSeeded = true
    finally:
      uuidSeedLock.release()
    for i in 0 ..< 16:
      b[i] = Byte(rand(255))
  b[6] = (b[6] and 0x0F) or 0x40'u8
  b[8] = (b[8] and 0x3F) or 0x80'u8
  copyMem(outBuf, addr b[0], 16)

import std/tables

proc parseConfig*(keys, vals: CStringArr, n: csize_t): Table[string, string] =
  result = initTable[string, string](if n.int > 0: n.int else: 1)
  for i in 0 ..< n.int:
    if keys[i] != nil and vals[i] != nil:
      result[$keys[i]] = $vals[i]
