## query/scanner.nim — V2Scanner with leapfrog triejoin.
##
## Port of spier-eavt-query/src/engine/scanner.rs (~855 lines Rust → Nim).

import std/[options, tables, strutils]
import scheme
import keys
export keys.beUint32, keys.beUint64

# ═══════════════════════════════════════════════════════════════════════════════
# Cursor abstraction
# ═══════════════════════════════════════════════════════════════════════════════

type
  NimCursor* = ref object
    isValidCb*: proc(): bool {.closure.}
    currentKeyCb*: proc(): Option[seq[byte]] {.closure.}
    stepCb*: proc() {.closure.}
    skipGroupCb*: proc(groupEnd: int) {.closure.}
    seekCb*: proc(target: seq[byte]) {.closure.}
    invalidateCb*: proc() {.closure.}

# ═══════════════════════════════════════════════════════════════════════════════
# KeyVsPrefix — result of classify_key
# ═══════════════════════════════════════════════════════════════════════════════

type
  KeyVsPrefix* = enum
    kvpNoPrefix
    kvpBefore
    kvpMatch
    kvpAfter

  PositionStack* = ref object
    cursor*: NimCursor
    idxOrder*: seq[string]
    stack*: seq[SExpr]         # fixed entries (values)
    currentActiveKey*: Option[seq[byte]]
    atEnd*: bool

  V2Scanner* = ref object
    pos*: PositionStack
    indexName*: string
    asOfTx*: Option[int64]
    valueAttrType*: Option[uint32]
    historyMode*: bool
    prefixCache*: seq[byte]
    tInPrefix*: bool

# ═══════════════════════════════════════════════════════════════════════════════
# Storage type constants (from resolver_consts)
# ═══════════════════════════════════════════════════════════════════════════════

const
  DbTypeString* = 20'u32
  DbTypeRef* = 21'u32
  DbTypeLong* = 22'u32
  DbTypeKeyword* = 23'u32
  DbTypeBoolean* = 24'u32
  DbTypeInstant* = 25'u32
  DbTypeBytes* = 26'u32
  DbTypeFloat* = 27'u32
  DbTypeBlob* = 28'u32

# ═══════════════════════════════════════════════════════════════════════════════
# PositionStack
# ═══════════════════════════════════════════════════════════════════════════════

proc newPositionStack*(cursor: NimCursor; idxOrder: seq[string]): PositionStack =
  PositionStack(
    cursor: cursor,
    idxOrder: idxOrder,
    stack: @[],
    currentActiveKey: none[seq[byte]](),
    atEnd: true,
  )

proc pushFixed*(ps: PositionStack; val: SExpr) =
  ps.stack.add val

proc popFixed*(ps: PositionStack): Option[SExpr] =
  if ps.stack.len > 0:
    result = some(ps.stack[^1])
    ps.stack.setLen(ps.stack.len - 1)

proc fixedEntries*(ps: PositionStack): seq[(int, SExpr)] =
  for i, v in ps.stack:
    result.add (i, v)

proc currentPosition*(ps: PositionStack): int =
  ps.stack.len

proc posName*(ps: PositionStack): string =
  let ci = currentPosition(ps)
  if ci < ps.idxOrder.len:
    ps.idxOrder[ci]
  else:
    "t"

# ═══════════════════════════════════════════════════════════════════════════════
# Key helpers
# ═══════════════════════════════════════════════════════════════════════════════

proc findVEnd(key: openArray[byte]; start: int; isUnordered: bool): int =
  if isUnordered:
    if start + 4 > key.len: return key.len
    let length = int(beUint32(key, start))
    return start + 4 + length
  var pos = start
  while pos + 9 <= key.len:
    if key[pos + 8] == 0xFF'u8:
      pos += 9
    else:
      return pos + 9
  key.len

proc isUnorderedAttr*(vt: Option[uint32]): bool =
  vt.isSome and vt.get == DbTypeBlob

