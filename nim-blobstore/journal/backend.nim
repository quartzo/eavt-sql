## backend.nim (journal backend)
##
## Sequential file-backed journal. The on-disk file lives at
## `<path>/journal/journal`, where `<path>` comes from the `path` config key.
##
## Frame format (big-endian, matching the Rust `JournalFile`):
##   [u32 klen][key bytes][u32 vlen][value bytes]
##
## `read` replays the whole file and re-emits every valid frame packed into a
## single Nim-allocated buffer; the caller frees it via the vtable `freeBuf`.

import std/os
import abi
import std/locks

type
  JournalHandle* = object
    path*: string          ## full path to the journal file
    lock*: Lock

# Forward declarations so openJournal can assign them before their bodies.
proc appendImpl(h: pointer, key: ptr Byte, klen: csize_t,
                `val`: ptr Byte, vlen: csize_t,
                errOut: ptr cint): cint {.cdecl.}
proc readImpl(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
              errOut: ptr cint): cint {.cdecl.}
proc truncateImpl(h: pointer, errOut: ptr cint): cint {.cdecl.}
proc sizeImpl(h: pointer, outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.}

proc journalDir(path: string): string =
  result = path / "journal"

proc fullPath(path: string): string =
  result = journalDir(path) / "journal"

proc openJournal*(path: cstring, errOut: ptr cint): NimJournalVtablePtr =
  if path == nil or path == "":
    setErr(errOut, ErrConfig)
    return nil
  var vt = newVtable()
  var h = cast[ptr JournalHandle](allocShared0(sizeof(JournalHandle)))
  h[] = JournalHandle(path: $path, lock: Lock())
  initLock(h.lock)
  vt.handle = h
  vt.append = appendImpl
  vt.read = readImpl
  vt.truncate = truncateImpl
  vt.size = sizeImpl
  vt.freeBuf = freeShared
  # Ensure the journal directory exists up front so the first append is fast.
  try:
    createDir(fullPath(h.path).parentDir())
  except CatchableError:
    discard
  return vt

proc closeJournal*(vt: NimJournalVtablePtr) =
  if vt == nil: return
  if vt.handle != nil:
    var h = cast[ptr JournalHandle](vt.handle)
    deinitLock(h.lock)
    deallocShared(h)
  freeVtable(vt)

proc closeJournalVtable*(p: pointer) =
  closeJournal(cast[NimJournalVtablePtr](p))

