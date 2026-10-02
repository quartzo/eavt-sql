package front

import (
	"testing"

	"eavt-go/internal/msgpack"
)

// TestBuildSchemeLocal guards the request shape sent to the back: a valid
// msgpack map with exactly the five expected fields, and the compiled
// program embedded raw (not as a byte string).
func TestBuildSchemeLocal(t *testing.T) {
	progWire := msgpack.Marshal(msgpack.Int(42))
	frame := buildSchemeLocal(progWire,
		[]msgpack.Value{msgpack.Str("p1")}, []string{"c1", "c2"})

	v, err := msgpack.Unmarshal(frame)
	if err != nil {
		t.Fatalf("frame is not valid msgpack: %v", err)
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		t.Fatalf("frame is not a map: %T", v)
	}
	if len(m) != 5 {
		t.Fatalf("map has %d pairs, want 5", len(m))
	}
	if got := memberStr(m, "type"); got != "scheme-local" {
		t.Errorf("type = %q", got)
	}
	if got := memberStr(m, "mode"); got != "query" {
		t.Errorf("mode = %q", got)
	}
	prog, ok := msgpack.Member(m, msgpack.Str("program"))
	if !ok {
		t.Fatal("missing program")
	}
	if i, ok := prog.(msgpack.Int); !ok || i != 42 {
		t.Errorf("program = %#v, want Int(42)", prog)
	}
	if params := memberArray(m, "params"); len(params) != 1 || params[0] != msgpack.Str("p1") {
		t.Errorf("params = %#v", params)
	}
}
