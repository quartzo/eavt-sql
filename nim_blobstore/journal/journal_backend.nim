## backend.nim (journal backend)
##
## Sequential file-backed journal. The on-disk file lives at
## `<path>/journal/journal`, where `<path>` comes from the `path` config key.
##
## Frame format (big-endian, matching the Rust `JournalFile`):
##   [u32 klen][key bytes][u32 vlen][value bytes]

import std/os

type
  Journal* = ref object
    path*: string

proc fullPath(j: Journal): string =
  j.path / "journal" / "journal"

proc newJournal*(path: string): Journal =
  if path.len == 0:
    raise newException(IOError, "journal path is empty")
  result = Journal(path: path)
  try:
    createDir(result.fullPath().parentDir())
  except CatchableError:
    raise newException(IOError, "cannot create journal directory")

proc close*(j: Journal) =
  if j != nil:
    j.path = ""

proc append*(j: Journal, key, value: openArray[byte]) =
  if j == nil:
    raise newException(IOError, "journal not open")
  var f: File
  if not open(f, j.fullPath(), fmAppend):
    try:
      createDir(j.fullPath().parentDir())
    except CatchableError:
      raise newException(IOError, "journal append: cannot create dir")
    if not open(f, j.fullPath(), fmAppend):
      raise newException(IOError, "journal append: cannot open file")
  defer: f.close()
  var klenBuf: array[4, byte]
  let klen = key.len
  klenBuf[0] = byte((klen shr 24) and 0xFF)
  klenBuf[1] = byte((klen shr 16) and 0xFF)
  klenBuf[2] = byte((klen shr 8) and 0xFF)
  klenBuf[3] = byte(klen and 0xFF)
  discard f.writeBuffer(addr klenBuf[0], 4)
  if klen > 0:
    discard f.writeBuffer(unsafeAddr key[0], klen)
  var vlenBuf: array[4, byte]
  let vlen = value.len
  vlenBuf[0] = byte((vlen shr 24) and 0xFF)
  vlenBuf[1] = byte((vlen shr 16) and 0xFF)
  vlenBuf[2] = byte((vlen shr 8) and 0xFF)
  vlenBuf[3] = byte(vlen and 0xFF)
  discard f.writeBuffer(addr vlenBuf[0], 4)
  if vlen > 0:
    discard f.writeBuffer(unsafeAddr value[0], vlen)

proc readAll*(j: Journal): seq[(seq[byte], seq[byte])] =
  if not fileExists(j.fullPath()):
    return @[]
  var data: string
  try:
    data = readFile(j.fullPath())
  except CatchableError:
    raise newException(IOError, "journal read: cannot read file")
  var pos = 0
  while pos + 4 <= data.len:
    let klen = int(cast[uint32](data[pos].uint32 shl 24 or
      data[pos+1].uint32 shl 16 or data[pos+2].uint32 shl 8 or
      data[pos+3].uint32))
    pos += 4
    if pos + klen > data.len:
      raise newException(IOError, "journal read: truncated key")
    var k = newSeq[byte](klen)
    for i in 0..<klen: k[i] = byte(data[pos + i])
    pos += klen
    if pos + 4 > data.len:
      raise newException(IOError, "journal read: truncated vlen")
    let vlen = int(cast[uint32](data[pos].uint32 shl 24 or
      data[pos+1].uint32 shl 16 or data[pos+2].uint32 shl 8 or
      data[pos+3].uint32))
    pos += 4
    if pos + vlen > data.len:
      raise newException(IOError, "journal read: truncated value")
    var v = newSeq[byte](vlen)
    for i in 0..<vlen: v[i] = byte(data[pos + i])
    pos += vlen
    result.add (k, v)
  if pos < data.len:
    raise newException(IOError, "journal read: trailing garbage after last frame")

proc truncate*(j: Journal) =
  if j == nil: return
  if fileExists(j.fullPath()):
    try:
      removeFile(j.fullPath())
    except CatchableError:
      raise newException(IOError, "journal truncate: cannot remove file")

proc len*(j: Journal): uint64 =
  if not fileExists(j.fullPath()): return 0
  try:
    return cast[uint64](getFileSize(j.fullPath()))
  except CatchableError:
    return 0
