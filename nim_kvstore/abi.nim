## abi.nim — shared types and helpers for the KV store.
##
## The C-ABI vtable types (PageStore, BlobStore, KVStore, MemTable) have
## been removed.  Only journal vtable types remain (for the page-store's
## journal bridge).

import std/tables

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

  ## Journal vtable mirror (used by the page store for its journal bridge).
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

template setErr*(errOut: ptr cint; code: cint) =
  if errOut != nil: errOut[] = code

proc allocByteBuf*(n: Natural): ptr Byte =
  if n == 0: result = cast[ptr Byte](allocShared0(1))
  else: result = cast[ptr Byte](allocShared(n))

proc freeShared*(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)

proc parseConfig*(keys, vals: CStringArr; n: csize_t): Table[string, string] =
  result = initTable[string, string](if n.int > 0: n.int else: 1)
  for i in 0 ..< n.int:
    if keys[i] != nil and vals[i] != nil:
      result[$keys[i]] = $vals[i]
