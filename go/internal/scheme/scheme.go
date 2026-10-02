// Package scheme ports nim_scheme/scheme.nim: a stack-based EDN VM with
// yield/resume used to execute compiled Datalog programs.  Programs are EDN
// vectors with keyword opcodes, e.g. [:begin [:set! x 5] x].
package scheme

import (
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"

	"eavt-go/internal/numfmt"
	"eavt-go/internal/sexpr"
)

// Program is a compiled scheme program.
type Program struct{ Body sexpr.Expr }

// Environment is a flat binding table.
type Environment struct{ bindings map[string]sexpr.Expr }

// NewEnvironment returns an empty environment.
func NewEnvironment() *Environment {
	return &Environment{bindings: map[string]sexpr.Expr{}}
}

// Get looks up a binding.
func (e *Environment) Get(name string) (sexpr.Expr, bool) {
	v, ok := e.bindings[name]
	return v, ok
}

// Set binds a name.
func (e *Environment) Set(name string, v sexpr.Expr) { e.bindings[name] = v }

// EvalStep is the result of one evaluation step (done or a yielded row).
type EvalStep struct {
	Yield  bool
	Result sexpr.Expr
}

func done(v sexpr.Expr) EvalStep     { return EvalStep{Result: v} }
func yieldRow(v sexpr.Expr) EvalStep { return EvalStep{Yield: true, Result: v} }

// Done returns a completed evaluation step.
func Done(v sexpr.Expr) EvalStep { return done(v) }

// YieldRow returns a yielded row step.
func YieldRow(v sexpr.Expr) EvalStep { return yieldRow(v) }

// HostFns dispatches host functions by name.
type HostFns interface {
	Call(name string, args []sexpr.Expr) (EvalStep, error)
}

// IsTruthy mirrors Nim isTruthy.
func IsTruthy(e sexpr.Expr) bool {
	switch v := e.(type) {
	case nil:
		return false
	case sexpr.Void:
		return false
	case sexpr.Bool:
		return bool(v)
	}
	return true
}

// String renders an expression like Nim's `$`.
func String(e sexpr.Expr) string {
	switch v := e.(type) {
	case nil:
		return "#void"
	case sexpr.Void:
		return "#void"
	case sexpr.Bool:
		if bool(v) {
			return "#t"
		}
		return "#f"
	case sexpr.Int:
		return fmt.Sprintf("%d", int64(v))
	case sexpr.Float:
		return numfmt.FloatString(float64(v))
	case sexpr.Str:
		return "\"" + string(v) + "\""
	case sexpr.Bytes:
		parts := make([]string, len(v))
		for i, b := range v {
			parts[i] = fmt.Sprintf("%d", b)
		}
		return "#b\"" + strings.Join(parts, "") + "\""
	case sexpr.Symbol:
		return string(v)
	case sexpr.Keyword:
		return ":" + string(v)
	case sexpr.List:
		parts := make([]string, len(v))
		for i, it := range v {
			parts[i] = String(it)
		}
		return "[" + strings.Join(parts, " ") + "]"
	case sexpr.Resource:
		return "#<resource>"
	}
	return "#void"
}

// ── value encoding (wire boundary for ranges) ────────────────────────────

const (
	rangeLoOpen int32 = 1
	rangeHiOpen int32 = 2

	rangeOpEq  int32 = 0
	rangeOpNeq int32 = 1
	rangeOpGt  int32 = 2
	rangeOpGte int32 = 3
	rangeOpLt  int32 = 4
	rangeOpLte int32 = 5
	rangeOpIn  int32 = 6
)

func encodeIntBytes(n int64) []byte {
	x := uint64(n) ^ (uint64(1) << 63)
	out := make([]byte, 8)
	for i := 0; i < 8; i++ {
		out[i] = byte(x >> (uint(7-i) * 8))
	}
	return out
}

func encodeFloatBytes(f float64) []byte {
	x := math.Float64bits(f)
	if x>>63 == 1 {
		x = ^x
	} else {
		x ^= uint64(1) << 63
	}
	out := make([]byte, 8)
	for i := 0; i < 8; i++ {
		out[i] = byte(x >> (uint(7-i) * 8))
	}
	return out
}

func encodeVariableBytes(s string) []byte {
	// Nim uses cstring: bytes up to the first NUL.
	if i := strings.IndexByte(s, 0); i >= 0 {
		s = s[:i]
	}
	var out []byte
	for pos := 0; pos < len(s); {
		remaining := len(s) - pos
		blockLen := remaining
		if blockLen > 8 {
			blockLen = 8
		}
		for j := 0; j < blockLen; j++ {
			out = append(out, s[pos+j])
		}
		for j := blockLen; j < 8; j++ {
			out = append(out, 0)
		}
		if remaining <= 8 {
			out = append(out, byte(blockLen))
		} else {
			out = append(out, 0xFF)
		}
		pos += blockLen
	}
	return out
}

