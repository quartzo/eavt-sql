## blobstore_file.nim
##
## File-backed BlobStore backend (directory of zstd-less raw blobs in a
## 2-level hex-sharded layout; named roots live in the same dir). Port of
## spier-blobstore-file/src/lib.rs. Exports `nim_blob_file_open` /
## `nim_blob_file_close`.

import std/os
import std/algorithm
import std/options
import std/strutils
import std/tables

import abi
import spinlock

# ---------------------------------------------------------------------------
# Backend type
# ---------------------------------------------------------------------------

type
  FileBackend* = ref object
    base*: Option[string]    # "{path}/blobs"
    readOnly*: bool

# ---------------------------------------------------------------------------
# Global registry (keeps Nim refs alive across the FFI boundary under arc).
# ---------------------------------------------------------------------------

var regLock: SpinLock
var registry: Table[pointer, FileBackend]
initSpinLock(regLock)

proc registerBackend(b: FileBackend): pointer =
  let key = cast[pointer](b)
  regLock.acquire()
  try: registry[key] = b
  finally: regLock.release()
  result = key

proc unregisterBackend(key: pointer): FileBackend =
  regLock.acquire()
  try:
    result = registry.getOrDefault(key, nil)
    if result != nil: registry.del(key)
  finally: regLock.release()

# ---------------------------------------------------------------------------
# Hex helpers
# ---------------------------------------------------------------------------

const hexChars = "0123456789abcdef"

proc uuidToHex(id: ByteArr16): string =
  result = newString(32)
  for i, b in id:
    result[i*2]   = hexChars[(b shr 4).int]
    result[i*2+1] = hexChars[(b and 0x0F).int]

proc hexCharToByte(c: char): Option[Byte] =
  case c
  of '0'..'9': some(Byte(ord(c) - ord('0')))
  of 'a'..'f': some(Byte(ord(c) - ord('a') + 10))
  of 'A'..'F': some(Byte(ord(c) - ord('A') + 10))
  else: none(Byte)

proc uuidFromHex(s: string): Option[ByteArr16] =
  if s.len != 32: return none(ByteArr16)
  var bytes: ByteArr16
  for i in 0 ..< 16:
    let hi = hexCharToByte(s[i*2])
    let lo = hexCharToByte(s[i*2+1])
    if hi.isNone or lo.isNone: return none(ByteArr16)
    bytes[i] = (hi.get() shl 4) or lo.get()
  result = some(bytes)

proc uuidPath(base, id: string): string =
  # base/XX/YY/<full-hex-uuid>
  base / id[0..1] / id[2..3] / id

# ---------------------------------------------------------------------------
# Atomic write (temp + rename). Mirrors Rust's `write_file_atomic`.
# ---------------------------------------------------------------------------

proc writeAtomic(path: string, data: ptr Byte, len: int): Option[string] =
  let parent = parentDir(path)
  if parent.len > 0:
    try: createDir(parent)
    except OSError: return some("createDir " & parent & ": " & getCurrentExceptionMsg())
  let tmp = path & ".tmp"
  try:
    let f = open(tmp, fmWrite)
    defer: f.close()
    if len > 0:
      var s = newString(len)
      copyMem(addr s[0], data, len)
      f.write(s)
  except OSError, IOError:
    return some("write " & tmp & ": " & getCurrentExceptionMsg())
  try: moveFile(tmp, path)
  except OSError:
    return some("rename " & tmp & " -> " & path & ": " & getCurrentExceptionMsg())

# ---------------------------------------------------------------------------
# Method implementations
# ---------------------------------------------------------------------------

proc failReadOnly(errOut: ptr cint): cint =
  setErr(errOut, ErrReadOnly); return 1'i32