proc isVariableValue*(vt: Option[uint32]; keyLen: int): bool =
  if vt.isSome and (vt.get == DbTypeString or vt.get == DbTypeBytes or vt.get == DbTypeBlob):
    return true
  keyLen != 28  # not the fixed-size 28-byte key

# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner
# ═══════════════════════════════════════════════════════════════════════════════

proc newV2Scanner*(indexName: string; idxOrder: seq[string]; asOfTx: Option[int64];
                   valueAttrType: Option[uint32]): V2Scanner =
  let invalidCursor = NimCursor(
    isValidCb: proc(): bool = false,
    currentKeyCb: proc(): Option[seq[byte]] = none[seq[byte]](),
    stepCb: proc() = discard,
    skipGroupCb: proc(ge: int) = discard,
    seekCb: proc(tg: seq[byte]) = discard,
    invalidateCb: proc() = discard,
  )
  V2Scanner(
    pos: newPositionStack(invalidCursor, idxOrder),
    indexName: indexName.toUpperAscii(),
    asOfTx: asOfTx,
    valueAttrType: valueAttrType,
    historyMode: false,
    prefixCache: @[],
    tInPrefix: false,
  )

proc setCursor*(sc: V2Scanner; cursor: NimCursor) =
  sc.pos.cursor = cursor
  sc.pos.atEnd = false

proc atEnd*(sc: V2Scanner): bool = sc.pos.atEnd

# ── prefix_cache ──

proc recomputePrefix*(sc: V2Scanner) =
  var buf: seq[byte] = @[]
  var tInPrefix = false
  let fixed = sc.pos.fixedEntries()
  for pi, pn in sc.pos.idxOrder:
    var found = false
    for (idx, v) in fixed:
      if idx == pi:
        found = true
        case pn:
        of "a":
          let v32 = uint32(v.ival)
          buf.add byte(v32 shr 24); buf.add byte((v32 shr 16) and 0xFF)
          buf.add byte((v32 shr 8) and 0xFF); buf.add byte(v32 and 0xFF)
        of "e":
          buf.add keys.encodeEid(v.ival)
        of "v":
          if sc.valueAttrType == some(DbTypeBlob):
            buf.add keys.encodeVariableUnordered(v.bytesval)
          elif v.kind == sStr:
            buf.add keys.encodeVariable(v.sval)
          elif v.kind == sBytes:
            buf.add keys.encodeVariableUnordered(v.bytesval)
          else:
            buf.add keys.encodeFixed(v)
        of "t":
          let sf = keys.encodeSuffix(v.ival, false)
          buf.add byte(sf shr 56); buf.add byte((sf shr 48) and 0xFF)
          buf.add byte((sf shr 40) and 0xFF); buf.add byte((sf shr 32) and 0xFF)
          buf.add byte(sf shr 24); buf.add byte((sf shr 16) and 0xFF)
          buf.add byte((sf shr 8) and 0xFF); buf.add byte(sf and 0xFF)
          tInPrefix = true
        else:
          buf.add keys.encodeBoundValue(v)
        break
    if not found: break
  sc.prefixCache = buf
  sc.tInPrefix = tInPrefix

proc saveValue*(sc: V2Scanner; val: SExpr) =
  sc.pos.pushFixed(val)
  sc.recomputePrefix()

proc popSavedValue*(sc: V2Scanner) =
  discard sc.pos.popFixed()
  sc.recomputePrefix()

proc setValueAttrType*(sc: V2Scanner; vt: Option[uint32]) =
  sc.valueAttrType = vt
  sc.recomputePrefix()

# ── classify_key ──

