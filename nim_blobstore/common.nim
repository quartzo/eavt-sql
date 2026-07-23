## nim_blobstore/common.nim — shared types for all blobstore backends.
##
## Extracted from the duplicated `abi.nim` copies that existed in each
## backend.  All backends import from here instead.

import std/[sysrand, random, tables]

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

template setErr*(errOut: ptr cint; code: cint) =
  if errOut != nil: errOut[] = code

proc newUuidBytes*(outBuf: ptr Byte) =
  var id: array[16, uint8]
  for i in 0..15:
    id[i] = uint8(rand(255))
  copyMem(outBuf, addr id[0], 16)

proc allocByteBuf*(n: Natural): ptr Byte =
  if n == 0:
    result = cast[ptr Byte](allocShared0(1))
  else:
    result = cast[ptr Byte](allocShared(n))

proc freeShared*(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)
