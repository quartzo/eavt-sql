package engine

import (
	"testing"

	"eavt-go/internal/cursor"
	"eavt-go/internal/datalog"
	"eavt-go/internal/eavt"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/query"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

// setup writes a schema (person/name string) + one datom and returns the store.
func setup(t *testing.T) *QueryStore {
	t.Helper()
	kv, err := kvstore.New(kvstore.Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kv.Close() })

	attrEid := int64(100)
	// Schema: [eid 100] :db/ident person/name ; :db/valueType :db.type/string.
	kv.Put(1, eavt.BuildAevtKey(eavt.DbIdentAid, attrEid, eavt.EncodeVariable("person/name"), 1, false))
	kv.Put(1, eavt.BuildAevtKey(eavt.DbValueTypeAid, attrEid, eavt.EncodeInt(int64(eavt.DbTypeString)), 1, false))
	// Datom: [eid 200] person/name "Alice".
	kv.Put(0, eavt.BuildEavtKey(200, uint32(attrEid), eavt.EncodeVariable("Alice"), 1, false))
	// Index keys for the datom (EAVT/AVET/AEVT; VAET is ref-only).
	kv.Put(1, eavt.BuildAevtKey(uint32(attrEid), 200, eavt.EncodeVariable("Alice"), 1, false))
	kv.Put(2, eavt.BuildAvetKey(uint32(attrEid), eavt.EncodeVariable("Alice"), 200, 1, false))
	// Padding datoms so the planner's EAVT cardinality estimate is realistic
	// (a 1-key store makes blind-first orderings win the cost search).
	for i := 0; i < 20; i++ {
		kv.Put(0, eavt.BuildEavtKey(int64(300+i), 999, eavt.EncodeVariable("pad"), int64(i), false))
	}

	return New(kv)
}

func TestBootstrapResolver(t *testing.T) {
	q := setup(t)
	aid, ok := q.LookupAttr("person/name")
	if !ok || aid != 100 {
		t.Fatalf("person/name = %d %v", aid, ok)
	}
	vt, ok := q.ValueTypeFor(aid)
	if !ok || vt != eavt.DbTypeString {
		t.Fatalf("valueType = %d", vt)
	}
}

func TestScannerExtracts(t *testing.T) {
	q := setup(t)
	sc := query.NewV2Scanner("EAVT", []string{"e", "a", "v", "t", "added"}, 0, false)
	sc.SetCursor(q.OpenCursor(0, nil, false))
	sc.SaveValue(sexpr.Int(200))
	sc.AdvanceToActiveAt()
	got, ok := sc.ExtractCurrent()
	if !ok || got != sexpr.Int(100) {
		t.Fatalf("attr = %#v %v", got, ok)
	}
	sc.SaveValue(sexpr.Int(100))
	sc.AdvanceToActiveAtPreserving()
	got, ok = sc.ExtractCurrent()
	if !ok {
		t.Fatal("value missing")
	}
	if s, ok := got.(sexpr.Str); !ok || s != "Alice" {
		t.Fatalf("value = %#v", got)
	}
}

func TestLookupValueAndEntity(t *testing.T) {
	q := setup(t)
	if v, ok := q.LookupValue(200, "person/name"); !ok || v != sexpr.Str("Alice") {
		t.Fatalf("lookupValue = %#v %v", v, ok)
	}
	if eid, ok := q.LookupEntity("person/name", sexpr.Str("Alice")); !ok || eid != 200 {
		t.Fatalf("lookupEntity = %d %v", eid, ok)
	}
}

func TestCompileAndExecuteQuery(t *testing.T) {
	q := setup(t)
	stats := q.Eavt.BuildCompileStats()
	prog, _, err := datalog.CompileDatalogQuery("[:find ?n :where [?e :person/name ?n]]", stats)
	if err != nil {
		t.Fatal(err)
	}
	sess := NewQuerySession(q, scheme.Program{Body: prog}, nil, 0, 0, false)
	stream := NewStreamingSession(sess)
	rows, more, err := stream.NextBatch(100)
	if err != nil {
		t.Fatal(err)
	}
	if more {
		t.Fatal("expected all rows in one batch")
	}
	if len(rows) != 1 || len(rows[0]) != 1 {
		t.Fatalf("rows = %#v", rows)
	}
	if s, ok := rows[0][0].(sexpr.Str); !ok || s != "Alice" {
		t.Fatalf("row value = %#v", rows[0][0])
	}
}

