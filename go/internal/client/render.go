package client

import (
	"encoding/base64"
	"encoding/json"
	"strconv"
	"strings"

	"eavt-go/internal/msgpack"
	"eavt-go/internal/numfmt"
)

// ValueString renders a row value the way the Nim REPL does: it mirrors
// msgpack2json.toJsonNode + parseValue.  Strings/ints/floats/bools/nil render
// plainly; msgpack bin and ext become the JSON wrappers; an all-int array is
// decoded as raw bytes.
func ValueString(v msgpack.Value) string {
	switch x := v.(type) {
	case msgpack.Str:
		return string(x)
	case msgpack.Bin:
		return binStr(x)
	case msgpack.Ext:
		return extStr(x)
	case msgpack.Int:
		return strconv.FormatInt(int64(x), 10)
	case msgpack.Float:
		return FloatString(float64(x))
	case msgpack.Bool:
		if x {
			return "true"
		}
		return "false"
	case msgpack.Nil, nil:
		return "null"
	case msgpack.Array:
		if len(x) > 0 && allInts(x) {
			b := make([]byte, len(x))
			for i, e := range x {
				b[i] = byte(int64(e.(msgpack.Int)))
			}
			return string(b)
		}
		return "[" + strings.Join(mapValues(x, valueJSON), ",") + "]"
	case msgpack.Map:
		parts := make([]string, 0, len(x))
		for _, p := range x {
			parts = append(parts, valueJSON(p.Key)+":"+valueJSON(p.Value))
		}
		return "{" + strings.Join(parts, ",") + "}"
	}
	return "null"
}

func allInts(xs []msgpack.Value) bool {
	for _, e := range xs {
		if _, ok := e.(msgpack.Int); !ok {
			return false
		}
	}
	return true
}

func mapValues(xs []msgpack.Value, f func(msgpack.Value) string) []string {
	out := make([]string, len(xs))
	for i, e := range xs {
		out[i] = f(e)
	}
	return out
}

// valueJSON is used for nested container/map values; strings are JSON-quoted.
func valueJSON(v msgpack.Value) string {
	if s, ok := v.(msgpack.Str); ok {
		b, _ := json.Marshal(string(s))
		return string(b)
	}
	return ValueString(v)
}

func binStr(b []byte) string {
	return `{"type":"bin","len":` + strconv.Itoa(len(b)) +
		`,"data":"` + base64.StdEncoding.EncodeToString(b) + `"}`
}

func extStr(e msgpack.Ext) string {
	return `{"type":"ext","len":` + strconv.Itoa(len(e.Data)) +
		`,"exttype":` + strconv.Itoa(e.Type) +
		`,"data":"` + base64.StdEncoding.EncodeToString(e.Data) + `"}`
}

// FloatString reproduces Nim's $float (delegates to internal/numfmt).
func FloatString(f float64) string { return numfmt.FloatString(f) }