func encodeVariableUnorderedBytes(data []byte) []byte {
	length := len(data)
	out := []byte{byte(length >> 24), byte(length >> 16), byte(length >> 8), byte(length)}
	return append(out, data...)
}

func encodeSExprBytes(v sexpr.Expr) []byte {
	switch x := v.(type) {
	case sexpr.Int:
		return encodeIntBytes(int64(x))
	case sexpr.Float:
		return encodeFloatBytes(float64(x))
	case sexpr.Str:
		return encodeVariableBytes(string(x))
	case sexpr.Bytes:
		return encodeVariableUnorderedBytes(x)
	case sexpr.Bool:
		out := make([]byte, 8)
		if bool(x) {
			out[0] = 0x80
		}
		return out
	}
	return make([]byte, 8)
}

func kindRank(e sexpr.Expr) int {
	switch e.(type) {
	case sexpr.Void, nil:
		return 0
	case sexpr.Bool:
		return 1
	case sexpr.Int:
		return 2
	case sexpr.Float:
		return 3
	case sexpr.Str:
		return 4
	case sexpr.Bytes:
		return 5
	case sexpr.Symbol:
		return 6
	case sexpr.Keyword:
		return 7
	case sexpr.List:
		return 8
	case sexpr.Resource:
		return 9
	}
	return 0
}

func cmpValueS(a, b sexpr.Expr) int {
	if kindRank(a) != kindRank(b) {
		return kindRank(a) - kindRank(b)
	}
	switch x := a.(type) {
	case sexpr.Bool:
		y := b.(sexpr.Bool)
		if bool(x) == bool(y) {
			return 0
		}
		if !bool(x) {
			return -1
		}
		return 1
	case sexpr.Int:
		y := b.(sexpr.Int)
		switch {
		case int64(x) < int64(y):
			return -1
		case int64(x) > int64(y):
			return 1
		}
		return 0
	case sexpr.Float:
		y := b.(sexpr.Float)
		switch {
		case float64(x) < float64(y):
			return -1
		case float64(x) > float64(y):
			return 1
		}
		return 0
	case sexpr.Str:
		return strings.Compare(string(x), string(b.(sexpr.Str)))
	case sexpr.Keyword:
		return strings.Compare(string(x), string(b.(sexpr.Keyword)))
	case sexpr.Bytes:
		y := b.(sexpr.Bytes)
		if len(x) != len(y) {
			return len(x) - len(y)
		}
		for i := range x {
			if x[i] < y[i] {
				return -1
			}
			if x[i] > y[i] {
				return 1
			}
		}
		return 0
	}
	return 0
}

type opt struct {
	set bool
	v   sexpr.Expr
}

func some(v sexpr.Expr) opt { return opt{true, v} }
func none() opt             { return opt{} }

type interval struct {
	lo, hi         opt
	loOpen, hiOpen bool
}

func mergeIntervals(intervals []interval) []interval {
	if len(intervals) <= 1 {
		return intervals
	}
	sorted := append([]interval(nil), intervals...)
	sort.SliceStable(sorted, func(i, j int) bool {
		a, b := sorted[i], sorted[j]
		if !a.lo.set && !b.lo.set {
			return false
		}
		if !a.lo.set {
			return true
		}
		if !b.lo.set {
			return false
		}
		return cmpValueS(a.lo.v, b.lo.v) < 0
	})
	result := []interval{sorted[0]}
	for _, cur := range sorted[1:] {
		prev := result[len(result)-1]
		canMerge := false
		if !prev.hi.set {
			canMerge = true
		} else if cur.lo.set {
			if kindRank(cur.lo.v) != kindRank(prev.hi.v) {
				canMerge = false
			} else if cmpValueS(cur.lo.v, prev.hi.v) < 0 {
				canMerge = true
			} else if cmpValueS(cur.lo.v, prev.hi.v) == 0 {
				canMerge = !prev.hiOpen && !cur.loOpen
			}
		}
		if canMerge {
			var newHi opt
			newHiOpen := false
			switch {
			case !prev.hi.set:
				newHi = cur.hi
				newHiOpen = cur.hiOpen
			case !cur.hi.set:
				newHi = none()
				newHiOpen = false
			case cmpValueS(cur.hi.v, prev.hi.v) > 0:
				newHi = cur.hi
				newHiOpen = cur.hiOpen
			case cmpValueS(cur.hi.v, prev.hi.v) < 0:
				newHi = prev.hi
				newHiOpen = prev.hiOpen
			default:
				newHi = prev.hi
				newHiOpen = prev.hiOpen && cur.hiOpen
			}
			result[len(result)-1] = interval{
				lo: prev.lo, hi: newHi,
				loOpen: prev.loOpen, hiOpen: newHiOpen,
			}
		} else {
			result = append(result, cur)
		}
	}
	return result
}

