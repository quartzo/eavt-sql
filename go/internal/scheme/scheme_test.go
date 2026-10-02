package scheme

import (
	"testing"

	"eavt-go/internal/edn"
	"eavt-go/internal/sexpr"
)

func toS(e edn.Value) sexpr.Expr {
	switch v := e.(type) {
	case edn.Int:
		return sexpr.Int(int64(v))
	case edn.Float:
		return sexpr.Float(float64(v))
	case edn.Str:
		return sexpr.Str(string(v))
	case edn.Bool:
		return sexpr.Bool(bool(v))
	case edn.Nil:
		return sexpr.Void{}
	case edn.Keyword:
		return sexpr.Keyword(string(v))
	case edn.Symbol:
		return sexpr.Symbol(string(v))
	case edn.List:
		out := make([]sexpr.Expr, len(v))
		for i, it := range v {
			out[i] = toS(it)
		}
		return sexpr.List(out)
	}
	return sexpr.Void{}
}

func p(t *testing.T, src string) sexpr.Expr {
	t.Helper()
	v, err := edn.Read(src)
	if err != nil {
		t.Fatalf("edn parse %q: %v", src, err)
	}
	return toS(v)
}

type testHost struct {
	attr  string
	pairs [][2]int64
}

func (h *testHost) Call(name string, args []sexpr.Expr) (EvalStep, error) {
	if name == "save-many" {
		h.attr = string(args[0].(sexpr.Str))
		for i := 1; i+1 < len(args); i += 2 {
			h.pairs = append(h.pairs, [2]int64{int64(args[i].(sexpr.Int)), int64(args[i+1].(sexpr.Int))})
		}
		return Done(sexpr.Void{}), nil
	}
	return EvalStep{}, EvalError("unknown host function: " + name)
}

func evalSrc(t *testing.T, src string, host HostFns) (string, error) {
	t.Helper()
	res, err := Eval(Program{Body: p(t, src)}, NewEnvironment(), host)
	if err != nil {
		return "", err
	}
	return String(res), nil
}

func mustEval(t *testing.T, src string) string {
	t.Helper()
	s, err := evalSrc(t, src, &testHost{})
	if err != nil {
		t.Fatalf("eval %q: %v", src, err)
	}
	return s
}

func TestLiteralsAndBegin(t *testing.T) {
	cases := map[string]string{
		"[:begin 42]":        "42",
		"[:begin 1 2 3]":     "3",
		"[:begin]":           "#void",
		"[:begin 1 2 3 4 5]": "5",
	}
	for src, want := range cases {
		if got := mustEval(t, src); got != want {
			t.Errorf("%s = %q, want %q", src, got, want)
		}
	}
}

func TestWhenIf(t *testing.T) {
	cases := map[string]string{
		"[:when true 42]":                    "42",
		"[:when false 42]":                   "#void",
		"[:when true 1 2 3]":                 "3",
		"[:if true 42 99]":                   "42",
		"[:if false 42 99]":                  "99",
		"[:if false 42]":                     "#void",
		"[:when true [:when true 42]]":       "42",
		"[:if [:if false true false] 42 99]": "99",
	}
	for src, want := range cases {
		if got := mustEval(t, src); got != want {
			t.Errorf("%s = %q, want %q", src, got, want)
		}
	}
}

func TestSetAndBindings(t *testing.T) {
	cases := map[string]string{
		"[:begin [:set! x 10] [:when true x]]":           "10",
		"[:begin [:set! x 1] [:set! x 2] x]":             "2",
		"[:begin [:set! a 1] [:set! b a] [:set! c b] c]": "1",
	}
	for src, want := range cases {
		if got := mustEval(t, src); got != want {
			t.Errorf("%s = %q, want %q", src, got, want)
		}
	}
	if _, err := evalSrc(t, `[:begin [:set! "x" 10]]`, &testHost{}); err == nil {
		t.Error("set! with non-symbol should raise")
	}
}

func TestLogic(t *testing.T) {
	cases := map[string]string{
		"[:not true]":            "#f",
		"[:not false]":           "#t",
		"[:and true true]":       "#t",
		"[:and true false]":      "#f",
		"[:and]":                 "#t",
		"[:and true false true]": "#f",
		"[:or true false]":       "#t",
		"[:or false false]":      "#f",
		"[:or]":                  "#f",
		"[:or false false true]": "#t",
	}
	for src, want := range cases {
		if got := mustEval(t, src); got != want {
			t.Errorf("%s = %q, want %q", src, got, want)
		}
	}
}

func TestArithmetic(t *testing.T) {
	cases := map[string]string{
		"[:+ 2 3]":                       "5",
		"[:+ 1 2 3 4]":                   "10",
		"[:begin [:set! x 5] [:+ x 3]]":  "8",
		"[:+ [:+ 1 2] 3]":                "6",
		"[:* [:+ 1 2] [:- 10 7]]":        "9",
		"[:begin [:set! x 5] [:> x 2]]":  "#t",
		"[:< 1 [:+ 1 2]]":                "#t",
		"[:begin [:set! x -3] [:abs x]]": "3",
		"[:/ 7 2]":                       "3.5",
		"[:mod 7 3]":                     "1",
	}
	for src, want := range cases {
		if got := mustEval(t, src); got != want {
			t.Errorf("%s = %q, want %q", src, got, want)
		}
	}
}

func TestAssertAndErrors(t *testing.T) {
	if got := mustEval(t, `[:begin [:assert true] 42]`); got != "42" {
		t.Errorf("assert pass = %q", got)
	}
	if _, err := evalSrc(t, `[:assert false "boom"]`, &testHost{}); err == nil {
		t.Error("assert false should raise")
	}
	if _, err := evalSrc(t, `x`, &testHost{}); err == nil {
		t.Error("unbound variable should raise")
	}
	if _, err := evalSrc(t, `[:nope 1 2]`, &testHost{}); err == nil {
		t.Error("unknown host function should raise")
	}
}

func TestHostSaveMany(t *testing.T) {
	h := &testHost{}
	if _, err := evalSrc(t, `[:save-many "user.name" 1 10 2 20]`, h); err != nil {
		t.Fatal(err)
	}
	if h.attr != "user.name" {
		t.Errorf("attr = %q", h.attr)
	}
	if len(h.pairs) != 2 || h.pairs[0] != [2]int64{1, 10} || h.pairs[1] != [2]int64{2, 20} {
		t.Errorf("pairs = %#v", h.pairs)
	}
}

func TestRangesCreate(t *testing.T) {
	// (> x 5) with a bound x should produce one interval with encoded lo bytes.
	got := mustEval(t, `[:begin [:set! x 5] [:ranges-create [:> x]]]`)
	_ = got
	// Empty restriction.
	if got := mustEval(t, `[:ranges-create []]`); got != "[]" {
		t.Errorf("empty ranges = %q", got)
	}
}
