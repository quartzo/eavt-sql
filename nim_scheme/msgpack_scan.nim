## msgpack_scan.nim — Top-level msgpack map key scan + raw pair injection.
##
## Shared by the transactor and the query-server gateway.  Both need
## exactly a few things from client frames: the value of top-level keys
## ("type", "id", "mode", ...) and a way to attach a correlation "id"
## without touching the payload.  Full msgpack→JsonNode conversion of
## large scheme programs costs more than executing them (measured
## ~15 ms per 129 KB frame); these helpers instead
##
##   • walk ONLY the top-level map's key slots, skipping values by
##     header length (never decoding their contents), and
##   • append ("id", n) to the raw bytes — msgpack maps are unordered,
##     so appending a pair at the end is protocol-legal.
##
## Everything is bounds-checked and depth-capped; malformed input yields
## empty results rather than exceptions.

const
  MaxDepth* = 64          # container nesting cap (malformed-input guard)

# ── Low-level readers ───────────────────────────────────────────────────────

func rd8(buf: string; pos: int): int {.inline.} =
  ord(buf[pos])

func rdBe16(buf: string; pos: int): int {.inline.} =
  (ord(buf[pos]) shl 8) or ord(buf[pos + 1])

func rdBe32(buf: string; pos: int): int64 {.inline.} =
  (int64(ord(buf[pos])) shl 24) or (int64(ord(buf[pos + 1])) shl 16) or
  (int64(ord(buf[pos + 2])) shl 8) or int64(ord(buf[pos + 3]))

# ── Value skipping ──────────────────────────────────────────────────────────

proc skipValue*(buf: string; pos, depth: int): int =
  ## Index just past the value starting at `pos`, or -1 if malformed /
  ## truncated / deeper than MaxDepth.  Never reads value contents.
  ## Exported: wire.nim uses it to hop between tagged nodes.
  if depth > MaxDepth or pos < 0 or pos >= buf.len:
    return -1
  template fin(p: int): int =
    (if p <= buf.len: p else: -1)
  let b = rd8(buf, pos)
  case b
  of 0x00..0x7f, 0xe0..0xff, 0xc0, 0xc2, 0xc3:
    fin(pos + 1)
  of 0xcc, 0xd0:                                         # u8 / i8
    fin(pos + 2)
  of 0xcd, 0xd1:                                         # u16 / i16
    fin(pos + 3)
  of 0xd4:                                               # fixext1 (+type byte)
    fin(pos + 3)
  of 0xd5:                                               # fixext2
    fin(pos + 4)
  of 0xca, 0xce, 0xd2:                                   # f32 / u32 / i32
    fin(pos + 5)
  of 0xd6:                                               # fixext4
    fin(pos + 6)
  of 0xcb, 0xcf, 0xd3:                                   # f64 / u64 / i64
    fin(pos + 9)
  of 0xd7:                                               # fixext8
    fin(pos + 10)
  of 0xd8:                                               # fixext16
    fin(pos + 18)
  of 0xa0..0xbf:                                         # fixstr
    fin(pos + 1 + (b and 0x1f))
  of 0xd9:                                               # str8
    if pos + 1 >= buf.len: -1 else: fin(pos + 2 + rd8(buf, pos + 1))
  of 0xda:                                               # str16
    if pos + 2 >= buf.len: -1 else: fin(pos + 3 + rdBe16(buf, pos + 1))
  of 0xdb:                                               # str32
    if pos + 4 >= buf.len: -1
    else:
      let n = rdBe32(buf, pos + 1)
      if n < 0 or n > int64(buf.len): -1 else: fin(pos + 5 + int(n))
  of 0xc4:                                               # bin8
    if pos + 1 >= buf.len: -1 else: fin(pos + 2 + rd8(buf, pos + 1))
  of 0xc5:                                               # bin16
    if pos + 2 >= buf.len: -1 else: fin(pos + 3 + rdBe16(buf, pos + 1))
  of 0xc6:                                               # bin32
    if pos + 4 >= buf.len: -1
    else:
      let n = rdBe32(buf, pos + 1)
      if n < 0 or n > int64(buf.len): -1 else: fin(pos + 5 + int(n))
  of 0xc7:                                               # ext8
    if pos + 1 >= buf.len: -1 else: fin(pos + 3 + rd8(buf, pos + 1))
  of 0xc8:                                               # ext16
    if pos + 2 >= buf.len: -1 else: fin(pos + 4 + rdBe16(buf, pos + 1))
  of 0xc9:                                               # ext32
    if pos + 4 >= buf.len: -1
    else:
      let n = rdBe32(buf, pos + 1)
      if n < 0 or n > int64(buf.len): -1 else: fin(pos + 6 + int(n))
  of 0x90..0x9f:                                         # fixarray
    var p = pos + 1
    for i in 1 .. (b and 0x0f):
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
    fin(p)
  of 0xdc:                                               # array16
    if pos + 2 >= buf.len: return -1
    var p = pos + 3
    for i in 1 .. rdBe16(buf, pos + 1):
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
    fin(p)
  of 0xdd:                                               # array32
    if pos + 4 >= buf.len: return -1
    let n = rdBe32(buf, pos + 1)
    if n < 0 or n > int64(buf.len): return -1
    var p = pos + 5
    for i in 1 .. int(n):
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
    fin(p)
  of 0x80..0x8f:                                         # fixmap
    var p = pos + 1
    for i in 1 .. (b and 0x0f):
      p = skipValue(buf, p, depth + 1)                   # key
      if p < 0: return -1
      p = skipValue(buf, p, depth + 1)                   # value
      if p < 0: return -1
    fin(p)
  of 0xde:                                               # map16
    if pos + 2 >= buf.len: return -1
    var p = pos + 3
    for i in 1 .. rdBe16(buf, pos + 1):
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
    fin(p)
  of 0xdf:                                               # map32
    if pos + 4 >= buf.len: return -1
    let n = rdBe32(buf, pos + 1)
    if n < 0 or n > int64(buf.len): return -1
    var p = pos + 5
    for i in 1 .. int(n):
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
      p = skipValue(buf, p, depth + 1)
      if p < 0: return -1
    fin(p)
  else:
    -1

