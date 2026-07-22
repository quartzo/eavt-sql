## blobstore_file.nim
##
## File-backed BlobStore backend — 2-level hex-sharded blobs on disk.
## Port of spier-blobstore-file/src/lib.rs.

import std/[os, algorithm, options, strutils, tables]
import abi
import spinlock

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native type — the public API.  No C-ABI needed for Nim callers.
# ══════════════════════════════════════════════════════════════════════════════

type
  FileBlobStore* = ref object
    base*: Option[string]      ## "{path}/blobs"
    readOnly*: bool

  FilePutResult* = object
    id*: ByteArr16
    written*: bool

# ══════════════════════════════════════════════════════════════════════════════
# Hex helpers
# ══════════════════════════════════════════════════════════════════════════════

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
    if hi.isNone() or lo.isNone(): return none(ByteArr16)
    bytes[i] = (hi.get() shl 4) or lo.get()
  result = some(bytes)

proc uuidPath(base, id: string): string =
  base / id[0..1] / id[2..3] / id

# ══════════════════════════════════════════════════════════════════════════════
# Atomic write (temp + rename).
# ══════════════════════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════════════════════
# Nim API — all operations on FileBlobStore (no vtable, no cast).
# ══════════════════════════════════════════════════════════════════════════════

proc newFileBlobStore*(path: string; readOnly = false): FileBlobStore =
  result = FileBlobStore(
    base: some(path / "blobs"),
    readOnly: readOnly,
  )
  if not readOnly:
    try: createDir(result.base.get())
    except OSError: discard

proc failReadOnly(s: FileBlobStore): bool =
  if s.readOnly:
    raise newException(IOError, "read-only")
  true

proc put*(s: FileBlobStore; data: openArray[byte]): ByteArr16 =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  newUuidBytes(addr result[0])
  let path = uuidPath(s.base.get(), uuidToHex(result))
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "put: " & e.get())

proc putAt*(s: FileBlobStore; id: ByteArr16; data: openArray[byte]) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = uuidPath(s.base.get(), uuidToHex(id))
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "putAt: " & e.get())

proc get*(s: FileBlobStore; id: ByteArr16): Option[seq[byte]] =
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = uuidPath(s.base.get(), uuidToHex(id))
  if not fileExists(path): return none[seq[byte]]()
  try:
    let raw = readFile(path)
    var r = newSeq[byte](raw.len)
    if raw.len > 0: copyMem(addr r[0], addr raw[0], raw.len)
    result = some(r)
  except OSError, IOError:
    raise newException(IOError, "get: " & getCurrentExceptionMsg())

proc delete*(s: FileBlobStore; id: ByteArr16) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = uuidPath(s.base.get(), uuidToHex(id))
  try:
    removeFile(path)
  except OSError:
    if fileExists(path):
      raise newException(IOError, "delete: " & getCurrentExceptionMsg())

proc list*(s: FileBlobStore): seq[ByteArr16] =
  if s.base.isNone(): raise newException(IOError, "no base path")
  if not dirExists(s.base.get()): return @[]
  for e1 in walkDir(s.base.get()):
    if e1.kind != pcDir: continue
    for e2 in walkDir(e1.path):
      if e2.kind != pcDir: continue
      for e3 in walkDir(e2.path):
        if e3.kind != pcFile: continue
        let name = splitFile(e3.path).name
        if name.endsWith(".tmp"): continue
        let idOpt = uuidFromHex(name)
        if idOpt.isSome(): result.add idOpt.get()

proc putRoot*(s: FileBlobStore; name: string; data: openArray[byte]) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = s.base.get() / name
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "putRoot: " & e.get())

proc getRoot*(s: FileBlobStore; name: string): Option[seq[byte]] =
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = s.base.get() / name
  if not fileExists(path): return none[seq[byte]]()
  try:
    let raw = readFile(path)
    var r = newSeq[byte](raw.len)
    if raw.len > 0: copyMem(addr r[0], addr raw[0], raw.len)
    result = some(r)
  except OSError, IOError:
    raise newException(IOError, "getRoot: " & getCurrentExceptionMsg())

proc listRoots*(s: FileBlobStore): seq[string] =
  if s.base.isNone(): raise newException(IOError, "no base path")
  if not dirExists(s.base.get()): return @[]
  for entry in walkDir(s.base.get()):
    if entry.kind != pcFile: continue
    let name = splitFile(entry.path).name
    if name.startsWith("root_") and not name.endsWith(".tmp"):
      result.add name
  result.sort(cmp[string])

proc deleteRoot*(s: FileBlobStore; name: string) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = s.base.get() / name
  try:
    removeFile(path)
  except OSError:
    if fileExists(path):
      raise newException(IOError, "deleteRoot: " & getCurrentExceptionMsg())

# ══════════════════════════════════════════════════════════════════════════════
# Global registry — for the C-ABI bridge (page store still uses vtable).
# ══════════════════════════════════════════════════════════════════════════════

var regLock: SpinLock
var registry: Table[pointer, FileBlobStore]
initSpinLock(regLock)

