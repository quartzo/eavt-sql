## scheme.nim — Nim Scheme IR evaluator.
##
## Port of spier-scheme (~1500 lines Rust → Nim).
## Stack-based VM with yield/resume for streaming queries.

import std/[tables, strutils, options, sequtils, algorithm]

# ═══════════════════════════════════════════════════════════════════════════════
# SExpr — the universal value type
# ═══════════════════════════════════════════════════════════════════════════════

type
  SExprKind* = enum
    sVoid, sBool, sInt, sFloat, sStr, sBytes, sSymbol, sKeyword, sList, sResource

  SExpr* = ref object
    case kind*: SExprKind
    of sBool:   bval*: bool
    of sInt:    ival*: int64
    of sFloat:  fval*: float64
    of sStr:    sval*: string
    of sBytes:  bytesval*: seq[byte]
    of sSymbol: symval*: string
    of sKeyword: kwval*: string
    of sList:   items*: seq[SExpr]
    of sResource: rid*: int
    of sVoid:   discard

  SchemeProgram* = object
    body*: SExpr

proc newVoid*(): SExpr = SExpr(kind: sVoid)
proc newBool*(b: bool): SExpr = SExpr(kind: sBool, bval: b)
proc newInt*(i: int64): SExpr = SExpr(kind: sInt, ival: i)
proc newFloat*(f: float64): SExpr = SExpr(kind: sFloat, fval: f)
proc newStr*(s: string): SExpr = SExpr(kind: sStr, sval: s)
proc newBytes*(b: seq[byte]): SExpr = SExpr(kind: sBytes, bytesval: b)
proc newSymbol*(s: string): SExpr = SExpr(kind: sSymbol, symval: s)
proc newKeyword*(s: string): SExpr = SExpr(kind: sKeyword, kwval: s)
proc newList*(items: seq[SExpr]): SExpr = SExpr(kind: sList, items: items)
proc newResource*(r: int): SExpr = SExpr(kind: sResource, rid: r)

proc isTruthy*(e: SExpr): bool =
  not (e.kind == sVoid or (e.kind == sBool and not e.bval))

proc `$`*(e: SExpr): string =
  case e.kind:
  of sVoid: "#void"
  of sBool: (if e.bval: "#t" else: "#f")
  of sInt: $e.ival
  of sFloat: $e.fval
  of sStr: "\"" & e.sval & "\""
  of sBytes: "#b\"" & e.bytesval.mapIt($it).join("") & "\""
  of sSymbol: e.symval
  of sKeyword: ":" & e.kwval
  of sList: "[" & e.items.mapIt($it).join(" ") & "]"
  of sResource: "#<resource>"

proc writeScheme*(program: SchemeProgram): string =
  $program.body

const MAX_WIDTH = 100

const RangeLoOpen = 1'i32
const RangeHiOpen = 2'i32
const RangeOpEq = 0'i32
const RangeOpNeq = 1'i32
const RangeOpGt = 2'i32
const RangeOpGte = 3'i32
const RangeOpLt = 4'i32
const RangeOpLte = 5'i32
const RangeOpIn = 6'i32

