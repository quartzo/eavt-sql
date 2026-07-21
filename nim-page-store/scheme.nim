## scheme.nim — Nim Scheme IR evaluator.
##
## Port of spier-scheme (~1500 lines Rust → Nim).
## Stack-based VM with yield/resume for streaming queries.

import std/[tables, strutils, strformat, options, sequtils, parseutils]

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
    of sResource: rptr*: pointer
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
proc newResource*(p: pointer): SExpr = SExpr(kind: sResource, rptr: p)

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
  if pos < input.len: inc pos # skip closing "
  return newStr(s)

proc parseList(input: string; pos: var int): SExpr =
  inc pos # skip opening (
  var items: seq[SExpr] = @[]
  skipWhitespace(input, pos)
  while pos < input.len and input[pos] != ')':
    items.add parse(input, pos)
    skipWhitespace(input, pos)
  if pos < input.len: inc pos # skip closing )
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
    started*: bool

# ═══════════════════════════════════════════════════════════════════════════════
# Evaluator
# ═══════════════════════════════════════════════════════════════════════════════

type EvalError* = object of CatchableError

const SpecialForms = ["let*", "let", "when", "if", "begin", "set!",
                       "print", "assert", "and", "or", "not"]

proc isSpecialForm(name: string): bool = name in SpecialForms

proc evalExpr(expr: SExpr; env: var Environment; host: HostFns;
              state: var YieldState): EvalStep

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
      # Value produced — return if stack empty, else process through continuations
      if state.stack.len == 0:
        return done(step.result)
    of fkApply: discard
    of fkLetBindings: discard
    of fkWhenTest: discard
    of fkIfTest: discard
    of fkAndSeq: discard
    of fkOrSeq: discard
    of fkSetFrame: discard
    of fkDepthRunBody: discard
  return done(newVoid())

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
        raise newException(EvalError, "special form not yet implemented: " & name)
      if host.isNative(name):
        # Evaluate all args eagerly, then call host
        var args: seq[SExpr] = @[]
        for i in 1..<expr.items.len:
          let argStep = evalExpr(expr.items[i], env, host, state)
          if argStep.kind == esYield: return argStep
          args.add argStep.result
        return host.call(name, args)
      raise newException(EvalError, "unknown function: " & name)
    raise newException(EvalError, "cannot apply non-symbol as function")
  else: discard
  return done(newVoid())

# ═══════════════════════════════════════════════════════════════════════════════
# Batch evaluator (non-yielding)
# ═══════════════════════════════════════════════════════════════════════════════

proc eval*(program: SchemeProgram; env: var Environment; host: HostFns): SExpr =
  var state = YieldState()
  let step = evalWithYield(program, env, host, state)
  if step.kind == esDone: return step.result
  raise newException(EvalError, "unexpected yield in batch eval")
