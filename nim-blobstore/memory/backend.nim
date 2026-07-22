## blobstore_memory.nim
##
## In-memory BlobStore backend (HashMap + sorted roots). Port of
## spier-blobstore-memory/src/lib.rs. Exports `nim_blob_memory_open` /
## `nim_blob_memory_close` with a C ABI.

import std/tables
import std/algorithm

import abi
import spinlock

# ---------------------------------------------------------------------------
# Backend type (GC-managed ref; kept alive via global registry)
# ---------------------------------------------------------------------------

type
  MemBackend* = ref object
    lock*: SpinLock
    blobs*: Table[ByteArr16, seq[Byte]]
    roots*: Table[string, seq[Byte]]

# ---------------------------------------------------------------------------
# Global registry — keeps Nim refs alive across the FFI boundary.
# Under --mm:arc, refs are refcounted; the registry holds the strong ref.
# ---------------------------------------------------------------------------

var regLock: SpinLock
var registry: Table[pointer, MemBackend]
initSpinLock(regLock)

proc registerBackend(b: MemBackend): pointer =
  let key = cast[pointer](b)
  regLock.acquire()
  try:
    registry[key] = b
  finally:
    regLock.release()
  result = key

proc unregisterBackend(key: pointer): MemBackend =
  regLock.acquire()
  try:
    result = registry.getOrDefault(key, nil)
    if result != nil:
      registry.del(key)
  finally:
    regLock.release()

# ---------------------------------------------------------------------------
# Trait-method implementations
# ---------------------------------------------------------------------------

