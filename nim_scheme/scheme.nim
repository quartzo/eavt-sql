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

proc writeScheme*(program: SchemeProgram): string =
  $program.body

const MAX_WIDTH = 100

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
              state: var YieldState): EvalStep {.nimcall.}

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
    let iterStep = host.call("scanner-iterate-init", initArgs)
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
    # (ranges-create expr) → flat list of (op val) pairs with (branch) separators
    let inner = if args.items.len >= 2: args.items[1] else: newList(@[])
    let opMap = {"=": 0'i32, "!=": 1, ">": 2, ">=": 3, "<": 4, "<=": 5}.toTable
    proc walk(sexpr: SExpr; resultList: var seq[SExpr]) =
      case sexpr.kind:
      of sList:
        if sexpr.items.len == 0: return
        let head = sexpr.items[0]
        if head.kind == sSymbol and head.symval == "and":
          for i in 1..<sexpr.items.len: walk(sexpr.items[i], resultList)
        elif head.kind == sSymbol and head.symval == "or":
          for i in 1..<sexpr.items.len:
            resultList.add newList(@[newSymbol("branch")])
            walk(sexpr.items[i], resultList)
        elif head.kind == sSymbol and head.symval in opMap:
          if sexpr.items.len >= 2:
            resultList.add newList(@[newInt(opMap[head.symval]), sexpr.items[1]])
      else: discard
    var items: seq[SExpr] = @[]
    walk(inner, items)
    return done(newList(items))
  of "while":
    if args.items.len < 2:
      raise newException(EvalError, "while: expected (while cond body...)")
    let condExpr = args.items[1]
    var body: seq[SExpr] = @[]
    for i in 2..<args.items.len: body.add args.items[i]
    state.stack.add Frame(kind: fkWhile, wCond: condExpr, wBody: body, wPhase: 0)
    return evalExpr(condExpr, env, host, state)
  # -- Arithmetic --
  of "+":
    var anyFloat = isFloat(args.items[1])
    var res = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      anyFloat = anyFloat or isFloat(args.items[i])
      res += sexprNumToF64(args.items[i])
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "-":
    var anyFloat = isFloat(args.items[1])
    var res = sexprNumToF64(args.items[1])
    if args.items.len == 2:
      res = -res
    else:
      for i in 2..<args.items.len:
        anyFloat = anyFloat or isFloat(args.items[i])
        res -= sexprNumToF64(args.items[i])
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "*":
    var anyFloat = isFloat(args.items[1])
    var res = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      anyFloat = anyFloat or isFloat(args.items[i])
      res *= sexprNumToF64(args.items[i])
    return done(if anyFloat: SExpr(kind: sFloat, fval: res) else: SExpr(kind: sInt, ival: int64(res)))
  of "/":
    var res = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let n = sexprNumToF64(args.items[i])
      if n == 0.0: raise newException(EvalError, "division by zero")
      res /= n
    return done(SExpr(kind: sFloat, fval: res))
  of "mod":
    let a = sexprNumToF64(args.items[1])
    let b = sexprNumToF64(args.items[2])
    if b == 0.0: raise newException(EvalError, "mod: division by zero")
    return done(SExpr(kind: sInt, ival: int64(a) mod int64(b)))
  of "<":
    var prev = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let cur = sexprNumToF64(args.items[i])
      if prev >= cur: return done(newBool(false))
      prev = cur
    return done(newBool(true))
  of ">":
    var prev = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let cur = sexprNumToF64(args.items[i])
      if prev <= cur: return done(newBool(false))
      prev = cur
    return done(newBool(true))
  of "<=":
    var prev = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let cur = sexprNumToF64(args.items[i])
      if prev > cur: return done(newBool(false))
      prev = cur
    return done(newBool(true))
  of ">=":
    var prev = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let cur = sexprNumToF64(args.items[i])
      if prev < cur: return done(newBool(false))
      prev = cur
    return done(newBool(true))
  of "=":
    var prev = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      let cur = sexprNumToF64(args.items[i])
      if abs(prev - cur) > 0.0:
        return done(newBool(false))
      prev = cur
    return done(newBool(true))
  of "!=":
    return done(newBool(abs(sexprNumToF64(args.items[1]) - sexprNumToF64(args.items[2])) > 0.0))
  of "min":
    var anyFloat = isFloat(args.items[1])
    var best = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      anyFloat = anyFloat or isFloat(args.items[i])
      let n = sexprNumToF64(args.items[i])
      if n < best: best = n
    return done(if anyFloat: SExpr(kind: sFloat, fval: best) else: SExpr(kind: sInt, ival: int64(best)))
  of "max":
    var anyFloat = isFloat(args.items[1])
    var best = sexprNumToF64(args.items[1])
    for i in 2..<args.items.len:
      anyFloat = anyFloat or isFloat(args.items[i])
      let n = sexprNumToF64(args.items[i])
      if n > best: best = n
    return done(if anyFloat: SExpr(kind: sFloat, fval: best) else: SExpr(kind: sInt, ival: int64(best)))
  of "abs":
    case args.items[1].kind:
    of sInt: return done(SExpr(kind: sInt, ival: args.items[1].ival.abs))
    of sFloat: return done(SExpr(kind: sFloat, fval: args.items[1].fval.abs))
    else: raise newException(EvalError, "abs expects number")
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
