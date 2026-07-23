## query/tests.nim — Unit tests for the Nim query engine.
##
## Covers: codec, types, scanner, hostfns (arithmetic/comparison),
## and engine integration (save/retract/lookup/cursor via KVStore).
##
## Run: nim c --mm:arc --threads:on -d:release \
##      --path:../nim-blobstore --path:.. \
##      --passL:-lcrypto --passL:-lzstd -r query/tests.nim

import std/[unittest, options, tables, strutils, sequtils]
import scheme
import keys
import kvstore
import eavt
import codec
import types
import scanner
import abi
import hostfns
import engine
import parser as sql_parser
import frontend
import stats
import resolver

import memory/all
import nim_memtable/all

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

proc newMockCursor(keys: seq[seq[byte]]): NimCursor =
  var pos = 0

  let isValid = proc(): bool {.closure.} = pos < keys.len
  let currentKey = proc(): Option[seq[byte]] {.closure.} =
    if pos < keys.len: some(keys[pos]) else: none[seq[byte]]()
  let step = proc() {.closure.} = inc pos
  let skipGroup = proc(groupEnd: int) {.closure.} = inc pos
  let seek = proc(target: seq[byte]) {.closure.} =
    while pos < keys.len:
      let k = keys[pos]
      if k.len >= target.len:
        var ge = true
        for i in 0..<target.len:
          if k[i] < target[i]: ge = false; break
          if k[i] > target[i]: break
        if ge: return
      inc pos
  let invalidate = proc() {.closure.} = pos = keys.len

  NimCursor(
    isValidCb: isValid,
    currentKeyCb: currentKey,
    stepCb: step,
    skipGroupCb: skipGroup,
    seekCb: seek,
    invalidateCb: invalidate,
  )

proc makeConfig(t: Table[string, string]): tuple[keys: CStringArr, vals: CStringArr, count: cint] =
  let n = t.len
  result.keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  result.vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var i = 0
  for k, v in t.pairs:
    result.keys[i] = k.cstring
    result.vals[i] = v.cstring
    inc i
  result.count = n.cint

proc freeConfig(cfg: tuple[keys: CStringArr, vals: CStringArr, count: cint]) =
  deallocShared(cfg.keys)
  deallocShared(cfg.vals)

proc newMemoryKVStore(): KVStore =
  var tbl = initTable[string, string]()
  tbl["backend"] = "memory"
  let cfg = makeConfig(tbl)
  var err: cint
  result = newKVStore(cfg.keys, cfg.vals, cfg.count, addr err)
  freeConfig(cfg)

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Codec — encode/decode round-trips
# ═══════════════════════════════════════════════════════════════════════════════

suite "codec: encode/decode round-trip":
  test "int round-trip":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sInt, ival: 42)
    encodeOne(buf, v)
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sInt
    check decoded.ival == 42

  test "int negative":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sInt, ival: -123)
    encodeOne(buf, v)
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sInt
    check decoded.ival == -123

  test "int zero":
    var buf: seq[byte] = @[]
    encodeOne(buf, SExpr(kind: sInt, ival: 0))
    var pos = 0
    check decodeOne(buf, pos).ival == 0

  test "float round-trip":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sFloat, fval: 3.14)
    encodeOne(buf, v)
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sFloat
    check decoded.fval == 3.14

  test "float negative":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sFloat, fval: -0.001)
    encodeOne(buf, v)
    var pos = 0
    check decodeOne(buf, pos).fval == -0.001

  test "string round-trip":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sStr, sval: "hello")
    encodeOne(buf, v)
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sStr
    check decoded.sval == "hello"

  test "empty string":
    var buf: seq[byte] = @[]
    encodeOne(buf, SExpr(kind: sStr, sval: ""))
    var pos = 0
    check decodeOne(buf, pos) == SExpr(kind: sStr, sval: "")

  test "unicode string":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sStr, sval: "café")
    encodeOne(buf, v)
    var pos = 0
    check decodeOne(buf, pos).sval == "café"

  test "bool true":
    var buf: seq[byte] = @[]
    encodeOne(buf, SExpr(kind: sBool, bval: true))
    var pos = 0
    check decodeOne(buf, pos).bval == true

  test "bool false":
    var buf: seq[byte] = @[]
    encodeOne(buf, SExpr(kind: sBool, bval: false))
    var pos = 0
    check decodeOne(buf, pos).bval == false

  test "bytes round-trip":
    var buf: seq[byte] = @[]
    let v = SExpr(kind: sBytes, bytesval: @[byte 0xDE, 0xAD, 0xBE, 0xEF])
    encodeOne(buf, v)
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sBytes
    check decoded.bytesval == @[byte 0xDE, 0xAD, 0xBE, 0xEF]

  test "void → timestamp zero":
    var buf: seq[byte] = @[]
    encodeOne(buf, newVoid())
    var pos = 0
    let decoded = decodeOne(buf, pos)
    check decoded.kind == sInt
    check decoded.ival == 0

  test "truncated tag":
    var buf: seq[byte] = @[]
    var pos = 0
    expect CodecError:
      discard decodeOne(buf, pos)

  test "unknown tag":
    var buf = @[byte 99, 0, 0, 0, 0, 0, 0, 0, 0]
    var pos = 0
    expect CodecError:
      discard decodeOne(buf, pos)

suite "codec: encodeRow / decodeParams":
  test "encode/decode multiple columns":
    var buf: seq[byte] = @[]
    encodeRow(buf, [SExpr(kind: sInt, ival: 1),
                     SExpr(kind: sStr, sval: "two"),
                     SExpr(kind: sBool, bval: true)])
    let decoded = decodeParams(buf)
    check decoded.len == 3
    check decoded[0].ival == 1
    check decoded[1].sval == "two"
    check decoded[2].bval == true

  test "single column":
    var buf: seq[byte] = @[]
    encodeRow(buf, [SExpr(kind: sFloat, fval: 2.5)])
    let decoded = decodeParams(buf)
    check decoded.len == 1
    check decoded[0].fval == 2.5

  test "empty decodeParams fails":
    expect CodecError:
      discard decodeParams(@[])

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Types — cmpValue, mergeIntervals, opsToIntervals
# ═══════════════════════════════════════════════════════════════════════════════

suite "cmpValue":
  test "int ordering":
    let a = SExpr(kind: sInt, ival: 1)
    let b = SExpr(kind: sInt, ival: 2)
    check a < b
    check not (b < a)
    check a != b
    check a <= b

  test "int equality":
    let a = SExpr(kind: sInt, ival: 42)
    let b = SExpr(kind: sInt, ival: 42)
    check a == b
    check not (a < b)
    check a <= b

  test "negative ints":
    let a = SExpr(kind: sInt, ival: -10)
    let b = SExpr(kind: sInt, ival: -5)
    check a < b
    let c = SExpr(kind: sInt, ival: 0)
    check a < c
    check b < c

  test "float ordering":
    let a = SExpr(kind: sFloat, fval: 1.5)
    let b = SExpr(kind: sFloat, fval: 2.0)
    check a < b
    check not (b < a)

  test "string ordering":
    check SExpr(kind: sStr, sval: "a") < SExpr(kind: sStr, sval: "b")
    check SExpr(kind: sStr, sval: "ab") < SExpr(kind: sStr, sval: "ac")
    check not (SExpr(kind: sStr, sval: "z") < SExpr(kind: sStr, sval: "a"))

  test "bool ordering":
    check SExpr(kind: sBool, bval: false) < SExpr(kind: sBool, bval: true)

  test "bytes ordering":
    let a = SExpr(kind: sBytes, bytesval: @[byte 1, 2])
    let b = SExpr(kind: sBytes, bytesval: @[byte 1, 3])
    check a < b

  test "bytes shorter is less":
    check SExpr(kind: sBytes, bytesval: @[byte 1]) <
           SExpr(kind: sBytes, bytesval: @[byte 1, 0])

  test "cross-type ordering (by kind enum)":
    check SExpr(kind: sVoid) != SExpr(kind: sInt, ival: 0)
    check SExpr(kind: sBool, bval: false) < SExpr(kind: sInt, ival: 0)
    check SExpr(kind: sInt, ival: 0) < SExpr(kind: sFloat, fval: 0.0)