# ── Top-level map access ────────────────────────────────────────────────────

func isMsgpackMap*(buf: string): bool {.raises: [].} =
  ## True when `buf` starts with a msgpack map header (fixmap/map16/map32).
  if buf.len == 0: return false
  case rd8(buf, 0)
  of 0x80..0x8f, 0xde, 0xdf: true
  else: false

proc mapCountAndHeaderLen(buf: string): tuple[count: int64, hdr: int] =
  ## (-1, 0) when not a map / truncated header.
  if buf.len == 0: return (-1, 0)
  let b = rd8(buf, 0)
  if b >= 0x80 and b <= 0x8f: return (int64(b and 0x0f), 1)
  if b == 0xde:
    if buf.len < 3: return (-1, 0)
    return (int64(rdBe16(buf, 1)), 3)
  if b == 0xdf:
    if buf.len < 5: return (-1, 0)
    return (rdBe32(buf, 1), 5)
  return (-1, 0)

proc decodeStrAt*(buf: string; start, stop: int): string {.raises: [].} =
  ## Decode a msgpack str occupying [start, stop); "" if it is not a str.
  if start < 0 or stop > buf.len or start >= stop: return ""
  let b = rd8(buf, start)
  if b >= 0xa0 and b <= 0xbf:
    let n = b and 0x1f
    if start + 1 + n == stop: return buf[start + 1 ..< stop]
  elif b == 0xd9:
    if start + 2 <= stop:
      let n = rd8(buf, start + 1)
      if start + 2 + n == stop: return buf[start + 2 ..< stop]
  elif b == 0xda:
    if start + 3 <= stop:
      let n = rdBe16(buf, start + 1)
      if start + 3 + n == stop: return buf[start + 3 ..< stop]
  elif b == 0xdb:
    if start + 5 <= stop:
      let n = int(rdBe32(buf, start + 1))
      if n >= 0 and start + 5 + n == stop: return buf[start + 5 ..< stop]
  ""