proc classifyKey*(sc: V2Scanner; key: openArray[byte]): KeyVsPrefix =
  let bp = sc.prefixCache
  if bp.len == 0: return kvpNoPrefix
  let n = min(bp.len, key.len)
  var ord: int
  if sc.tInPrefix:
    let last = n - 1
    block:
      for i in 0..<last:
        if key[i] < bp[i]: ord = -1; break
        if key[i] > bp[i]: ord = 1; break
    if ord == 0:
      let k = key[last] and 0xFE'u8
      let p = bp[last] and 0xFE'u8
      if k < p: ord = -1
      elif k > p: ord = 1
      else: ord = 0
  else:
    for i in 0..<n:
      if key[i] < bp[i]: ord = -1; break
      if key[i] > bp[i]: ord = 1; break
  if ord < 0: return kvpBefore
  if ord > 0: return kvpAfter
  if key.len < bp.len: return kvpBefore
  kvpMatch

# ── value_start / value_end ──

proc valueStart*(sc: V2Scanner; key: openArray[byte]): int =
  let ci = sc.pos.currentPosition()
  let pn = sc.pos.posName()
  if ci >= sc.pos.idxOrder.len or pn == "t" or pn == "added":
    return key.len - 8
  case sc.indexName:
  of "EAVT":
    case ci
    of 0: 0
    of 1: 8
    else: 12
  of "AEVT":
    case ci
    of 0: 0
    of 1: 4
    else: 12
  of "AVET":
    case ci
    of 0: 0
    of 1: 4
    else:
      let vs = 4
      if isVariableValue(sc.valueAttrType, key.len):
        findVEnd(key, vs, isUnorderedAttr(sc.valueAttrType))
      else: vs + 8
  of "VAET":
    case ci
    of 0: 0
    of 1: 8
    else: 12
  else: 12

proc valueEnd*(sc: V2Scanner; key: openArray[byte]): int =
  let ci = sc.pos.currentPosition()
  if ci >= sc.pos.idxOrder.len: return key.len
  let pn = sc.pos.posName()
  let vs = sc.valueStart(key)
  case pn:
  of "e": vs + 8
  of "a": vs + 4
  of "v":
    if isVariableValue(sc.valueAttrType, key.len):
      findVEnd(key, vs, isUnorderedAttr(sc.valueAttrType))
    else: vs + 8
  else: key.len

# ── suffix ──

proc extractSuffix(key: openArray[byte]): uint64 =
  let start = key.len - 8
  beUint64(key, start)

# ── extract_current ──

proc extractCurrent*(sc: V2Scanner): Option[SExpr] =
  let key = sc.pos.currentActiveKey
  if key.isNone: return none[SExpr]()
  let k = key.get
  if classifyKey(sc, k) notin {kvpMatch, kvpNoPrefix}:
    return none[SExpr]()
  let pn = sc.pos.posName()
  let ci = sc.pos.currentPosition()

  if ci >= sc.pos.idxOrder.len or pn == "t" or pn == "added":
    let suffix = extractSuffix(k)
    let (t, retracted) = keys.decodeSuffix(suffix)
    if pn == "added":
      return some(SExpr(kind: sBool, bval: not retracted))
    else:
      return some(SExpr(kind: sInt, ival: int64(t)))

  let vs = sc.valueStart(k)
  let ve = sc.valueEnd(k)

  case pn:
  of "a":
    return some(SExpr(kind: sInt, ival: int64(beUint32(k, vs))))
  of "e":
    let raw = beUint64(k, vs)
    return some(SExpr(kind: sInt, ival: int64(raw)))
  of "v":
    if isVariableValue(sc.valueAttrType, k.len):
      let data = k[vs..<ve]
      if sc.valueAttrType == some(DbTypeString):
        return some(SExpr(kind: sStr, sval: keys.decodeVariableStr(data, 0)))
      elif sc.valueAttrType == some(DbTypeBytes):
        return some(SExpr(kind: sBytes, bytesval: @(data)))
      elif sc.valueAttrType == some(DbTypeBlob):
        return some(SExpr(kind: sBytes, bytesval: @(data)))
      else:
        return some(SExpr(kind: sStr, sval: keys.decodeVariableStr(data, 0)))
    else:
      let raw = beUint64(k, vs)
      case true:
      of true:
        if sc.valueAttrType == some(DbTypeFloat):
          return some(SExpr(kind: sFloat, fval: keys.decodeFloat64(raw)))
        elif sc.valueAttrType == some(DbTypeBoolean):
          return some(SExpr(kind: sBool, bval: raw != 0))
        elif sc.valueAttrType == some(DbTypeInstant) or sc.valueAttrType == some(DbTypeRef):
          return some(SExpr(kind: sInt, ival: keys.decodeInt64(raw)))
        else:
          return some(SExpr(kind: sInt, ival: int64(raw)))
      else: discard
  else: discard
  none[SExpr]()

