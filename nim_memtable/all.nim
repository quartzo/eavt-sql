## all.nim (memtable backend)
##
## Single compilation entry point for the memtable static library
## (`libnim_memtable.a`). Exports the C-ABI open/close symbols that Rust
## links against.

import abi
import backend

proc nim_memtable_open*(num_cf: cuint, errOut: ptr cint): NimMemTableVtablePtr
    {.exportc: "nim_memtable_open", cdecl.} =
  result = openMemTable(num_cf, errOut)

proc nim_memtable_close*(vt: NimMemTableVtablePtr)
    {.exportc: "nim_memtable_close", cdecl.} =
  closeMemTable(vt)
