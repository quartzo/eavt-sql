## nim-blobstore/blobstore.nim — BlobStore trait.
##
## All backends (memory, file, eventually s3) implement this interface.
## The page store dispatches through it — no C-ABI vtable, no casts.

import std/options
import common

type
  BlobStore* = ref object of RootObj

method put*(s: BlobStore; data: openArray[byte]): ByteArr16 {.base.} =
  raise newException(IOError, "not implemented")

method putAt*(s: BlobStore; id: ByteArr16; data: openArray[byte]) {.base.} =
  raise newException(IOError, "not implemented")

method get*(s: BlobStore; id: ByteArr16): Option[seq[byte]] {.base.} =
  raise newException(IOError, "not implemented")

method delete*(s: BlobStore; id: ByteArr16) {.base.} =
  raise newException(IOError, "not implemented")

method list*(s: BlobStore): seq[ByteArr16] {.base.} =
  raise newException(IOError, "not implemented")

method putRoot*(s: BlobStore; name: string; data: openArray[byte]) {.base.} =
  raise newException(IOError, "not implemented")

method getRoot*(s: BlobStore; name: string): Option[seq[byte]] {.base.} =
  raise newException(IOError, "not implemented")

method listRoots*(s: BlobStore): seq[string] {.base.} =
  raise newException(IOError, "not implemented")

method deleteRoot*(s: BlobStore; name: string) {.base.} =
  raise newException(IOError, "not implemented")

method close*(s: BlobStore) {.base.} =
  discard
