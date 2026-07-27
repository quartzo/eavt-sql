## pages.nim — Leaf page serialization (prefix-compressed, varint-encoded).
##
## Port of spier-kvstore/src/pages.rs

const MaxRawSize* = 256 * 1024

proc commonPrefixLen*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  var i = 0
  while i < n and a[i] == b[i]:
    inc i
  result = i

proc writeVarint*(buf: var seq[byte]; value: int) =
  var v = value
  while true:
    let b = byte(v and 0x7F)
    v = v shr 7
    if v == 0:
      buf.add b
      break
    buf.add(b or 0x80)

proc readVarint*(data: openArray[byte]; offset: int): (int, int) =
  var shift: int = 0
  var value: int = 0
  var off = offset
  while true:
    if off >= data.len:
      raise newException(ValueError, "truncated varint")
    let b = data[off]
    inc off
    value = value or ((b.int and 0x7F) shl shift)
    if (b and 0x80) == 0:
      return (value, off)
    inc shift, 7
    if shift >= (sizeof(int) * 8):
      raise newException(ValueError, "varint too long")

proc serializePage*(keys: seq[seq[byte]]): seq[byte] =
  result = newSeqOfCap[byte](keys.len * 8)
  let count = keys.len.uint16
  result.add byte(count shr 8)
  result.add byte(count and 0xFF)
  var prev: seq[byte] = @[]
  for key in keys:
    let plen = commonPrefixLen(prev, key)
    let suffix = key[plen .. ^1]
    writeVarint(result, plen)
    writeVarint(result, suffix.len)
    result.add suffix
    prev = key

proc deserializePage*(data: openArray[byte]): seq[seq[byte]] =
  if data.len < 2:
    raise newException(ValueError, "page too short")
  let count = (uint16(data[0]) shl 8 or uint16(data[1])).int
  result = newSeqOfCap[seq[byte]](count)
  var offset = 2
  var prev: seq[byte] = @[]
  for _ in 0 ..< count:
    let (plenRaw, next1) = readVarint(data, offset)
    offset = next1
    let (slen, next2) = readVarint(data, offset)
    offset = next2
    let extent = offset + slen
    if extent > data.len:
      raise newException(ValueError,
        "truncated key: offset=" & $offset & " slen=" & $slen & " dataLen=" & $data.len)
    let plen = min(plenRaw, prev.len)
    var key = newSeqOfCap[byte](plen + slen)
    key.add prev[0 ..< plen]
    key.add data[offset ..< extent]
    offset = extent
    prev = key
    result.add key

proc buildPages*(keys: seq[seq[byte]]): seq[(seq[byte], seq[byte])] =
  if keys.len == 0:
    return @[]
  if keys.len == 1:
    return @[(keys[0], serializePage(keys))]
  var total: int = 0
  for k in keys:
    total += k.len
  if total <= MaxRawSize:
    return @[(keys[0], serializePage(keys))]
  let mid = keys.len div 2
  result = buildPages(keys[0 ..< mid])
  result.add buildPages(keys[mid .. ^1])

# ══════════════════════════════════════════════════════════════════════════════
# Key-value leaf page serialization (CFs >= 10)
# ══════════════════════════════════════════════════════════════════════════════

proc serializePageKv*(pairs: seq[(seq[byte], seq[byte])]): seq[byte] =
  ## Serialize key-value pairs with prefix compression on keys.
  ## Format: count(u16) + for each: plen(varint) slen(varint) suffix(bytes) vlen(varint) value(bytes)
  result = newSeqOfCap[byte](pairs.len * 16)
  let count = pairs.len.uint16
  result.add byte(count shr 8)
  result.add byte(count and 0xFF)
  var prev: seq[byte] = @[]
  for (key, value) in pairs:
    let plen = commonPrefixLen(prev, key)
    let suffix = key[plen .. ^1]
    writeVarint(result, plen)
    writeVarint(result, suffix.len)
    result.add suffix
    writeVarint(result, value.len)
    result.add value
    prev = key

proc deserializePageKv*(data: openArray[byte]): seq[(seq[byte], seq[byte])] =
  if data.len < 2:
    raise newException(ValueError, "page too short")
  let count = (uint16(data[0]) shl 8 or uint16(data[1])).int
  result = newSeqOfCap[(seq[byte], seq[byte])](count)
  var offset = 2
  var prev: seq[byte] = @[]
  for _ in 0 ..< count:
    let (plenRaw, next1) = readVarint(data, offset)
    offset = next1
    let (slen, next2) = readVarint(data, offset)
    offset = next2
    let keyEnd = offset + slen
    if keyEnd > data.len:
      raise newException(ValueError, "truncated key")
    let plen = min(plenRaw, prev.len)
    var key = newSeqOfCap[byte](plen + slen)
    key.add prev[0 ..< plen]
    key.add data[offset ..< keyEnd]
    offset = keyEnd
    let (vlen, next3) = readVarint(data, offset)
    offset = next3
    let valEnd = offset + vlen
    if valEnd > data.len:
      raise newException(ValueError, "truncated value")
    var value = newSeq[byte](vlen)
    if vlen > 0: copyMem(addr value[0], unsafeAddr data[offset], vlen)
    offset = valEnd
    prev = key
    result.add (key, value)

proc buildPagesKv*(pairs: seq[(seq[byte], seq[byte])]): seq[(seq[byte], seq[byte])] =
  if pairs.len == 0:
    return @[]
  if pairs.len == 1:
    return @[(pairs[0][0], serializePageKv(pairs))]
  var total: int = 0
  for (k, v) in pairs:
    total += k.len + v.len
  if total <= MaxRawSize:
    return @[(pairs[0][0], serializePageKv(pairs))]
  let mid = pairs.len div 2
  result = buildPagesKv(pairs[0 ..< mid])
  result.add buildPagesKv(pairs[mid .. ^1])
