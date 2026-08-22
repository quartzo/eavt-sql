## query/types.nim — Range types and interval merging for the query engine.
##
## Port of spier-eavt-query/src/engine/types.rs (~269 lines Rust → Nim).

import std/[options, sequtils, algorithm]
import scheme

# ═══════════════════════════════════════════════════════════════════════════════
# Value comparison for SExpr (used as the universal Value type)
# ═══════════════════════════════════════════════════════════════════════════════

proc cmpValue*(a, b: SExpr): int =
  ## Total ordering for SExpr values, compatible with EAVT key ordering.
  if a.kind != b.kind:
    return ord(a.kind) - ord(b.kind)
  case a.kind:
  of sVoid: 0
  of sBool: ord(a.bval) - ord(b.bval)
  of sInt:
    if a.ival < b.ival: -1
    elif a.ival > b.ival: 1
    else: 0
  of sFloat:
    if a.fval < b.fval: -1
    elif a.fval > b.fval: 1
    else: 0
  of sStr: cmp(a.sval, b.sval)
  of sBytes:
    if a.bytesval.len < b.bytesval.len: -1
    elif a.bytesval.len > b.bytesval.len: 1
    else:
      for i in 0..<a.bytesval.len:
        if a.bytesval[i] < b.bytesval[i]: return -1
        if a.bytesval[i] > b.bytesval[i]: return 1
      0
  else: 0

proc `<`*(a, b: SExpr): bool = cmpValue(a, b) < 0
proc `<=`*(a, b: SExpr): bool = cmpValue(a, b) <= 0
proc `==`*(a, b: SExpr): bool = cmpValue(a, b) == 0

# ═══════════════════════════════════════════════════════════════════════════════
# Range spec constants
# ═══════════════════════════════════════════════════════════════════════════════

const
  RangeLoOpen* = int32(1)
  RangeHiOpen* = int32(2)

type
  RangeSpec* = object
    lo*: Option[SExpr]
    hi*: Option[SExpr]
    flags*: int32

  ByteRangeSpec* = object
    lo*: Option[seq[byte]]
    hi*: Option[seq[byte]]
    flags*: int32

# ═══════════════════════════════════════════════════════════════════════════════
# merge_intervals
# ═══════════════════════════════════════════════════════════════════════════════

proc mergeIntervals*(intervals: seq[(Option[SExpr], Option[SExpr], int32)]):
    seq[(Option[SExpr], Option[SExpr], int32)] =
  if intervals.len <= 1:
    return intervals

  var sorted = intervals
  sorted.sort(proc(a, b: (Option[SExpr], Option[SExpr], int32)): int =
    if not a[0].isSome and not b[0].isSome: 0
    elif not a[0].isSome: -1
    elif not b[0].isSome: 1
    else: cmpValue(a[0].get, b[0].get))

  result.add sorted[0]

  for (lo, hi, flags) in sorted[1..^1]:
    let (prevLo, prevHi, prevFlags) = result[^1]

    let canMerge =
      if prevHi.isNone: true
      elif lo.isSome:
        let prevHiVal = prevHi.get
        let loVal = lo.get
        if loVal.kind != prevHiVal.kind: false
        elif loVal < prevHiVal: true
        elif loVal == prevHiVal:
          let prevHiClosed = (prevFlags and RangeHiOpen) == 0
          let loClosed = (flags and RangeLoOpen) == 0
          prevHiClosed and loClosed
        else: false
      else: false

    if canMerge:
      let newHi =
        if prevHi.isNone: hi
        elif hi.isNone: none[SExpr]()
        elif hi.get > prevHi.get: hi
        else: prevHi

      let newHiOpen =
        if prevHi.isNone: (flags and RangeHiOpen) != 0
        elif hi.isNone: false
        elif hi.get > prevHi.get: (flags and RangeHiOpen) != 0
        elif hi.get < prevHi.get: (prevFlags and RangeHiOpen) != 0
        else: (prevFlags and RangeHiOpen) != 0 and (flags and RangeHiOpen) != 0

      let newFlags = (prevFlags and RangeLoOpen) or
                     (if newHiOpen: RangeHiOpen else: int32(0))
      result[^1] = (prevLo, newHi, newFlags)
    else:
      result.add (lo, hi, flags)