proc appendImpl(h: pointer, key: ptr Byte, klen: csize_t,
                `val`: ptr Byte, vlen: csize_t,
                errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var jh = cast[ptr JournalHandle](h)
  jh.lock.withLock:
    var f: File
    if not open(f, fullPath(jh.path), fmAppend):
      # Parent dir may not exist yet; create it and retry once.
      try:
        createDir(fullPath(jh.path).parentDir())
      except CatchableError:
        setErr(errOut, ErrIo)
        return -1
      if not open(f, fullPath(jh.path), fmAppend):
        setErr(errOut, ErrIo)
        return -1
    defer: f.close()
    var klenBuf: array[4, byte]
    klenBuf[0] = byte((klen shr 24) and 0xFF)
    klenBuf[1] = byte((klen shr 16) and 0xFF)
    klenBuf[2] = byte((klen shr 8) and 0xFF)
    klenBuf[3] = byte(klen and 0xFF)
    discard f.writeBuffer(addr klenBuf[0], 4)
    if klen > 0:
      discard f.writeBuffer(cast[pointer](key), klen)
    var vlenBuf: array[4, byte]
    vlenBuf[0] = byte((vlen shr 24) and 0xFF)
    vlenBuf[1] = byte((vlen shr 16) and 0xFF)
    vlenBuf[2] = byte((vlen shr 8) and 0xFF)
    vlenBuf[3] = byte(vlen and 0xFF)
    discard f.writeBuffer(addr vlenBuf[0], 4)
    if vlen > 0:
      discard f.writeBuffer(cast[pointer](`val`), vlen)
  return 0

proc readImpl(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
              errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var jh = cast[ptr JournalHandle](h)
  outBuf[] = nil
  outLen[] = 0
  if not fileExists(fullPath(jh.path)):
    return 0  # empty journal -> empty result
  var data: string
  try:
    data = readFile(fullPath(jh.path))
  except CatchableError:
    setErr(errOut, ErrIo)
    return -1
  # Replay: validate every frame.  Error on truncated frames or trailing
  # garbage after the last valid frame (no silent discard).
  var packed = newSeq[byte](0)
  var off = 0
  while off + 4 <= data.len:
    # --- klen ---
    let klen = cast[uint32](cast[byte](data[off]).uint32 shl 24 or
                            cast[byte](data[off+1]).uint32 shl 16 or
                            cast[byte](data[off+2]).uint32 shl 8 or
                            cast[byte](data[off+3]).uint32)
    off += 4
    packed.add(cast[byte]((klen shr 24) and 0xFF))
    packed.add(cast[byte]((klen shr 16) and 0xFF))
    packed.add(cast[byte]((klen shr 8) and 0xFF))
    packed.add(cast[byte](klen and 0xFF))
    if off + klen.int > data.len:
      setErr(errOut, ErrIo)
      return -1   # truncated key
    for c in data[off ..< off + klen.int]: packed.add(c.byte)
    off += klen.int

    # --- vlen ---
    if off + 4 > data.len:
      setErr(errOut, ErrIo)
      return -1   # truncated vlen (missing after key)
    let vlen = cast[uint32](cast[byte](data[off]).uint32 shl 24 or
                            cast[byte](data[off+1]).uint32 shl 16 or
                            cast[byte](data[off+2]).uint32 shl 8 or
                            cast[byte](data[off+3]).uint32)
    off += 4
    packed.add(cast[byte]((vlen shr 24) and 0xFF))
    packed.add(cast[byte]((vlen shr 16) and 0xFF))
    packed.add(cast[byte]((vlen shr 8) and 0xFF))
    packed.add(cast[byte](vlen and 0xFF))
    if off + vlen.int > data.len:
      setErr(errOut, ErrIo)
      return -1   # truncated value
    for c in data[off ..< off + vlen.int]: packed.add(c.byte)
    off += vlen.int

  if off < data.len:
    setErr(errOut, ErrIo)
    return -1       # trailing garbage after last complete frame
  if packed.len == 0:
    outBuf[] = nil
    outLen[] = 0
  else:
    let buf = allocByteBuf(packed.len)
    copyMem(buf, addr packed[0], packed.len)
    outBuf[] = buf
    outLen[] = cast[csize_t](packed.len)
  return 0

proc truncateImpl(h: pointer, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var jh = cast[ptr JournalHandle](h)
  jh.lock.withLock:
    if fileExists(fullPath(jh.path)):
      try:
        removeFile(fullPath(jh.path))
      except CatchableError:
        setErr(errOut, ErrIo)
        return -1
  return 0

proc sizeImpl(h: pointer, outSize: ptr uint64, errOut: ptr cint): cint {.cdecl.} =
  if h == nil:
    setErr(errOut, ErrInvalidHandle)
    return -1
  var jh = cast[ptr JournalHandle](h)
  if not fileExists(fullPath(jh.path)):
    outSize[] = 0
  else:
    try:
      outSize[] = cast[uint64](getFileSize(fullPath(jh.path)))
    except CatchableError:
      setErr(errOut, ErrIo)
      return -1
  return 0

# ══════════════════════════════════════════════════════════════════════════════
# Nim-native API — clean wrapper over the C-ABI vtable for Nim callers.
# The KVStore, page store, and unit tests use this.
# ══════════════════════════════════════════════════════════════════════════════

type
  Journal* = ref object
    vt*: NimJournalVtablePtr      ## kept alive for close / underlying ops
    handle*: ptr JournalHandle    ## cached for direct field access (path, lock)

proc newJournal*(path: string): Journal =
  var err: cint
  result = Journal()
  result.vt = openJournal(path.cstring, addr err)
  if result.vt == nil:
    raise newException(IOError, "open journal failed: err=" & $err)
  result.handle = cast[ptr JournalHandle](result.vt.handle)

proc close*(j: Journal) =
  if j != nil and j.vt != nil:
    closeJournal(j.vt)
    j.vt = nil
    j.handle = nil

proc append*(j: Journal, key, value: openArray[byte]) =
  var err: cint
  let kptr = if key.len > 0: cast[ptr Byte](unsafeAddr key[0]) else: nil
  let vptr = if value.len > 0: cast[ptr Byte](unsafeAddr value[0]) else: nil
  let rc = j.vt.append(j.vt.handle, kptr, key.len.csize_t,
                        vptr, value.len.csize_t, addr err)
  if rc != 0:
    raise newException(IOError, "journal append failed: err=" & $err)

proc readAll*(j: Journal): seq[(seq[byte], seq[byte])] =
  ## Read all frames as (key, value) pairs.  Raises on corruption.
  var buf: pointer = nil
  var blen: csize_t = 0
  var err: cint
  let rc = j.vt.read(j.vt.handle, addr buf, addr blen, addr err)
  if rc != 0:
    raise newException(IOError, "journal read failed: err=" & $err)
  if buf == nil: return
  var pos = 0
  let raw = cast[ptr UncheckedArray[byte]](buf)
  while pos + 4 <= blen.int:
    let klen = int(uint32(raw[pos]) shl 24 or uint32(raw[pos+1]) shl 16 or
                   uint32(raw[pos+2]) shl 8 or uint32(raw[pos+3]))
    pos += 4
    var k = newSeq[byte](klen)
    for i in 0..<klen: k[i] = raw[pos + i]
    pos += klen
    let vlen = int(uint32(raw[pos]) shl 24 or uint32(raw[pos+1]) shl 16 or
                   uint32(raw[pos+2]) shl 8 or uint32(raw[pos+3]))
    pos += 4
    var v = newSeq[byte](vlen)
    for i in 0..<vlen: v[i] = raw[pos + i]
    pos += vlen
    result.add (k, v)
  j.vt.freeBuf(buf)

proc truncate*(j: Journal) =
  var err: cint
  let rc = j.vt.truncate(j.vt.handle, addr err)
  if rc != 0:
    raise newException(IOError, "journal truncate failed: err=" & $err)

proc len*(j: Journal): uint64 =
  var err: cint
  let rc = j.vt.size(j.vt.handle, addr result, addr err)
  if rc != 0:
    raise newException(IOError, "journal size failed: err=" & $err)
