package sexpr

import (
	"bytes"
	"reflect"
	"testing"

	"eavt-go/internal/msgpack"
)

func TestWireRoundTrip(t *testing.T) {
	prog := List{
		Keyword("begin"),
		List{Symbol("set!"), Symbol("x"), Int(5)},
		List{Keyword("while"), Bool(true), Str("body")},
		Float(1.5), Void{}, Bytes([]byte{0, 1, 2}),
	}
	wire := ToWire(prog)
	got, err := UnmarshalWire(wire)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, prog) {
		t.Fatalf("roundtrip = %#v", got)
	}
}

func TestUnmarshalWireRejectsMap(t *testing.T) {
	wire := msgpack.Marshal(msgpack.Map{{Key: msgpack.Str("k"), Value: msgpack.Int(1)}})
	if _, err := UnmarshalWire(wire); err == nil {
		t.Fatal("maps should be rejected")
	}
}

func TestUnmarshalWireRejectsUnknownExt(t *testing.T) {
	wire := msgpack.Marshal(msgpack.Ext{Type: 99, Data: []byte("x")})
	if _, err := UnmarshalWire(wire); err == nil {
		t.Fatal("unknown ext type should be rejected")
	}
}

func TestUnmarshalWireDepth(t *testing.T) {
	// Build a nested array deeper than MaxWireDepth.
	deep := Expr(Int(1))
	for i := 0; i < MaxWireDepth+2; i++ {
		deep = List{deep}
	}
	if _, err := UnmarshalWire(ToWire(deep)); err == nil {
		t.Fatal("deep nesting should be rejected")
	}
}

func TestBytesEncodesAsBin(t *testing.T) {
	wire := ToWire(Bytes([]byte{0xff, 0x00}))
	if !bytes.HasPrefix(wire, []byte{0xc4}) {
		t.Fatalf("bytes should encode as bin, got % x", wire)
	}
}
