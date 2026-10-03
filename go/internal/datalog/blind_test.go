package datalog

import "testing"

// TestBlindFirstTinyCardinality is a regression test: with tiny index
// estimates the reference cost search can order a blind var (no active
// clause) first.  That produces iter plans whose vars are never bound, so the
// query runs but returns nothing.  A blind step must only be taken when no
// non-blind candidate remains.
func TestBlindFirstTinyCardinality(t *testing.T) {
	q := "[:find ?n ?m :where [?e :person/name ?n] [?e :person/email ?m]]"
	for _, total := range []float64{1, 2, 3, 5, 10, 40, 1000} {
		s := NewCompileStats()
		s.AttrIDs["person/name"] = 100
		s.AttrIDs["person/email"] = 101
		s.IndexEstimates["EAVT:"] = total
		_, _, ordered, plans, err := CompileDatalogQueryDebug(q, s)
		if err != nil {
			t.Fatalf("total=%v: %v", total, err)
		}
		if len(ordered) == 0 || ordered[0] != "e" {
			t.Fatalf("total=%v: ordered=%v, want the shared ?e first", total, ordered)
		}
		for i, ip := range plans {
			if len(ip.VarDepths) == 0 {
				t.Fatalf("total=%v: iter plan %d binds no var (dead scanner)", total, i)
			}
		}
	}
}
