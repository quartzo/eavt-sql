## all.nim (combined blobstore + journal + page-store + memtable)
##
## Single compilation entry point for `libnim_page_store.a`.
## All backends compiled together — one NimMain, one runtime, no conflicts.

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all
import ./abi
import ./backend
import ./kvstore

proc nim_page_store_open*(keys, vals: CStringArr; count: cint;
                           errOut: ptr cint): NimPageStoreVtablePtr
    {.exportc: "nim_page_store_open", cdecl.} =
  result = openPageStore(keys, vals, count, errOut)

proc nim_page_store_commit_merge*(handle: pointer; data: ptr Byte; dlen: csize_t;
                                   clearJournal: cint; errOut: ptr cint): cint
    {.exportc: "nim_page_store_commit_merge", cdecl.} =
  result = psCommitMerge(handle, data, dlen, clearJournal, errOut)

proc nim_kvstore_open*(keys, vals: CStringArr; count: cint;
                        errOut: ptr cint): NimKVStoreVtablePtr
    {.exportc: "nim_kvstore_open", cdecl.} =
  result = openKvStore(keys, vals, count, errOut)