# ── advance_to_active_at ──

proc advanceToActiveAt*(sc: V2Scanner) =
  let pn = sc.pos.posName()

  if pn == "added":
    if sc.pos.currentActiveKey.isSome:
      sc.pos.atEnd = false
    else:
      sc.pos.atEnd = true
    return

  let asOfTx = sc.asOfTx
  let isTPos = pn == "t"

  if sc.historyMode and isTPos:
    # history_each
    while sc.pos.cursor.isValidCb():
      let key = sc.pos.cursor.currentKeyCb()
      if key.isNone or key.get.len < 8:
        sc.pos.cursor.stepCb()
        continue
      let k = key.get
      case classifyKey(sc, k):
      of kvpNoPrefix, kvpMatch: discard
      of kvpBefore, kvpAfter:
        sc.pos.atEnd = true
        return
      let suffix = extractSuffix(k)
      let (t, _) = keys.decodeSuffix(suffix)
      if asOfTx.isSome and t.int64 > asOfTx.get:
        sc.pos.cursor.stepCb()
        continue
      sc.pos.currentActiveKey = some(k)
      sc.pos.atEnd = false
      return
    sc.pos.currentActiveKey = none[seq[byte]]()
    sc.pos.atEnd = true
    return

  # normal advance
  while sc.pos.cursor.isValidCb():
    let key = sc.pos.cursor.currentKeyCb()
    if key.isNone or key.get.len < 8:
      sc.pos.cursor.stepCb()
      continue
    let firstKey = key.get
    case classifyKey(sc, firstKey):
    of kvpNoPrefix, kvpMatch: discard
    of kvpBefore:
      sc.pos.cursor.seekCb(sc.prefixCache)
      continue
    of kvpAfter:
      sc.pos.currentActiveKey = none[seq[byte]]()
      sc.pos.atEnd = true
      return

    var foundKey: Option[seq[byte]] = none[seq[byte]]()
    let groupEnd = firstKey.len - 8
    var curGroup = firstKey[0..<groupEnd]

    while sc.pos.cursor.isValidCb():
      let key = sc.pos.cursor.currentKeyCb()
      if key.isNone or key.get.len < 8:
        sc.pos.cursor.stepCb()
        continue
      let k = key.get
      let ge = k.len - 8
      if k[0..<ge] != curGroup:
        if foundKey.isSome: break
        curGroup = k[0..<ge]

      let suffix = extractSuffix(k)
      let (t, retracted) = keys.decodeSuffix(suffix)

      if asOfTx.isSome and t.int64 > asOfTx.get:
        sc.pos.cursor.stepCb()
        continue

      if sc.historyMode or not retracted:
        foundKey = some(k)

      if foundKey.isSome: break
      sc.pos.cursor.skipGroupCb(ge)

    if foundKey.isSome:
      sc.pos.currentActiveKey = foundKey
      sc.pos.atEnd = false
      return

  sc.pos.currentActiveKey = none[seq[byte]]()
  sc.pos.atEnd = true

# ── seek_past_value_at ──