proc registerBackend(b: FileBlobStore): pointer =
  let key = cast[pointer](b)
  regLock.acquire()
  try: registry[key] = b
  finally: regLock.release()
  result = key

proc unregisterBackend(key: pointer): FileBlobStore =
  regLock.acquire()
  try:
    result = registry.getOrDefault(key, nil)
    if result != nil: registry.del(key)
  finally: regLock.release()

# ══════════════════════════════════════════════════════════════════════════════
# C-ABI vtable bridge — thin wrappers that delegate to the Nim API above.
# ══════════════════════════════════════════════════════════════════════════════

proc filePut(h: pointer, data: ptr Byte, len: csize_t,
             idOut: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    var s = newSeq[byte](len)
    if len > 0: copyMem(addr s[0], data, len)
    let id = b.put(s)
    copyMem(idOut, unsafeAddr id[0], 16)
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc filePutAt(h: pointer, id: ptr Byte, data: ptr Byte, len: csize_t,
               errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    var s = newSeq[byte](len)
    if len > 0: copyMem(addr s[0], data, len)
    b.putAt(idArr, s)
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileDelete(h: pointer, id: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    b.delete(idArr)
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileGet(h: pointer, id: ptr Byte,
             outBuf: ptr pointer, outLen: ptr csize_t,
             outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    let r = b.get(idArr)
    if r.isNone():
      outPresent[] = 0; outBuf[] = nil; outLen[] = 0
    else:
      let raw = r.get()
      let buf = allocByteBuf(raw.len)
      if raw.len > 0: copyMem(buf, addr raw[0], raw.len)
      outBuf[] = cast[pointer](buf)
      outLen[] = raw.len.csize_t
      outPresent[] = 1
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileList(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
              errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    let ids = b.list()
    let total = ids.len * 16
    let buf = allocByteBuf(total)
    let dst = cast[BytePtr](buf)
    for i, id in ids:
      copyMem(addr dst[i * 16], unsafeAddr id[0], 16)
    outBuf[] = cast[pointer](buf)
    outLen[] = total.csize_t
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc filePutRoot(h: pointer, name: cstring, data: ptr Byte, len: csize_t,
                 errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    var s = newSeq[byte](len)
    if len > 0: copyMem(addr s[0], data, len)
    b.putRoot($name, s)
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileGetRoot(h: pointer, name: cstring,
                 outBuf: ptr pointer, outLen: ptr csize_t,
                 outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    let r = b.getRoot($name)
    if r.isNone():
      outPresent[] = 0; outBuf[] = nil; outLen[] = 0
    else:
      let raw = r.get()
      let buf = allocByteBuf(raw.len)
      if raw.len > 0: copyMem(buf, addr raw[0], raw.len)
      outBuf[] = cast[pointer](buf)
      outLen[] = raw.len.csize_t
      outPresent[] = 1
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileListRoots(h: pointer, outBuf: ptr pointer, outCount: ptr csize_t,
                   errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    let roots = b.listRoots()
    let count = roots.len
    let arr = cast[CStringArr](allocShared0(sizeof(cstring) * max(count, 1)))
    for i, n in roots:
      let cs = allocShared0(n.len + 1)
      if n.len > 0: copyMem(cs, unsafeAddr n[0], n.len)
      arr[i] = cast[cstring](cs)
    outBuf[] = cast[pointer](arr)
    outCount[] = count.csize_t
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileDeleteRoot(h: pointer, name: cstring, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[FileBlobStore](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  try:
    b.deleteRoot($name)
    return 0
  except:
    setErr(errOut, ErrIo); return -1

proc fileFreeBuf(p: pointer) {.cdecl.} = freeShared(p)

proc fileFreeStrs(arr: CStringArr, count: csize_t) {.cdecl.} =
  if arr == nil: return
  for i in 0 ..< count.int:
    if arr[i] != nil:
      deallocShared(cast[pointer](arr[i]))
  deallocShared(cast[pointer](arr))

# ══════════════════════════════════════════════════════════════════════════════
# C-ABI open/close — delegate to the Nim API.
# ══════════════════════════════════════════════════════════════════════════════

proc nim_blob_file_open*(keys, vals: CStringArr, n: csize_t,
                         errOut: ptr cint): NimBlobVtablePtr =
  let cfg = parseConfig(keys, vals, n)
  let path = cfg.getOrDefault("path", "")
  let readOnly = cfg.getOrDefault("read_only", "false") == "true"
  if path.len == 0:
    setErr(errOut, ErrConfig)
    return nil
  let b = FileBlobStore(
    base: some(path / "blobs"),
    readOnly: readOnly,
  )
  if not readOnly:
    try: createDir(b.base.get())
    except OSError:
      setErr(errOut, ErrIo)
      return nil
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

proc nim_blob_file_close*(vt: NimBlobVtablePtr) =
  if vt == nil: return
  let h = vt.handle
  let b = unregisterBackend(h)
  if b != nil:
    discard  # ref drops; arc frees
  freeVtable(vt)

proc closeVtable*(p: pointer) =
  nim_blob_file_close(cast[NimBlobVtablePtr](p))