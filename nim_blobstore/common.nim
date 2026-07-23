## nim_blobstore/common.nim — shared types for all blobstore backends.

import std/[sysrand, random]

type
  Byte* = uint8
  ByteArr16* = array[16, Byte]
  BytePtr* = ptr UncheckedArray[Byte]

proc newUuidBytes*(outBuf: ptr Byte) =
  var id: array[16, uint8]
  for i in 0..15:
    id[i] = uint8(rand(255))
  copyMem(outBuf, addr id[0], 16)