proc memPut(h: pointer, data: ptr Byte, len: csize_t,
            idOut: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var dataCopy: seq[Byte] = newSeq[Byte](len.int)
  if len.int > 0:
    copyMem(addr dataCopy[0], data, len.int)
  var id: ByteArr16
  newUuidBytes(addr id[0])
  b.lock.acquire()
  try:
    b.blobs[id] = dataCopy
  finally:
    b.lock.release()
  copyMem(idOut, addr id[0], 16)
  result = 0'i32

proc memPutAt(h: pointer, id: ptr Byte, data: ptr Byte, len: csize_t,
              errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  var dataCopy: seq[Byte] = newSeq[Byte](len.int)
  if len.int > 0:
    copyMem(addr dataCopy[0], data, len.int)
  b.lock.acquire()
  try:
    b.blobs[idArr] = dataCopy
  finally:
    b.lock.release()
  result = 0'i32

proc memDelete(h: pointer, id: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  b.lock.acquire()
  try:
    b.blobs.del(idArr)
  finally:
    b.lock.release()
  result = 0'i32

proc memGet(h: pointer, id: ptr Byte,
            outBuf: ptr pointer, outLen: ptr csize_t,
            outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  var present = false
  var dataCopy: seq[Byte] = @[]
  b.lock.acquire()
  try:
    present = b.blobs.hasKey(idArr)
    if present:
      dataCopy = b.blobs[idArr]
  finally:
    b.lock.release()
  if not present:
    outPresent[] = 0'i32
    outBuf[] = nil
    outLen[] = 0
  else:
    outPresent[] = 1'i32
    let buf = allocByteBuf(dataCopy.len)
    if dataCopy.len > 0:
      copyMem(buf, addr dataCopy[0], dataCopy.len)
    outBuf[] = cast[pointer](buf)
    outLen[] = dataCopy.len.csize_t
  result = 0'i32

proc memList(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
             errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var ids: seq[ByteArr16] = @[]
  b.lock.acquire()
  try:
    for k in b.blobs.keys:
      ids.add(k)
  finally:
    b.lock.release()
  let total = ids.len * 16
  let buf = allocByteBuf(total)
  let dst = cast[BytePtr](buf)
  for i, id in ids:
    copyMem(addr dst[i * 16], unsafeAddr id[0], 16)
  outBuf[] = cast[pointer](buf)
  outLen[] = total.csize_t
  result = 0'i32

proc memPutRoot(h: pointer, name: cstring, data: ptr Byte, len: csize_t,
                errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  let key = $name
  var dataCopy: seq[Byte] = newSeq[Byte](len.int)
  if len.int > 0:
    copyMem(addr dataCopy[0], data, len.int)
  b.lock.acquire()
  try:
    b.roots[key] = dataCopy
  finally:
    b.lock.release()
  result = 0'i32

proc memGetRoot(h: pointer, name: cstring,
                outBuf: ptr pointer, outLen: ptr csize_t,
                outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  let key = $name
  var present = false
  var dataCopy: seq[Byte] = @[]
  b.lock.acquire()
  try:
    present = b.roots.hasKey(key)
    if present:
      dataCopy = b.roots[key]
  finally:
    b.lock.release()
  if not present:
    outPresent[] = 0'i32
    outBuf[] = nil
    outLen[] = 0
  else:
    outPresent[] = 1'i32
    let buf = allocByteBuf(dataCopy.len)
    if dataCopy.len > 0:
      copyMem(buf, addr dataCopy[0], dataCopy.len)
    outBuf[] = cast[pointer](buf)
    outLen[] = dataCopy.len.csize_t
  result = 0'i32

proc memListRoots(h: pointer, outBuf: ptr pointer, outCount: ptr csize_t,
                  errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  var names: seq[string] = @[]
  b.lock.acquire()
  try:
    for k in b.roots.keys:
      names.add(k)
  finally:
    b.lock.release()
  # Match Rust's BTreeMap<String,_> behavior: lexicographic order.
  names.sort(cmp[string])
  let count = names.len
  let arr = cast[CStringArr](allocShared0(sizeof(cstring) * max(count, 1)))
  for i, n in names:
    let cs = allocShared0(n.len + 1)
    if n.len > 0:
      copyMem(cs, unsafeAddr n[0], n.len)
    arr[i] = cast[cstring](cs)
  outBuf[] = cast[pointer](arr)
  outCount[] = count.csize_t
  result = 0'i32

proc memDeleteRoot(h: pointer, name: cstring, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[MemBackend](h)
  if b == nil:
    setErr(errOut, ErrInvalidHandle); return 1'i32
  let key = $name
  b.lock.acquire()
  try:
    b.roots.del(key)
  finally:
    b.lock.release()
  result = 0'i32

# ---------------------------------------------------------------------------
# free helpers
# ---------------------------------------------------------------------------

proc memFreeBuf(p: pointer) {.cdecl.} =
  freeShared(p)

proc memFreeStrs(arr: CStringArr, count: csize_t) {.cdecl.} =
  if arr == nil: return
  for i in 0 ..< count.int:
    if arr[i] != nil:
      deallocShared(cast[pointer](arr[i]))
  deallocShared(cast[pointer](arr))

# ---------------------------------------------------------------------------
# Exported open/close
# ---------------------------------------------------------------------------

proc nim_blob_memory_open*(keys, vals: CStringArr, n: csize_t,
                           errOut: ptr cint): NimBlobVtablePtr
                           {.exportc, cdecl.} =
  let b = MemBackend()
  b.blobs = initTable[ByteArr16, seq[Byte]]()
  b.roots = initTable[string, seq[Byte]]()
  initSpinLock(b.lock)
  # Touch config so we consume it (none of the memory options are honored by
  # Rust's MemoryBlobStore::new() either).
  discard parseConfig(keys, vals, n)
  let key = registerBackend(b)
  let vt = newVtable()
  vt.handle = key
  vt.put = memPut
  vt.putAt = memPutAt
  vt.delete = memDelete
  vt.get = memGet
  vt.list = memList
  vt.putRoot = memPutRoot
  vt.getRoot = memGetRoot
  vt.listRoots = memListRoots
  vt.deleteRoot = memDeleteRoot
  vt.freeBuf = memFreeBuf
  vt.freeStrs = memFreeStrs
  result = vt

proc nim_blob_memory_close*(vt: NimBlobVtablePtr) {.exportc, cdecl.} =
  if vt == nil: return
  let h = vt.handle
  let b = unregisterBackend(h)
  if b != nil:
    deinitSpinLock(b.lock)
    # `b` ref drops here; arc frees the tables/seqs.
  freeVtable(vt)
