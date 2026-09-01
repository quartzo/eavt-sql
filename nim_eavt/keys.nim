## keys.nim — EAVT key encoding for 4 column families.
##
## Port of spier-transactor/src/keys.rs (~839 lines Rust → Nim).

import std/[strutils]
import resolver
import scheme  # for PartDb, PartUser, PartTx, partitionOf, makeEntityId
import nim_memtable/treap_backend  # Arena, KeyRef, allocKeyBytes

# ═══════════════════════════════════════════════════════════════════════════════
# Encode mode
# ═══════════════════════════════════════════════════════════════════════════════

type
  EncodeMode* = enum
    emRef
    emVariable   # text, keyword
    emBlob       # bytes, blob
    emFixed      # int, float, bool, instant

# ═══════════════════════════════════════════════════════════════════════════════
# Suffix: [t (8 bytes big-endian)] + [1 byte: 0=active, 1=retracted]
# ═══════════════════════════════════════════════════════════════════════════════

proc encodeSuffix*(t: int64; retracted: bool): uint64 =
  result = (cast[uint64](t) shl 1) or (if retracted: 1 else: 0)

# ── Word stores big-endian (mesmo output do encadear de shifts; 1 store 8B) ──

when system.cpuEndian == littleEndian:
  proc bswap64u(v: uint64): uint64 {.inline.} =
    ((v and 0x00000000000000FF'u64) shl 56) or
    ((v and 0x000000000000FF00'u64) shl 40) or
    ((v and 0x0000000000FF0000'u64) shl 24) or
    ((v and 0x00000000FF000000'u64) shl 8) or
    ((v and 0x000000FF00000000'u64) shr 8) or
    ((v and 0x0000FF0000000000'u64) shr 24) or
    ((v and 0x00FF000000000000'u64) shr 40) or
    ((v and 0xFF00000000000000'u64) shr 56)
  proc bswap32u(v: uint32): uint32 {.inline.} =
    ((v and 0x000000FF'u32) shl 24) or ((v and 0x0000FF00'u32) shl 8) or
    ((v and 0x00FF0000'u32) shr 8) or ((v and 0xFF000000'u32) shr 24)
else:
  template bswap64u(v: uint64): uint64 = v
  template bswap32u(v: uint32): uint32 = v

proc storeBE64*(p: ptr UncheckedArray[byte]; off: int; v: uint64) {.inline.} =
  ## 8 bytes big-endian em `p[off..off+8)` — substitui 8 `seq.add`.
  let x = bswap64u(v)
  copyMem(addr p[off], unsafeAddr x, 8)

proc storeBE32*(p: ptr UncheckedArray[byte]; off: int; v: uint32) {.inline.} =
  ## 4 bytes big-endian em `p[off..off+4)` — substitui 4 `seq.add`.
  let x = bswap32u(v)
  copyMem(addr p[off], unsafeAddr x, 4)

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT key: [eid 8B BE][attr 4B BE][value_encoded][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════


proc encodeInt*(n: int64): seq[byte] =
  # Flip sign bit for ordering; 1 store BE em vez de 8 adds.
  let x = bswap64u(cast[uint64](n xor (1'i64 shl 63)))
  result = newSeq[byte](8)
  copyMem(addr result[0], unsafeAddr x, 8)

proc encodeEid*(eid: int64): seq[byte] =
  encodeInt(eid)

proc encodeFloat*(f: float64): seq[byte] =
  var x = cast[uint64](f)
  # If negative, flip all bits; if positive, flip sign bit only
  if (x shr 63) == 1:
    x = not x
  else:
    x = x xor (1'u64 shl 63)
  let b = bswap64u(x)
  result = newSeq[byte](8)
  copyMem(addr result[0], unsafeAddr b, 8)

proc encodeVariable*(s: string): seq[byte] =
  ## Encode a string for lexicographic ordering: 8-byte blocks + control byte.
  ## Control: 0xFF = more blocks follow; 0..7 = last block valid bytes.
  ## Blocos cheios: 1 load + 1 store de 8B; cauda: byte a byte (sem overread).
  let raw = s.cstring
  var len = 0
  while raw[len] != '\0': inc len
  result = newSeqOfCap[byte](len + (len div 8) + 2)
  var wbuf: uint64
  var pos = 0
  while pos < len:
    let remaining = len - pos
    let base = result.len
    result.setLen(base + 9)
    if remaining > 8:
      copyMem(addr wbuf, unsafeAddr raw[pos], 8)
      copyMem(addr result[base], addr wbuf, 8)
      result[base + 8] = 0xFF
    else:
      for j in 0 ..< remaining: result[base + j] = byte(raw[pos + j])
      for j in remaining ..< 8: result[base + j] = 0
      result[base + 8] = byte(remaining)
    pos += 8

proc encodeVariableUnordered*(data: openArray[byte]): seq[byte] =
  let length = data.len
  result = newSeq[byte](length + 4)
  storeBE32(cast[ptr UncheckedArray[byte]](addr result[0]), 0, length.uint32)
  if length > 0:
    copyMem(addr result[4], unsafeAddr data[0], length)

# Value encoding by mode
proc encodeValue*(v: string; mode: EncodeMode; refEid: int64 = 0): seq[byte] =
  case mode:
  of emRef: return encodeEid(refEid)
  of emVariable: return encodeVariable(v)
  of emBlob: return encodeVariableUnordered(v.toOpenArrayByte(0, v.len - 1))
  of emFixed:
    # Canonical boolean spellings (SExpr sBool renders as "true"/"false").
    if v == "true": return encodeInt(1)
    if v == "false": return encodeInt(0)
    # Try to parse as int64
    try:
      let n = parseInt(v)
      return encodeInt(n)
    except ValueError:
      # Try float
      try:
        let f = parseFloat(v)
        return encodeFloat(f)
      except ValueError:
        # Interrupt: silently encoding unparseable values as 0 corrupted
        # data without a trace — a type mismatch must be loud.
        raise newException(ValueError,
          "cannot encode fixed value (not int/float): \"" & v & "\"")

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT entry builder — generates keys for all 4 CFs
# ═══════════════════════════════════════════════════════════════════════════════

type
  EavtEntry* = object
    cf*: uint8
    key*: KeyRef
proc buildEavtKey*(eid: int64; attr: uint32; valueEncoded: openArray[byte];
                    t: int64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  let eBytes = encodeEid(eid)
  result = newSeqOfCap[byte](8 + 4 + valueEncoded.len + 8)
  result.add eBytes
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add valueEncoded
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# AEVT key: [attr 4B BE][eid 8B BE][value_encoded][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildAevtKey*(attr: uint32; eid: int64; valueEncoded: openArray[byte];
                    t: int64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  let eBytes = encodeEid(eid)
  result = newSeqOfCap[byte](4 + 8 + valueEncoded.len + 8)
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add eBytes
  result.add valueEncoded
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# AVET key: [attr 4B BE][value_encoded][eid 8B BE][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildAvetKey*(attr: uint32; valueEncoded: openArray[byte]; eid: int64;
                    t: int64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  let eBytes = encodeEid(eid)
  result = newSeqOfCap[byte](4 + valueEncoded.len + 8 + 8)
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add valueEncoded
  result.add eBytes
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# VAET key: [value_encoded][attr 4B BE][eid 8B BE][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildVaetKey*(valueEncoded: openArray[byte]; attr: uint32; eid: int64;
                    t: int64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  let eBytes = encodeEid(eid)
  result = newSeqOfCap[byte](valueEncoded.len + 4 + 8 + 8)
  result.add valueEncoded
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add eBytes
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# Value encoding
# ═══════════════════════════════════════════════════════════════════════════════

proc buildEavtEntries*(arena: Arena; eid: int64; attr: uint32; encodedValue: seq[byte];
                        t: int64; retracted: bool; mode: EncodeMode;
                        indexed: bool): seq[EavtEntry] =
  ## Monta as chaves direto no arena com stores de palavra — sem seqs
  ## intermediárias nem memcpys de fragmentos (o payload [8B eid] etc. é
  ## escrito 1x por chave com storeBE64/32 + 1 copyMem do valor).
  let sf = encodeSuffix(t, retracted)
  let ex = cast[uint64](eid) xor (1'u64 shl 63)
  let vlen = encodedValue.len
  let klen = 8 + 4 + vlen + 8

  # CF 0: eavt [eid][attr][val][sf]
  var p = allocKeyBytes(arena, klen)
  storeBE64(p, 0, ex)
  storeBE32(p, 8, attr)
  if vlen > 0: copyMem(addr p[12], unsafeAddr encodedValue[0], vlen)
  storeBE64(p, 12 + vlen, sf)
  result.add EavtEntry(cf: 0, key: KeyRef(p: p, len: klen))

  # CF 1: aevt [attr][eid][val][sf]
  p = allocKeyBytes(arena, klen)
  storeBE32(p, 0, attr)
  storeBE64(p, 4, ex)
  if vlen > 0: copyMem(addr p[12], unsafeAddr encodedValue[0], vlen)
  storeBE64(p, 12 + vlen, sf)
  result.add EavtEntry(cf: 1, key: KeyRef(p: p, len: klen))

  if mode == emRef:
    # CF 3: vaet [val][attr][eid][sf]
    p = allocKeyBytes(arena, klen)
    if vlen > 0: copyMem(addr p[0], unsafeAddr encodedValue[0], vlen)
    storeBE32(p, vlen, attr)
    storeBE64(p, vlen + 4, ex)
    storeBE64(p, vlen + 12, sf)
    result.add EavtEntry(cf: 3, key: KeyRef(p: p, len: klen))
    if indexed:
      # CF 2: avet [attr][val][eid][sf]
      p = allocKeyBytes(arena, klen)
      storeBE32(p, 0, attr)
      if vlen > 0: copyMem(addr p[4], unsafeAddr encodedValue[0], vlen)
      storeBE64(p, 4 + vlen, ex)
      storeBE64(p, 12 + vlen, sf)
      result.add EavtEntry(cf: 2, key: KeyRef(p: p, len: klen))
  else:
    if indexed:
      # CF 2: avet [attr][val][eid][sf]
      p = allocKeyBytes(arena, klen)
      storeBE32(p, 0, attr)
      if vlen > 0: copyMem(addr p[4], unsafeAddr encodedValue[0], vlen)
      storeBE64(p, 4 + vlen, ex)
      storeBE64(p, 12 + vlen, sf)
      result.add EavtEntry(cf: 2, key: KeyRef(p: p, len: klen))

# ═══════════════════════════════════════════════════════════════════════════════
# Decoding (used by query engine scanner)
# ═══════════════════════════════════════════════════════════════════════════════

proc decodeSuffix*(encoded: uint64): (int64, bool) =
  ## Returns (t, retracted) from an encoded suffix.
  let raw = encoded shr 1
  let t = cast[int64](raw)
  let retracted = (encoded and 1) != 0
  (t, retracted)

proc decodeInt64*(raw: uint64): int64 =
  ## Reverse of encodeInt — reverse sign-flip.
  cast[int64](raw xor (1'u64 shl 63))

proc decodeEid*(raw: uint64): int64 =
  ## Reverse of encodeEid — reverse sign-flip.
  decodeInt64(raw)

proc decodeFloat64*(raw: uint64): float64 =
  ## Reverse of encodeFloat — reverse sign-flip.
  var x = raw
  if (x shr 63) == 1:
    x = x xor (1'u64 shl 63)
  else:
    x = not x
  cast[float64](x)

proc beUint64*(data: openArray[byte]; start: int): uint64 =
  for i in 0..7:
    result = (result shl 8) or uint64(data[start + i])

proc beUint32*(data: openArray[byte]; start: int): uint32 =
  for i in 0..3:
    result = (result shl 8) or uint32(data[start + i])

# ═══════════════════════════════════════════════════════════════════════════════
# Stored value decoding (query engine)
# ═══════════════════════════════════════════════════════════════════════════════

proc decodeVariableStr*(data: openArray[byte]; start: int = 0): string =
  ## Decode an 8+1-block encoded string.
  result = ""
  var pos = start
  while pos + 9 <= data.len:
    let control = data[pos + 8]
    # Append full 8-byte block to result
    for j in 0..7:
      result.add char(data[pos + j])
    if control != 0xFF'u8:
      # Last block — trim padding zeros
      let validBytes = int(control)
      if validBytes < 8:
        result.setLen(result.len - (8 - validBytes))
      return result
    pos += 9
  return result

proc decodeStoredValue*(data: openArray[byte]; vt: uint32): SExpr =
  ## Decode a stored EAVT value given its db valueType.
  case vt:
  of DbTypeRef:
    if data.len >= 8: SExpr(kind: sInt, ival: decodeInt64(beUint64(data, 0)))
    else: SExpr(kind: sInt, ival: 0)
  of DbTypeBoolean:
    if data.len >= 8: SExpr(kind: sBool, bval: decodeInt64(beUint64(data, 0)) != 0)
    else: SExpr(kind: sBool, bval: false)
  of DbTypeLong, DbTypeInstant:
    if data.len >= 8: SExpr(kind: sInt, ival: decodeInt64(beUint64(data, 0)))
    else: SExpr(kind: sInt, ival: 0)
  of DbTypeFloat:
    if data.len >= 8: SExpr(kind: sFloat, fval: decodeFloat64(beUint64(data, 0)))
    else: SExpr(kind: sFloat, fval: 0.0)
  of DbTypeBytes, DbTypeBlob:
    if data.len >= 4:
      let n = (uint32(data[0]) shl 24 or uint32(data[1]) shl 16 or
               uint32(data[2]) shl 8 or uint32(data[3])).int
      let m = min(n, data.len - 4)
      var b = newSeq[byte](m)
      if m > 0: copyMem(addr b[0], unsafeAddr data[4], m)
      SExpr(kind: sBytes, bytesval: b)
    else:
      SExpr(kind: sBytes, bytesval: @[])
  else:
    SExpr(kind: sStr, sval: decodeVariableStr(data, 0))


# ═══════════════════════════════════════════════════════════════════════════════
# Fixed-size encoding (for query engine scanner — sign-flip for int, float, bool, instant)
# ═══════════════════════════════════════════════════════════════════════════════

proc encodeFixed*(val: SExpr): seq[byte] =
  ## Encodes a value with sign-flip for fixed-size ordering (int, float, bool, timestamp).
  case val.kind:
  of sInt:
    var x = cast[uint64](val.ival xor (1'i64 shl 63))
    result = newSeqOfCap[byte](8)
    for i in countdown(7, 0): result.add byte((x shr (i * 8)) and 0xFF)
  of sFloat:
    var x = cast[uint64](val.fval)
    if (x shr 63) == 1: x = not x
    else: x = x xor (1'u64 shl 63)
    result = newSeqOfCap[byte](8)
    for i in countdown(7, 0): result.add byte((x shr (i * 8)) and 0xFF)
  of sBool:
    result = newSeqOfCap[byte](8)
    result.add byte(if val.bval: 0x80 else: 0x00)
    for _ in 1..7: result.add byte(0)
  else:
    result = newSeqOfCap[byte](8)
    for _ in 0..7: result.add byte(0)

proc encodeBoundValue*(val: SExpr): seq[byte] =
  ## Encodes a value for scanner prefix building.
  ## Keywords encode like strings (variable-length, ordered).
  case val.kind:
  of sStr, sKeyword:  encodeVariable(if val.kind == sStr: val.sval else: val.kwval)
  of sBytes: encodeVariableUnordered(val.bytesval)
  else:     encodeFixed(val)

# CF index helpers
proc cfNameToId*(name: string): int =
  case name:
  of "eavt": 0
  of "aevt": 1
  of "avet": 2
  of "vaet": 3
  else: 0

proc cfForIndex*(index: string): string =
  case index.toLowerAscii():
  of "eavt": "eavt"
  of "aevt": "aevt"
  of "avet": "avet"
  of "vaet": "vaet"
  else: "eavt"

proc indexOrder*(index: string): seq[string] =
  case index.toLowerAscii():
  of "eavt": @["e", "a", "v"]
  of "aevt": @["a", "e", "v"]
  of "avet": @["a", "v", "e"]
  of "vaet": @["v", "a", "e"]
  else: @["e", "a", "v"]
