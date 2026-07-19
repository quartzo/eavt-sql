## keys.nim — EAVT key encoding for 4 column families.
##
## Port of spier-transactor/src/keys.rs (~839 lines Rust → Nim).

import std/[strutils, strformat]
import ./resolver  # for PartDb, PartUser, PartTx, partitionOf, makeEntityId

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
