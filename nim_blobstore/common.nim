## nim_blobstore/common.nim — shared types for all blobstore backends.

import std/sysrand

type
  Byte* = uint8
  ByteArr16* = array[16, Byte]
  BytePtr* = ptr UncheckedArray[Byte]

proc newUuidBytes*(outBuf: ptr Byte) =
  ## OS-CSPRNG bytes (getrandom/urandom): no shared mutable state, safe to
  ## call from multiple workers concurrently. (std/random's global Rand was
  ## a data race across pool workers and produced duplicate UUIDs, which
  ## collided in writeAtomic's tmp file.)
  var id: array[16, uint8]
  if not urandom(id):
    raise newException(IOError, "urandom failed")
  copyMem(outBuf, addr id[0], 16)