proc encodeIntBytes(n: int64): seq[byte] =
  var x = cast[uint64](n xor (1'i64 shl 63))
  result = newSeqOfCap[byte](8)
  for i in countdown(7, 0): result.add byte((x shr (i * 8)) and 0xFF)
proc encodeFloatBytes(f: float64): seq[byte] =
  var x = cast[uint64](f)
  if (x shr 63) == 1: x = not x
  else: x = x xor (1'u64 shl 63)
  result = newSeqOfCap[byte](8)
  for i in countdown(7, 0): result.add byte((x shr (i * 8)) and 0xFF)
proc encodeVariableBytes(s: string): seq[byte] =
  let raw = s.cstring
  var len = 0
  while raw[len] != '\0': inc len
  result = newSeqOfCap[byte](len + (len div 8) + 2)
  var pos = 0
  while pos < len:
    let remaining = len - pos
    let blockLen = min(remaining, 8)
    for j in 0..<blockLen: result.add byte(raw[pos + j])
    for j in blockLen..<8: result.add byte(0)
    if remaining <= 8: result.add byte(blockLen)
    else: result.add byte(0xFF)
    pos += blockLen
proc encodeVariableUnorderedBytes(data: seq[byte]): seq[byte] =
  let length = data.len
  result = newSeqOfCap[byte](length + 4)
  result.add byte(length shr 24); result.add byte((length shr 16) and 0xFF)
  result.add byte((length shr 8) and 0xFF); result.add byte(length and 0xFF)
  result.add data
proc encodeSExprBytes(v: SExpr): seq[byte] =
  case v.kind:
  of sInt: result = encodeIntBytes(v.ival)
  of sFloat: result = encodeFloatBytes(v.fval)
  of sStr: result = encodeVariableBytes(v.sval)
  of sBytes: result = encodeVariableUnorderedBytes(v.bytesval)
  of sBool:
    result = newSeqOfCap[byte](8)
    result.add byte(if v.bval: 0x80 else: 0x00)
    for _ in 1..7: result.add byte(0)
  else:
    result = newSeqOfCap[byte](8)
    for _ in 0..7: result.add byte(0)

proc cmpValueS(a, b: SExpr): int =
  if a.kind != b.kind:
    return ord(a.kind) - ord(b.kind)
  case a.kind:
  of sVoid: 0
  of sBool: ord(a.bval) - ord(b.bval)
  of sInt:
    if a.ival < b.ival: -1 elif a.ival > b.ival: 1 else: 0
  of sFloat:
    if a.fval < b.fval: -1 elif a.fval > b.fval: 1 else: 0
  of sStr: cmp(a.sval, b.sval)
  of sKeyword: cmp(a.kwval, b.kwval)
  of sBytes:
    if a.bytesval.len < b.bytesval.len: -1
    elif a.bytesval.len > b.bytesval.len: 1
    else:
      for i in 0..<a.bytesval.len:
        if a.bytesval[i] < b.bytesval[i]: return -1
        if a.bytesval[i] > b.bytesval[i]: return 1
      0
  else: 0

proc mergeIntervalsS(intervals: seq[(Option[SExpr], Option[SExpr], int32)]): seq[(Option[SExpr], Option[SExpr], int32)] =
  if intervals.len <= 1: return intervals
  var sorted = intervals
  sorted.sort(proc(a, b: (Option[SExpr], Option[SExpr], int32)): int =
    if not a[0].isSome and not b[0].isSome: 0
    elif not a[0].isSome: -1
    elif not b[0].isSome: 1
    else: cmpValueS(a[0].get, b[0].get))
  result.add sorted[0]
  for (lo, hi, flags) in sorted[1..^1]:
    let (prevLo, prevHi, prevFlags) = result[^1]
    let canMerge =
      if prevHi.isNone: true
      elif lo.isSome:
        let prevHiVal = prevHi.get
        let loVal = lo.get
        if loVal.kind != prevHiVal.kind: false
        elif cmpValueS(loVal, prevHiVal) < 0: true
        elif cmpValueS(loVal, prevHiVal) == 0:
          let prevHiClosed = (prevFlags and RangeHiOpen) == 0
          let loClosed = (flags and RangeLoOpen) == 0
          prevHiClosed and loClosed
        else: false
      else: false
    if canMerge:
      let newHi =
        if prevHi.isNone: hi
        elif hi.isNone: none[SExpr]()
        elif cmpValueS(hi.get, prevHi.get) > 0: hi
        else: prevHi
      let newHiOpen =
        if prevHi.isNone: (flags and RangeHiOpen) != 0
        elif hi.isNone: false
        elif cmpValueS(hi.get, prevHi.get) > 0: (flags and RangeHiOpen) != 0
        elif cmpValueS(hi.get, prevHi.get) < 0: (prevFlags and RangeHiOpen) != 0
        else: (prevFlags and RangeHiOpen) != 0 and (flags and RangeHiOpen) != 0
      let newFlags = (prevFlags and RangeLoOpen) or (if newHiOpen: RangeHiOpen else: 0'i32)
      result[^1] = (prevLo, newHi, newFlags)
    else:
      result.add (lo, hi, flags)

proc opsToIntervalsS(ops: seq[(int32, SExpr)]): seq[(Option[SExpr], Option[SExpr], int32)] =
  var neqVals: seq[SExpr] = @[]
  var rangeOps: seq[(int32, SExpr)] = @[]
  var inVals: seq[SExpr] = @[]
  for (op, val) in ops:
    case op:
    of RangeOpNeq: neqVals.add val
    of RangeOpIn: inVals.add val
    else: rangeOps.add (op, val)
  if inVals.len > 0 and rangeOps.len == 0 and neqVals.len == 0:
    var sorted = inVals
    sorted.sort(proc(a, b: SExpr): int = cmpValueS(a,b))
    for v in sorted:
      result.add (some(v), some(v), 0'i32)
    return mergeIntervalsS(result)
  var lo: Option[SExpr] = none[SExpr]()
  var hi: Option[SExpr] = none[SExpr]()
  var loOpen = false
  var hiOpen = false
  for (op, val) in rangeOps:
    case op:
    of RangeOpGt, RangeOpGte:
      if lo.isNone or cmpValueS(val, lo.get) > 0 or (cmpValueS(val, lo.get)==0 and op==RangeOpGt):
        lo = some(val); loOpen = (op==RangeOpGt)
    of RangeOpLt, RangeOpLte:
      if hi.isNone or cmpValueS(val, hi.get) < 0 or (cmpValueS(val, hi.get)==0 and op==RangeOpLt):
        hi = some(val); hiOpen = (op==RangeOpLt)
    of RangeOpEq:
      lo = some(val); hi = some(val); loOpen=false; hiOpen=false
    else: discard
  if lo.isSome and hi.isSome and cmpValueS(lo.get, hi.get) > 0:
    return @[]
  var flags = 0'i32
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
          if cmpValueS(nv, ivLo.get) <= 0: inRange = false
        else:
          if cmpValueS(nv, ivLo.get) < 0: inRange = false
      if inRange and ivHi.isSome:
        let hiOpenI = (ivFlags and RangeHiOpen) != 0
        if hiOpenI:
          if cmpValueS(nv, ivHi.get) >= 0: inRange = false
        else:
          if cmpValueS(nv, ivHi.get) > 0: inRange = false
      if not inRange:
        newIntervals.add (ivLo, ivHi, ivFlags)
      else:
        let leftFlags = (ivFlags and (not RangeHiOpen)) or RangeHiOpen
        newIntervals.add (ivLo, some(nv), leftFlags)
        let rightFlags = (ivFlags and (not RangeLoOpen)) or RangeLoOpen
        newIntervals.add (some(nv), ivHi, rightFlags)
    intervals = newIntervals
  mergeIntervalsS(intervals)

proc writeSchemePretty*(program: SchemeProgram): string =
  var outStr = ""
  proc writeExprPretty(expr: SExpr; indent: int): int =
    case expr.kind:
    of sList:
      if expr.items.len == 0:
        outStr.add "()"
        return indent + 2
      let compact = $expr
      if indent + compact.len <= MAX_WIDTH:
        outStr.add compact
        return indent + compact.len
      outStr.add "("
      var col = indent + 1
      var first = true
      let childIndent = indent + 2
      for item in expr.items:
        if first:
          first = false
        else:
          outStr.add "\n"
          for _ in 0 ..< childIndent:
            outStr.add " "
          col = childIndent
        col = writeExprPretty(item, childIndent)
      outStr.add ")"
      col + 1
    else:
      let s = $expr
      outStr.add s
      indent + s.len
  discard writeExprPretty(program.body, 0)
  outStr

# ═══════════════════════════════════════════════════════════════════════════════
# Parser — S-expression parser
# ═══════════════════════════════════════════════════════════════════════════════

type ParseError* = object of CatchableError

proc parse(input: string; pos: var int): SExpr

proc skipWhitespace(input: string; pos: var int) =
  while pos < input.len and input[pos] in {' ', '\t', '\n', '\r'}: inc pos
  if pos < input.len - 1 and input[pos] == ';':
    while pos < input.len and input[pos] != '\n': inc pos
    skipWhitespace(input, pos)

proc parseAtom(input: string; pos: var int): SExpr =
  var start = pos
  while pos < input.len and input[pos] notin {' ', '\t', '\n', '\r', ')', '('}: inc pos
  let s = input[start..<pos]
  if s == "#void" or s == "#nil": return newVoid()
  if s == "#t": return newBool(true)
  if s == "#f": return newBool(false)
  try: return newInt(parseBiggestInt(s))
  except ValueError:
    # Grammar dispatch: int → float → symbol. Not an error path.
    try: return newFloat(parseFloat(s))
    except ValueError: return newSymbol(s)

proc parseStr(input: string; pos: var int): SExpr =
  inc pos # skip opening "
  var s = ""
  while pos < input.len and input[pos] != '"':
    if input[pos] == '\\':
      inc pos
      if pos < input.len:
        case input[pos]:
        of 'n': s.add '\n'
        of 't': s.add '\t'
        of '\\': s.add '\\'
        of '"': s.add '"'
        else: s.add input[pos]
    else:
      s.add input[pos]
    inc pos
  if pos >= input.len:
    raise newException(ParseError, "parse error at " & $pos & ": unterminated string")
  inc pos # skip closing "
  return newStr(s)

proc parseList(input: string; pos: var int): SExpr =
  inc pos # skip opening (
  var items: seq[SExpr] = @[]
  skipWhitespace(input, pos)
  while pos < input.len and input[pos] != ')':
    items.add parse(input, pos)
    skipWhitespace(input, pos)
  if pos >= input.len:
    raise newException(ParseError, "parse error at " & $pos & ": unterminated list")
  inc pos # skip closing )
  return newList(items)

proc parse(input: string; pos: var int): SExpr =
  skipWhitespace(input, pos)
  if pos >= input.len: return newVoid()
  case input[pos]:
  of '(': return parseList(input, pos)
  of '"': return parseStr(input, pos)
  else: return parseAtom(input, pos)

proc parse*(input: string): SExpr =
  var pos = 0
  result = parse(input, pos)

# ═══════════════════════════════════════════════════════════════════════════════
# Environment — flat binding table
# ═══════════════════════════════════════════════════════════════════════════════

type
  Environment* = object
    bindings*: Table[string, SExpr]
    depthCounter*: int

proc newEnvironment*(): Environment =
  result.bindings = initTable[string, SExpr]()

proc get*(env: Environment; name: string): Option[SExpr] =
  if name in env.bindings: some(env.bindings[name]) else: none(SExpr)

proc set*(env: var Environment; name: string; value: SExpr) =
  env.bindings[name] = value

# ═══════════════════════════════════════════════════════════════════════════════
# EvalStep — result of one evaluation step
# ═══════════════════════════════════════════════════════════════════════════════

type
  EvalStepKind* = enum
    esDone, esYield

  EvalStep* = object
    case kind*: EvalStepKind
    of esDone: result*: SExpr
    of esYield: row*: SExpr

proc done*(v: SExpr): EvalStep = EvalStep(kind: esDone, result: v)
proc yieldRow*(v: SExpr): EvalStep = EvalStep(kind: esYield, row: v)

# ═══════════════════════════════════════════════════════════════════════════════
# HostFns — virtual methods for host functions (ref object + inheritance)
# ═══════════════════════════════════════════════════════════════════════════════

type
  HostFns* = ref object of RootObj

method scannerOpen*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerRead*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerPush*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerPop*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerPrefix*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerIterateInit*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method scannerIterateNext*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method internA*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method attrName*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method resolveVal*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method param*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method save*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method saveMany*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method retract*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method allocEntity*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method txEntity*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method lookupEntity*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method getOrCreateEntity*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method lookupValue*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method declareAttr*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method declarePartition*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method resultRow*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method result*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method dbgScanners*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard
method rangesShow*(h: HostFns; args: seq[SExpr]): EvalStep {.base, gcsafe.} = discard

# ═══════════════════════════════════════════════════════════════════════════════
# Evaluator stack frames
# ═══════════════════════════════════════════════════════════════════════════════

type
  FrameKind = enum
    fkEval, fkApply, fkWhenTest, fkIfTest,
    fkAndSeq, fkOrSeq, fkSetFrame, fkWhile

  Frame = ref object
    case kind: FrameKind
    of fkEval: fexpr: SExpr
    of fkApply:
      ffunc: SExpr
      fargs: seq[SExpr]
      fargsEval: seq[(string, SExpr)]
      fargsRemaining: seq[SExpr]
    of fkWhenTest:
      wtCond: SExpr
      wtBody: seq[SExpr]
    of fkIfTest:
      itCondition: SExpr
      itThen: seq[SExpr]
      itElse: seq[SExpr]
    of fkAndSeq: asRemaining: seq[SExpr]
    of fkOrSeq: osRemaining: seq[SExpr]
    of fkSetFrame:
      sfName: string
      sfEnv: Environment
    of fkWhile:
      wCond: SExpr
      wBody: seq[SExpr]
      wPhase: int  # 0 = eval cond, 1 = eval body

  YieldState* = object
    stack*: seq[Frame]
    started*: bool

# ═══════════════════════════════════════════════════════════════════════════════
# Evaluator
# ═══════════════════════════════════════════════════════════════════════════════

type EvalError* = object of CatchableError

const SpecialForms = ["when", "if", "begin", "set!",
                       "print", "assert", "and", "or", "not",
                       "scanner-iterate", "ranges-create", "while",
                       "+", "-", "*", "/", "mod",
                       "<", ">", "<=", ">=", "=", "!=",
                       "min", "max", "abs"]

proc isSpecialForm(name: string): bool = name in SpecialForms

# ── Arithmetic helpers ──

proc isFloat(expr: SExpr): bool = expr.kind == sFloat

proc sexprNumToF64(expr: SExpr): float64 =
  case expr.kind:
  of sInt: float64(expr.ival)
  of sFloat: expr.fval
  else: raise newException(EvalError, "expected number, got " & $expr)

proc evalExpr(expr: SExpr; env: var Environment; host: HostFns;
              state: var YieldState): EvalStep {.nimcall, gcsafe.}

# ── processValue — apply a value to the next frame on stack ──

proc processValue(value: SExpr; state: var YieldState; env: var Environment;
                   host: HostFns) =
  while state.stack.len > 0:
    if state.stack[^1].kind == fkEval: return
    var frame = move(state.stack[^1])
    state.stack.setLen(state.stack.len - 1)
    case frame.kind:
    of fkWhenTest:
      if isTruthy(value):
        for i in countdown(frame.wtBody.len - 1, 0):
          state.stack.add Frame(kind: fkEval, fexpr: frame.wtBody[i])
      else:
        state.stack.add Frame(kind: fkEval, fexpr: newVoid())
    of fkIfTest:
      let body = if isTruthy(value): frame.itThen else: frame.itElse
      if body.len == 0:
        state.stack.add Frame(kind: fkEval, fexpr: newVoid())
      else:
        for i in countdown(body.len - 1, 0):
          state.stack.add Frame(kind: fkEval, fexpr: body[i])
    of fkSetFrame:
      env.set(frame.sfName, value)
      continue
    of fkWhile:
      if frame.wPhase == 0:
        if isTruthy(value):
          state.stack.add Frame(kind: fkWhile, wCond: frame.wCond,
            wBody: frame.wBody, wPhase: 1)
          for i in countdown(frame.wBody.len - 1, 0):
            state.stack.add Frame(kind: fkEval, fexpr: frame.wBody[i])
        return
      else:
        state.stack.add Frame(kind: fkWhile, wCond: frame.wCond,
          wBody: frame.wBody, wPhase: 0)
        state.stack.add Frame(kind: fkEval, fexpr: frame.wCond)
        return
    of fkAndSeq:
      if not isTruthy(value):
        state.stack.add Frame(kind: fkEval, fexpr: newBool(false))
        return
      if frame.asRemaining.len == 0:
        state.stack.add Frame(kind: fkEval, fexpr: value)
        return
      let nextAnd = frame.asRemaining[0]
      let restAnd = frame.asRemaining[1..frame.asRemaining.high]
      state.stack.add Frame(kind: fkAndSeq, asRemaining: restAnd)
      state.stack.add Frame(kind: fkEval, fexpr: nextAnd)
      return
    of fkOrSeq:
      if isTruthy(value):
        state.stack.add Frame(kind: fkEval, fexpr: value)
        return
      if frame.osRemaining.len == 0:
        state.stack.add Frame(kind: fkEval, fexpr: newBool(false))
        return
      let nextOr = frame.osRemaining[0]
      let restOr = frame.osRemaining[1..frame.osRemaining.high]
      state.stack.add Frame(kind: fkOrSeq, osRemaining: restOr)
      state.stack.add Frame(kind: fkEval, fexpr: nextOr)
      return
    else:
      discard

proc evalFully(expr: SExpr; env: var Environment; host: HostFns;
               state: var YieldState): EvalStep {.nimcall.} =
  ## Evaluate `expr` to a final value, draining any continuation frames the
  ## evaluation pushes (special forms work in non-tail/arg position).
  ## Yields propagate to the caller.
  let baseDepth = state.stack.len
  let step = evalExpr(expr, env, host, state)
  if step.kind == esYield: return step
  var lastVal = step.result
  while state.stack.len > baseDepth:
    processValue(lastVal, state, env, host)
    if state.stack.len <= baseDepth: break
    if state.stack[^1].kind != fkEval: break
    let top = state.stack[^1]
    state.stack.setLen(state.stack.len - 1)
    let s2 = evalExpr(top.fexpr, env, host, state)
    if s2.kind == esYield: return s2
    lastVal = s2.result
  done(lastVal)

# ── Resumable evaluator entry point ──

proc evalWithYield*(program: SchemeProgram; env: var Environment;
                     host: HostFns; state: var YieldState): EvalStep =
  if not state.started:
    state.started = true
    state.stack.add Frame(kind: fkEval, fexpr: program.body)
  while state.stack.len > 0:
    let frame = state.stack[^1]
    state.stack.setLen(state.stack.len - 1)
    case frame.kind:
    of fkEval:
      let step = evalExpr(frame.fexpr, env, host, state)
      if step.kind == esYield: return step
      processValue(step.result, state, env, host)
      if state.stack.len == 0:
        return done(step.result)
    else:
      # Non-Eval continuation frame reached by the main loop (happens after
      # a yield resume): route it through processValue with a Void value.
      state.stack.add frame
      processValue(newVoid(), state, env, host)
  return done(newVoid())

# ── evalNumArgs — evaluate args.items[1..^1] to numbers, propagating yields ──

proc evalNumArgs(args: SExpr; env: var Environment; host: HostFns;
                 state: var YieldState; nums: var seq[float64];
                 anyFloat: var bool): EvalStep =
  result = done(newVoid())
  for i in 1 ..< args.items.len:
    let v = evalFully(args.items[i], env, host, state)
    if v.kind == esYield: return v
    if isFloat(v.result): anyFloat = true
    nums.add sexprNumToF64(v.result)

# ── evalSpecialForm — dispatch special forms ──

proc evalSpecialForm(name: string; args: SExpr; env: var Environment;
                      host: HostFns; state: var YieldState): EvalStep =
  case name:
  of "begin":
    for i in countdown(args.items.len - 1, 2):
      state.stack.add Frame(kind: fkEval, fexpr: args.items[i])
    if args.items.len >= 2:
      return evalExpr(args.items[1], env, host, state)
    return done(newVoid())
  of "when":
    let testExpr = args.items[1]
    var body: seq[SExpr] = @[]
    for i in 2..<args.items.len: body.add args.items[i]
    state.stack.add Frame(kind: fkWhenTest, wtBody: body)
    return evalExpr(testExpr, env, host, state)
  of "if":
    let testExpr = args.items[1]
    let thenExpr = args.items[2]
    var elseBody: seq[SExpr] = @[]
    if args.items.len > 3:
      for i in 3..<args.items.len: elseBody.add args.items[i]
    state.stack.add Frame(kind: fkIfTest, itThen: @[thenExpr], itElse: elseBody)
    return evalExpr(testExpr, env, host, state)
  of "set!":
    if args.items.len < 3 or args.items[1].kind != sSymbol:
      raise newException(EvalError, "set!: expected (set! symbol value)")
    let name = args.items[1].symval
    let valExpr = args.items[2]
    state.stack.add Frame(kind: fkSetFrame, sfName: name)
    return evalExpr(valExpr, env, host, state)
  of "print":
    for i in 1..<args.items.len:
      let v = evalFully(args.items[i], env, host, state)
      if v.kind == esYield: return v
      stderr.writeLine($v.result)
    return done(newVoid())
  of "assert":
    let v = evalFully(args.items[1], env, host, state)
    if v.kind == esYield: return v
    if not isTruthy(v.result):
      var msg = "assertion failed"
      if args.items.len > 2 and args.items[2].kind == sStr:
        msg = args.items[2].sval
      raise newException(EvalError, msg)
    return done(newVoid())
  of "and":
    var last = newBool(true)
    for i in 1..<args.items.len:
      let v = evalFully(args.items[i], env, host, state)
      if v.kind == esYield: return v
      if not isTruthy(v.result): return done(newBool(false))
      last = v.result
    return done(last)
  of "or":
    for i in 1..<args.items.len:
      let v = evalFully(args.items[i], env, host, state)
      if v.kind == esYield: return v
      if isTruthy(v.result): return done(v.result)
    return done(newBool(false))
  of "not":
    let v = evalFully(args.items[1], env, host, state)
    if v.kind == esYield: return v
    return done(newBool(not isTruthy(v.result)))
  of "scanner-iterate":
    # (scanner-iterate scanner-expr-or-list (param) [:ranges ranges-expr] body...)
    # Rewritten using LeapIterator + while.
    if args.items.len < 4:
      raise newException(EvalError,
        "scanner-iterate: expected (scanner-iterate scanners (param) [:ranges r] body...+)")
    var scannerExprs: seq[SExpr] = @[]
    let se = args.items[1]
    if se.kind == sList and se.items.len > 0:
      scannerExprs = se.items
    else:
      scannerExprs = @[se]
    let paramsList = args.items[2]
    if paramsList.kind != sList or paramsList.items.len == 0 or
       paramsList.items[0].kind != sSymbol:
      raise newException(EvalError,
        "scanner-iterate: expected (param) — non-empty list of symbols")
    let paramName = paramsList.items[0].symval
    var rangesExpr: SExpr = nil
    var body: seq[SExpr] = @[]
    var i = 3
    while i < args.items.len:
      let it = args.items[i]
      if it.kind == sSymbol and it.symval == ":ranges":
        if rangesExpr != nil:
          raise newException(EvalError, "scanner-iterate: :ranges specified more than once")
        if i + 1 >= args.items.len:
          raise newException(EvalError, "scanner-iterate: :ranges requires a value")
        rangesExpr = args.items[i + 1]
        i += 2
        continue
      body.add it
      inc i
    if body.len == 0:
      raise newException(EvalError, "scanner-iterate: missing body")
    var rangesVal = newList(@[])
    if rangesExpr != nil:
      let rs = evalExpr(rangesExpr, env, host, state)
      if rs.kind == esYield: return rs
      rangesVal = rs.result
    var scannerVals: seq[SExpr] = @[]
    for e in scannerExprs:
      let sv = evalExpr(e, env, host, state)
      if sv.kind == esYield: return sv
      scannerVals.add sv.result

    # Build init args: scanners... ranges
    var initArgs: seq[SExpr] = @[]
    for sv in scannerVals: initArgs.add sv
    initArgs.add rangesVal
    let iterStep = host.scannerIterateInit(initArgs)
    if iterStep.kind == esYield: return iterStep
    if iterStep.result.kind == sVoid:
      return done(newVoid())
    let iterRes = iterStep.result

    # Push: (while (set! param (scanner-iterate-next iter)) body...)
    # scanner-iterate-next returns the first value (started=true) then advances.
    let condExpr = newList(@[newSymbol("set!"), newSymbol(paramName),
      newList(@[newSymbol("scanner-iterate-next"), iterRes])])
    state.stack.add Frame(kind: fkWhile,
      wCond: condExpr, wBody: body, wPhase: 0)
    state.stack.add Frame(kind: fkEval, fexpr: condExpr)
    return done(newVoid())
  of "ranges-create":
    # (ranges-create expr) → list of [lo, hi, flags] triples with open/closed borders.
    # lo/hi are SExpr values or sVoid for -inf/+inf; flags is int with bit 1=lo open, 2=hi open.
    let inner = if args.items.len >= 2: args.items[1] else: newList(@[])
    let opMap = {"=": 0'i32, "!=": 1, ">": 2, ">=": 3, "<": 4, "<=": 5, "in": 6'i32}.toTable
    var flat: seq[SExpr] = @[]
    proc walk(sexpr: SExpr; flat: var seq[SExpr];
              env: var Environment; host: HostFns; state: var YieldState) =
      case sexpr.kind:
      of sList:
        if sexpr.items.len == 0: return
        let head = sexpr.items[0]
        let headName = case head.kind
          of sKeyword: head.kwval
          of sSymbol: head.symval
          else: ""
        if headName == "and":
          for i in 1..<sexpr.items.len: walk(sexpr.items[i], flat, env, host, state)
        elif headName == "or":
          for i in 1..<sexpr.items.len:
            flat.add newList(@[newKeyword("branch")])
            walk(sexpr.items[i], flat, env, host, state)
        elif headName in opMap:
          if headName == "in":
            for idx in 1..<sexpr.items.len:
              let step = evalExpr(sexpr.items[idx], env, host, state)
              if step.kind == esYield:
                raise newException(EvalError, "ranges-create: value expression yielded unexpectedly")
              flat.add newList(@[newInt(RangeOpIn), step.result])
          elif sexpr.items.len >= 2:
            let step = evalExpr(sexpr.items[1], env, host, state)
            if step.kind == esYield:
              raise newException(EvalError, "ranges-create: value expression yielded unexpectedly")
            flat.add newList(@[newInt(opMap[headName]), step.result])
      else: discard
    walk(inner, flat, env, host, state)
    # Parse flat into branches seq[seq[(op,val)]]
    var branches: seq[seq[(int32, SExpr)]] = @[@[]]
    for item in flat:
      if item.kind == sList and item.items.len == 1 and item.items[0].kind == sKeyword and item.items[0].kwval == "branch":
        branches.add @[]
      elif item.kind == sList and item.items.len >= 2 and item.items[0].kind == sInt:
        let op = int32(item.items[0].ival)
        branches[^1].add (op, item.items[1])
    # Single empty branch (no ops) → no restriction
    if branches.len == 1 and branches[0].len == 0:
      return done(newList(@[]))
    # Remove empty branches from leading branch marker
    var nonEmpty: seq[seq[(int32, SExpr)]] = @[]
    for b in branches:
      if b.len > 0: nonEmpty.add b
    if nonEmpty.len == 0:
      return done(newList(@[]))
    var allIntervals: seq[(Option[SExpr], Option[SExpr], int32)] = @[]
    for b in nonEmpty:
      for iv in opsToIntervalsS(b): allIntervals.add iv
    let merged = mergeIntervalsS(allIntervals)
    if merged.len == 0:
      # Empty intervals → unsatisfiable: produce sentinel that host will treat as empty (no rows)
      # Encode as single triple with lo>hi marker: use flags=-1 to signal empty
      return done(newList(@[newList(@[newVoid(), newVoid(), newInt(-1)])]))
    var outItems: seq[SExpr] = @[]
    for (lo, hi, flags) in merged:
      let loB = if lo.isSome: newBytes(encodeSExprBytes(lo.get)) else: newVoid()
      let hiB = if hi.isSome: newBytes(encodeSExprBytes(hi.get)) else: newVoid()
      outItems.add newList(@[loB, hiB, newInt(flags)])
    return done(newList(outItems))
  of "while":
    if args.items.len < 2:
      raise newException(EvalError, "while: expected (while cond body...)")
    let condExpr = args.items[1]
    var body: seq[SExpr] = @[]
    for i in 2..<args.items.len: body.add args.items[i]
    state.stack.add Frame(kind: fkWhile, wCond: condExpr, wBody: body, wPhase: 0)
    return evalExpr(condExpr, env, host, state)
  # -- Arithmetic (args evaluated via evalNumArgs, yields propagate) --
  of "+":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var res = 0.0
    for n in nums: res += n
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "-":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var res = nums[0]
    if nums.len == 1: res = -res
    else:
      for i in 1 ..< nums.len: res -= nums[i]
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "*":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var res = 1.0
    for n in nums: res *= n
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "/":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var res = nums[0]
    for i in 1 ..< nums.len:
      if nums[i] == 0.0: raise newException(EvalError, "division by zero")
      res /= nums[i]
    return done(SExpr(kind: sFloat, fval: res))
  of "mod":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    if nums.len < 2 or nums[1] == 0.0: raise newException(EvalError, "mod: division by zero")
    return done(SExpr(kind: sInt, ival: int64(nums[0]) mod int64(nums[1])))
  of "<":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    for i in 1 ..< nums.len:
      if nums[i-1] >= nums[i]: return done(newBool(false))
    return done(newBool(true))
  of ">":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    for i in 1 ..< nums.len:
      if nums[i-1] <= nums[i]: return done(newBool(false))
    return done(newBool(true))
  of "<=":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    for i in 1 ..< nums.len:
      if nums[i-1] > nums[i]: return done(newBool(false))
    return done(newBool(true))
  of ">=":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    for i in 1 ..< nums.len:
      if nums[i-1] < nums[i]: return done(newBool(false))
    return done(newBool(true))
  of "=":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    for i in 1 ..< nums.len:
      if abs(nums[i-1] - nums[i]) > 0.0: return done(newBool(false))
    return done(newBool(true))
  of "!=":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    if nums.len < 2: return done(newBool(false))
    return done(newBool(abs(nums[0] - nums[1]) > 0.0))
  of "min":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var best = nums[0]
    for i in 1 ..< nums.len:
      if nums[i] < best: best = nums[i]
    return done(if anyFloat: SExpr(kind: sFloat, fval: best) else: SExpr(kind: sInt, ival: int64(best)))
  of "max":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    var best = nums[0]
    for i in 1 ..< nums.len:
      if nums[i] > best: best = nums[i]
    return done(if anyFloat: SExpr(kind: sFloat, fval: best) else: SExpr(kind: sInt, ival: int64(best)))
  of "abs":
    var anyFloat = false
    var nums: seq[float64] = @[]
    let s = evalNumArgs(args, env, host, state, nums, anyFloat)
    if s.kind == esYield: return s
    return done(if anyFloat: SExpr(kind: sFloat, fval: abs(nums[0]))
                            else: SExpr(kind: sInt, ival: int64(abs(nums[0]))))
  else:
    raise newException(EvalError, "unknown special form: " & name)

# ── Expression evaluation ──

proc evalExpr(expr: SExpr; env: var Environment; host: HostFns;
              state: var YieldState): EvalStep =
  case expr.kind:
  of sVoid, sBool, sInt, sFloat, sStr, sKeyword, sBytes, sResource:
    return done(expr)
  of sSymbol:
    let v = env.get(expr.symval)
    if v.isSome: return done(v.get)
    raise newException(EvalError, "unbound: " & expr.symval)
  of sList:
    if expr.items.len == 0: return done(newVoid())
    let first = expr.items[0]
    if first.kind == sKeyword:
      # EDN VM: opcodes are keywords heading vectors — [:begin ...],
      # [:scanner-open ...], [:+ 1 2] (docs: passo 2, fase A).
      let name = first.kwval
      if isSpecialForm(name):
        return evalSpecialForm(name, expr, env, host, state)
      # Host function dispatch
      var args: seq[SExpr] = @[]
      for i in 1..<expr.items.len:
        let argStep = evalFully(expr.items[i], env, host, state)
        if argStep.kind == esYield: return argStep
        args.add argStep.result
      case name
      of "scanner-open": return host.scannerOpen(args)
      of "scanner-read": return host.scannerRead(args)
      of "scanner-push": return host.scannerPush(args)
      of "scanner-pop": return host.scannerPop(args)
      of "scanner-prefix": return host.scannerPrefix(args)
      of "scanner-iterate-init": return host.scannerIterateInit(args)
      of "scanner-iterate-next": return host.scannerIterateNext(args)
      of "intern-a": return host.internA(args)
      of "attr-name": return host.attrName(args)
      of "resolve-val": return host.resolveVal(args)
      of "param": return host.param(args)
      of "save": return host.save(args)
      of "save-many": return host.saveMany(args)
      of "retract": return host.retract(args)
      of "alloc-entity": return host.allocEntity(args)
      of "tx-entity": return host.txEntity(args)
      of "lookup-entity": return host.lookupEntity(args)
      of "get-or-create-entity": return host.getOrCreateEntity(args)
      of "lookup-value": return host.lookupValue(args)
      of "declare-attr": return host.declareAttr(args)
      of "declare-partition": return host.declarePartition(args)
      of "result-row": return host.resultRow(args)
      of "result": return host.result(args)
      of "dbg-scanners": return host.dbgScanners(args)
      of "ranges-show": return host.rangesShow(args)
      else: raise newException(EvalError, "unknown host function: " & name)
    if first.kind == sSymbol:
      raise newException(EvalError,
        "legacy scheme form rejected — programs are EDN vectors with " &
        "keyword opcodes: [" & first.symval & " ...]")
    raise newException(EvalError, "cannot apply non-keyword as function")
  return done(newVoid())

# ═══════════════════════════════════════════════════════════════════════════════
# Batch evaluator (non-yielding)
# ═══════════════════════════════════════════════════════════════════════════════

proc eval*(program: SchemeProgram; env: var Environment; host: HostFns): SExpr =
  var state = YieldState()
  let step = evalWithYield(program, env, host, state)
  if step.kind == esDone: return step.result
  raise newException(EvalError, "unexpected yield in batch eval")

# ═══════════════════════════════════════════════════════════════════════════════
# VmSession — streaming VM with yield/resume
# ═══════════════════════════════════════════════════════════════════════════════

type
  VmSession* = ref object
    program*: SchemeProgram
    env*: Environment
    state*: YieldState
    done*: bool

proc newVmSession*(program: SchemeProgram): VmSession =
  VmSession(
    program: program,
    env: newEnvironment(),
    state: YieldState(),
    done: false,
  )

proc nextBatch*(sess: VmSession; host: HostFns; maxRows: int): (seq[seq[SExpr]], bool) =
  if sess.done or maxRows == 0:
    return (@[], false)

  var rows: seq[seq[SExpr]] = @[]
  while rows.len < maxRows:
    let step = evalWithYield(sess.program, sess.env, host, sess.state)
    case step.kind:
    of esYield:
      if step.row.kind == sList:
        rows.add step.row.items
    of esDone:
      sess.done = true
      return (rows, false)

  (rows, true)

# ── Flat wire tx ops (no intermediate SExpr on the transactor) ──────────────

type
  TxWSlotKind* = enum
    tskMissing   # nil / absent
    tskInt       # tempid (<0) or positive eid — sign decides at use
    tskFloat
    tskBool
    tskStr
    tskKw        # keyword interned at transport capture (symtab.nim)
    tskBytes
    tskLookupRef # [attr value] — attr keyword interned in refSym
  TxWSlot* = object
    kind*: TxWSlotKind
    i*: int64
    f*: float64
    b*: bool
    s*: string             # tskStr payload
    sym*: uint32           # tskKw / tskLookupRef refAttr (interned; 0 invalid)
    bin*: seq[byte]        # tskBytes
    refVal*: ref TxWSlot   # tskLookupRef: scalar value (rare — heap ok)
  TxWOp* = object
    isRetract*: bool
    e*: TxWSlot            # e slot (typed by the decoder; e.i mutated to the
                           #   resolved eid by the interpreter)
    attrSym*: uint32       # op attr keyword interned (0 = not a keyword)
    v*: TxWSlot            # v slot
    # interpreter-filled fields (0 = no-op / undeclared marker):
    attrId*: uint32
    vresolved*: int64      # v-slot tempid/lookup-ref → resolved eid
