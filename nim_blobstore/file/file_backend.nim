## blobstore_file.nim
##
## File-backed BlobStore backend — 2-level hex-sharded blobs on disk.
## Port of spier-blobstore-file/src/lib.rs.

import std/[os, algorithm, options, strutils]
import ../common
import ../blobstore

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native type — implements the BlobStore trait.
# ══════════════════════════════════════════════════════════════════════════════

type
  FileBlobStore* = ref object of BlobStore
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

method put*(s: FileBlobStore; data: openArray[byte]): ByteArr16 =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  newUuidBytes(addr result[0])
  let path = uuidPath(s.base.get(), uuidToHex(result))
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "put: " & e.get())

method putAt*(s: FileBlobStore; id: ByteArr16; data: openArray[byte]) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = uuidPath(s.base.get(), uuidToHex(id))
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "putAt: " & e.get())

method get*(s: FileBlobStore; id: ByteArr16): Option[seq[byte]] =
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

method delete*(s: FileBlobStore; id: ByteArr16) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = uuidPath(s.base.get(), uuidToHex(id))
  try:
    removeFile(path)
  except OSError:
    if fileExists(path):
      raise newException(IOError, "delete: " & getCurrentExceptionMsg())

method list*(s: FileBlobStore): seq[ByteArr16] =
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

method putRoot*(s: FileBlobStore; name: string; data: openArray[byte]) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = s.base.get() / name
  let e = writeAtomic(path, cast[ptr Byte](if data.len > 0: unsafeAddr data[0] else: nil), data.len)
  if e.isSome():
    raise newException(IOError, "putRoot: " & e.get())

method getRoot*(s: FileBlobStore; name: string): Option[seq[byte]] =
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

method listRoots*(s: FileBlobStore): seq[string] =
  if s.base.isNone(): raise newException(IOError, "no base path")
  if not dirExists(s.base.get()): return @[]
  for entry in walkDir(s.base.get()):
    if entry.kind != pcFile: continue
    let name = splitFile(entry.path).name
    if name.startsWith("root_") and not name.endsWith(".tmp"):
      result.add name
  result.sort(cmp[string])

method deleteRoot*(s: FileBlobStore; name: string) =
  discard failReadOnly(s)
  if s.base.isNone(): raise newException(IOError, "no base path")
  let path = s.base.get() / name
  try:
    removeFile(path)
  except OSError:
    if fileExists(path):
      raise newException(IOError, "deleteRoot: " & getCurrentExceptionMsg())