proc topValue*(buf: string; key: string): tuple[found: bool, start, stop: int] {.
    raises: [].} =
  ## Locate the VALUE slot of `key` in the top-level msgpack map.
  ## found=false for missing key, non-map input, or malformed frame.
  let (count, hdr) = mapCountAndHeaderLen(buf)
  if count < 0: return
  var pos = hdr
  for i in 1 .. count:
    let kStart = pos
    pos = skipValue(buf, pos, 0)
    if pos < 0: return
    let vStart = pos
    pos = skipValue(buf, pos, 0)
    if pos < 0: return
    if decodeStrAt(buf, kStart, vStart) == key:
      return (true, vStart, pos)
  (false, 0, 0)

proc hasTopKey*(buf: string; key: string): bool {.raises: [].} =
  topValue(buf, key)[0]

proc getTopStr*(buf: string; key: string): string {.raises: [].} =
  ## String value of top-level `key`, or "" when missing / not a str.
  let (found, s, e) = topValue(buf, key)
  if found: decodeStrAt(buf, s, e) else: ""

proc getTopBool*(buf: string; key: string; fallback = false): bool {.
    raises: [].} =
  ## Bool value of top-level `key`; `fallback` when missing or not a bool.
  let (found, s, e) = topValue(buf, key)
  if found and e - s == 1:
    case rd8(buf, s)
    of 0xc3: return true
    of 0xc2: return false
    else: discard
  fallback

