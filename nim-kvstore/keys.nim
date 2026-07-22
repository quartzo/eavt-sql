## keys.nim — EAVT key encoding for 4 column families.
##
## Port of spier-transactor/src/keys.rs (~839 lines Rust → Nim).

import std/[strutils]
import ./resolver
import ./scheme  # for PartDb, PartUser, PartTx, partitionOf, makeEntityId

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

proc encodeSuffix*(t: uint64; retracted: bool): uint64 =
  # Suffix is t with the lowest bit encoding retraction status.
  # bits 63-1: t >> 1, bit 0: retracted
  result = (t shl 1) or (if retracted: 1 else: 0)

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT key: [eid 8B BE][attr 4B BE][value_encoded][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildEavtKey*(eid: uint64; attr: uint32; valueEncoded: openArray[byte];
                    t: uint64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  result = newSeqOfCap[byte](8 + 4 + valueEncoded.len + 8)
  result.add byte(eid shr 56); result.add byte((eid shr 48) and 0xFF)
  result.add byte((eid shr 40) and 0xFF); result.add byte((eid shr 32) and 0xFF)
  result.add byte((eid shr 24) and 0xFF); result.add byte((eid shr 16) and 0xFF)
  result.add byte((eid shr 8) and 0xFF); result.add byte(eid and 0xFF)
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

proc buildAevtKey*(attr: uint32; eid: uint64; valueEncoded: openArray[byte];
                    t: uint64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  result = newSeqOfCap[byte](4 + 8 + valueEncoded.len + 8)
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add byte(eid shr 56); result.add byte((eid shr 48) and 0xFF)
  result.add byte((eid shr 40) and 0xFF); result.add byte((eid shr 32) and 0xFF)
  result.add byte((eid shr 24) and 0xFF); result.add byte((eid shr 16) and 0xFF)
  result.add byte((eid shr 8) and 0xFF); result.add byte(eid and 0xFF)
  result.add valueEncoded
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# AVET key: [attr 4B BE][value_encoded][eid 8B BE][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildAvetKey*(attr: uint32; valueEncoded: openArray[byte]; eid: uint64;
                    t: uint64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  result = newSeqOfCap[byte](4 + valueEncoded.len + 8 + 8)
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add valueEncoded
  result.add byte(eid shr 56); result.add byte((eid shr 48) and 0xFF)
  result.add byte((eid shr 40) and 0xFF); result.add byte((eid shr 32) and 0xFF)
  result.add byte((eid shr 24) and 0xFF); result.add byte((eid shr 16) and 0xFF)
  result.add byte((eid shr 8) and 0xFF); result.add byte(eid and 0xFF)
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# VAET key: [value_encoded][attr 4B BE][eid 8B BE][suffix 8B BE]
# ═══════════════════════════════════════════════════════════════════════════════

proc buildVaetKey*(valueEncoded: openArray[byte]; attr: uint32; eid: uint64;
                    t: uint64; retracted: bool): seq[byte] =
  let sf = encodeSuffix(t, retracted)
  result = newSeqOfCap[byte](valueEncoded.len + 4 + 8 + 8)
  result.add valueEncoded
  result.add byte(attr shr 24); result.add byte((attr shr 16) and 0xFF)
  result.add byte((attr shr 8) and 0xFF); result.add byte(attr and 0xFF)
  result.add byte(eid shr 56); result.add byte((eid shr 48) and 0xFF)
  result.add byte((eid shr 40) and 0xFF); result.add byte((eid shr 32) and 0xFF)
  result.add byte((eid shr 24) and 0xFF); result.add byte((eid shr 16) and 0xFF)
  result.add byte((eid shr 8) and 0xFF); result.add byte(eid and 0xFF)
  result.add byte(sf shr 56); result.add byte((sf shr 48) and 0xFF)
  result.add byte((sf shr 40) and 0xFF); result.add byte((sf shr 32) and 0xFF)
  result.add byte(sf shr 24); result.add byte((sf shr 16) and 0xFF)
  result.add byte((sf shr 8) and 0xFF); result.add byte(sf and 0xFF)

# ═══════════════════════════════════════════════════════════════════════════════
# Value encoding
# ═══════════════════════════════════════════════════════════════════════════════

proc encodeRef*(eid: uint64): seq[byte] =
  result = newSeqOfCap[byte](8)
  result.add byte(eid shr 56); result.add byte((eid shr 48) and 0xFF)
  result.add byte((eid shr 40) and 0xFF); result.add byte((eid shr 32) and 0xFF)
  result.add byte(eid shr 24); result.add byte((eid shr 16) and 0xFF)
  result.add byte((eid shr 8) and 0xFF); result.add byte(eid and 0xFF)

proc encodeInt*(n: int64): seq[byte] =
  # Flip sign bit for ordering
  var x = cast[uint64](n xor (1'i64 shl 63))
  result = newSeqOfCap[byte](8)
  result.add byte(x shr 56); result.add byte((x shr 48) and 0xFF)
  result.add byte((x shr 40) and 0xFF); result.add byte((x shr 32) and 0xFF)
  result.add byte(x shr 24); result.add byte((x shr 16) and 0xFF)
  result.add byte((x shr 8) and 0xFF); result.add byte(x and 0xFF)

proc encodeFloat*(f: float64): seq[byte] =
  var x = cast[uint64](f)
  # If negative, flip all bits; if positive, flip sign bit only
  if (x shr 63) == 1:
    x = not x
  else:
    x = x xor (1'u64 shl 63)
  result = newSeqOfCap[byte](8)
  result.add byte(x shr 56); result.add byte((x shr 48) and 0xFF)
  result.add byte((x shr 40) and 0xFF); result.add byte((x shr 32) and 0xFF)
  result.add byte(x shr 24); result.add byte((x shr 16) and 0xFF)
  result.add byte((x shr 8) and 0xFF); result.add byte(x and 0xFF)

proc encodeVariable*(s: string): seq[byte] =
  let raw = s.cstring
  var i = 0
  while raw[i] != '\0': inc i
  let length = i
  result = newSeqOfCap[byte](length + 4)
  result.add byte(length shr 24); result.add byte((length shr 16) and 0xFF)
  result.add byte((length shr 8) and 0xFF); result.add byte(length and 0xFF)
  for j in 0..<length:
    result.add byte(raw[j])

proc encodeVariableUnordered*(data: openArray[byte]): seq[byte] =
  let length = data.len
  result = newSeqOfCap[byte](length + 4)
  result.add byte(length shr 24); result.add byte((length shr 16) and 0xFF)
  result.add byte((length shr 8) and 0xFF); result.add byte(length and 0xFF)
  result.add data

# Value encoding by mode
proc encodeValue*(v: string; mode: EncodeMode; refEid: uint64 = 0): seq[byte] =
  case mode:
  of emRef: return encodeRef(refEid)
  of emVariable: return encodeVariable(v)
  of emBlob: return encodeVariableUnordered(v.toOpenArrayByte(0, v.len - 1))
  of emFixed:
    # Try to parse as int64
    try:
      let n = parseInt(v)
      return encodeInt(n)
    except:
      # Try float
      try:
        let f = parseFloat(v)
        return encodeFloat(f)
      except:
        return encodeInt(0)

# ═══════════════════════════════════════════════════════════════════════════════
# EAVT entry builder — generates keys for all 4 CFs
# ═══════════════════════════════════════════════════════════════════════════════

type
  EavtEntry* = object
    cf*: uint8
    key*: seq[byte]

proc buildEavtEntries*(eid: uint64; attr: uint32; encodedValue: seq[byte];
                        t: uint64; retracted: bool; mode: EncodeMode;
                        indexed: bool): seq[EavtEntry] =
  let sf = encodeSuffix(t, retracted)
  var aBytes = newSeq[byte](4)
  aBytes[0] = byte(attr shr 24); aBytes[1] = byte((attr shr 16) and 0xFF)
  aBytes[2] = byte((attr shr 8) and 0xFF); aBytes[3] = byte(attr and 0xFF)
  var eBytes = encodeRef(eid)
  var sfBytes = newSeq[byte](8)
  sfBytes[0] = byte(sf shr 56); sfBytes[1] = byte((sf shr 48) and 0xFF)
  sfBytes[2] = byte((sf shr 40) and 0xFF); sfBytes[3] = byte((sf shr 32) and 0xFF)
  sfBytes[4] = byte(sf shr 24); sfBytes[5] = byte((sf shr 16) and 0xFF)
  sfBytes[6] = byte((sf shr 8) and 0xFF); sfBytes[7] = byte(sf and 0xFF)

  # CF 0: eavt [eid][attr][val][sf]
  result.add EavtEntry(cf: 0, key: eBytes & aBytes & encodedValue & sfBytes)
  # CF 1: aevt [attr][eid][val][sf]
  result.add EavtEntry(cf: 1, key: aBytes & eBytes & encodedValue & sfBytes)

  if mode == emRef:
    # CF 3: vaet [val][attr][eid][sf]
    result.add EavtEntry(cf: 3, key: encodedValue & aBytes & eBytes & sfBytes)
    if indexed:
      # CF 2: avet [attr][val][eid][sf]
      result.add EavtEntry(cf: 2, key: aBytes & encodedValue & eBytes & sfBytes)
  else:
    if indexed:
      result.add EavtEntry(cf: 2, key: aBytes & encodedValue & eBytes & sfBytes)

# ═══════════════════════════════════════════════════════════════════════════════
# Decoding (used by query engine scanner)
# ═══════════════════════════════════════════════════════════════════════════════

proc decodeSuffix*(encoded: uint64): (uint64, bool) =
  ## Returns (t, retracted) from an encoded suffix.
  let t = encoded shr 1
  let retracted = (encoded and 1) != 0
  (t, retracted)

proc decodeInt64*(raw: uint64): int64 =
  ## Reverse of encodeInt — reverse sign-flip.
  cast[int64](raw xor (1'u64 shl 63))

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
  ## Decode an emVariable value ([u32 len][bytes]) at `start`.
  if start + 4 > data.len: return ""
  let n = (uint32(data[start]) shl 24 or uint32(data[start+1]) shl 16 or
           uint32(data[start+2]) shl 8 or uint32(data[start+3])).int
  if start + 4 + n > data.len: return ""
  result = newString(n)
  if n > 0: copyMem(addr result[0], unsafeAddr data[start+4], n)

proc decodeStoredValue*(data: openArray[byte]; vt: uint32): SExpr =
  ## Decode a stored EAVT value given its db valueType.
  case vt:
  of DbTypeRef:
    if data.len >= 8: SExpr(kind: sInt, ival: cast[int64](beUint64(data, 0)))
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
  case val.kind:
  of sStr:  encodeVariable(val.sval)
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
