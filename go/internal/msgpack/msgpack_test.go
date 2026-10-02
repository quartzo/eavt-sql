package msgpack

import (
	"bytes"
	"errors"
	"math"
	"reflect"
	"testing"
)

func rt(t *testing.T, v Value) Value {
	t.Helper()
	b := Marshal(v)
	got, err := Unmarshal(b)
	if err != nil {
		t.Fatalf("Unmarshal(% x): %v", b, err)
	}
	return got
}

func TestRoundTripScalars(t *testing.T) {
	cases := []Value{
		Int(0), Int(127), Int(-32), Int(128), Int(-33), Int(255),
		Int(65536), Int(math.MaxInt64), Int(math.MinInt64),
		Float(1.5), Str("hello"), Str(""), Str(string(make([]byte, 300))),
		Bool(true), Bool(false), Nil{},
		Bin([]byte{0x00, 0xff, 0x01}),
	}
	for _, c := range cases {
		if got := rt(t, c); !reflect.DeepEqual(got, c) {
			t.Errorf("roundtrip %#v = %#v", c, got)
		}
	}
}

func TestRoundTripContainers(t *testing.T) {
	v := Map{
		{Key: Str("type"), Value: Str("scheme")},
		{Key: Int(1), Value: Array{Int(2), Nil{}, Str("x")}},
		{Key: Bool(true), Value: Bin([]byte("raw"))},
	}
	if got := rt(t, v); !reflect.DeepEqual(got, v) {
		t.Errorf("roundtrip = %#v", got)
	}
}

func TestExtSymbolKeyword(t *testing.T) {
	for _, e := range []Ext{
		{Type: ExtSymbol, Data: []byte("?e")},
		{Type: ExtKeyword, Data: []byte("person/name")},
	} {
		if got := rt(t, e); !reflect.DeepEqual(got, e) {
			t.Errorf("ext roundtrip = %#v", got)
		}
	}
}

func TestFixextWidths(t *testing.T) {
	// msgpack4nim compat: payload lengths 1/2/4/8/16 use fixext 0xd4..0xd8.
	want := map[int]byte{1: 0xd4, 2: 0xd5, 4: 0xd6, 8: 0xd7, 16: 0xd8}
	for n, code := range want {
		b := Marshal(Ext{Type: ExtKeyword, Data: bytes.Repeat([]byte("a"), n)})
		if b[0] != code {
			t.Errorf("len %d: header 0x%02x, want 0x%02x", n, b[0], code)
		}
		if got := rt(t, Ext{Type: ExtKeyword, Data: bytes.Repeat([]byte("a"), n)}); !reflect.DeepEqual(
			got, Ext{Type: ExtKeyword, Data: bytes.Repeat([]byte("a"), n)}) {
			t.Errorf("len %d roundtrip failed", n)
		}
	}
	// 3 bytes is not a fixext width -> ext8 (0xc7).
	b := Marshal(Ext{Type: ExtSymbol, Data: []byte("abc")})
	if b[0] != 0xc7 {
		t.Errorf("len 3: header 0x%02x, want 0xc7", b[0])
	}
}

func TestDecodeFailLoud(t *testing.T) {
	// Truncated string body.
	full := Marshal(Str("abcdef"))
	if _, err := Unmarshal(full[:5]); !errors.Is(err, Err) {
		t.Errorf("truncated: got %v, want Err", err)
	}
	// Unknown format byte 0xc1 (never used).
	if _, err := Unmarshal([]byte{0xc1}); !errors.Is(err, Err) {
		t.Errorf("unknown byte: got %v, want Err", err)
	}
	// Trailing content after a complete value.
	if _, err := Unmarshal(append(Marshal(Int(1)), 0x00)); !errors.Is(err, Err) {
		t.Errorf("trailing: got %v, want Err", err)
	}
}

func TestMember(t *testing.T) {
	m := Map{
		{Key: Str("rows"), Value: Array{}},
		{Key: Str("more"), Value: Bool(false)},
		{Key: Int(7), Value: Str("seven")},
	}
	if v, ok := Member(m, Str("more")); !ok || v != Bool(false) {
		t.Errorf("member more = %#v %v", v, ok)
	}
	if v, ok := Member(m, Int(7)); !ok || v != Str("seven") {
		t.Errorf("member int key = %#v %v", v, ok)
	}
	if _, ok := Member(m, Str("missing")); ok {
		t.Errorf("member missing should be false")
	}
}
