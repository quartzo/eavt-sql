## scheme.nim — Nim Scheme IR evaluator.
##
## Port of spier-scheme (~1500 lines Rust → Nim).
## Stack-based VM with yield/resume for streaming queries.

import std/[tables, strutils, options, sequtils]

# ═══════════════════════════════════════════════════════════════════════════════
# SExpr — the universal value type
# ═══════════════════════════════════════════════════════════════════════════════

type
  SExprKind* = enum
    sVoid, sBool, sInt, sFloat, sStr, sBytes, sSymbol, sList, sResource

  SExpr* = ref object
    case kind*: SExprKind
    of sBool:   bval*: bool
    of sInt:    ival*: int64
    of sFloat:  fval*: float64
    of sStr:    sval*: string
    of sBytes:  bytesval*: seq[byte]
    of sSymbol: symval*: string
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
  of sList: "(" & e.items.mapIt($it).join(" ") & ")"
  of sResource: "#<resource>"

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
  except:
    try: return newFloat(parseFloat(s))
    except: return newSymbol(s)

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
# HostFns callback
# ═══════════════════════════════════════════════════════════════════════════════

type
  HostFns* = ref object of RootObj

method call*(h: HostFns; name: string; args: seq[SExpr]): EvalStep {.base.} =
  discard
method isNative*(h: HostFns; name: string): bool {.base.} = false

# ═══════════════════════════════════════════════════════════════════════════════
# Evaluator stack frames
# ═══════════════════════════════════════════════════════════════════════════════

type
  FrameKind = enum
    fkEval, fkApply, fkLetBindings, fkWhenTest, fkIfTest,
    fkAndSeq, fkOrSeq, fkSetFrame, fkDepthRunBody

  Frame = ref object
    case kind: FrameKind
    of fkEval: fexpr: SExpr
    of fkApply:
      ffunc: SExpr
      fargs: seq[SExpr]
      fargsEval: seq[(string, SExpr)]
      fargsRemaining: seq[SExpr]
    of fkLetBindings:
      lbOp: string
      lbPairs: seq[(string, SExpr)]
      lbNames: seq[string]
      lbVals: seq[SExpr]
      lbCurrent: int
      lbBody: seq[SExpr]
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
    of fkDepthRunBody: discard

  YieldState* = object
    stack*: seq[Frame]
    dirtyDepthRunIdxs: seq[int]
    depthRuns*: seq[DepthRunFrame]
    started*: bool

  ## DepthRunFrame — one active `scanner-iterate` loop (port of the Rust
  ## frame in spier-scheme eval.rs). `stageKey` is the depth index, matching
  ## Rust's `state.depth_runs.len()` at push time.
  DepthRunFrame* = object
    stageKey*: int64
    scannerVals*: seq[SExpr]
    body*: seq[SExpr]
    paramName*: string
    ranges*: SExpr

# ═══════════════════════════════════════════════════════════════════════════════
# Evaluator
# ═══════════════════════════════════════════════════════════════════════════════

type EvalError* = object of CatchableError

const SpecialForms = ["let*", "let", "when", "if", "begin", "set!",
                       "print", "assert", "and", "or", "not",
                       "scanner-iterate"]

proc isSpecialForm(name: string): bool = name in SpecialForms

proc evalExpr(expr: SExpr; env: var Environment; host: HostFns;
              state: var YieldState): EvalStep {.nimcall.}

# ── processValue — apply a value to the next frame on stack ──