proc getTopInt*(buf: string; key: string; fallback: int64 = 0): int64 {.
    raises: [].} =
  ## Integer value of top-level `key`; `fallback` when missing or not an int.
  let (found, s, e) = topValue(buf, key)
  if not found or s >= e: return fallback
  let b = rd8(buf, s)
  template need(n: int): bool = s + n <= e
  case b
  of 0x00..0x7f:
    return int64(b)
  of 0xe0..0xff:
    return int64(cast[int8](byte(b)))
  of 0xcc:
    if need(2):
      return int64(rd8(buf, s + 1))
  of 0xcd:
    if need(3):
      return int64(rdBe16(buf, s + 1))
  of 0xce:
    if need(5):
      let v = rdBe32(buf, s + 1)
      if v <= int64(high(int32)):
        return v
  of 0xcf:
    if need(9):
      let hi = uint32(rdBe32(buf, s + 1)) and 0xFFFFFFFF'u32
      let lo = uint32(rdBe32(buf, s + 5)) and 0xFFFFFFFF'u32
      return cast[int64](uint64(hi) shl 32 or uint64(lo))
  of 0xd0:
    if need(2):
      return int64(cast[int8](byte(rd8(buf, s + 1))))
  of 0xd1:
    if need(3):
      return int64(cast[int16](uint16(rdBe16(buf, s + 1))))
  of 0xd2:
    if need(5):
      return int64(cast[int32](uint32(rdBe32(buf, s + 1)) and 0xFFFFFFFF'u32))
  of 0xd3:
    if need(9):
      let hi = uint32(rdBe32(buf, s + 1)) and 0xFFFFFFFF'u32
      let lo = uint32(rdBe32(buf, s + 5)) and 0xFFFFFFFF'u32
      return cast[int64](uint64(hi) shl 32 or uint64(lo))
  else:
    discard
  fallback

iterator topArrayElems*(buf: string; start, stop: int):
    tuple[s, e: int] {.raises: [].} =
  ## Iterate element slots [s, e) of the msgpack ARRAY occupying
  ## [start, stop).  Yields nothing for non-array / malformed input.
  if start >= 0 and stop <= buf.len and start < stop:
    let b = rd8(buf, start)
    var count = -1
    var pos = start + 1
    case b
    of 0x90..0x9f:
      count = b and 0x0f
    of 0xdc:
      if start + 3 <= stop:
        count = rdBe16(buf, start + 1)
        pos = start + 3
    of 0xdd:
      if start + 5 <= stop:
        let n = rdBe32(buf, start + 1)
        if n >= 0 and n <= int64(stop): count = int(n)
        pos = start + 5
    else:
      discard
    if count >= 0:
      for i in 1 .. count:
        if pos >= stop: break
        let sPos = pos
        let endPos = skipValue(buf, pos, 0)
        if endPos < 0 or endPos > stop: break
        yield (sPos, endPos)
        pos = endPos

proc valueBytesAt*(buf: string; start, stop: int): seq[byte] {.raises: [].} =
  ## Raw payload bytes of the str or bin value occupying [start, stop).
  ## Empty for other types.
  if start < 0 or stop > buf.len or start >= stop: return
  let b = rd8(buf, start)
  var n = -1
  var hdr = 0
  case b
  of 0xa0..0xbf:
    n = b and 0x1f
    hdr = 1
  of 0xd9:
    if start + 2 <= stop and start + 2 + int(rd8(buf, start + 1)) == stop:
      n = int(rd8(buf, start + 1))
      hdr = 2
  of 0xda:
    if start + 3 <= stop:
      let m = rdBe16(buf, start + 1)
      if start + 3 + m == stop:
        n = m
        hdr = 3
  of 0xdb:
    if start + 5 <= stop:
      let m = rdBe32(buf, start + 1)
      if m >= 0 and start + 5 + int(m) == stop:
        n = int(m)
        hdr = 5
  of 0xc4:
    if start + 2 <= stop and start + 2 + int(rd8(buf, start + 1)) == stop:
      n = int(rd8(buf, start + 1))
      hdr = 2
  of 0xc5:
    if start + 3 <= stop:
      let m = rdBe16(buf, start + 1)
      if start + 3 + m == stop:
        n = m
        hdr = 3
  of 0xc6:
    if start + 5 <= stop:
      let m = rdBe32(buf, start + 1)
      if m >= 0 and start + 5 + int(m) == stop:
        n = int(m)
        hdr = 5
  else:
    discard
  if n >= 0 and hdr > 0:
    result = newSeq[byte](n)
    for i in 0 ..< n:
      result[i] = byte(rd8(buf, start + hdr + i))

# ── Id injection ────────────────────────────────────────────────────────────

func encStrBytes(s: string): string =
  ## Encode `s` as a minimal msgpack str.
  let n = s.len
  if n <= 31:
    result = newString(1 + n)
    result[0] = chr(0xa0 or n)
  elif n <= 255:
    result = newString(2 + n)
    result[0] = chr(0xd9)
    result[1] = chr(n)
  elif n <= 65535:
    result = newString(3 + n)
    result[0] = chr(0xda)
    result[1] = chr((n shr 8) and 0xff)
    result[2] = chr(n and 0xff)
  else:
    result = newString(5 + n)
    result[0] = chr(0xdb)
    result[1] = chr((n shr 24) and 0xff)
    result[2] = chr((n shr 16) and 0xff)
    result[3] = chr((n shr 8) and 0xff)
    result[4] = chr(n and 0xff)
  if n > 0:
    copyMem(addr result[result.len - n], unsafeAddr s[0], n)

proc injectTopPair*(raw: string; key, val: string): string {.raises: [].} =
  ## Append ("key","val") to the top-level map of raw msgpack `raw`,
  ## patching the pair count.  Returns "" for non-map or malformed
  ## headers (callers surface that as a parse error).
  let (count, hdr) = mapCountAndHeaderLen(raw)
  if count < 0: return ""
  var header: string
  if hdr == 1:                                           # fixmap
    if count < 15:
      header = $chr(0x80 or int(count + 1))
    else:                                              # 15 -> promote map16
      header = "\xde\x00\x10"
  elif hdr == 3:                                         # map16
    if count < 65_535:
      let n = int(count + 1)
      header = $chr(0xde) & chr((n shr 8) and 0xff) & chr(n and 0xff)
    else:                                              # -> promote map32
      header = "\xdf\x00\x01\x00\x00"
  else:                                                  # map32
    if count == int64(high(int32)): return ""
    let n = count + 1
    header = $chr(0xdf) &
      chr(int(n shr 24) and 0xff) & chr(int(n shr 16) and 0xff) &
      chr(int(n shr 8) and 0xff) & chr(int(n) and 0xff)
  result = header
  if raw.len > hdr:
    result.add(raw[hdr .. ^1])
  result.add(encStrBytes(key))
  result.add(encStrBytes(val))
