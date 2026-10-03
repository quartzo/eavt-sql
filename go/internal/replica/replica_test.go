package replica

import (
	"encoding/binary"
	"testing"

	"eavt-go/internal/eavt"
	"eavt-go/internal/kvstore"
)

// walKey encodes one CF-0 key-only record in the journal/WAL format.
func walKey(key []byte) []byte {
	totKlen := 1 + len(key)
	out := make([]byte, 0, 4+totKlen+5)
	var h [4]byte
	binary.BigEndian.PutUint32(h[:], uint32(totKlen))
	out = append(out, h[:]...)
	out = append(out, 0) // cf 0
	out = append(out, key...)
	out = append(out, 0, 0, 0, 1, 0) // vlen=1, value=0x00
	return out
}

func chunk(keys ...[]byte) []byte {
	var out []byte
	for _, k := range keys {
		out = append(out, walKey(k)...)
	}
	return out
}

// TestWalSchemaRefreshBeforeDerive is a regression test: a `:db/unique` datom
// arriving in a WAL chunk must be visible to the resolver BEFORE the CF-2
// index keys are derived, otherwise unique-attr (AVET) queries on the replica
// return nothing until a flush/root adoption.
func TestWalSchemaRefreshBeforeDerive(t *testing.T) {
	dir := t.TempDir()
	// Initialise the on-disk format with a writable store, then reopen
	// read-only as the replica does.
	w, err := kvstore.New(kvstore.Config{Path: dir, NumCf: 64})
	if err != nil {
		t.Fatal(err)
	}
	_ = w.Close()
	r := Open(dir)
	if r == nil {
		t.Fatal("open replica")
	}
	t.Cleanup(r.Close)

	ident, _ := eavt.EncodeValue("person/email", eavt.EmVariable, 0)
	vt, _ := eavt.EncodeValue("", eavt.EmRef, int64(eavt.DbTypeString))
	card, _ := eavt.EncodeValue("", eavt.EmRef, int64(eavt.DbCardinalityOneAid))
	uniq, _ := eavt.EncodeValue("", eavt.EmRef, int64(eavt.DbUniqueIdentityAid))
	const attrEid = 100
	const dataEid = 200

	r.ApplyWal(chunk(
		eavt.BuildEavtKey(attrEid, eavt.DbIdentAid, ident, 1, false),
		eavt.BuildEavtKey(attrEid, eavt.DbValueTypeAid, vt, 1, false),
		eavt.BuildEavtKey(attrEid, eavt.DbCardinalityAid, card, 1, false),
		eavt.BuildEavtKey(attrEid, eavt.DbUniqueAid, uniq, 1, false),
	))
	val, _ := eavt.EncodeValue("a@b.c", eavt.EmVariable, 0)
	r.ApplyWal(chunk(eavt.BuildEavtKey(dataEid, attrEid, val, 1, false)))

	aid, ok := r.Store.Eavt.LookupAttr("person/email")
	if !ok || aid != attrEid {
		t.Fatalf("attr = %d %v", aid, ok)
	}
	if !r.Store.Eavt.IsUnique(aid) {
		t.Fatal("replica resolver does not know the attr is unique")
	}
	if got, ok := r.Store.Eavt.LookupEntityByValue("person/email", "a@b.c"); !ok || got != dataEid {
		t.Fatalf("unique lookup = %d %v, want %d", got, ok, dataEid)
	}
	// CF-2 (AVET) derived on the replica.
	prefix := append([]byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}, val...)
	if got := r.Store.Eavt.ScanPrefixActive(2, prefix); len(got) == 0 {
		t.Fatal("CF-2 not derived for the unique datom")
	}
	if r.Store.Eavt.Anchors.Len() == 0 {
		t.Fatal("anchor mirror not populated on the replica")
	}
}