func opsToIntervals(ops []opVal) []interval {
	var neqVals []sexpr.Expr
	var rangeOps []opVal
	var inVals []sexpr.Expr
	for _, o := range ops {
		switch o.op {
		case rangeOpNeq:
			neqVals = append(neqVals, o.val)
		case rangeOpIn:
			inVals = append(inVals, o.val)
		default:
			rangeOps = append(rangeOps, o)
		}
	}
	if len(inVals) > 0 && len(rangeOps) == 0 && len(neqVals) == 0 {
		sorted := append([]sexpr.Expr(nil), inVals...)
		sort.SliceStable(sorted, func(i, j int) bool { return cmpValueS(sorted[i], sorted[j]) < 0 })
		var result []interval
		for _, v := range sorted {
			result = append(result, interval{lo: some(v), hi: some(v)})
		}
		return mergeIntervals(result)
	}
	var lo, hi opt
	var loOpen, hiOpen bool
	for _, o := range rangeOps {
		switch o.op {
		case rangeOpGt, rangeOpGte:
			if !lo.set || cmpValueS(o.val, lo.v) > 0 || (cmpValueS(o.val, lo.v) == 0 && o.op == rangeOpGt) {
				lo = some(o.val)
				loOpen = o.op == rangeOpGt
			}
		case rangeOpLt, rangeOpLte:
			if !hi.set || cmpValueS(o.val, hi.v) < 0 || (cmpValueS(o.val, hi.v) == 0 && o.op == rangeOpLt) {
				hi = some(o.val)
				hiOpen = o.op == rangeOpLt
			}
		case rangeOpEq:
			lo = some(o.val)
			hi = some(o.val)
			loOpen, hiOpen = false, false
		}
	}
	if lo.set && hi.set && cmpValueS(lo.v, hi.v) > 0 {
		return nil
	}
	intervals := []interval{{lo: lo, hi: hi, loOpen: loOpen, hiOpen: hiOpen}}
	for _, nv := range neqVals {
		var newIntervals []interval
		for _, iv := range intervals {
			inRange := true
			if iv.lo.set {
				if iv.loOpen {
					if cmpValueS(nv, iv.lo.v) <= 0 {
						inRange = false
					}
				} else if cmpValueS(nv, iv.lo.v) < 0 {
					inRange = false
				}
			}
			if inRange && iv.hi.set {
				if iv.hiOpen {
					if cmpValueS(nv, iv.hi.v) >= 0 {
						inRange = false
					}
				} else if cmpValueS(nv, iv.hi.v) > 0 {
					inRange = false
				}
			}
			if !inRange {
				newIntervals = append(newIntervals, iv)
			} else {
				left := interval{lo: iv.lo, hi: some(nv), loOpen: iv.loOpen, hiOpen: true}
				right := interval{lo: some(nv), hi: iv.hi, loOpen: true, hiOpen: iv.hiOpen}
				newIntervals = append(newIntervals, left, right)
			}
		}
		intervals = newIntervals
	}
	return mergeIntervals(intervals)
}

type opVal struct {
	op  int32
	val sexpr.Expr
}

// ── evaluator frames ──────────────────────────────────────────────────────

type frameKind int

const (
	fkEval frameKind = iota
	fkWhenTest
	fkIfTest
	fkAndSeq
	fkOrSeq
	fkSetFrame
	fkWhile
)

type frame struct {
	kind   frameKind
	expr   sexpr.Expr
	wtBody []sexpr.Expr
	itThen []sexpr.Expr
	itElse []sexpr.Expr
	remain []sexpr.Expr
	sfName string
	wCond  sexpr.Expr
	wBody  []sexpr.Expr
	wPhase int
}

// YieldState holds the VM continuation stack.
type YieldState struct {
	stack   []frame
	started bool
}

// EvalError is a scheme evaluation error.
type EvalError string

func (e EvalError) Error() string { return string(e) }

var specialForms = map[string]bool{
	"when": true, "if": true, "begin": true, "set!": true,
	"print": true, "assert": true, "and": true, "or": true, "not": true,
	"scanner-iterate": true, "ranges-create": true, "while": true,
	"+": true, "-": true, "*": true, "/": true, "mod": true,
	"<": true, ">": true, "<=": true, ">=": true, "=": true, "!=": true,
	"min": true, "max": true, "abs": true,
}

func isSpecialForm(name string) bool { return specialForms[name] }

func sexprNumToF64(e sexpr.Expr) (float64, error) {
	switch v := e.(type) {
	case sexpr.Int:
		return float64(v), nil
	case sexpr.Float:
		return float64(v), nil
	}
	return 0, EvalError("expected number, got " + String(e))
}

func listItems(e sexpr.Expr) []sexpr.Expr {
	if l, ok := e.(sexpr.List); ok {
		return l
	}
	return nil
}