proc seekPastValueAt(sc: V2Scanner) =
  let pn = sc.pos.posName()
  let key = sc.pos.currentActiveKey
  if key.isNone:
    sc.pos.cursor.invalidateCb()
    return
  let k = key.get
  let vs = sc.valueStart(k)
  var target = k[0..<vs]

  if pn == "t":
    let suffix = extractSuffix(k)
    if suffix == 0:
      sc.pos.cursor.invalidateCb()
    else:
      let next = cast[array[8, byte]](suffix + 1)
      for i in 0..7: target.add next[i]
      sc.pos.cursor.seekCb(target)
    return

  # extract the raw value to compute next
  let ve = sc.valueEnd(k)
  let raw = k[vs..<ve]

  if pn == "a":
    let cur = beUint32(k, vs)
    if cur == uint32.high:
      sc.pos.cursor.invalidateCb()
    else:
      let next = cast[array[4, byte]](cur + 1)
      for i in 0..3: target.add next[i]
      sc.pos.cursor.seekCb(target)
  elif isVariableValue(sc.valueAttrType, k.len):
    # bytes: increment last byte
    var inc = raw
    var carry = true
    var i = inc.len - 1
    while carry and i >= 0:
      if inc[i] < 0xFF'u8:
        inc[i] = inc[i] + 1
        carry = false
      else:
        inc[i] = 0
        dec i
    if carry:
      sc.pos.cursor.invalidateCb()
    else:
      target.add inc
      sc.pos.cursor.seekCb(target)
  else:
    let cur = beUint64(k, vs)
    if cur == uint64.high:
      sc.pos.cursor.invalidateCb()
    else:
      let next = cast[array[8, byte]](cur + 1)
      for i in 0..7: target.add next[i]
      sc.pos.cursor.seekCb(target)

# ── leap_next_at ──

proc leapNextAt*(sc: V2Scanner) =
  let pn = sc.pos.posName()
  if pn == "added":
    sc.pos.atEnd = true
    return
  let key = sc.pos.currentActiveKey
  if key.isSome:
    sc.seekPastValueAt()
  sc.advanceToActiveAt()

# ── seek_to_value ──

proc seekToValue*(sc: V2Scanner; value: SExpr) =
  let pn = sc.pos.posName()
  let key = sc.pos.currentActiveKey
  if key.isNone:
    sc.pos.cursor.invalidateCb()
    return
  let k = key.get
  let vs = sc.valueStart(k)
  var target = k[0..<vs]

  case pn:
  of "e":
    target.add keys.encodeEid(value.ival)
  of "a":
    let v32 = uint32(value.ival)
    target.add byte(v32 shr 24); target.add byte((v32 shr 16) and 0xFF)
    target.add byte((v32 shr 8) and 0xFF); target.add byte(v32 and 0xFF)
  of "v":
    if isUnorderedAttr(sc.valueAttrType):
      target.add keys.encodeVariableUnordered(value.bytesval)
    elif value.kind == sStr:
      target.add keys.encodeVariable(value.sval)
    elif value.kind == sBytes:
      target.add keys.encodeVariableUnordered(value.bytesval)
    else:
      target.add keys.encodeFixed(value)
  else: discard

  for _ in 0..7: target.add 0'u8
  sc.pos.cursor.seekCb(target)
  sc.advanceToActiveAt()

# ── attr_id helpers ──

proc attrIdFromPrefixBytes*(sc: V2Scanner): Option[uint32] =
  let off = case sc.indexName:
    of "EAVT", "VAET": 8
    of "AEVT", "AVET": 0
    else: return none[uint32]()
  if sc.prefixCache.len >= off + 4:
    some(beUint32(sc.prefixCache, off))
  else:
    none[uint32]()

proc attrIdFromKey*(sc: V2Scanner): Option[uint32] =
  let key = sc.pos.currentActiveKey
  if key.isNone: return none[uint32]()
  let k = key.get
  let off = case sc.indexName:
    of "EAVT", "VAET": 8
    of "AEVT", "AVET": 0
    else: 8
  if k.len >= off + 4:
    some(beUint32(k, off))
  else:
    none[uint32]()