proc filePut(h: pointer, data: ptr Byte, len: csize_t,
             idOut: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.readOnly: return failReadOnly(errOut)
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  var id: ByteArr16
  newUuidBytes(addr id[0])
  let hex = uuidToHex(id)
  let path = uuidPath(b.base.get(), hex)
  let e = writeAtomic(path, data, len.int)
  if e.isSome:
    setErr(errOut, ErrIo); return 1'i32
  copyMem(idOut, addr id[0], 16)
  result = 0'i32

proc filePutAt(h: pointer, id: ptr Byte, data: ptr Byte, len: csize_t,
               errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.readOnly: return failReadOnly(errOut)
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  let path = uuidPath(b.base.get(), uuidToHex(idArr))
  let e = writeAtomic(path, data, len.int)
  if e.isSome:
    setErr(errOut, ErrIo); return 1'i32
  result = 0'i32

proc fileDelete(h: pointer, id: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.readOnly: return failReadOnly(errOut)
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  let path = uuidPath(b.base.get(), uuidToHex(idArr))
  try:
    removeFile(path)
  except OSError:
    # NotFound is OK; re-check existence to match Rust's ErrorKind::NotFound branch.
    if fileExists(path):
      setErr(errOut, ErrIo)
      return 1'i32
  result = 0'i32

proc fileGet(h: pointer, id: ptr Byte,
             outBuf: ptr pointer, outLen: ptr csize_t,
             outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  var idArr: ByteArr16
  copyMem(addr idArr[0], id, 16)
  let path = uuidPath(b.base.get(), uuidToHex(idArr))
  if not fileExists(path):
    outPresent[] = 0'i32
    outBuf[] = nil
    outLen[] = 0
    return 0'i32
  try:
    let s = readFile(path)
    let n = s.len
    let buf = allocByteBuf(n)
    if n > 0:
      copyMem(buf, addr s[0], n)
    outBuf[] = cast[pointer](buf)
    outLen[] = n.csize_t
    outPresent[] = 1'i32
  except OSError, IOError:
    setErr(errOut, ErrIo)
    return 1'i32
  result = 0'i32

proc fileList(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
              errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  let base = b.base.get()
  var ids: seq[ByteArr16] = @[]
  if dirExists(base):
    for e1 in walkDir(base):
      if e1.kind != pcDir: continue
      for e2 in walkDir(e1.path):
        if e2.kind != pcDir: continue
        for e3 in walkDir(e2.path):
          if e3.kind != pcFile: continue
          let name = splitFile(e3.path).name
          if name.endsWith(".tmp"): continue
          let idOpt = uuidFromHex(name)
          if idOpt.isSome:
            ids.add(idOpt.get())
  let total = ids.len * 16
  let buf = allocByteBuf(total)
  let dst = cast[BytePtr](buf)
  for i, id in ids:
    copyMem(addr dst[i * 16], unsafeAddr id[0], 16)
  outBuf[] = cast[pointer](buf)
  outLen[] = total.csize_t
  result = 0'i32

proc filePutRoot(h: pointer, name: cstring, data: ptr Byte, len: csize_t,
                 errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.readOnly: return failReadOnly(errOut)
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  let path = b.base.get() / ($name)
  let e = writeAtomic(path, data, len.int)
  if e.isSome:
    setErr(errOut, ErrIo); return 1'i32
  result = 0'i32

proc fileGetRoot(h: pointer, name: cstring,
                 outBuf: ptr pointer, outLen: ptr csize_t,
                 outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  let path = b.base.get() / ($name)
  if not fileExists(path):
    outPresent[] = 0'i32
    outBuf[] = nil
    outLen[] = 0
    return 0'i32
  try:
    let s = readFile(path)
    let n = s.len
    let buf = allocByteBuf(n)
    if n > 0:
      copyMem(buf, addr s[0], n)
    outBuf[] = cast[pointer](buf)
    outLen[] = n.csize_t
    outPresent[] = 1'i32
  except OSError, IOError:
    setErr(errOut, ErrIo)
    return 1'i32
  result = 0'i32

proc fileListRoots(h: pointer, outBuf: ptr pointer, outCount: ptr csize_t,
                   errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  let base = b.base.get()
  var roots: seq[string] = @[]
  if dirExists(base):
    for entry in walkDir(base):
      if entry.kind != pcFile: continue
      let name = splitFile(entry.path).name
      if name.startsWith("root_") and not name.endsWith(".tmp"):
        roots.add(name)
  roots.sort(cmp[string])
  let count = roots.len
  let arr = cast[CStringArr](allocShared0(sizeof(cstring) * max(count, 1)))
  for i, n in roots:
    let cs = allocShared0(n.len + 1)
    if n.len > 0:
      copyMem(cs, unsafeAddr n[0], n.len)
    arr[i] = cast[cstring](cs)
  outBuf[] = cast[pointer](arr)
  outCount[] = count.csize_t
  result = 0'i32

proc fileDeleteRoot(h: pointer, name: cstring, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBackend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  if b.readOnly: return failReadOnly(errOut)
  if b.base.isNone: setErr(errOut, ErrInvalidArg); return 1'i32
  let path = b.base.get() / ($name)
  try:
    removeFile(path)
  except OSError:
    if fileExists(path):
      setErr(errOut, ErrIo)
      return 1'i32
  result = 0'i32

# ---------------------------------------------------------------------------
# free helpers
# ---------------------------------------------------------------------------

proc fileFreeBuf(p: pointer) {.cdecl.} = freeShared(p)

proc fileFreeStrs(arr: CStringArr, count: csize_t) {.cdecl.} =
  if arr == nil: return
  for i in 0 ..< count.int:
    if arr[i] != nil:
      deallocShared(cast[pointer](arr[i]))
  deallocShared(cast[pointer](arr))

# ---------------------------------------------------------------------------
# Exported open / close
# ---------------------------------------------------------------------------

proc nim_blob_file_open*(keys, vals: CStringArr, n: csize_t,
                        errOut: ptr cint): NimBlobVtablePtr
                        {.exportc, cdecl.} =
  let cfg = parseConfig(keys, vals, n)
  var base: Option[string] = none(string)
  if cfg.hasKey("path"):
    base = some(cfg["path"] & "/blobs")
  let readOnly = cfg.hasKey("read_only") and cfg["read_only"] == "true"
  if base.isSome and not readOnly:
    try: createDir(base.get())
    except OSError:
      setErr(errOut, ErrIo)
      return nil
  let b = FileBackend(base: base, readOnly: readOnly)
  let key = registerBackend(b)
  let vt = newVtable()
  vt.handle = key
  vt.put = filePut
  vt.putAt = filePutAt
  vt.delete = fileDelete
  vt.get = fileGet
  vt.list = fileList
  vt.putRoot = filePutRoot
  vt.getRoot = fileGetRoot
  vt.listRoots = fileListRoots
  vt.deleteRoot = fileDeleteRoot
  vt.freeBuf = fileFreeBuf
  vt.freeStrs = fileFreeStrs
  result = vt

proc nim_blob_file_close*(vt: NimBlobVtablePtr) {.exportc, cdecl.} =
  if vt == nil: return
  let h = vt.handle
  let b = unregisterBackend(h)
  if b != nil:
    discard  # ref drops naturally; arc frees.
  freeVtable(vt)
