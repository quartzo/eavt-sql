package transactor

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"eavt-go/internal/eavt"
)

// TestAutoFlushOnThreshold verifies the threshold-crossing hook arms the
// single-flight background flusher and the datoms survive the flush.
func TestAutoFlushOnThreshold(t *testing.T) {
	dir := t.TempDir()
	e, err := NewEngine(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()

	e.KV.FlushThreshold = 1 // arm on the next write
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("person/name", eavt.DbTypeString, false, false); err != nil {
		t.Fatal(err)
	}
	eid := e.Store.Eavt.AllocateEntityId()
	if _, err := e.Store.Eavt.EavtSave(eid, "person/name", "Alice", 1); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if e.KV.PS.CurrentRoot() != "" && !e.KV.FlushActive() {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if e.KV.PS.CurrentRoot() == "" {
		t.Fatal("auto-flush did not publish a root")
	}
	e.flushSync()
	if v, ok := e.Store.Eavt.LookupValueStr(eid, "person/name"); !ok || v != "Alice" {
		t.Fatalf("lookup after flush = %q %v", v, ok)
	}
	st := e.statsText()
	for _, want := range []string{"rss=", "hyd=", "anchor=", "counters:", "saves="} {
		if !strings.Contains(st, want) {
			t.Fatalf("stats text missing %q: %s", want, st)
		}
	}
	if got := e.treeText(); !strings.Contains(got, "cf=0") {
		t.Fatalf("tree text = %q", got)
	}
}
