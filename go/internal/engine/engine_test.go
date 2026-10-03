package engine

import (
	"testing"

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
	sc.SetCursor(q.OpenCursor(0, nil))
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
	sc.SetCursor(q.OpenCursor(0, nil))
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
	sc2.SetCursor(q.OpenCursor(0, nil))
	sc2.SaveValue(sexpr.Int(200))
	sc2.AdvanceToActiveAt()
	if got, ok := sc2.ExtractCurrent(); !ok || got != sexpr.Int(100) {
		t.Fatalf("fallback attr = %#v %v", got, ok)
	}
}