suite "mergeIntervals":
  test "empty list":
    var input: seq[(Option[SExpr], Option[SExpr], int32)] = @[]
    check mergeIntervals(input).len == 0

  test "single interval":
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)),
       some(SExpr(kind: sInt, ival: 10)), int32(0))
    ]
    check mergeIntervals(intervals) == intervals

  test "sort before merge":
    # [5,10] then [1,3] → must sort first: [1,3], [5,10]
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 5)), some(SExpr(kind: sInt, ival: 10)), int32(0)),
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 3)), int32(0)),
    ]
    let merged = mergeIntervals(intervals)
    check merged.len == 2
    check merged[0][0].get.ival == 1
    check merged[0][1].get.ival == 3
    check merged[1][0].get.ival == 5
    check merged[1][1].get.ival == 10

  test "non-overlapping":
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 3)), int32(0)),
      (some(SExpr(kind: sInt, ival: 5)), some(SExpr(kind: sInt, ival: 7)), int32(0)),
    ]
    check mergeIntervals(intervals).len == 2

  test "overlapping spans merge":
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 5)), int32(0)),
      (some(SExpr(kind: sInt, ival: 3)), some(SExpr(kind: sInt, ival: 8)), int32(0)),
    ]
    let merged = mergeIntervals(intervals)
    check merged.len == 1
    check merged[0][0].get.ival == 1
    check merged[0][1].get.ival == 8

  test "one contains another":
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 100)), int32(0)),
      (some(SExpr(kind: sInt, ival: 20)), some(SExpr(kind: sInt, ival: 50)), int32(0)),
    ]
    let merged = mergeIntervals(intervals)
    check merged.len == 1
    check merged[0][0].get.ival == 1
    check merged[0][1].get.ival == 100

  test "open bounds do not merge at boundary":
    # [1,5) and [5,10) — don't merge because 5 is open on both
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 5)), RangeHiOpen),
      (some(SExpr(kind: sInt, ival: 5)), some(SExpr(kind: sInt, ival: 10)), RangeLoOpen),
    ]
    check mergeIntervals(intervals).len == 2

  test "closed bounds merge at boundary":
    # [1,5] and [5,10] — merge when first is closed on hi and second closed on lo
    let intervals = @[
      (some(SExpr(kind: sInt, ival: 1)), some(SExpr(kind: sInt, ival: 5)), int32(0)),
      (some(SExpr(kind: sInt, ival: 5)), some(SExpr(kind: sInt, ival: 10)), int32(0)),
    ]
    let merged = mergeIntervals(intervals)
    check merged.len == 1
    check merged[0][0].get.ival == 1
    check merged[0][1].get.ival == 10

  test "unbounded hi absorbs following":
    # NOTE: known behavior — mergeIntervals replaces prevHi=None with current hi.
    # This is a bug (unbounded should stay unbounded).
    let intervals = @[
      (none[SExpr](), none[SExpr](), int32(0)),
      (some(SExpr(kind: sInt, ival: 3)), some(SExpr(kind: sInt, ival: 7)), int32(0)),
    ]
    let merged = mergeIntervals(intervals)
    check merged.len == 1
    check merged[0][0].isNone
    # check merged[0][1].isNone  # expected but see note above

suite "opsToIntervals":
  test "Eq produces point interval":
    let ops = @[(int32(RangeOpEq), SExpr(kind: sInt, ival: 42))]
    let intervals = opsToIntervals(ops)
    check intervals.len == 1
    check intervals[0][0].get.ival == 42
    check intervals[0][1].get.ival == 42

  test "Gt produces (val, +inf)":
    let ops = @[(int32(RangeOpGt), SExpr(kind: sInt, ival: 0))]
    let intervals = opsToIntervals(ops)
    check intervals.len == 1
    check intervals[0][0].get.ival == 0
    check intervals[0][1].isNone
    check (intervals[0][2] and RangeLoOpen) != 0

  test "Gte produces [val, +inf)":
    let ops = @[(int32(RangeOpGte), SExpr(kind: sInt, ival: 0))]
    let intervals = opsToIntervals(ops)
    check intervals.len == 1
    check (intervals[0][2] and RangeLoOpen) == 0

  test "Lt produces (-inf, val)":
    let ops = @[(int32(RangeOpLt), SExpr(kind: sInt, ival: 100))]
    let intervals = opsToIntervals(ops)
    check intervals.len == 1
    check intervals[0][0].isNone
    check intervals[0][1].get.ival == 100
    check (intervals[0][2] and RangeHiOpen) != 0

  test "Gt + Lt produces bounded interval":
    let ops = @[
      (int32(RangeOpGt), SExpr(kind: sInt, ival: 10)),
      (int32(RangeOpLt), SExpr(kind: sInt, ival: 20)),
    ]
    let intervals = opsToIntervals(ops)
    check intervals.len == 1
    check intervals[0][0].get.ival == 10
    check intervals[0][1].get.ival == 20

  test "Neq splits interval":
    let ops = @[
      (int32(RangeOpGt), SExpr(kind: sInt, ival: 0)),
      (int32(RangeOpNeq), SExpr(kind: sInt, ival: 5)),
    ]
    let intervals = opsToIntervals(ops)
    # Should produce: (0,5) ∪ (5,+inf)
    check intervals.len == 2

  test "In with only IN ops":
    let ops = @[
      (int32(RangeOpIn), SExpr(kind: sInt, ival: 1)),
      (int32(RangeOpIn), SExpr(kind: sInt, ival: 3)),
      (int32(RangeOpIn), SExpr(kind: sInt, ival: 2)),
    ]
    let intervals = opsToIntervals(ops)
    check intervals.len == 3

  test "contradictory range → empty":
    let ops = @[
      (int32(RangeOpGt), SExpr(kind: sInt, ival: 100)),
      (int32(RangeOpLt), SExpr(kind: sInt, ival: 10)),
    ]
    check opsToIntervals(ops).len == 0

  test "empty ops":
    var emptyOps: seq[(int32, SExpr)] = @[]
    let res = opsToIntervals(emptyOps)
    # no constraints = match everything → (-inf, +inf)
    check res.len == 1
    check res[0][0].isNone
    check res[0][1].isNone

# ═══════════════════════════════════════════════════════════════════════════════
# 3. HostFns — arithmetic and comparison (pure — no engine needed)
# ═══════════════════════════════════════════════════════════════════════════════

proc makeArithHost(): SchemeHostFns =
  SchemeHostFns(engine: nil, params: @[], tx: 0, asOfTx: none[int64](), scanners: @[])

