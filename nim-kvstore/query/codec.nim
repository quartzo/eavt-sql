## query/codec.nim — query value wire codec.
##
## Compatible with spier-value/src/query_codec.rs (Rust) and
## src/eavt_sql/query_codec.py (Python). Big-endian throughout.
##
## Value tags:
##   1 = Text   [u32 len][utf-8]
##   2 = Int64  [8B]
##   3 = Float64[8B]
##   4 = Bool   [1B]
##   5 = Bytes  [u32 len][data]
##   6 = Timestamp (micros) [8B]
##   99 = Unknown [u8 tag][u64 payload]  (decode → error, like Rust)

import std/[options, math]
import ../scheme

const
  TagText* = 1'u8
  TagInt64* = 2'u8
  TagFloat64* = 3'u8
  TagBool* = 4'u8
  TagBytes* = 5'u8
  TagTimestamp* = 6'u8
  TagUnknown* = 99'u8

type CodecError* = object of CatchableError

# ── little helpers ──

proc getU32(buf: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > buf.len: raise newException(CodecError, "truncated u32")
  result = uint32(buf[pos]) shl 24 or uint32(buf[pos+1]) shl 16 or
           uint32(buf[pos+2]) shl 8 or uint32(buf[pos+3])
  pos += 4

proc getU64(buf: openArray[byte]; pos: var int): uint64 =
  if pos + 8 > buf.len: raise newException(CodecError, "truncated u64")
  for i in 0..7: result = (result shl 8) or uint64(buf[pos+i])
  pos += 8

proc putU32(outBuf: var seq[byte]; v: uint32) =
  outBuf.add byte(v shr 24); outBuf.add byte((v shr 16) and 0xFF)
  outBuf.add byte((v shr 8) and 0xFF); outBuf.add byte(v and 0xFF)

proc putU64(outBuf: var seq[byte]; v: uint64) =
  for i in countdown(7, 0): outBuf.add byte(v shr (i * 8))

# ── decode ──

proc decodeOne*(buf: openArray[byte]; pos: var int): SExpr =
  if pos >= buf.len: raise newException(CodecError, "truncated tag")
  let tag = buf[pos]; inc pos
  case tag:
  of TagText:
    let n = getU32(buf, pos).int
    if pos + n > buf.len: raise newException(CodecError, "truncated text")
    var s = newString(n)
    if n > 0: copyMem(addr s[0], unsafeAddr buf[pos], n)
    pos += n
    SExpr(kind: sStr, sval: s)
  of TagInt64:
    SExpr(kind: sInt, ival: cast[int64](getU64(buf, pos)))
  of TagFloat64:
    SExpr(kind: sFloat, fval: cast[float64](getU64(buf, pos)))
  of TagBool:
    if pos >= buf.len: raise newException(CodecError, "truncated bool")
    let b = buf[pos] != 0; inc pos
    SExpr(kind: sBool, bval: b)
  of TagBytes:
    let n = getU32(buf, pos).int
    if pos + n > buf.len: raise newException(CodecError, "truncated bytes")
    var b = newSeq[byte](n)
    if n > 0: copyMem(addr b[0], unsafeAddr buf[pos], n)
    pos += n
    SExpr(kind: sBytes, bytesval: b)
  of TagTimestamp:
    # Rust value_to_sexpr: Timestamp(ts) → SExpr::Int(ts)
    SExpr(kind: sInt, ival: cast[int64](getU64(buf, pos)))
  of TagUnknown:
    raise newException(CodecError, "unknown(tag) cannot convert to concrete value")
  else:
    raise newException(CodecError, "unknown tag " & $tag)

proc decodeParams*(buf: openArray[byte]): seq[SExpr] =
  ## decode_values: [u32 count][tagged values]...
  if buf.len < 4: raise newException(CodecError, "decode_values: buffer too short")
  var pos = 0
  let n = getU32(buf, pos)
  result = newSeqOfCap[SExpr](n)
  for _ in 0..<n:
    result.add decodeOne(buf, pos)

# ── encode ──

proc encodeOne*(outBuf: var seq[byte]; v: SExpr) =
  ## sexpr_to_value mapping (Rust scheme.rs):
  ##   Int→Int64, Float→Float64, Str→Text, Bool→Bool, Bytes→Bytes,
  ##   Void→Timestamp(0); anything else is an error.
  case v.kind:
  of sInt:
    outBuf.add TagInt64
    putU64(outBuf, cast[uint64](v.ival))
  of sFloat:
    outBuf.add TagFloat64
    putU64(outBuf, cast[uint64](v.fval))
  of sStr:
    outBuf.add TagText
    putU32(outBuf, v.sval.len.uint32)
    for c in v.sval: outBuf.add byte(c)
  of sBool:
    outBuf.add TagBool
    outBuf.add (if v.bval: 1'u8 else: 0'u8)
  of sBytes:
    outBuf.add TagBytes
    putU32(outBuf, v.bytesval.len.uint32)
    outBuf.add v.bytesval
  of sVoid:
    outBuf.add TagTimestamp
    putU64(outBuf, 0)
  else:
    raise newException(CodecError, "cannot convert " & $v.kind & " to storage value")

proc encodeRow*(outBuf: var seq[byte]; cols: openArray[SExpr]) =
  ## Streaming row format: [u32 num_cols][tagged values]...
  putU32(outBuf, cols.len.uint32)
  for c in cols: encodeOne(outBuf, c)
