package transactor

import (
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"eavt-go/internal/downstream"
	"eavt-go/internal/eavt"
	"eavt-go/internal/perf"
	"eavt-go/internal/sexpr"
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

// TestPerfBuckets exercises the optional ns counters (EAVT_PERF_COUNTERS).
func TestPerfBuckets(t *testing.T) {
	perf.SetEnabled(true)
	defer perf.SetEnabled(false)
	dir := t.TempDir()
	e, err := NewEngine(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("person/name", eavt.DbTypeString, false, false); err != nil {
		t.Fatal(err)
	}
	eid := e.Store.Eavt.AllocateEntityId()
	if err := e.Store.SaveWithT(eid, "person/name", sexpr.Str("Alice"), 1, 0); err != nil {
		t.Fatal(err)
	}
	_ = e.Store.Eavt.ScanPrefixActive(0, nil)
	pt := e.perfText()
	for _, want := range []string{"saveWithT perf", "scanPrefix perf", "batchWrite perf"} {
		if !strings.Contains(pt, want) {
			t.Fatalf("perf text missing %q:\n%s", want, pt)
		}
	}
	e.perfText()
}

// TestAutoGCPostFlush verifies the post-flush auto-GC keeps the root count
// within GcMaxRootCount.  It drives the production path (the flush/GC
// runner): the synchronous kv.Flush() bypasses the runner and, by design, no
// longer queues auto-GC — publish and a GC pass are serialized on the runner.
func TestAutoGCPostFlush(t *testing.T) {
	dir := t.TempDir()
	e, err := NewEngine(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	e.KV.GcMaxAgeSecs = 43200
	e.KV.GcMaxRootCount = 2
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("person/name", eavt.DbTypeString, false, false); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		eid := e.Store.Eavt.AllocateEntityId()
		if _, err := e.Store.Eavt.EavtSave(eid, "person/name", fmt.Sprintf("n%d", i), int64(i+1)); err != nil {
			t.Fatal(err)
		}
		// flushSync returns when the runner is idle, i.e. after the auto-GC
		// pass queued by this publish has run too.
		e.flushSync()
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		roots, err := e.KV.PS.ListRoots()
		if err != nil {
			t.Fatal(err)
		}
		if len(roots) <= e.KV.GcMaxRootCount {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("roots = %d after auto-GC, want <= %d", len(roots), e.KV.GcMaxRootCount)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestGcRunsOffEngineLock asserts the operational-path invariant: a GC pass
// must complete while another goroutine holds the engine write lock (which is
// what an in-flight tx application holds).  With GcFull under e.mu — the old
// implementation — this request would block until the lock was released, i.e.
// GC would stop tx application for the whole listing/live-set/delete walk.
func TestGcRunsOffEngineLock(t *testing.T) {
	dir := t.TempDir()
	e, err := NewEngine(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("person/name", eavt.DbTypeString, false, false); err != nil {
		t.Fatal(err)
	}
	eid := e.Store.Eavt.AllocateEntityId()
	if _, err := e.Store.Eavt.EavtSave(eid, "person/name", "Alice", 1); err != nil {
		t.Fatal(err)
	}
	e.flushSync() // a root exists for the pass to look at

	e.mu.Lock() // stand in for a tx application running for the whole pass
	req := e.requestGc(true /* gc-dry */, false)
	select {
	case <-req.done:
	case <-time.After(10 * time.Second):
		e.mu.Unlock()
		t.Fatal("GC blocked on the engine write lock — it must run off the operational path")
	}
	e.mu.Unlock()
	if req.err != nil {
		t.Fatalf("gc-dry failed: %v", req.err)
	}
}

// TestAdminGcDryResponse exercises the admin handler end to end: the report
// comes back on the connection while the pass runs on the runner.
func TestAdminGcDryResponse(t *testing.T) {
	dir := t.TempDir()
	e, err := NewEngine(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	client, server := net.Pipe()
	defer client.Close()
	go func() {
		e.handleAdmin(server, "gc-dry", "1")
		server.Close()
	}()
	frame, err := downstream.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(frame), "dry_run=1") {
		t.Fatalf("gc-dry response = %s", frame)
	}
}