proc processValue(value: SExpr; state: var YieldState; env: var Environment;
                   host: HostFns) =
  while state.stack.len > 0:
    if state.stack[^1].kind == fkEval: return
    var frame = move(state.stack[^1])
    state.stack.setLen(state.stack.len - 1)
    case frame.kind:
    of fkLetBindings:
      frame.lbVals.add value
      frame.lbNames.add frame.lbPairs[frame.lbCurrent][0]
      if frame.lbOp == "let*":
        env.set(frame.lbNames[^1], value)
      inc frame.lbCurrent
      if frame.lbCurrent < frame.lbPairs.len:
        state.stack.add frame
        state.stack.add Frame(kind: fkEval, fexpr: frame.lbPairs[frame.lbCurrent][1])
      else:
        if frame.lbOp == "let":
          for i, n in frame.lbNames: env.set(n, frame.lbVals[i])
        for i in countdown(frame.lbBody.len - 1, 0):
          state.stack.add Frame(kind: fkEval, fexpr: frame.lbBody[i])
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
    of fkDepthRunBody:
      # One iteration of a scanner-iterate loop finished: advance the
      # leapfrog and either re-run the body or unwind.
      if state.depthRuns.len == 0: continue
      let dr = state.depthRuns[^1]
      var leapArgs = @[newInt(dr.stageKey)]
      for sv in dr.scannerVals: leapArgs.add sv
      leapArgs.add dr.ranges
      let okStep = host.call("scheme-leap-next", leapArgs)
      if okStep.kind == esYield:
        raise newException(EvalError, "unexpected yield in scheme-leap-next")
      if isTruthy(okStep.result):
        if dr.paramName.len > 0 and dr.scannerVals.len > 0:
          let vStep = host.call("scanner-read", @[dr.scannerVals[0]])
          if vStep.kind == esYield:
            raise newException(EvalError, "unexpected yield in scanner-read")
          env.set(dr.paramName, vStep.result)
        state.stack.add Frame(kind: fkDepthRunBody)
        for i in countdown(dr.body.len - 1, 0):
          state.stack.add Frame(kind: fkEval, fexpr: dr.body[i])
        return
      else:
        # Loop exhausted — the scanner-iterate form evaluates to Void.
        state.depthRuns.setLen(state.depthRuns.len - 1)
        state.stack.add Frame(kind: fkEval, fexpr: newVoid())
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
  of "let", "let*":
    let bindings = args.items[1]
    var pairs: seq[(string, SExpr)] = @[]
    if bindings.kind == sList:
      for b in bindings.items:
        if b.kind == sList and b.items.len >= 2:
          pairs.add ((b.items[0].symval, b.items[1]))
    var body: seq[SExpr] = @[]
    for i in 2..<args.items.len: body.add args.items[i]
    state.stack.add Frame(kind: fkLetBindings, lbOp: name, lbPairs: pairs,
      lbCurrent: 0, lbBody: body)
    if pairs.len > 0:
      state.stack.add Frame(kind: fkEval, fexpr: pairs[0][1])
      return done(newVoid())
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
      if args.items.len > 2: msg = args.items[2].sval
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
    # Port of spier-scheme eval.rs::eval_scanner_iterate_frame.
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
    var leapArgs = @[newInt(0)]
    for sv in scannerVals: leapArgs.add sv
    leapArgs.add rangesVal
    let ok = host.call("scheme-leap-init", leapArgs)
    if ok.kind == esYield: return ok
    if not isTruthy(ok.result):
      return done(newVoid())
    let val = host.call("scanner-read", @[scannerVals[0]])
    if val.kind == esYield: return val
    env.set(paramName, val.result)
    state.depthRuns.add DepthRunFrame(
      stageKey: state.depthRuns.len.int64,
      scannerVals: scannerVals, body: body,
      paramName: paramName, ranges: rangesVal)
    state.stack.add Frame(kind: fkDepthRunBody)
    for j in countdown(body.len - 1, 0):
      state.stack.add Frame(kind: fkEval, fexpr: body[j])
    return done(newVoid())
  else:
    raise newException(EvalError, "unknown special form: " & name)

# ── Expression evaluation ──

proc evalExpr(expr: SExpr; env: var Environment; host: HostFns;
              state: var YieldState): EvalStep =
  case expr.kind:
  of sVoid, sBool, sInt, sFloat, sStr, sBytes, sResource:
    return done(expr)
  of sSymbol:
    let v = env.get(expr.symval)
    if v.isSome: return done(v.get)
    raise newException(EvalError, "unbound: " & expr.symval)
  of sList:
    if expr.items.len == 0: return done(newVoid())
    let first = expr.items[0]
    if first.kind == sSymbol:
      let name = first.symval
      if isSpecialForm(name):
        return evalSpecialForm(name, expr, env, host, state)
      if host.isNative(name):
        var args: seq[SExpr] = @[]
        for i in 1..<expr.items.len:
          let argStep = evalFully(expr.items[i], env, host, state)
          if argStep.kind == esYield: return argStep
          args.add argStep.result
        return host.call(name, args)
      raise newException(EvalError, "unbound: " & name)
    raise newException(EvalError, "cannot apply non-symbol as function")
  return done(newVoid())

# ═══════════════════════════════════════════════════════════════════════════════
# Batch evaluator (non-yielding)
# ═══════════════════════════════════════════════════════════════════════════════

proc eval*(program: SchemeProgram; env: var Environment; host: HostFns): SExpr =
  var state = YieldState()
  let step = evalWithYield(program, env, host, state)
  if step.kind == esDone: return step.result
  raise newException(EvalError, "unexpected yield in batch eval")
