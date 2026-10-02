package eavt

import "testing"

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