// TestScannerExtractsHydrated verifies the M6 cursor fast path: a CF-0 scan
// anchored at a hydrated eid is served from the entry and yields the same
// results as the merged cursor.
func TestScannerExtractsHydrated(t *testing.T) {
	q := setup(t)
	q.Eavt.HydrateEID(200)
	if !q.Eavt.Hyd.Contains(200) {
		t.Fatal("eid 200 not hydrated")
	}
	sc := query.NewV2Scanner("EAVT", []string{"e", "a", "v", "t", "added"}, 0, false)
	sc.SetCursor(q.OpenCursor(0, nil, false))
	sc.SaveValue(sexpr.Int(200))
	sc.AdvanceToActiveAt()
	got, ok := sc.ExtractCurrent()
	if !ok || got != sexpr.Int(100) {
		t.Fatalf("attr = %#v %v", got, ok)
	}
	sc.SaveValue(sexpr.Int(100))
	sc.AdvanceToActiveAtPreserving()
	got, ok = sc.ExtractCurrent()
	if !ok {
		t.Fatal("value missing")
	}
	if s, ok := got.(sexpr.Str); !ok || s != "Alice" {
		t.Fatalf("value = %#v", got)
	}
	// A non-hydrated eid falls back to the merged cursor transparently.
	q.Eavt.Hyd.Evict(200)
	sc2 := query.NewV2Scanner("EAVT", []string{"e", "a", "v", "t", "added"}, 0, false)
	sc2.SetCursor(q.OpenCursor(0, nil, false))
	sc2.SaveValue(sexpr.Int(200))
	sc2.AdvanceToActiveAt()
	if got, ok := sc2.ExtractCurrent(); !ok || got != sexpr.Int(100) {
		t.Fatalf("fallback attr = %#v %v", got, ok)
	}
}

// TestOpenCursorHydGuard verifies the hydrated fast path is wired only for
// non-history CF-0 scans (as-of/history would otherwise hide old versions).
func TestOpenCursorHydGuard(t *testing.T) {
	q := setup(t)
	if mc := q.OpenCursor(0, nil, false).(*cursor.MergedCursor); mc.Hyd == nil {
		t.Fatal("hyd not wired for normal CF-0")
	}
	if mc := q.OpenCursor(0, nil, true).(*cursor.MergedCursor); mc.Hyd != nil {
		t.Fatal("hyd must be disabled for history/as-of")
	}
	if mc := q.OpenCursor(2, nil, false).(*cursor.MergedCursor); mc.Hyd != nil {
		t.Fatal("hyd wired for a non-CF-0 cursor")
	}
}

// TestDatalogQueryTinyStore is a regression test for the blind-first planner
// bug: a store with only one datom per attribute (total EAVT estimate ~2)
// must still return the joined row.
func TestDatalogQueryTinyStore(t *testing.T) {
	kv, err := kvstore.New(kvstore.Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kv.Close() })

	attrs := []struct {
		eid  int64
		name string
	}{{100, "person/name"}, {101, "person/email"}}
	for _, a := range attrs {
		kv.Put(1, eavt.BuildAevtKey(eavt.DbIdentAid, a.eid, eavt.EncodeVariable(a.name), 1, false))
		kv.Put(1, eavt.BuildAevtKey(eavt.DbValueTypeAid, a.eid, eavt.EncodeInt(int64(eavt.DbTypeString)), 1, false))
	}
	kv.Put(0, eavt.BuildEavtKey(200, 100, eavt.EncodeVariable("Alice"), 1, false))
	kv.Put(1, eavt.BuildAevtKey(100, 200, eavt.EncodeVariable("Alice"), 1, false))
	kv.Put(2, eavt.BuildAvetKey(100, eavt.EncodeVariable("Alice"), 200, 1, false))
	kv.Put(0, eavt.BuildEavtKey(200, 101, eavt.EncodeVariable("a@b.c"), 1, false))
	kv.Put(1, eavt.BuildAevtKey(101, 200, eavt.EncodeVariable("a@b.c"), 1, false))
	kv.Put(2, eavt.BuildAvetKey(101, eavt.EncodeVariable("a@b.c"), 200, 1, false))

	q := New(kv)
	if stats := q.Eavt.BuildCompileStats(); stats.IndexEstimates["EAVT:"] > 5 {
		t.Fatalf("tiny store estimate unexpectedly large: %v", stats.IndexEstimates["EAVT:"])
	}
	query := "[:find ?n ?m :where [?e :person/name ?n] [?e :person/email ?m]]"
	prog, _, err := datalog.CompileDatalogQuery(query, q.Eavt.BuildCompileStats())
	if err != nil {
		t.Fatal(err)
	}
	sess := NewQuerySession(q, scheme.Program{Body: prog}, nil, 1, 0, false)
	stream := NewStreamingSession(sess)
	rows, _, err := stream.NextBatch(100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("tiny-store join returned no row (blind-first planner bug)")
	}
}
