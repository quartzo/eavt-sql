package eavt

import (
	"testing"

	"eavt-go/internal/kvstore"
	"eavt-go/internal/sexpr"
)

func newKV(t *testing.T) *kvstore.KVStore {
	t.Helper()
	kv, err := kvstore.New(kvstore.Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kv.Close() })
	return kv
}

func TestEncodeIntRoundTrip(t *testing.T) {
	for _, n := range []int64{0, 1, -1, 42, -42, 1 << 40, -(1 << 40)} {
		if got := DecodeInt64(beUint64Test(EncodeInt(n))); got != n {
			t.Errorf("int %d roundtrip = %d", n, got)
		}
	}
}

func beUint64Test(b []byte) uint64 { return BeUint64(b, 0) }

func TestEncodeFloatRoundTrip(t *testing.T) {
	for _, f := range []float64{0, 1.5, -1.5, 1e-4, 1e16, -3.25} {
		if got := DecodeFloat64(BeUint64(EncodeFloat(f), 0)); got != f {
			t.Errorf("float %v roundtrip = %v", f, got)
		}
	}
}

func TestVariableRoundTrip(t *testing.T) {
	for _, s := range []string{"", "a", "person/name", "0123456789abcdef", "with nuls"} {
		enc := EncodeVariable(s)
		if got := DecodeVariableStr(enc, 0); got != s {
			t.Errorf("variable %q roundtrip = %q", s, got)
		}
	}
}

func TestBuildEntriesShape(t *testing.T) {
	// Non-ref indexed: CF 0,1,2.
	got := BuildEavtEntries(1, 3, EncodeVariable("x"), 1, false, EmVariable, true)
	var cfs []uint8
	for _, e := range got {
		cfs = append(cfs, e.CF)
	}
	if len(cfs) != 3 || cfs[0] != 0 || cfs[1] != 1 || cfs[2] != 2 {
		t.Fatalf("cf shape = %v", cfs)
	}
	// Ref: CF 0,1,3 (+2 when indexed).
	got = BuildEavtEntries(1, 3, EncodeEid(9), 1, false, EmRef, true)
	cfs = nil
	for _, e := range got {
		cfs = append(cfs, e.CF)
	}
	if len(cfs) != 4 {
		t.Fatalf("ref cf shape = %v", cfs)
	}
}

func TestDecodeStoredValue(t *testing.T) {
	if v := DecodeStoredValue(EncodeInt(7), DbTypeLong); v != sexpr.Int(7) {
		t.Errorf("long = %#v", v)
	}
	if v := DecodeStoredValue(EncodeVariable("hi"), DbTypeString); v != sexpr.Str("hi") {
		t.Errorf("string = %#v", v)
	}
	if v := DecodeStoredValue(EncodeFloat(2.5), DbTypeFloat); v != sexpr.Float(2.5) {
		t.Errorf("float = %#v", v)
	}
}

func TestNormalizeAttr(t *testing.T) {
	cases := map[string]string{
		":company/name": "company/name",
		"company.name":  "company/name",
		"company/name":  "company/name",
	}
	for in, want := range cases {
		got, err := NormalizeAttr(in)
		if err != nil || got != want {
			t.Errorf("normalize %q = %q, %v", in, got, err)
		}
	}
	if _, err := NormalizeAttr("bare"); err == nil {
		t.Error("bare name should be rejected")
	}
}

func TestResolverBootstrapAndUserAttrs(t *testing.T) {
	r := NewResolver()
	if aid, ok := r.LookupAttr("db/ident"); !ok || aid != DbIdentAid {
		t.Fatalf("db/ident = %d %v", aid, ok)
	}
	// Bootstrap schema attribute value types.
	if vt, ok := r.ValueTypeFor(DbIdentAid); !ok || vt != DbTypeString {
		t.Fatalf("db/ident vt = %d", vt)
	}
	r.LoadUserAttr("person/name", 100, DbTypeString, false, false, true)
	if aid, ok := r.LookupAttr("person/name"); !ok || aid != 100 {
		t.Fatalf("person/name = %d %v", aid, ok)
	}
	if !r.IsIndexed(100) {
		t.Error("person/name should be indexed")
	}
	if r.IsMany(100) {
		t.Error("person/name should be card-one")
	}
}

func TestScanPrefixActiveNewestWins(t *testing.T) {
	kv := newKV(t)
	eng := NewEngine(kv)
	eid := int64(100)
	attr := uint32(100)
	val := EncodeVariable("Alice")
	prefix := append(EncodeEid(eid), byte(attr>>24), byte(attr>>16), byte(attr>>8), byte(attr))

	kv.Put(0, BuildEavtKey(eid, attr, val, 1, false))
	got := eng.ScanPrefixActive(0, prefix)
	if len(got) != 1 {
		t.Fatalf("active after put = %d", len(got))
	}

	kv.Put(0, BuildEavtKey(eid, attr, val, 2, true)) // retract
	if got := eng.ScanPrefixActive(0, prefix); len(got) != 0 {
		t.Fatalf("active after retract = %d", len(got))
	}

	kv.Put(0, BuildEavtKey(eid, attr, val, 3, false)) // re-assert
	got = eng.ScanPrefixActive(0, prefix)
	if len(got) != 1 || BeUint64(got[0], len(got[0])-8)>>1 != 3 {
		t.Fatalf("active after re-assert = %v", got)
	}
}

func TestScanPrefixIncludesHistory(t *testing.T) {
	kv := newKV(t)
	eng := NewEngine(kv)
	eid := int64(7)
	attr := uint32(1)
	val := EncodeVariable("v")
	prefix := append(EncodeEid(eid), byte(attr>>24), byte(attr>>16), byte(attr>>8), byte(attr))
	kv.Put(0, BuildEavtKey(eid, attr, val, 1, false))
	kv.Put(0, BuildEavtKey(eid, attr, val, 2, true))
	if got := eng.ScanPrefix(0, prefix); len(got) != 2 {
		t.Fatalf("raw scan = %d, want 2", len(got))
	}
}

func TestEntityIDRoundTrip(t *testing.T) {
	eid := MakeEntityID(PartUser, 42)
	if PartitionOf(eid) != PartUser || SeqOf(eid) != 42 {
		t.Fatalf("eid decompose: p=%d s=%d", PartitionOf(eid), SeqOf(eid))
	}
}

func TestBuildCompileStats(t *testing.T) {
	kv := newKV(t)
	eng := NewEngine(kv)
	stats := eng.BuildCompileStats()
	if aid, ok := stats.AttrIDs["db/ident"]; !ok || aid != 1 {
		t.Fatalf("attrIds db/ident = %d %v", aid, ok)
	}
}
