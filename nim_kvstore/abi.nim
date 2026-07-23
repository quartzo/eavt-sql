## abi.nim — shared byte array types for the KV store.

type
  Byte* = uint8
  ByteArr16* = array[16, Byte]
  BytePtr* = ptr UncheckedArray[Byte]