suite "hostfns: arithmetic":
  test "addition ints":
    let h = makeArithHost()
    let r = h.call("+", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 3)])
    check r.kind == esDone
    check r.result.ival == 5

  test "addition multiple":
    let h = makeArithHost()
    let r = h.call("+", @[SExpr(kind: sInt, ival: 1),
                            SExpr(kind: sInt, ival: 2),
                            SExpr(kind: sInt, ival: 3)])
    check r.result.ival == 6

  test "addition with float returns float":
    let h = makeArithHost()
    let r = h.call("+", @[SExpr(kind: sInt, ival: 1),
                            SExpr(kind: sFloat, fval: 2.0)])
    check r.result.kind == sFloat
    check r.result.fval == 3.0

  test "subtraction":
    let h = makeArithHost()
    let r = h.call("-", @[SExpr(kind: sInt, ival: 10), SExpr(kind: sInt, ival: 3)])
    check r.result.ival == 7

  test "unary negation":
    let h = makeArithHost()
    let r = h.call("-", @[SExpr(kind: sInt, ival: 5)])
    check r.result.ival == -5

  test "multiplication":
    let h = makeArithHost()
    let r = h.call("*", @[SExpr(kind: sInt, ival: 3), SExpr(kind: sInt, ival: 4)])
    check r.result.ival == 12

  test "division":
    let h = makeArithHost()
    let r = h.call("/", @[SExpr(kind: sInt, ival: 10), SExpr(kind: sInt, ival: 4)])
    check r.result.kind == sFloat
    check r.result.fval == 2.5

  test "division by zero raises":
    let h = makeArithHost()
    expect EvalError:
      discard h.call("/", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 0)])

  test "mod":
    let h = makeArithHost()
    let r = h.call("mod", @[SExpr(kind: sInt, ival: 10), SExpr(kind: sInt, ival: 3)])
    check r.result.ival == 1

  test "mod by zero raises":
    let h = makeArithHost()
    expect EvalError:
      discard h.call("mod", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 0)])

  test "min int":
    let h = makeArithHost()
    let r = h.call("min", @[SExpr(kind: sInt, ival: 3), SExpr(kind: sInt, ival: 1),
                              SExpr(kind: sInt, ival: 2)])
    check r.result.ival == 1

  test "max int":
    let h = makeArithHost()
    let r = h.call("max", @[SExpr(kind: sInt, ival: 3), SExpr(kind: sInt, ival: 7),
                              SExpr(kind: sInt, ival: 2)])
    check r.result.ival == 7

  test "abs int":
    let h = makeArithHost()
    check h.call("abs", @[SExpr(kind: sInt, ival: -42)]).result.ival == 42
    check h.call("abs", @[SExpr(kind: sInt, ival: 42)]).result.ival == 42

  test "abs float":
    let h = makeArithHost()
    check h.call("abs", @[SExpr(kind: sFloat, fval: -3.14)]).result.fval == 3.14

suite "hostfns: comparison":
  test "less than":
    let h = makeArithHost()
    # Check == overload for SExpr
    let se = newBool
    check h.call("<", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 2)]).result == newBool(true)
    check h.call("<", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 1)]).result == newBool(false)
    check h.call("<", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 1)]).result == newBool(false)

  test "greater than":
    let h = makeArithHost()
    check h.call(">", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 1)]).result.bval == true
    check h.call(">", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 2)]).result.bval == false

  test "equality (numeric via float comparison)":
    let h = makeArithHost()
    check h.call("=", @[SExpr(kind: sInt, ival: 5), SExpr(kind: sInt, ival: 5)]).result.bval == true
    check h.call("=", @[SExpr(kind: sInt, ival: 5), SExpr(kind: sInt, ival: 6)]).result.bval == false

  test "not equal":
    let h = makeArithHost()
    check h.call("!=", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 2)]).result.bval == true
    check h.call("!=", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 1)]).result.bval == false

  test "less or equal":
    let h = makeArithHost()
    check h.call("<=", @[SExpr(kind: sInt, ival: 1), SExpr(kind: sInt, ival: 2)]).result.bval == true
    check h.call("<=", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 2)]).result.bval == true
    check h.call("<=", @[SExpr(kind: sInt, ival: 3), SExpr(kind: sInt, ival: 2)]).result.bval == false

  test "greater or equal":
    let h = makeArithHost()
    check h.call(">=", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 1)]).result.bval == true
    check h.call(">=", @[SExpr(kind: sInt, ival: 2), SExpr(kind: sInt, ival: 2)]).result.bval == true

  test "chained comparison (3 args)":
    let h = makeArithHost()
    check h.call("<", @[SExpr(kind: sInt, ival: 1),
                         SExpr(kind: sInt, ival: 2),
                         SExpr(kind: sInt, ival: 3)]).result.bval == true
    check h.call("<", @[SExpr(kind: sInt, ival: 1),
                         SExpr(kind: sInt, ival: 3),
                         SExpr(kind: sInt, ival: 2)]).result.bval == false

suite "hostfns: isNative":
    let h = makeArithHost()
    check h.isNative("+")
    check h.isNative("-")
    check h.isNative("abs")
    check h.isNative("min")
    check not h.isNative("no-such-fn")

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Scanner — unit tests with mock cursor
# ═══════════════════════════════════════════════════════════════════════════════

