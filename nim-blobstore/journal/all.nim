## all.nim (journal backend)
##
## Single compilation entry point for the journal static library
## (`libnim_blobstore_journal.a`). Exports the C-ABI open/close symbols that
## Rust links against.

import abi
import backend

proc nim_journal_open*(path: cstring, errOut: ptr cint): NimJournalVtablePtr
    {.exportc: "nim_journal_open", cdecl.} =
  result = openJournal(path, errOut)

proc nim_journal_close*(vt: NimJournalVtablePtr)
    {.exportc: "nim_journal_close", cdecl.} =
  closeJournal(vt)
