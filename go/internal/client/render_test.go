package client

import (
	"math"
	"os"
	"strconv"
	"strings"
	"testing"

	"eavt-go/internal/msgpack"
)

func TestValueStringScalars(t *testing.T) {
	cases := []struct {
		v    msgpack.Value
		want string
	}{
		{msgpack.Str("hello"), "hello"},
		{msgpack.Int(42), "42"},
		{msgpack.Int(-1), "-1"},
		{msgpack.Bool(true), "true"},
		{msgpack.Bool(false), "false"},
		{msgpack.Nil{}, "null"},
	}
	for _, c := range cases {
		if got := ValueString(c.v); got != c.want {
			t.Errorf("ValueString(%#v) = %q, want %q", c.v, got, c.want)
		}
	}
}

// TestFloatGolden compares FloatString against vectors emitted by Nim's
// `$float` (dragonbox + formatDigits), see testdata/gen_floats.nim.
func TestFloatGolden(t *testing.T) {
	data, err := os.ReadFile("../../testdata/golden/floats.txt")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			t.Fatalf("bad golden line %q", line)
		}
		bits, err := strconv.ParseUint(parts[0], 16, 64)
		if err != nil {
			t.Fatalf("bad bit pattern %q: %v", parts[0], err)
		}
		f := math.Float64frombits(bits)
		if got := FloatString(f); got != parts[1] {
			t.Errorf("FloatString(%s) = %q, want %q", parts[0], got, parts[1])
		}
	}
}

func TestValueStringBinExt(t *testing.T) {
	got := ValueString(msgpack.Bin([]byte{0x00, 0xff, 0x01}))
	want := `{"type":"bin","len":3,"data":"AP8B"}`
	if got != want {
		t.Errorf("bin = %q, want %q", got, want)
	}
	got = ValueString(msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte("person/name")})
	want = `{"type":"ext","len":11,"exttype":6,"data":"cGVyc29uL25hbWU="}`
	if got != want {
		t.Errorf("ext = %q, want %q", got, want)
	}
}

func TestValueStringArrays(t *testing.T) {
	bytesArr := msgpack.Array{msgpack.Int(65), msgpack.Int(66)}
	if got := ValueString(bytesArr); got != "AB" {
		t.Errorf("int array = %q, want %q", got, "AB")
	}
	strArr := msgpack.Array{msgpack.Str("a"), msgpack.Str("b")}
	if got := ValueString(strArr); got != `["a","b"]` {
		t.Errorf("str array = %q", got)
	}
}