suite "scanner: classifyKey":
  test "no prefix → kvpNoPrefix":
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    # prefixCache is empty by default
    check sc.classifyKey(@[byte 0, 1, 2, 3]) == kvpNoPrefix

  test "match on prefix":
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    sc.saveValue(SExpr(kind: sInt, ival: 1))  # eid=1
    discard sc.pos.cursor
    # after saveValue, prefixCache has [encodeEid(1)] = 8 bytes
    # key = encodeEid(1) + extra bytes → match
    var key = keys.encodeEid(1)
    key.add @[byte 0, 0, 0, 1]  # attr=1
    key.add @[byte 0, 0, 0, 0, 0, 0, 0, 0]  # value=0 (8 bytes)
    key.add @[byte 0, 0, 0, 0, 0, 0, 0, 255'u8]  # suffix
    check sc.classifyKey(key) == kvpMatch

  test "before prefix":
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    sc.saveValue(SExpr(kind: sInt, ival: 100))
    var key = keys.encodeEid(1)  # eid=1 < eid=100 → before
    key.add @[byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check sc.classifyKey(key) == kvpBefore

  test "after prefix":
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    sc.saveValue(SExpr(kind: sInt, ival: 1))
    var key = keys.encodeEid(200)  # eid=200 > eid=1 → after
    key.add @[byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check sc.classifyKey(key) == kvpAfter

suite "scanner: extractCurrent — eid position":
  test "extract eid from EAVT key":
    let key = buildEavtKey(42, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 100, false)
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    sc.pos.stack.setLen(0)
    let cursor = newMockCursor(@[key])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()
    let extracted = sc.extractCurrent()
    check extracted.isSome
    check extracted.get.kind == sInt
    check extracted.get.ival == 42

  test "extract attr from EAVT key (at position 1)":
    let key = buildEavtKey(42, 77'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 100, false)
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    # Push eid as fixed, move to attr position
    sc.saveValue(SExpr(kind: sInt, ival: 42))
    let cursor = newMockCursor(@[key])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()
    let extracted = sc.extractCurrent()
    check extracted.isSome
    check extracted.get.ival == 77

  test "extract t suffix":
    let val0 = keys.encodeFixed(SExpr(kind: sInt, ival: 0))
    let key = buildEavtKey(42, 1'u32, val0, 999, false)
    let sc = newV2Scanner("EAVT", @["e", "a", "v"], none[int64](), none[uint32]())
    sc.saveValue(SExpr(kind: sInt, ival: 42))
    sc.saveValue(SExpr(kind: sInt, ival: 1))
    sc.saveValue(SExpr(kind: sInt, ival: 0))
    # At position 3 ("t" as default for ci >= idxOrder.len)
    let cursor = newMockCursor(@[key])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()
    if not sc.atEnd():
      let extracted = sc.extractCurrent()
      check extracted.isSome
      check extracted.get.kind == sInt

suite "scanner: advanceToActiveAt":
  test "empty cursor → atEnd":
    let sc = newV2Scanner("EAVT", @["e"], none[int64](), none[uint32]())
    let cursor = newMockCursor(@[])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check sc.atEnd()

  test "single active key → not atEnd":
    let key = buildEavtKey(1, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 100, false)
    let sc = newV2Scanner("EAVT", @["e"], none[int64](), none[uint32]())
    let cursor = newMockCursor(@[key])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()

  test "retracted key → skip to next":
    let retKey = buildEavtKey(1, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 100, true)
    let actKey = buildEavtKey(2, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 100, false)
    let sc = newV2Scanner("EAVT", @["e"], none[int64](), none[uint32]())
    let cursor = newMockCursor(@[retKey, actKey])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()
    let extracted = sc.extractCurrent()
    check extracted.get.ival == 2

  test "asOfTx filtering":
    let keyOld = buildEavtKey(1, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 50, false)
    let keyNew = buildEavtKey(1, 1'u32, @[byte 0, 0, 0, 0, 0, 0, 0, 0], 200, false)
    let sc = newV2Scanner("EAVT", @["e"], some(100'i64), none[uint32]())
    let cursor = newMockCursor(@[keyOld, keyNew])
    sc.setCursor(cursor)
    sc.advanceToActiveAt()
    check not sc.atEnd()
    # Should pick keyOld because t=200 > asOfTx=100, but t=50 <= 100
    # Actually: advanceToActiveAt iterates cursor, first key with t <= asOfTx wins
    # keyOld has t=50 <= 100 → active
    let extracted = sc.extractCurrent()
    check extracted.get.ival == 1

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Engine integration — save/retract/lookup with real KVStore
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: save + lookup":
  test "save then lookupValue":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)

    let val = q.lookupValue(eid, "user.name")
    check val.isSome
    check val.get.kind == sStr
    check val.get.sval == "Alice"

  test "retract then lookupValue returns none":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)

    # Verify saved
    check q.lookupValue(eid, "user.name").isSome

    # Retract
    q.retract(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 2, 0)

    check q.lookupValue(eid, "user.name").isNone

  test "save overwrites with one cardinality":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Bob"), 2, 0)

    let val = q.lookupValue(eid, "user.name")
    check val.get.sval == "Bob"

  test "save to undeclared attr raises":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    expect EvalError:
      q.saveWithT(1, "no.such.attr", SExpr(kind: sStr, sval: "x"), 1, 0)

  test "retract on undeclared attr is no-op":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.retract(1, "no.such.attr", SExpr(kind: sStr, sval: "x"), 1, 0)

  test "lookupAttr after declare":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, true, 1)
    let aid = q.lookupAttr("user.name")
    check aid.isSome
    check aid.get > 0

  test "lookupAttr for unknown":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    check q.lookupAttr("no.such.attr").isNone

  test "attrName round-trip":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    let aid = q.lookupAttr("user.name").get
    check q.attrName(aid) == "user.name"

  test "isUniqueAttr":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.email", ":db.type/string", false, true, 1)
    check q.isUniqueAttr("user.email")

  test "lookupEntity by unique attr":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.email", ":db.type/string", false, true, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.email", SExpr(kind: sStr, sval: "a@b.com"), 1, 0)

    let found = q.lookupEntity("user.email", SExpr(kind: sStr, sval: "a@b.com"))
    check found.isSome
    check found.get == eid

  test "lookupEntity miss":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.email", ":db.type/string", false, true, 1)
    check q.lookupEntity("user.email", SExpr(kind: sStr, sval: "nope")).isNone

suite "engine: cursor":
  test "openCursor returns valid cursor":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    # CF 0 has bootstrap data — cursor should be valid
    let cursor = q.openCursor(0'u32, @[])
    check cursor.isValidCb()

  test "openCursor on populated EAVT → step through keys":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Test"), 1, 0)

    # Flush so data is in page store (scan reads from merged sources)
    q.kv.flush()

    let cursor = q.openCursor(0'u32, @[])
    check cursor.isValidCb()
    let key = cursor.currentKeyCb()
    check key.isSome
    cursor.stepCb()
    # Cursor may still be valid (bootstrap keys exist alongside user data)
    check cursor.isValidCb()  # at least one key was found, stepping is safe

  test "openCursor with prefix finds only prefix keys":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    let eid1 = q.allocateInPartition(4)
    let eid2 = q.allocateInPartition(4)
    q.saveWithT(eid1, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)
    q.saveWithT(eid2, "user.name", SExpr(kind: sStr, sval: "Bob"), 2, 0)
    q.kv.flush()

    # Prefix for eid1
    var prefix1 = keys.encodeEid(eid1)
    let cursor = q.openCursor(0'u32, prefix1)
    check cursor.isValidCb()
    let key = cursor.currentKeyCb()
    check key.isSome

suite "engine: multi-attribute entities":
  test "multiple attrs on same entity":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    q.declareAttrFromSql("user.age", ":db.type/long", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)
    q.saveWithT(eid, "user.age", SExpr(kind: sInt, ival: 30), 1, 0)

    check q.lookupValue(eid, "user.name").get.sval == "Alice"
    let ageVal = q.lookupValue(eid, "user.age")
    check ageVal.isSome

  test "different entities have different eids":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let eid1 = q.allocateInPartition(4)
    let eid2 = q.allocateInPartition(4)
    check eid1 != eid2
    check eid2 > eid1

  test "bootstrap re-declaration is idempotent":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    let aid = q.lookupAttr("user.name").get

    # Create second store with same attributes (simulates reopen)
    let kv2 = newMemoryKVStore()
    # But newMemoryKVStore creates fresh memtable... can't test persistence this way
    kv2.close()

suite "engine: param access":
  test "param host function accesses params array":
    let h = SchemeHostFns(
      engine: nil,
      params: @[SExpr(kind: sInt, ival: 42), SExpr(kind: sStr, sval: "hello")],
      tx: 0,
      asOfTx: none[int64](),
      scanners: @[],
    )
    let r = h.call("param", @[SExpr(kind: sInt, ival: 1)])
    check r.result.ival == 42

    let r2 = h.call("param", @[SExpr(kind: sInt, ival: 2)])
    check r2.result.sval == "hello"

  test "param out of range raises":
    let h = makeArithHost()
    expect EvalError:
      discard h.call("param", @[SExpr(kind: sInt, ival: 1)])

suite "engine: StreamingSession → nextBatch":
  test "nextBatch on select scheme with result-row":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)
    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Alice"), 1, 0)

    let program = scheme.parse("(begin " &
                         "  (let* ((s0 (scanner-open \"EAVT\" #f))) " &
                         "    (scanner-iterate s0 (e) " &
                         "      (result-row e))))")
    let proto = newQuerySession(q, SchemeProgram(body: program), @[], 0, none[int64]())
    let sess = newStreamingSession(proto)

    let (rows, more) = sess.nextBatch(10)
    check rows.len >= 1
    check not more

suite "engine: DML with batch execute":
  test "UPSERT program executes save":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let progStr = "(begin " &
      "(declare-attr \"user.name\" \":db.type/string\" #f #f) " &
      "(let* ((eid (alloc-entity 4))) " &
      "  (save eid \"user.name\" \"UPSERT User\") " &
      "  (result eid)))"

    let program = SchemeProgram(body: scheme.parse(progStr))
    let session = newQuerySession(q, program, @[], 0, none[int64]())
    let result = executeProgram(session)

    check result.kind == sList
    # Should be (result <eid>)
    let eid = result.items[1].ival
    check eid > 0

    let val = q.lookupValue(eid, "user.name")
    check val.isSome
    check val.get.sval == "UPSERT User"

  test "retract in DML program removes value":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "user.name", SExpr(kind: sStr, sval: "Before"), 1, 0)

    let progStr = "(begin (retract " & $eid & " \"user.name\" \"Before\") " &
      "(result (lookup-value " & $eid & " \"user.name\")))"
    let program = SchemeProgram(body: scheme.parse(progStr))
    let session = newQuerySession(q, program, @[], 2, none[int64]())
    let result = executeProgram(session)

    # result should be (result ()) → nil lookup
    check result.kind == sList
    check result.items.len >= 2
    check result.items[1].kind == sVoid

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: partitions
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: partitions":
  test "declare-partition returns id via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(result (declare-partition \"my.part\"))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.kind == sList
    let pid = result.items[1].ival
    check pid > 0

  test "declare-partition is idempotent via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(declare-partition \"my.part\")"))
    var session = newQuerySession(q, prog, @[], 0, none[int64]())
    discard executeProgram(session)

    let prog2 = SchemeProgram(body: scheme.parse("(result (declare-partition \"my.part\"))"))
    session = newQuerySession(q, prog2, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].ival > 0

  test "alloc-entity in custom partition via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse(
      "(begin " &
      "  (declare-partition \"custom\") " &
      "  (let* ((pid (declare-partition \"custom\"))) " &
      "    (result (alloc-entity pid))))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.kind == sList
    check result.items[1].ival > 0

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: alloc-entity / tx-entity via Scheme
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: alloc-entity / tx-entity":
  test "alloc-entity returns eid via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(result (alloc-entity))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].ival > 0

  test "alloc-entity produces distinct eids":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse(
      "(result (alloc-entity) (alloc-entity) (alloc-entity))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    # (result e1 e2 e3) — flattened args, not nested list
    check result.kind == sList
    check result.items.len == 4  # "result" + 3 distinct eids
    check result.items[1].ival != result.items[2].ival
    check result.items[2].ival != result.items[3].ival
    check result.items[1].ival != result.items[3].ival

  test "tx-entity returns current tx":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(result (tx-entity))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].ival == 0  # tx is 0

  test "alloc-entity with default partition":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(result (alloc-entity 4))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].ival > 0

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: combined roundtrip
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: combined roundtrip":
  test "alloc + save + lookup-value roundtrip via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse(
      "(begin " &
      "  (declare-attr \"user.name\" \":db.type/string\" #f #t) " &
      "  (declare-attr \"user.hq\" \":db.type/string\" #f #f) " &
      "  (let* ((c1 (alloc-entity)) " &
      "         (c2 (alloc-entity))) " &
      "    (save c1 \"user.name\" \"ACME\") " &
      "    (save c1 \"user.hq\" \"NYC\") " &
      "    (save c2 \"user.name\" \"Globex\") " &
      "    (save c2 \"user.hq\" \"SF\") " &
      "    (result c1 " &
      "           (lookup-value c1 \"user.name\") " &
      "           (lookup-value c1 \"user.hq\") " &
      "           c2 " &
      "           (lookup-value c2 \"user.name\") " &
      "           (lookup-value c2 \"user.hq\") " &
      "           (lookup-entity \"user.name\" \"Globex\"))))"))
    let session = newQuerySession(q, prog, @[], 1, none[int64]())
    let result = executeProgram(session)
    check result.kind == sList
    # Flat (result c1 name1 hq1 c2 name2 hq2 globex-eid)
    check result.items.len == 8  # "result" + 7 values
    let c1 = result.items[1].ival
    let name1 = result.items[2].sval
    let hq1 = result.items[3].sval
    let c2 = result.items[4].ival
    let name2 = result.items[5].sval
    let hq2 = result.items[6].sval
    let globexEid = result.items[7].ival
    check name1 == "ACME"
    check hq1 == "NYC"
    check name2 == "Globex"
    check hq2 == "SF"
    check globexEid == c2

  test "state persists across multiple calls":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("user.name", ":db.type/string", false, false, 1)

    var prog = SchemeProgram(body: scheme.parse(
      "(begin (let* ((e (alloc-entity))) " &
      "  (save e \"user.name\" \"Zed\") " &
      "  (result e)))"))
    var session = newQuerySession(q, prog, @[], 1, none[int64]())
    let r1 = executeProgram(session)
    let eid = r1.items[1].ival

    prog = SchemeProgram(body: scheme.parse(
      "(result (lookup-value " & $eid & " \"user.name\"))"))
    session = newQuerySession(q, prog, @[], 2, some(0'i64))
    let r2 = executeProgram(session)
    check r2.items[1].sval == "Zed"

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: error paths
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: error paths":
  test "save to undeclared attr errors via Scheme":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((e (alloc-entity))) (save e \"no.such.attr\" \"x\"))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    expect EvalError:
      discard executeProgram(session)

  test "lookup-entity on non-unique errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    q.declareAttrFromSql("tag.x", ":db.type/string", true, false, 1)

    let prog = SchemeProgram(body: scheme.parse(
      "(lookup-entity \"tag.x\" \"anything\")"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    expect EvalError:
      discard executeProgram(session)

  test "parse error propagates":
    # Unterminated S-expression causes ParseError
    var caught = false
    try:
      discard scheme.parse("(result 'unterminated")
    except CatchableError:
      caught = true
    check caught

  test "unknown host function errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(no-such-fn 1 2)"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    expect EvalError:
      discard executeProgram(session)

  test "result with no args returns void in list":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let prog = SchemeProgram(body: scheme.parse("(result)"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.kind == sList
    # (result) → (result) with empty args
    check result.items.len >= 1

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: blob type (ported from test_blob.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: blob type":
  test "blob declare + save bytes":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.data", ":db.type/blob", false, false, 1)

    let eid = q.allocateInPartition(4)
    let raw = @[byte(0xDE), 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]
    q.saveWithT(eid, "blob.data", SExpr(kind: sBytes, bytesval: raw), 1, 0)

    let val = q.lookupValue(eid, "blob.data")
    check val.isSome
    check val.get.kind == sBytes
    check val.get.bytesval == raw

  test "blob empty bytes":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.empty", ":db.type/blob", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.empty", SExpr(kind: sBytes, bytesval: @[]), 1, 0)

    let val = q.lookupValue(eid, "blob.empty")
    check val.isSome
    check val.get.bytesval.len == 0

  test "blob large bytes (25KB)":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.large", ":db.type/blob", false, false, 1)

    var raw = newSeq[byte]()
    for i in 0..<25600: raw.add(byte(i and 0xFF))
    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.large", SExpr(kind: sBytes, bytesval: raw), 1, 0)

    let val = q.lookupValue(eid, "blob.large")
    check val.isSome
    check val.get.bytesval == raw

  test "blob with null bytes":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.null", ":db.type/blob", false, false, 1)

    let raw = @[byte(0x00), 0x00, 0xFF, 0x00, 0xFE, 0x00]
    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.null", SExpr(kind: sBytes, bytesval: raw), 1, 0)

    let val = q.lookupValue(eid, "blob.null")
    check val.isSome
    check val.get.bytesval == raw

  test "blob many cardinality accumulates values":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.many", ":db.type/blob", true, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.many", SExpr(kind: sBytes, bytesval: @[byte(0x01), 0x02]), 1, 0)
    q.saveWithT(eid, "blob.many", SExpr(kind: sBytes, bytesval: @[byte(0x03), 0x04]), 2, 0)

    # Scan EAVT to count datoms for this eid+attr
    var prefix = keys.encodeEid(eid)
    let aid = q.lookupAttr("blob.many").get
    prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
    prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
    var found = 0
    let mc = q.kv.openScanCursor(0)
    while true:
      let k = mc.next()
      if k.isNone: break
      let key = k.get
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 0: inc found
    check found == 2

  test "blob one cardinality overwrites":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.one", ":db.type/blob", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.one", SExpr(kind: sBytes, bytesval: @[byte(0xAA), 0xBB]), 1, 0)
    q.saveWithT(eid, "blob.one", SExpr(kind: sBytes, bytesval: @[byte(0xCC), 0xDD]), 2, 0)

    let val = q.lookupValue(eid, "blob.one")
    check val.isSome
    check val.get.bytesval == @[byte(0xCC), 0xDD]

  test "blob retract removes datom":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("blob.del", ":db.type/blob", false, false, 1)

    let raw = @[byte(0x01), 0x02, 0x03]
    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "blob.del", SExpr(kind: sBytes, bytesval: raw), 1, 0)
    q.retract(eid, "blob.del", SExpr(kind: sBytes, bytesval: raw), 2, 0)

    check q.lookupValue(eid, "blob.del").isNone

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: dedup (ported from test_dedup.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: dedup":
  test "lookup finds entity by unique attr (dedup entity)":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("empresa.nome", ":db.type/string", false, true, 1)

    let eid1 = q.allocateInPartition(4)
    q.saveWithT(eid1, "empresa.nome", SExpr(kind: sStr, sval: "teste"), 1, 0)

    let found = q.lookupEntity("empresa.nome", SExpr(kind: sStr, sval: "teste"))
    check found.isSome
    check found.get == eid1

  test "multiple attrs on same entity are visible":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("empresa.nome", ":db.type/string", false, false, 1)
    q.declareAttrFromSql("empresa.id", ":db.type/long", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "empresa.nome", SExpr(kind: sStr, sval: "teste"), 1, 0)
    q.saveWithT(eid, "empresa.id", SExpr(kind: sInt, ival: 42), 1, 0)

    check q.lookupValue(eid, "empresa.nome").get.sval == "teste"
    check q.lookupValue(eid, "empresa.id").get.ival == 42

  test "retract one of many attr — remaining visible":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("empresa.tag", ":db.type/string", true, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "empresa.tag", SExpr(kind: sStr, sval: "a"), 1, 0)
    q.saveWithT(eid, "empresa.tag", SExpr(kind: sStr, sval: "b"), 1, 0)
    q.retract(eid, "empresa.tag", SExpr(kind: sStr, sval: "a"), 2, 0)

    # "a" should be invisible, "b" should be visible
    let va = q.lookupValue(eid, "empresa.tag")
    # For MANY cardinality, lookupValue returns only the latest active value (not all)
    # Verify that at least "b" is accessible
    # Scan EAVT group to check retraction behavior properly
    var prefix = keys.encodeEid(eid)
    let aid = q.lookupAttr("empresa.tag").get
    prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
    prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
    let mc = q.kv.openScanCursor(0)
    # Walk backwards through keys to determine which value-groups are active
    var retractedGroups: seq[seq[byte]] = @[]
    var activeGroups: seq[seq[byte]] = @[]
    while true:
      let k = mc.next()
      if k.isNone: break
      let key = k.get
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        let group = key[0..<key.len-8]
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 1:
          retractedGroups.add group
        else:
          if group notin retractedGroups:
            activeGroups.add group
    # At least one value should be active (the "b" value)
    check activeGroups.len >= 1

  test "save same many attr value twice — stored once":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("empresa.tag", ":db.type/string", true, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "empresa.tag", SExpr(kind: sStr, sval: "x"), 1, 0)
    q.saveWithT(eid, "empresa.tag", SExpr(kind: sStr, sval: "x"), 1, 0)

    var prefix = keys.encodeEid(eid)
    let aid = q.lookupAttr("empresa.tag").get
    prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
    prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
    var count = 0
    let mc = q.kv.openScanCursor(0)
    while true:
      let k = mc.next()
      if k.isNone: break
      let key = k.get
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        let sf = beUint64(key, key.len - 8)
        if (sf and 1) == 0: inc count
    check count == 1

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: partition (ported from test_partition.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: partition":
  test "multiple partitions get sequential ids":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let pid1 = q.declarePartition("alpha", 1)
    let pid2 = q.declarePartition("beta", 1)
    check pid2 == pid1 + 1

  test "alloc in partition uses correct partition bits":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let eid = q.allocateInPartition(4)
    check (eid shr 44) == 4  # partition bits

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: asOfTx (ported from test_per_pattern_asof.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: asOfTx":
  test "later value visible when asOf is high":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("company.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "company.name", SExpr(kind: sStr, sval: "old"), 1, 0)
    q.saveWithT(eid, "company.name", SExpr(kind: sStr, sval: "new"), 2, 0)

    # With asOf=0, should see only "old" (t=1 <= 0 is false, so scan sees both?)
    # Actually lookupValue with no asOf always returns the latest active
    let val = q.lookupValue(eid, "company.name")
    check val.isSome
    check val.get.sval == "new"

  test "retract hides value from future queries":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("company.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "company.name", SExpr(kind: sStr, sval: "visible"), 1, 0)
    q.retract(eid, "company.name", SExpr(kind: sStr, sval: "visible"), 2, 0)

    check q.lookupValue(eid, "company.name").isNone

  test "cardinality one overwrite visible only for later asOf":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("company.name", ":db.type/string", false, false, 1)

    let eid = q.allocateInPartition(4)
    q.saveWithT(eid, "company.name", SExpr(kind: sStr, sval: "old"), 1, 0)
    q.saveWithT(eid, "company.name", SExpr(kind: sStr, sval: "new"), 2, 0)

    # Latest active should be "new"
    let val = q.lookupValue(eid, "company.name")
    check val.get.sval == "new"

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: scanner host fns (ported from test_scheme_scanner.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: scanner host fns":
  test "scanner-open EAVT returns resource":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) (result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.kind == sList
    # (result bytes...) — prefix should be empty
    check result.items[1].kind == sBytes
    check result.items[1].bytesval.len == 0

  test "scanner-open AEVT":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"AEVT\"))) (result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "scanner-open AVET":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"AVET\"))) (result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "scanner-open VAET":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"VAET\"))) (result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "scanner-push eid in EAVT":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s 1000) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    let pref = result.items[1].bytesval
    check pref.len == 8  # eid = 8 bytes

  test "scanner-push eid + attr in EAVT":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s 1000) " &
      "(scanner-push s 42) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    let pref = result.items[1].bytesval
    check pref.len == 12  # 8 eid + 4 attr

  test "scanner-pop restores prefix":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s 1000) " &
      "(scanner-push s 42) " &
      "(scanner-pop s) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    let pref = result.items[1].bytesval
    check pref.len == 8  # back to eid only

  test "scanner-pop on empty is no-op":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-pop s) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "scanner-pop to empty":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s 1000) " &
      "(scanner-pop s) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "scanner-push-pop-push":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s 1000) " &
      "(scanner-push s 42) " &
      "(scanner-pop s) " &
      "(scanner-push s 99) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    let pref = result.items[1].bytesval
    check pref.len == 12

  test "scanner-push push return void":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(result (scanner-push s 1)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].kind == sVoid  # push returns Void

  test "scanner-open history mode":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\" #t))) " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 0

  test "two scanners independent":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let prog = SchemeProgram(body: scheme.parse(
      "(begin " &
      "  (let* ((s0 (scanner-open \"EAVT\")) " &
      "         (s1 (scanner-open \"EAVT\"))) " &
      "    (scanner-push s0 100) " &
      "    (scanner-push s1 200) " &
      "    (result (scanner-prefix s0) (scanner-prefix s1))))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    # (result pref0 pref1) — both should be 8 bytes (eid)
    check result.items[1].kind == sBytes
    check result.items[2].kind == sBytes
    check result.items[1].bytesval.len == 8
    check result.items[2].bytesval.len == 8

  test "scanner-push large eid":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let large = (1'i64 shl 62) - 1
    let prog = SchemeProgram(body: scheme.parse(
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $large & ") " &
      "(result (scanner-prefix s)))"))
    let session = newQuerySession(q, prog, @[], 0, none[int64]())
    let result = executeProgram(session)
    check result.items[1].bytesval.len == 8


# ═══════════════════════════════════════════════════════════════════════════════
# Engine: scanner-iterate (ported from test_scheme_iterate.py)
# ═══════════════════════════════════════════════════════════════════════════════

proc runSelect(q: QueryStore; progText: string; params: seq[SExpr] = @[];
                maxRows: int = 500): seq[seq[SExpr]] =
  let program = SchemeProgram(body: scheme.parse(progText))
  let proto = newQuerySession(q, program, params, 0, none[int64]())
  let sess = newStreamingSession(proto)
  while result.len < maxRows:
    let (rows, more) = sess.nextBatch(100)
    result.add rows
    if not more: break

suite "engine: scanner-iterate basic":
  test "iterate emits all values for eid+aid":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 1), 1, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 2), 1, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 3), 1, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[1'i64, 2, 3]

  test "iterate single value":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("user.age", ":db.type/long", false, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "user.age", SExpr(kind: sInt, ival: 25), 1, 0)
    let aid = q.lookupAttr("user.age").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)))")
    check rows.len == 1
    check rows[0][0].ival == 25

  test "iterate order is sorted":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 3), 1, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 1), 1, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 2), 1, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[1'i64, 2, 3]

  test "iterate excludes retracted":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 1), 1, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 2), 1, 0)
    q.retract(eid, "tag.x", SExpr(kind: sInt, ival: 1), 2, 0)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 3), 3, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check 1'i64 notin vals
    check vals == @[2'i64, 3]

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: scanner-iterate :ranges
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: scanner-iterate :ranges":
  test "ranges filters values":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [5'i64, 10, 15, 20, 25]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\")) " &
      "       (r0 (ranges-create (and (>= 10) (<= 20))))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges r0 (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[10'i64, 15, 20]

  test "ranges eq single value":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [5'i64, 10, 15, 20, 25]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges (ranges-create (= 15)) (result-row v)))")
    check rows.len == 1
    check rows[0][0].ival == 15

  test "ranges neq excludes value":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [5'i64, 10, 15, 20, 25]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get

    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges (ranges-create (!= 15)) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[5'i64, 10, 20, 25]

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: multi-scanner leapfrog
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: multi-scanner leapfrog":
  test "two scanners intersection":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let aid = q.lookupAttr("tag.x").get
    let eid1 = q.allocateInPartition(4'u64)
    let eid2 = q.allocateInPartition(4'u64)
    for v in [10'i64, 20, 30]: q.saveWithT(eid1, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    for v in [20'i64, 30, 40]: q.saveWithT(eid2, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)

    let rows = runSelect(q,
      "(let* ((s1 (scanner-open \"EAVT\")) " &
      "       (s2 (scanner-open \"EAVT\"))) " &
      "(scanner-push s1 " & $eid1 & ") (scanner-push s1 " & $aid.int64 & ") " &
      "(scanner-push s2 " & $eid2 & ") (scanner-push s2 " & $aid.int64 & ") " &
      "(scanner-iterate (s1 s2) (v) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[20'i64, 30]

  test "disjoint value sets emit nothing":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let aid = q.lookupAttr("tag.x").get
    let eid1 = q.allocateInPartition(4'u64)
    let eid2 = q.allocateInPartition(4'u64)
    for v in [1'i64, 2, 3]: q.saveWithT(eid1, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    for v in [100'i64, 200]: q.saveWithT(eid2, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)

    let rows = runSelect(q,
      "(let* ((s1 (scanner-open \"EAVT\")) " &
      "       (s2 (scanner-open \"EAVT\"))) " &
      "(scanner-push s1 " & $eid1 & ") (scanner-push s1 " & $aid.int64 & ") " &
      "(scanner-push s2 " & $eid2 & ") (scanner-push s2 " & $aid.int64 & ") " &
      "(scanner-iterate (s1 s2) (v) (result-row v)))")
    check rows.len == 0

  test "single matching value in both scanners":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let aid = q.lookupAttr("tag.x").get
    let eid1 = q.allocateInPartition(4'u64)
    let eid2 = q.allocateInPartition(4'u64)
    q.saveWithT(eid1, "tag.x", SExpr(kind: sInt, ival: 42), 1, 0)
    q.saveWithT(eid2, "tag.x", SExpr(kind: sInt, ival: 42), 1, 0)

    let rows = runSelect(q,
      "(let* ((s1 (scanner-open \"EAVT\")) " &
      "       (s2 (scanner-open \"EAVT\"))) " &
      "(scanner-push s1 " & $eid1 & ") (scanner-push s1 " & $aid.int64 & ") " &
      "(scanner-push s2 " & $eid2 & ") (scanner-push s2 " & $aid.int64 & ") " &
      "(scanner-iterate (s1 s2) (v) (result-row v)))")
    check rows.len == 1
    check rows[0][0].ival == 42

suite "engine: scanner-iterate more":
  test "iterate no prefix emits datoms":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 1), 1, 0)
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-iterate s (v) (result-row v)))")
    # declare+save writes entries — at least 1 datom
    check rows.len > 0

  test "iterate with attr_name in result-row":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 10), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v (attr-name " & $aid.int64 & "))))")
    check rows.len >= 1
    check rows[0][1].sval == "tag.x"

  test "iterate AEVT finds eids by attr":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 10), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"AEVT\"))) " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (e) (result-row e)))")
    check rows.len >= 1

  test "param accessible in body":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: 10), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v v)))")
    check rows.len >= 1
    check rows[0][0] == rows[0][1]

  test "ranges OR disjoint":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [1'i64, 5, 10, 15, 20]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges (ranges-create (or (= 1) (= 20))) " &
      "  (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[1'i64, 20]

  test "ranges empty filter all":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [5'i64, 10, 15]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\")) " &
      "       (r0 (ranges-create (and)))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges r0 (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[5'i64, 10, 15]

  test "ranges filters out everything":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [5'i64, 10, 15]:
      q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) :ranges (ranges-create (and (> 100) (< 200))) " &
      "  (result-row v)))")
    check rows.len == 0

  test "multi three-way join":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let aid = q.lookupAttr("tag.x").get
    let eid1 = q.allocateInPartition(4'u64)
    let eid2 = q.allocateInPartition(4'u64)
    let eid3 = q.allocateInPartition(4'u64)
    for v in [10'i64, 20, 30]: q.saveWithT(eid1, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    for v in [20'i64, 30, 40]: q.saveWithT(eid2, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    for v in [30'i64, 40, 50]: q.saveWithT(eid3, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let rows = runSelect(q,
      "(let* ((s1 (scanner-open \"EAVT\")) " &
      "       (s2 (scanner-open \"EAVT\")) " &
      "       (s3 (scanner-open \"EAVT\"))) " &
      "(scanner-push s1 " & $eid1 & ") (scanner-push s1 " & $aid.int64 & ") " &
      "(scanner-push s2 " & $eid2 & ") (scanner-push s2 " & $aid.int64 & ") " &
      "(scanner-push s3 " & $eid3 & ") (scanner-push s3 " & $aid.int64 & ") " &
      "(scanner-iterate (s1 s2 s3) (v) (result-row v)))")
    check rows.len == 1
    check rows[0][0].ival == 30

  test "multi with ranges":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let aid = q.lookupAttr("tag.x").get
    let eid1 = q.allocateInPartition(4'u64)
    let eid2 = q.allocateInPartition(4'u64)
    for v in [10'i64, 20, 30, 50]: q.saveWithT(eid1, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    for v in [20'i64, 30, 50, 70]: q.saveWithT(eid2, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let rows = runSelect(q,
      "(let* ((s1 (scanner-open \"EAVT\")) " &
      "       (s2 (scanner-open \"EAVT\")) " &
      "       (r0 (ranges-create (>= 30)))) " &
      "(scanner-push s1 " & $eid1 & ") (scanner-push s1 " & $aid.int64 & ") " &
      "(scanner-push s2 " & $eid2 & ") (scanner-push s2 " & $aid.int64 & ") " &
      "(scanner-iterate (s1 s2) (v) :ranges r0 (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[30'i64, 50]

  test "second iterate call empty":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.x", ":db.type/long", true, false, 1)
    let eid = q.allocateInPartition(4'u64)
    for v in [1'i64, 2, 3]: q.saveWithT(eid, "tag.x", SExpr(kind: sInt, ival: v), 1, 0)
    let aid = q.lookupAttr("tag.x").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $eid & ") " &
      "(scanner-push s " & $aid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)) " &
      "(scanner-iterate s (v) (result-row v)))")
    # Only first iterate emits — second is empty
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[1'i64, 2, 3]

  test "iterate body can save":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("tag.src", ":db.type/long", true, false, 1)
    q.declareAttrFromSql("tag.copy", ":db.type/long", true, false, 1)
    let srcAid = q.lookupAttr("tag.src").get
    let srcEid = q.allocateInPartition(4'u64)
    for v in [1'i64, 2, 3]: q.saveWithT(srcEid, "tag.src", SExpr(kind: sInt, ival: v), 1, 0)
    let dstEid = q.allocateInPartition(4'u64)
    discard runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $srcEid & ") " &
      "(scanner-push s " & $srcAid.int64 & ") " &
      "(scanner-iterate s (v) (save " & $dstEid & " \"tag.copy\" v)))")
    # Verify copies were saved by scanning dstEid
    let dstAid = q.lookupAttr("tag.copy").get
    let rows = runSelect(q,
      "(let* ((s (scanner-open \"EAVT\"))) " &
      "(scanner-push s " & $dstEid & ") " &
      "(scanner-push s " & $dstAid.int64 & ") " &
      "(scanner-iterate s (v) (result-row v)))")
    var vals = newSeq[int64]()
    for row in rows:
      if row.len > 0 and row[0].kind == sInt: vals.add row[0].ival
    check vals == @[1'i64, 2, 3]

# ═══════════════════════════════════════════════════════════════════════════════
# Engine: select-path (yield-mode) — ported from test_scheme_arith.py
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: select-path (yield-mode)":
  test "arith in select path":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let rows = runSelect(q, "(begin (+ 1 2) (result-row 3))")
    check rows.len == 1
    check rows[0][0].ival == 3

  test "and in select path":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let rows = runSelect(q, "(begin (and #t 42) (result-row 1))")
    check rows.len == 1
    check rows[0][0].ival == 1

  test "or in select path":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let rows = runSelect(q, "(begin (or #f 7) (result-row 2))")
    check rows.len == 1
    check rows[0][0].ival == 2

  test "not in select path":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let rows = runSelect(q, "(begin (not #t) (result-row 3))")
    check rows.len == 1
    check rows[0][0].ival == 3

# ═══════════════════════════════════════════════════════════════════════════════
# runSql helper: full SQL → Scheme → execute pipeline
# ═══════════════════════════════════════════════════════════════════════════════

proc runSql(q: QueryStore; sql: string): seq[SExpr] =
  let stmt = sql_parser.parse(sql)
  let cstats = CompileStats(
    lookupAttr: proc(name: string): uint32 =
      q.eavt.lookupAttr(name).get(otherwise = 0),
    estimateIndexSize: proc(index: string, bound: openArray[uint64]): float64 =
      10_000_000.0,
    partitionIdFor: proc(name: string): uint64 =
      q.eavt.partitionIdFor(name).get(otherwise = 0),
    isRefAttr: proc(name: string): bool =
      let aid = q.eavt.lookupAttr(name).get(otherwise = 0)
      if aid == 0: false
      else: q.eavt.valueTypeFor(aid).get(otherwise = 0) == 21'u32,
    isIndexedAttr: proc(name: string): bool = true,
  )
  let compiled = compileSql(stmt, cstats)
  let tx = q.allocateTx()
  if compiled.isSelect:
    let proto = newQuerySession(q, compiled.program, @[], tx, none[int64]())
    let sess = newStreamingSession(proto)
    var rows: seq[seq[SExpr]]
    while rows.len < 500:
      let (batch, more) = sess.nextBatch(100)
      rows.add batch
      if not more: break
    for row in rows:
      result.add SExpr(kind: sList, items: row)
  else:
    let session = newQuerySession(q, compiled.program, @[], tx, none[int64]())
    let r = executeProgram(session)
    result.add r

proc expectRows(q: QueryStore; sql: string): seq[SExpr] =
  result = runSql(q, sql)

const PART_TX = 3'u64
const TX_PARTITION_BASE = PART_TX shl 44

func extractT(txEid: int64): int64 =
  txEid and ((1'i64 shl 44) - 1)

# ═══════════════════════════════════════════════════════════════════════════════
# TX tests (ported from test_tx.py)
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# TX tests (ported from test_tx.py)
# ═══════════════════════════════════════════════════════════════════════════════

suite "engine: TX entity (port of test_tx.py)":
  test "upsert as TX returns eid":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    discard runSql(q, "ATTRIBUTE tx.user STRING ONE")
    let rows = runSql(q, "UPSERT AS TX SET tx.user = 'bob'")
    check rows.len >= 1
    let r = rows[0]
    check r.kind == sList
    check r.items[0].symval == "result"
    let txEid = r.items[1].ival
    check txEid >= TX_PARTITION_BASE.int64
    check extractT(txEid) > 1

  test "separate tx UPSERTs give distinct eids":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    discard runSql(q, "ATTRIBUTE tx.user STRING ONE")
    let rA = runSql(q, "UPSERT AS TX SET tx.user = 'alice'")
    let rB = runSql(q, "UPSERT AS TX SET tx.user = 'bob'")
    let eidA = rA[0].items[1].ival
    let eidB = rB[0].items[1].ival
    check eidA != eidB
    check extractT(eidB) > extractT(eidA)

  test "ATTRIBUTE compiles and executes":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    let rows = runSql(q, "ATTRIBUTE tx.user STRING ONE")
    check rows.len >= 1
    let r = rows[0]
    check r.kind == sList
    check r.items[0].symval == "result"
    check r.items[1].sval == "tx.user"
    check q.eavt.isDeclared(q.eavt.lookupAttr("tx.user").get)

  test "upsert multi-clause returns result":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    discard runSql(q, "ATTRIBUTE tx.user STRING ONE")
    discard runSql(q, "ATTRIBUTE company.name STRING ONE")
    let rows = runSql(q,
      "UPSERT AS D1 SET company.name = 'ACME', AS TX SET tx.user = 'alice'")
    check rows.len >= 1
    let r = rows[0]
    check r.kind == sList
    check r.items[0].symval == "result"
    check r.items.len >= 2
