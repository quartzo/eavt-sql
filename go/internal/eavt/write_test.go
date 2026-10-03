package eavt

import (
	"fmt"
	"sync"
	"testing"
)

func TestEavtWritePath(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()

	if _, _, err := e.EavtDeclareAttr("person/name", DbTypeString, false, false); err != nil {
		t.Fatal(err)
	}
	eid := e.AllocateEntityId()
	if eid == 0 {
		t.Fatal("allocate returned 0")
	}
	if _, err := e.EavtSave(eid, "person/name", "Alice", 1); err != nil {
		t.Fatal(err)
	}
	if v, ok := e.LookupValueStr(eid, "person/name"); !ok || v != "Alice" {
		t.Fatalf("lookup = %q %v", v, ok)
	}
	// Card-one save retracts the previous active value.
	if _, err := e.EavtSave(eid, "person/name", "Alicia", 2); err != nil {
		t.Fatal(err)
	}
	if v, _ := e.LookupValueStr(eid, "person/name"); v != "Alicia" {
		t.Fatalf("after overwrite = %q", v)
	}
	if err := e.EavtRetract(eid, "person/name", "Alicia", 3); err != nil {
		t.Fatal(err)
	}
	if v, ok := e.LookupValueStr(eid, "person/name"); ok {
		t.Fatalf("retract left %q", v)
	}
}

func TestEavtUniqueLookup(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	if _, _, err := e.EavtDeclareAttr("person/email", DbTypeString, false, true); err != nil {
		t.Fatal(err)
	}
	eid := e.AllocateEntityId()
	if _, err := e.EavtSave(eid, "person/email", "a@b.c", 1); err != nil {
		t.Fatal(err)
	}
	if got, ok := e.LookupEntityByValue("person/email", "a@b.c"); !ok || got != eid {
		t.Fatalf("unique lookup = %d %v, want %d", got, ok, eid)
	}
	if _, ok := e.LookupEntityByValue("person/email", "missing"); ok {
		t.Fatal("missing unique value resolved")
	}
}

func TestBootstrapSystemAttrsIdempotent(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	// Re-bootstrapping must not duplicate datoms.
	before := len(e.ScanPrefix(1, []byte{0, 0, 0, byte(DbIdentAid)}))
	e.BootstrapSystemAttrs()
	after := len(e.ScanPrefix(1, []byte{0, 0, 0, byte(DbIdentAid)}))
	if before != after || before == 0 {
		t.Fatalf("ident datoms before=%d after=%d", before, after)
	}
}

// TestHydratedAndAnchorCurrent verifies the M6/M7 mirrors track the write path
// (write-through) including retract removal.
func TestHydratedAndAnchorCurrent(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	aid, _, err := e.EavtDeclareAttr("person/email", DbTypeString, false, true)
	if err != nil {
		t.Fatal(err)
	}
	eid := e.AllocateEntityId()
	enc, _ := EncodeValue("a@b.c", EmVariable, 0)
	e.BatchWrite(BuildEavtEntries(eid, aid, enc, 1, false, EmVariable, true))

	if !e.Hyd.Contains(eid) || e.Hyd.KeyCount(eid) != 1 || !e.Hyd.HasAttrKey(eid, aid) {
		t.Fatalf("hydrated mirror not current: %+v", e.Hyd.Stats())
	}
	if got, ok := e.Anchors.Probe(aid, enc); !ok || got != eid {
		t.Fatalf("anchor probe = %d %v", got, ok)
	}
	if v, ok := e.LookupValueStr(eid, "person/email"); !ok || v != "a@b.c" {
		t.Fatalf("lookup = %q %v", v, ok)
	}

	e.BatchWrite(BuildEavtEntries(eid, aid, enc, 2, true, EmVariable, true))
	if e.Hyd.KeyCount(eid) != 0 {
		t.Fatal("hydrated entry not cleared on retract")
	}
	if _, ok := e.Anchors.Probe(aid, enc); ok {
		t.Fatal("anchor not removed on retract")
	}
	if got := e.ScanPrefixActive(0, EncodeEid(eid)); len(got) != 0 {
		t.Fatalf("scan after retract = %d", len(got))
	}
}

// TestRecoverRebuildsAnchors verifies RecoverWriteState re-derives the anchor
// hash from the CF-0 replay residue (WAL CF-0-only).
func TestRecoverRebuildsAnchors(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	aid, _, err := e.EavtDeclareAttr("person/email", DbTypeString, false, true)
	if err != nil {
		t.Fatal(err)
	}
	eid := e.AllocateEntityId()
	enc, _ := EncodeValue("x@y.z", EmVariable, 0)
	e.BatchWrite(BuildEavtEntries(eid, aid, enc, 1, false, EmVariable, true))

	e.Anchors.Clear()
	if _, ok := e.Anchors.Probe(aid, enc); ok {
		t.Fatal("anchor survived clear")
	}
	e.RecoverWriteState()
	if got, ok := e.Anchors.Probe(aid, enc); !ok || got != eid {
		t.Fatalf("recover anchor = %d %v, want %d", got, ok, eid)
	}
}

// TestConcurrentMirrorReadWrite exercises the hydrated/anchor mirrors under
// concurrent CF-0 writes and reads (the transactor/query-server model:
// goroutine-per-connection).  Run under -race.
func TestConcurrentMirrorReadWrite(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	aid, _, err := e.EavtDeclareAttr("person/email", DbTypeString, false, true)
	if err != nil {
		t.Fatal(err)
	}
	eid := e.AllocateEntityId()

	var wg sync.WaitGroup
	done := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			enc, _ := EncodeValue(fmt.Sprintf("v%d@x", i), EmVariable, 0)
			e.BatchWrite(BuildEavtEntries(eid, aid, enc, int64(i+1), false, EmVariable, true))
		}
		close(done)
	}()
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pre := EncodeEid(eid)
			for {
				select {
				case <-done:
					return
				default:
				}
				_ = e.ScanPrefixActive(0, pre)
				_, _ = e.Anchors.Probe(aid, []byte("v1@x"))
				_, _ = e.LookupEntityByValue("person/email", "v2@x")
			}
		}()
	}
	wg.Wait()
}

// TestScanStats verifies the scan counters advance.
func TestScanStats(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	_ = e.ScanPrefixActive(0, nil)
	if calls, _ := e.ScanStats(); calls == 0 {
		t.Fatal("scan calls not counted")
	}
	e.ResetScanCounters()
	if calls, keys := e.ScanStats(); calls != 0 || keys != 0 {
		t.Fatalf("reset left %d/%d", calls, keys)
	}
}

// TestScanDiagCounts verifies the eavtScanDiag counter accrues for cf != 0.
func TestScanDiagCounts(t *testing.T) {
	kv := newKV(t)
	e := NewEngine(kv)
	e.BootstrapSystemAttrs()
	e.SetScanDiag(true)
	for i := 0; i < 2000; i++ {
		_ = e.ScanPrefixActive(1, []byte{0, 0, 0, byte(DbIdentAid)})
	}
	if calls, _, _ := e.ScanDiag(); calls != 2000 {
		t.Fatalf("diag calls = %d, want 2000", calls)
	}
}