func processValue(value sexpr.Expr, state *YieldState, env *Environment, host HostFns) error {
	for len(state.stack) > 0 {
		if state.stack[len(state.stack)-1].kind == fkEval {
			return nil
		}
		fr := state.stack[len(state.stack)-1]
		state.stack = state.stack[:len(state.stack)-1]
		switch fr.kind {
		case fkWhenTest:
			if IsTruthy(value) {
				for i := len(fr.wtBody) - 1; i >= 0; i-- {
					state.stack = append(state.stack, frame{kind: fkEval, expr: fr.wtBody[i]})
				}
			} else {
				state.stack = append(state.stack, frame{kind: fkEval, expr: sexpr.Void{}})
			}
		case fkIfTest:
			body := fr.itElse
			if IsTruthy(value) {
				body = fr.itThen
			}
			if len(body) == 0 {
				state.stack = append(state.stack, frame{kind: fkEval, expr: sexpr.Void{}})
			} else {
				for i := len(body) - 1; i >= 0; i-- {
					state.stack = append(state.stack, frame{kind: fkEval, expr: body[i]})
				}
			}
		case fkSetFrame:
			env.Set(fr.sfName, value)
		case fkWhile:
			if fr.wPhase == 0 {
				if IsTruthy(value) {
					state.stack = append(state.stack, frame{kind: fkWhile, wCond: fr.wCond, wBody: fr.wBody, wPhase: 1})
					for i := len(fr.wBody) - 1; i >= 0; i-- {
						state.stack = append(state.stack, frame{kind: fkEval, expr: fr.wBody[i]})
					}
				}
				return nil
			}
			state.stack = append(state.stack, frame{kind: fkWhile, wCond: fr.wCond, wBody: fr.wBody, wPhase: 0})
			state.stack = append(state.stack, frame{kind: fkEval, expr: fr.wCond})
			return nil
		case fkAndSeq:
			if !IsTruthy(value) {
				state.stack = append(state.stack, frame{kind: fkEval, expr: sexpr.Bool(false)})
				return nil
			}
			if len(fr.remain) == 0 {
				state.stack = append(state.stack, frame{kind: fkEval, expr: value})
				return nil
			}
			next := fr.remain[0]
			rest := fr.remain[1:]
			state.stack = append(state.stack, frame{kind: fkAndSeq, remain: rest})
			state.stack = append(state.stack, frame{kind: fkEval, expr: next})
			return nil
		case fkOrSeq:
			if IsTruthy(value) {
				state.stack = append(state.stack, frame{kind: fkEval, expr: value})
				return nil
			}
			if len(fr.remain) == 0 {
				state.stack = append(state.stack, frame{kind: fkEval, expr: sexpr.Bool(false)})
				return nil
			}
			next := fr.remain[0]
			rest := fr.remain[1:]
			state.stack = append(state.stack, frame{kind: fkOrSeq, remain: rest})
			state.stack = append(state.stack, frame{kind: fkEval, expr: next})
			return nil
		}
	}
	return nil
}

