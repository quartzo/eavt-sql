## test_scheme.nim — Unit tests for the EDN VM (nim_scheme).
## Programs are EDN vectors with keyword opcodes: [:begin [:set! x 5] x]

import std/[unittest, options, strutils]
import scheme, edn

# ═══════════════════════════════════════════════════════════════════════════════
# EDN VM evaluator tests
# ═══════════════════════════════════════════════════════════════════════════════

type
  NilHost = ref object of HostFns

proc se(expr: SExpr; host: HostFns = nil): SExpr =
  var env = newEnvironment()
  eval(SchemeProgram(body: expr), env, if host == nil: NilHost() else: host)

proc ses(expr: SExpr; host: HostFns = nil): string = $(se(expr, host))

proc p(src: string): SExpr = readEdn(src)

type
  SaveManyHost = ref object of HostFns
    attr: string
    pairs: seq[(int64, int)]

method saveMany*(h: SaveManyHost; args: seq[SExpr]): EvalStep =
  h.attr = args[0].sval
  var i = 1
  while i < args.len:
    h.pairs.add((args[i].ival, args[i + 1].ival.int))
    inc i, 2
  return done(newVoid())

suite "ednvm.save-many":
  test "flat pairs dispatch to hostfn in one form":
    let h = SaveManyHost()
    discard se(p("[:save-many \"user.name\" 1 10 2 20]"), h)
    check h.attr == "user.name"
    check h.pairs == @[(1'i64, 10), (2'i64, 20)]
  test "single pair":
    let h = SaveManyHost()
    discard se(p("[:save-many \"a\" 7 8]"), h)
    check h.pairs == @[(7'i64, 8)]

suite "ednvm.literals":
  test "void":       check ses(newVoid()) == "#void"
  test "bool true":  check ses(newBool(true)) == "#t"
  test "bool false": check ses(newBool(false)) == "#f"
  test "int":        check ses(SExpr(kind: sInt, ival: 42)) == "42"

suite "ednvm.begin":
  test "int":        check ses(p("[:begin 42]")) == "42"
  test "last":       check ses(p("[:begin 1 2 3]")) == "3"
  test "empty":      check ses(p("[:begin]")) == "#void"
  test "multiple":   check ses(p("[:begin 1 2 3 4 5]")) == "5"

suite "ednvm.when":
  test "true":       check ses(p("[:when true 42]")) == "42"
  test "false":      check ses(p("[:when false 42]")) == "#void"
  test "true body":  check ses(p("[:when true 1 2 3]")) == "3"

suite "ednvm.if":
  test "true":       check ses(p("[:if true 42 99]")) == "42"
  test "false":      check ses(p("[:if false 42 99]")) == "99"
  test "no else":    check ses(p("[:if false 42]")) == "#void"

suite "ednvm.set":
  test "with when":  check ses(p("[:begin [:set! x 10] [:when true x]]")) == "10"
  test "overwrite":  check ses(p("[:begin [:set! x 1] [:set! x 2] x]")) == "2"
  test "non-symbol name raises EvalError not Defect":
    var exc: ref CatchableError = nil
    try:
      discard se(p("[:begin [:set! \"x\" 10]]"))
    except CatchableError as e:
      exc = e
    check exc != nil
    check "set!" in exc.msg

suite "ednvm.not":
  test "true":       check ses(p("[:not true]")) == "#f"
  test "false":      check ses(p("[:not false]")) == "#t"

suite "ednvm.and":
  test "both true":  check ses(p("[:and true true]")) == "#t"
  test "true false": check ses(p("[:and true false]")) == "#f"
  test "single":     check ses(p("[:and true]")) == "#t"
  test "zero":       check ses(p("[:and]")) == "#t"
  test "three":      check ses(p("[:and true true true]")) == "#t"
  test "short circuit": check ses(p("[:and true false true]")) == "#f"

suite "ednvm.or":
  test "both true":  check ses(p("[:or true true]")) == "#t"
  test "true false": check ses(p("[:or true false]")) == "#t"
  test "both false": check ses(p("[:or false false]")) == "#f"
  test "single":     check ses(p("[:or true]")) == "#t"
  test "zero":       check ses(p("[:or]")) == "#f"
  test "three":      check ses(p("[:or false false true]")) == "#t"

suite "ednvm.bindings":
  test "simple":     check ses(p("[:begin [:set! x 42] x]")) == "42"
  test "multiple":   check ses(p("[:begin [:set! a 1] [:set! b 2] [:set! c 3] c]")) == "3"
  test "star seq":   check ses(p("[:begin [:set! a 10] [:set! b a] b]")) == "10"
  test "star chain": check ses(p("[:begin [:set! a 1] [:set! b a] [:set! c b] c]")) == "1"

suite "ednvm.arith":
  test "call add":        check ses(p("[:+ 2 3]")) == "5"
  test "add chain":       check ses(p("[:+ 1 2 3 4]")) == "10"
  test "add variable":    check ses(p("[:begin [:set! x 5] [:+ x 3]]")) == "8"
  test "add nested":      check ses(p("[:+ [:+ 1 2] 3]")) == "6"
  test "mul nested":      check ses(p("[:* [:+ 1 2] [:- 10 7]]")) == "9"
  test "cmp variable":    check ses(p("[:begin [:set! x 5] [:> x 2]]")) == "#t"
  test "cmp nested":      check ses(p("[:< 1 [:+ 1 2]]")) == "#t"
  test "abs variable":    check ses(p("[:begin [:set! x -3] [:abs x]]")) == "3"

suite "ednvm.nested":
  test "when when":  check ses(p("[:when true [:when true 42]]")) == "42"
  test "if if":      check ses(p("[:if [:if false true false] 42 99]")) == "99"
  test "when if":    check ses(p("[:when true [:if true 1 2]]")) == "1"

suite "ednvm.assert":
  test "pass":       check ses(p("[:begin [:assert true] 42]")) == "42"
  test "fail":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: p("[:assert false \"boom\"]")), env, NilHost())

suite "ednvm.errors":
  test "unbound variable":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: p("x")), env, NilHost())
  test "unknown host function":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: p("[:nope 1 2]")), env, NilHost())
  test "legacy symbol-head form rejected":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: newList(@[newSymbol("begin"), newInt(1)])),
                   env, NilHost())