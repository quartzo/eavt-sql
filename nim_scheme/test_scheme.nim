## test_scheme.nim — Unit tests for nim_scheme (Scheme IR evaluator).

import std/[unittest, options]
import scheme

# ═══════════════════════════════════════════════════════════════════════════════
# Scheme evaluator tests
# ═══════════════════════════════════════════════════════════════════════════════

type
  NilHost = ref object of HostFns
  AddHost = ref object of HostFns

method call(h: NilHost; n: string; a: seq[SExpr]): EvalStep = done(newVoid())
method isNative(h: NilHost; n: string): bool = false

method call(h: AddHost; n: string; a: seq[SExpr]): EvalStep =
  if a.len == 2 and a[0].kind == sInt and a[1].kind == sInt:
    done(SExpr(kind: sInt, ival: a[0].ival + a[1].ival))
  else: done(newVoid())
method isNative(h: AddHost; n: string): bool = n == "add"

proc se(expr: SExpr; host: HostFns = nil): SExpr =
  var env = newEnvironment()
  eval(SchemeProgram(body: expr), env, if host == nil: NilHost() else: host)

proc ses(expr: SExpr; host: HostFns = nil): string = $(se(expr, host))

suite "scheme.literals":
  test "void":       check ses(newVoid()) == "#void"
  test "bool true":  check ses(newBool(true)) == "#t"
  test "bool false": check ses(newBool(false)) == "#f"
  test "int":        check ses(SExpr(kind: sInt, ival: 42)) == "42"

suite "scheme.begin":
  test "int":        check ses(parse"(begin 42)") == "42"
  test "last":       check ses(parse"(begin 1 2 3)") == "3"
  test "empty":      check ses(parse"(begin)") == "#void"
  test "multiple":   check ses(parse"(begin 1 2 3 4 5)") == "5"

suite "scheme.when":
  test "true":       check ses(parse"(when #t 42)") == "42"
  test "false":      check ses(parse"(when #f 42)") == "#void"
  test "true body":  check ses(parse"(when #t 1 2 3)") == "3"

suite "scheme.if":
  test "true":       check ses(parse"(if #t 42 99)") == "42"
  test "false":      check ses(parse"(if #f 42 99)") == "99"
  test "no else":    check ses(parse"(if #f 42)") == "#void"

suite "scheme.set":
  test "with when":  check ses(parse"(begin (set! x 10) (when #t x))") == "10"
  test "overwrite":  check ses(parse"(begin (set! x 1) (set! x 2) x)") == "2"

suite "scheme.not":
  test "true":       check ses(parse"(not #t)") == "#f"
  test "false":      check ses(parse"(not #f)") == "#t"

suite "scheme.and":
  test "both true":  check ses(parse"(and #t #t)") == "#t"
  test "true false": check ses(parse"(and #t #f)") == "#f"
  test "single":     check ses(parse"(and #t)") == "#t"
  test "zero":       check ses(parse"(and)") == "#t"
  test "three":      check ses(parse"(and #t #t #t)") == "#t"
  test "short circuit": check ses(parse"(and #t #f #t)") == "#f"

suite "scheme.or":
  test "both true":  check ses(parse"(or #t #t)") == "#t"
  test "true false": check ses(parse"(or #t #f)") == "#t"
  test "both false": check ses(parse"(or #f #f)") == "#f"
  test "single":     check ses(parse"(or #t)") == "#t"
  test "zero":       check ses(parse"(or)") == "#f"
  test "three":      check ses(parse"(or #f #f #t)") == "#t"

suite "scheme.let":
  test "simple":     check ses(parse"(let ((x 42)) x)") == "42"
  test "multiple":   check ses(parse"(let ((a 1) (b 2) (c 3)) c)") == "3"
  test "star seq":   check ses(parse"(let* ((a 10) (b a)) b)") == "10"
  test "star chain": check ses(parse"(let* ((a 1) (b a) (c b)) c)") == "1"

suite "scheme.host":
  test "call add":   check ses(parse"(add 2 3)", AddHost()) == "5"
  test "nested":     check ses(parse"(add (add 1 2) (add 3 4))", AddHost()) == "10"

suite "scheme.nested":
  test "when when":  check ses(parse"(when #t (when #t 42))") == "42"
  test "if if":      check ses(parse"(if (if #f #t #f) 42 99)") == "99"
  test "when if":    check ses(parse"(when #t (if #t 1 2))") == "1"

suite "scheme.assert":
  test "pass":       check ses(parse"(begin (assert #t) 42)") == "42"
  test "fail":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse("(assert #f \"boom\")")), env, NilHost())

proc Q(s: string): string = "\"" & s & "\""

suite "scheme.parse":
  test "negative int": check ses(parse"-7") == "-7"
  test "string":       check ses(parse(Q("hello"))) == Q("hello")
  test "empty string": check ses(parse(Q(""))) == Q("")
  test "float":
    let r = se(parse"3.14")
    check r.kind == sFloat and abs(r.fval - 3.14) < 0.001

suite "scheme.errors":
  test "unbound variable":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse"x"), env, NilHost())
  test "unknown function":
    expect EvalError:
      var env = newEnvironment()
      discard eval(SchemeProgram(body: parse"(nope 1 2)"), env, NilHost())

# ══════════════════════════════════════════════════════════════════════════════
# PageStore Nim API tests (newPageStore → ptr PageStoreInner directly)
# ══════════════════════════════════════════════════════════════════════════════