func evalFully(expr sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	baseDepth := len(state.stack)
	step, err := evalExpr(expr, env, host, state)
	if err != nil {
		return EvalStep{}, err
	}
	if step.Yield {
		return step, nil
	}
	lastVal := step.Result
	for len(state.stack) > baseDepth {
		if err := processValue(lastVal, state, env, host); err != nil {
			return EvalStep{}, err
		}
		if len(state.stack) <= baseDepth {
			break
		}
		if state.stack[len(state.stack)-1].kind != fkEval {
			break
		}
		top := state.stack[len(state.stack)-1]
		state.stack = state.stack[:len(state.stack)-1]
		s2, err := evalExpr(top.expr, env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if s2.Yield {
			return s2, nil
		}
		lastVal = s2.Result
	}
	return done(lastVal), nil
}

// EvalWithYield resumes (or starts) evaluation, returning a yield or done.
func EvalWithYield(program Program, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	if !state.started {
		state.started = true
		state.stack = append(state.stack, frame{kind: fkEval, expr: program.Body})
	}
	for len(state.stack) > 0 {
		fr := state.stack[len(state.stack)-1]
		state.stack = state.stack[:len(state.stack)-1]
		if fr.kind == fkEval {
			step, err := evalExpr(fr.expr, env, host, state)
			if err != nil {
				return EvalStep{}, err
			}
			if step.Yield {
				return step, nil
			}
			if err := processValue(step.Result, state, env, host); err != nil {
				return EvalStep{}, err
			}
			if len(state.stack) == 0 {
				return done(step.Result), nil
			}
		} else {
			state.stack = append(state.stack, fr)
			if err := processValue(sexpr.Void{}, state, env, host); err != nil {
				return EvalStep{}, err
			}
		}
	}
	return done(sexpr.Void{}), nil
}

func evalNumArgs(args sexpr.Expr, env *Environment, host HostFns, state *YieldState,
	nums *[]float64, anyFloat *bool) (EvalStep, error) {
	items := listItems(args)
	for i := 1; i < len(items); i++ {
		v, err := evalFully(items[i], env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if v.Yield {
			return v, nil
		}
		if _, ok := v.Result.(sexpr.Float); ok {
			*anyFloat = true
		}
		n, err := sexprNumToF64(v.Result)
		if err != nil {
			return EvalStep{}, err
		}
		*nums = append(*nums, n)
	}
	return done(sexpr.Void{}), nil
}

func numResult(anyFloat bool, res float64) sexpr.Expr {
	if anyFloat {
		return sexpr.Float(res)
	}
	return sexpr.Int(int64(res))
}

func evalSpecialForm(name string, args sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	items := listItems(args)
	switch name {
	case "begin":
		for i := len(items) - 1; i >= 2; i-- {
			state.stack = append(state.stack, frame{kind: fkEval, expr: items[i]})
		}
		if len(items) >= 2 {
			return evalExpr(items[1], env, host, state)
		}
		return done(sexpr.Void{}), nil
	case "when":
		if len(items) < 2 {
			return EvalStep{}, EvalError("when: expected (when cond body...)")
		}
		body := append([]sexpr.Expr(nil), items[2:]...)
		state.stack = append(state.stack, frame{kind: fkWhenTest, wtBody: body})
		return evalExpr(items[1], env, host, state)
	case "if":
		if len(items) < 3 {
			return EvalStep{}, EvalError("if: expected (if cond then else...)")
		}
		elseBody := append([]sexpr.Expr(nil), items[3:]...)
		state.stack = append(state.stack, frame{kind: fkIfTest, itThen: []sexpr.Expr{items[2]}, itElse: elseBody})
		return evalExpr(items[1], env, host, state)
	case "set!":
		if len(items) < 3 {
			return EvalStep{}, EvalError("set!: expected (set! symbol value)")
		}
		sym, ok := items[1].(sexpr.Symbol)
		if !ok {
			return EvalStep{}, EvalError("set!: expected (set! symbol value)")
		}
		state.stack = append(state.stack, frame{kind: fkSetFrame, sfName: string(sym)})
		return evalExpr(items[2], env, host, state)
	case "print":
		for i := 1; i < len(items); i++ {
			v, err := evalFully(items[i], env, host, state)
			if err != nil {
				return EvalStep{}, err
			}
			if v.Yield {
				return v, nil
			}
			fmt.Fprintln(os.Stderr, String(v.Result))
		}
		return done(sexpr.Void{}), nil
	case "assert":
		if len(items) < 2 {
			return EvalStep{}, EvalError("assert: expected (assert expr [msg])")
		}
		v, err := evalFully(items[1], env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if v.Yield {
			return v, nil
		}
		if !IsTruthy(v.Result) {
			msg := "assertion failed"
			if len(items) > 2 {
				if s, ok := items[2].(sexpr.Str); ok {
					msg = string(s)
				}
			}
			return EvalStep{}, EvalError(msg)
		}
		return done(sexpr.Void{}), nil
	case "and":
		last := sexpr.Expr(sexpr.Bool(true))
		for i := 1; i < len(items); i++ {
			v, err := evalFully(items[i], env, host, state)
			if err != nil {
				return EvalStep{}, err
			}
			if v.Yield {
				return v, nil
			}
			if !IsTruthy(v.Result) {
				return done(sexpr.Bool(false)), nil
			}
			last = v.Result
		}
		return done(last), nil
	case "or":
		for i := 1; i < len(items); i++ {
			v, err := evalFully(items[i], env, host, state)
			if err != nil {
				return EvalStep{}, err
			}
			if v.Yield {
				return v, nil
			}
			if IsTruthy(v.Result) {
				return done(v.Result), nil
			}
		}
		return done(sexpr.Bool(false)), nil
	case "not":
		if len(items) < 2 {
			return EvalStep{}, EvalError("not: expected (not expr)")
		}
		v, err := evalFully(items[1], env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if v.Yield {
			return v, nil
		}
		return done(sexpr.Bool(!IsTruthy(v.Result))), nil
	case "scanner-iterate":
		return evalScannerIterate(items, env, host, state)
	case "ranges-create":
		return evalRangesCreate(items, env, host, state)
	case "while":
		if len(items) < 2 {
			return EvalStep{}, EvalError("while: expected (while cond body...)")
		}
		body := append([]sexpr.Expr(nil), items[2:]...)
		state.stack = append(state.stack, frame{kind: fkWhile, wCond: items[1], wBody: body, wPhase: 0})
		return evalExpr(items[1], env, host, state)
	case "+", "-", "*", "/", "mod", "<", ">", "<=", ">=", "=", "!=", "min", "max", "abs":
		return evalArith(name, items, env, host, state)
	}
	return EvalStep{}, EvalError("unknown special form: " + name)
}

func evalArith(name string, items []sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	var anyFloat bool
	var nums []float64
	s, err := evalNumArgs(sexpr.List(items), env, host, state, &nums, &anyFloat)
	if err != nil {
		return EvalStep{}, err
	}
	if s.Yield {
		return s, nil
	}
	switch name {
	case "+":
		res := 0.0
		for _, n := range nums {
			res += n
		}
		return done(numResult(anyFloat, res)), nil
	case "-":
		if len(nums) == 0 {
			return EvalStep{}, EvalError("-: expected at least one argument")
		}
		res := nums[0]
		if len(nums) == 1 {
			res = -res
		} else {
			for i := 1; i < len(nums); i++ {
				res -= nums[i]
			}
		}
		return done(numResult(anyFloat, res)), nil
	case "*":
		res := 1.0
		for _, n := range nums {
			res *= n
		}
		return done(numResult(anyFloat, res)), nil
	case "/":
		if len(nums) == 0 {
			return EvalStep{}, EvalError("/: expected at least one argument")
		}
		res := nums[0]
		for i := 1; i < len(nums); i++ {
			if nums[i] == 0.0 {
				return EvalStep{}, EvalError("division by zero")
			}
			res /= nums[i]
		}
		return done(sexpr.Float(res)), nil
	case "mod":
		if len(nums) < 2 || nums[1] == 0.0 {
			return EvalStep{}, EvalError("mod: division by zero")
		}
		return done(sexpr.Int(int64(nums[0]) % int64(nums[1]))), nil
	case "<":
		for i := 1; i < len(nums); i++ {
			if nums[i-1] >= nums[i] {
				return done(sexpr.Bool(false)), nil
			}
		}
		return done(sexpr.Bool(true)), nil
	case ">":
		for i := 1; i < len(nums); i++ {
			if nums[i-1] <= nums[i] {
				return done(sexpr.Bool(false)), nil
			}
		}
		return done(sexpr.Bool(true)), nil
	case "<=":
		for i := 1; i < len(nums); i++ {
			if nums[i-1] > nums[i] {
				return done(sexpr.Bool(false)), nil
			}
		}
		return done(sexpr.Bool(true)), nil
	case ">=":
		for i := 1; i < len(nums); i++ {
			if nums[i-1] < nums[i] {
				return done(sexpr.Bool(false)), nil
			}
		}
		return done(sexpr.Bool(true)), nil
	case "=":
		for i := 1; i < len(nums); i++ {
			if nums[i-1] != nums[i] {
				return done(sexpr.Bool(false)), nil
			}
		}
		return done(sexpr.Bool(true)), nil
	case "!=":
		if len(nums) < 2 {
			return done(sexpr.Bool(false)), nil
		}
		return done(sexpr.Bool(nums[0] != nums[1])), nil
	case "min":
		best := nums[0]
		for i := 1; i < len(nums); i++ {
			if nums[i] < best {
				best = nums[i]
			}
		}
		return done(numResult(anyFloat, best)), nil
	case "max":
		best := nums[0]
		for i := 1; i < len(nums); i++ {
			if nums[i] > best {
				best = nums[i]
			}
		}
		return done(numResult(anyFloat, best)), nil
	case "abs":
		if len(nums) == 0 {
			return EvalStep{}, EvalError("abs: expected one argument")
		}
		if anyFloat {
			return done(sexpr.Float(absF(nums[0]))), nil
		}
		return done(sexpr.Int(int64(absF(nums[0])))), nil
	}
	return EvalStep{}, EvalError("unknown arithmetic op: " + name)
}

func absF(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

func evalScannerIterate(items []sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	if len(items) < 4 {
		return EvalStep{}, EvalError("scanner-iterate: expected (scanner-iterate scanners (param) [:ranges r] body...+)")
	}
	se := items[1]
	var scannerExprs []sexpr.Expr
	if l, ok := se.(sexpr.List); ok && len(l) > 0 {
		scannerExprs = l
	} else {
		scannerExprs = []sexpr.Expr{se}
	}
	paramsList, ok := items[2].(sexpr.List)
	if !ok || len(paramsList) == 0 {
		return EvalStep{}, EvalError("scanner-iterate: expected (param) — non-empty list of symbols")
	}
	paramName, ok := paramsList[0].(sexpr.Symbol)
	if !ok {
		return EvalStep{}, EvalError("scanner-iterate: expected (param) — non-empty list of symbols")
	}
	var rangesExpr sexpr.Expr
	var body []sexpr.Expr
	i := 3
	for i < len(items) {
		it := items[i]
		if s, ok := it.(sexpr.Symbol); ok && string(s) == ":ranges" {
			if rangesExpr != nil {
				return EvalStep{}, EvalError("scanner-iterate: :ranges specified more than once")
			}
			if i+1 >= len(items) {
				return EvalStep{}, EvalError("scanner-iterate: :ranges requires a value")
			}
			rangesExpr = items[i+1]
			i += 2
			continue
		}
		body = append(body, it)
		i++
	}
	if len(body) == 0 {
		return EvalStep{}, EvalError("scanner-iterate: missing body")
	}
	var rangesVal sexpr.Expr = sexpr.List{}
	if rangesExpr != nil {
		rs, err := evalExpr(rangesExpr, env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if rs.Yield {
			return rs, nil
		}
		rangesVal = rs.Result
	}
	var scannerVals []sexpr.Expr
	for _, e := range scannerExprs {
		sv, err := evalExpr(e, env, host, state)
		if err != nil {
			return EvalStep{}, err
		}
		if sv.Yield {
			return sv, nil
		}
		scannerVals = append(scannerVals, sv.Result)
	}
	initArgs := append(append([]sexpr.Expr{}, scannerVals...), rangesVal)
	iterStep, err := host.Call("scanner-iterate-init", initArgs)
	if err != nil {
		return EvalStep{}, err
	}
	if iterStep.Yield {
		return iterStep, nil
	}
	if _, isVoid := iterStep.Result.(sexpr.Void); isVoid {
		return done(sexpr.Void{}), nil
	}
	iterRes := iterStep.Result
	condExpr := sexpr.List{sexpr.Symbol("set!"), sexpr.Symbol(string(paramName)),
		sexpr.List{sexpr.Symbol("scanner-iterate-next"), iterRes}}
	state.stack = append(state.stack, frame{kind: fkWhile, wCond: condExpr, wBody: body, wPhase: 0})
	state.stack = append(state.stack, frame{kind: fkEval, expr: condExpr})
	return done(sexpr.Void{}), nil
}

var rangeOpMap = map[string]int32{
	"=": rangeOpEq, "!=": rangeOpNeq, ">": rangeOpGt, ">=": rangeOpGte,
	"<": rangeOpLt, "<=": rangeOpLte, "in": rangeOpIn,
}

func evalRangesCreate(items []sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	var inner sexpr.Expr = sexpr.List{}
	if len(items) >= 2 {
		inner = items[1]
	}
	var flat []sexpr.Expr
	var walk func(se sexpr.Expr) error
	walk = func(se sexpr.Expr) error {
		l, ok := se.(sexpr.List)
		if !ok || len(l) == 0 {
			return nil
		}
		head := l[0]
		headName := ""
		switch h := head.(type) {
		case sexpr.Keyword:
			headName = string(h)
		case sexpr.Symbol:
			headName = string(h)
		}
		switch {
		case headName == "and":
			for i := 1; i < len(l); i++ {
				if err := walk(l[i]); err != nil {
					return err
				}
			}
		case headName == "or":
			for i := 1; i < len(l); i++ {
				flat = append(flat, sexpr.List{sexpr.Keyword("branch")})
				if err := walk(l[i]); err != nil {
					return err
				}
			}
		default:
			if headName == "in" {
				for idx := 1; idx < len(l); idx++ {
					step, err := evalExpr(l[idx], env, host, state)
					if err != nil {
						return err
					}
					if step.Yield {
						return EvalError("ranges-create: value expression yielded unexpectedly")
					}
					flat = append(flat, sexpr.List{sexpr.Int(int64(rangeOpIn)), step.Result})
				}
			} else if op, ok := rangeOpMap[headName]; ok && len(l) >= 2 {
				step, err := evalExpr(l[1], env, host, state)
				if err != nil {
					return err
				}
				if step.Yield {
					return EvalError("ranges-create: value expression yielded unexpectedly")
				}
				flat = append(flat, sexpr.List{sexpr.Int(int64(op)), step.Result})
			}
		}
		return nil
	}
	if err := walk(inner); err != nil {
		return EvalStep{}, err
	}
	branches := [][]opVal{{}}
	for _, item := range flat {
		il, ok := item.(sexpr.List)
		if !ok {
			continue
		}
		if len(il) == 1 {
			if k, ok := il[0].(sexpr.Keyword); ok && string(k) == "branch" {
				branches = append(branches, []opVal{})
				continue
			}
		}
		if len(il) >= 2 {
			if opInt, ok := il[0].(sexpr.Int); ok {
				branches[len(branches)-1] = append(branches[len(branches)-1],
					opVal{op: int32(opInt), val: il[1]})
			}
		}
	}
	if len(branches) == 1 && len(branches[0]) == 0 {
		return done(sexpr.List{}), nil
	}
	var nonEmpty [][]opVal
	for _, b := range branches {
		if len(b) > 0 {
			nonEmpty = append(nonEmpty, b)
		}
	}
	if len(nonEmpty) == 0 {
		return done(sexpr.List{}), nil
	}
	var allIntervals []interval
	for _, b := range nonEmpty {
		allIntervals = append(allIntervals, opsToIntervals(b)...)
	}
	merged := mergeIntervals(allIntervals)
	if len(merged) == 0 {
		return done(sexpr.List{sexpr.List{sexpr.Void{}, sexpr.Void{}, sexpr.Int(-1)}}), nil
	}
	out := make([]sexpr.Expr, 0, len(merged))
	for _, iv := range merged {
		var loB, hiB sexpr.Expr = sexpr.Void{}, sexpr.Void{}
		if iv.lo.set {
			loB = sexpr.Bytes(encodeSExprBytes(iv.lo.v))
		}
		if iv.hi.set {
			hiB = sexpr.Bytes(encodeSExprBytes(iv.hi.v))
		}
		var flags int32
		if iv.loOpen {
			flags |= rangeLoOpen
		}
		if iv.hiOpen {
			flags |= rangeHiOpen
		}
		out = append(out, sexpr.List{loB, hiB, sexpr.Int(int64(flags))})
	}
	return done(sexpr.List(out)), nil
}

func evalExpr(expr sexpr.Expr, env *Environment, host HostFns, state *YieldState) (EvalStep, error) {
	switch e := expr.(type) {
	case nil, sexpr.Void, sexpr.Bool, sexpr.Int, sexpr.Float, sexpr.Str, sexpr.Keyword, sexpr.Bytes, sexpr.Resource:
		return done(e), nil
	case sexpr.Symbol:
		if v, ok := env.Get(string(e)); ok {
			return done(v), nil
		}
		return EvalStep{}, EvalError("unbound: " + string(e))
	case sexpr.List:
		if len(e) == 0 {
			return done(sexpr.Void{}), nil
		}
		switch first := e[0].(type) {
		case sexpr.Keyword:
			name := string(first)
			if isSpecialForm(name) {
				return evalSpecialForm(name, e, env, host, state)
			}
			var args []sexpr.Expr
			for i := 1; i < len(e); i++ {
				argStep, err := evalFully(e[i], env, host, state)
				if err != nil {
					return EvalStep{}, err
				}
				if argStep.Yield {
					return argStep, nil
				}
				args = append(args, argStep.Result)
			}
			if host == nil {
				return EvalStep{}, EvalError("unknown host function: " + name)
			}
			return host.Call(name, args)
		case sexpr.Symbol:
			return EvalStep{}, EvalError("legacy scheme form rejected — programs are EDN vectors with keyword opcodes: [" + string(first) + " ...]")
		}
		return EvalStep{}, EvalError("cannot apply non-keyword as function")
	}
	return done(sexpr.Void{}), nil
}

// ── batch + streaming ─────────────────────────────────────────────────────

// Eval evaluates a program to completion (no yields).
func Eval(program Program, env *Environment, host HostFns) (sexpr.Expr, error) {
	var state YieldState
	step, err := EvalWithYield(program, env, host, &state)
	if err != nil {
		return nil, err
	}
	if !step.Yield {
		return step.Result, nil
	}
	return nil, errors.New("unexpected yield in batch eval")
}

// VmSession is a streaming VM with yield/resume.
type VmSession struct {
	Program Program
	Env     *Environment
	state   YieldState
	Done    bool
}

// NewVmSession creates a streaming session.
func NewVmSession(program Program) *VmSession {
	return &VmSession{Program: program, Env: NewEnvironment()}
}

// NextBatch returns up to maxRows rows and whether more remain.  It runs the
// program until it has maxRows rows or finishes (like the Nim VM) — the
// caller serializes it with other engine work, so no soft-yield is needed.
func (s *VmSession) NextBatch(host HostFns, maxRows int) ([][]sexpr.Expr, bool, error) {
	if s.Done || maxRows == 0 {
		return nil, false, nil
	}
	var rows [][]sexpr.Expr
	for len(rows) < maxRows {
		step, err := EvalWithYield(s.Program, s.Env, host, &s.state)
		if err != nil {
			return nil, false, err
		}
		if step.Yield {
			if l, ok := step.Result.(sexpr.List); ok {
				rows = append(rows, l)
			}
			continue
		}
		s.Done = true
		return rows, false, nil
	}
	return rows, true, nil
}

// CmpValue is the total ordering used by the query engine (same as the
// internal value comparison used by ranges).
func CmpValue(a, b sexpr.Expr) int { return cmpValueS(a, b) }

// WriteSchemePretty renders a program like nim_scheme's writeSchemePretty.
func WriteSchemePretty(p Program) string {
	const maxWidth = 100
	var b strings.Builder
	var writeExpr func(e sexpr.Expr, indent int) int
	writeExpr = func(e sexpr.Expr, indent int) int {
		if l, ok := e.(sexpr.List); ok {
			if len(l) == 0 {
				b.WriteString("()")
				return indent + 2
			}
			compact := String(e)
			if indent+len(compact) <= maxWidth {
				b.WriteString(compact)
				return indent + len(compact)
			}
			b.WriteString("(")
			col := indent + 1
			first := true
			childIndent := indent + 2
			for _, item := range l {
				if first {
					first = false
				} else {
					b.WriteString("\n")
					b.WriteString(strings.Repeat(" ", childIndent))
					col = childIndent
				}
				col = writeExpr(item, childIndent)
			}
			b.WriteString(")")
			return col + 1
		}
		s := String(e)
		b.WriteString(s)
		return indent + len(s)
	}
	writeExpr(p.Body, 0)
	return b.String()
}