# ═══════════════════════════════════════════════════════════════════════════════
# ops_to_intervals — converts range ops into canonical intervals
# ═══════════════════════════════════════════════════════════════════════════════

# Range op codes (from spier-query-ir)
const
  RangeOpEq* = 0
  RangeOpNeq* = 1
  RangeOpGt* = 2
  RangeOpGte* = 3
  RangeOpLt* = 4
  RangeOpLte* = 5
  RangeOpIn* = 6

proc opsToIntervals*(ops: seq[(int32, SExpr)]):
    seq[(Option[SExpr], Option[SExpr], int32)] =
  var neqVals: seq[SExpr] = @[]
  var rangeOps: seq[(int32, SExpr)] = @[]
  var inVals: seq[SExpr] = @[]

  for (op, val) in ops:
    case op:
    of RangeOpNeq: neqVals.add val
    of RangeOpIn:  inVals.add val
    else:          rangeOps.add (op, val)

  if inVals.len > 0 and rangeOps.len == 0 and neqVals.len == 0:
    var sorted = inVals
    sorted.sort(proc(a, b: SExpr): int = cmpValue(a, b))
    for v in sorted:
      result.add (some(v), some(v), int32(0))
    return mergeIntervals(result)

  var lo: Option[SExpr] = none[SExpr]()
  var hi: Option[SExpr] = none[SExpr]()
  var loOpen = false
  var hiOpen = false

  for (op, val) in rangeOps:
    case op:
    of RangeOpGt, RangeOpGte:
      if lo.isNone or val > lo.get or (val == lo.get and op == RangeOpGt):
        lo = some(val)
        loOpen = (op == RangeOpGt)
    of RangeOpLt, RangeOpLte:
      if hi.isNone or val < hi.get or (val == hi.get and op == RangeOpLt):
        hi = some(val)
        hiOpen = (op == RangeOpLt)
    of RangeOpEq:
      lo = some(val)
      hi = some(val)
      loOpen = false
      hiOpen = false
    else: discard

  if lo.isSome and hi.isSome and lo.get > hi.get:
    return @[]

  var flags = int32(0)
  if loOpen: flags = flags or RangeLoOpen
  if hiOpen: flags = flags or RangeHiOpen

  var intervals: seq[(Option[SExpr], Option[SExpr], int32)] = @[(lo, hi, flags)]

  for nv in neqVals:
    var newIntervals: seq[(Option[SExpr], Option[SExpr], int32)] = @[]
    for (ivLo, ivHi, ivFlags) in intervals:
      var inRange = true
      if ivLo.isSome:
        let loOpenI = (ivFlags and RangeLoOpen) != 0
        if loOpenI:
          if nv <= ivLo.get: inRange = false
        else:
          if nv < ivLo.get: inRange = false
      if inRange:
        if ivHi.isSome:
          let hiOpenI = (ivFlags and RangeHiOpen) != 0
          if hiOpenI:
            if nv >= ivHi.get: inRange = false
          else:
            if nv > ivHi.get: inRange = false
      if not inRange:
        newIntervals.add (ivLo, ivHi, ivFlags)
      else:
        let leftFlags = (ivFlags and (not RangeHiOpen)) or RangeHiOpen
        newIntervals.add (ivLo, some(nv), leftFlags)
        let rightFlags = (ivFlags and (not RangeLoOpen)) or RangeLoOpen
        newIntervals.add (some(nv), ivHi, rightFlags)
    intervals = newIntervals

  mergeIntervals(intervals)
