package datalog

import "testing"

// TestBlindFirstTinyCardinality is a regression test: with tiny index
// estimates the reference cost search can order a blind var (no active
// clause) first.  That produces iter plans whose vars are never bound, so the
// query runs but returns nothing.  A blind step must only be taken when no
// non-blind candidate remains.
func TestBlindFirstTinyCardinality(t *testing.T) {
	queries := []struct {
		name string
		q    string
	}{
		{"join", "[:find ?n ?m :where [?e :person/name ?n] [?e :person/email ?m]]"},
		// The predicate's var comes from a LATER pattern: the reference plan
		// orders ?a/?n blind-first, leaving ?n unbound at runtime (the back
		// answers "unbound: n").  This is the shape that diverged from the
		// Nim front in scripts/parity_front.sh before the session was tuned.
		{"predicate-in-later-pattern",
			"[:find ?n :where [?e :person/name ?n] [(> ?a 20)] [?e :person/age ?a]]"},
	}
	for _, c := range queries {
		for _, total := range []float64{1, 2, 3, 5, 10, 40, 1000} {
			s := NewCompileStats()
			s.AttrIDs["person/name"] = 100
			s.AttrIDs["person/email"] = 101
			s.AttrIDs["person/age"] = 102
			s.IndexEstimates["EAVT:"] = total
			_, _, ordered, plans, err := CompileDatalogQueryDebug(c.q, s)
			if err != nil {
				t.Fatalf("%s total=%v: %v", c.name, total, err)
			}
			if len(ordered) == 0 || ordered[0] != "e" {
				t.Fatalf("%s total=%v: ordered=%v, want the shared ?e first", c.name, total, ordered)
			}
			for i, ip := range plans {
				if len(ip.VarDepths) == 0 {
					t.Fatalf("%s total=%v: iter plan %d binds no var (dead scanner)", c.name, total, i)
				}
			}
		}
	}
}
