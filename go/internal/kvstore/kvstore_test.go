package kvstore

import (
	"bytes"
	"testing"

	"eavt-go/internal/memtable"
)

func newStore(t *testing.T) *KVStore {
	t.Helper()
	kv, err := New(Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kv.Close() })
	return kv
}

func scanKeys(t *testing.T, kv *KVStore, cf int) [][]byte {
	t.Helper()
	mc := kv.OpenScanCursor(cf)
	var out [][]byte
	for {
		k, ok := mc.Next()
		if !ok {
			break
		}
		out = append(out, k)
	}
	return out
}

func TestPutGetScanMemtable(t *testing.T) {
	kv := newStore(t)
	kv.Put(0, []byte{3})
	kv.Put(0, []byte{1})
	kv.Put(0, []byte{2})
	for _, k := range [][]byte{{1}, {2}, {3}} {
		if ok, _ := kv.Get(0, k); !ok {
			t.Fatalf("get %v false", k)
		}
	}
	got := scanKeys(t, kv, 0)
	want := [][]byte{{1}, {2}, {3}}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("scan[%d] = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestFlushThenReadPagestore(t *testing.T) {
	kv := newStore(t)
	for i := 0; i < 100; i++ {
		kv.Put(0, []byte{byte(i)})
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	if kv.MemtableSize() != 0 {
		t.Fatal("flush should reset memtable size")
	}
	if ok, _ := kv.Get(0, []byte{50}); !ok {
		t.Fatal("get after flush failed (pagestore)")
	}
	got := scanKeys(t, kv, 0)
	if len(got) != 100 {
		t.Fatalf("scan after flush = %d keys", len(got))
	}
	// Reads must merge memtable deltas again after the flush.
	kv.Put(0, []byte{200})
	if ok, _ := kv.Get(0, []byte{200}); !ok {
		t.Fatal("post-flush delta not visible")
	}
	if n := len(scanKeys(t, kv, 0)); n != 101 {
		t.Fatalf("scan after post-flush put = %d", n)
	}
}

func TestKvTombstoneAcrossFlush(t *testing.T) {
	kv := newStore(t)
	kv.PutKv(10, []byte("a"), []byte("1"))
	kv.PutKv(10, []byte("b"), []byte("2"))
	if v, ok, _ := kv.GetKv(10, []byte("a")); !ok || !bytes.Equal(v, []byte("1")) {
		t.Fatalf("get kv a = %q %v", v, ok)
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	if v, ok, _ := kv.GetKv(10, []byte("b")); !ok || !bytes.Equal(v, []byte("2")) {
		t.Fatalf("get kv b after flush = %q %v", v, ok)
	}
	kv.DeleteKv(10, []byte("a"))
	if _, ok, _ := kv.GetKv(10, []byte("a")); ok {
		t.Fatal("tombstone should hide value")
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := kv.GetKv(10, []byte("a")); ok {
		t.Fatal("tombstone should survive flush")
	}
	mc := kv.OpenScanCursorKv(10)
	var keys []string
	for {
		p, ok := mc.NextKv()
		if !ok {
			break
		}
		keys = append(keys, string(p[0]))
	}
	if len(keys) != 1 || keys[0] != "b" {
		t.Fatalf("kv scan = %v", keys)
	}
}

func TestApplyJournalExpanded(t *testing.T) {
	kv := newStore(t)
	kv.ApplyJournalRecordsExpanded([]memtable.CfKey{
		{Cf: 0, Key: []byte{1, 2, 3}},
		{Cf: 0, Key: []byte{1, 2, 4}},
	})
	if ok, _ := kv.Get(0, []byte{1, 2, 3}); !ok {
		t.Fatal("applied key missing")
	}
	if n := len(scanKeys(t, kv, 0)); n != 2 {
		t.Fatalf("scan = %d", n)
	}
}

func TestJournalParseRoundTrip(t *testing.T) {
	rec := writeJournalRecord(0, []byte{9, 8, 7}, nil, false)
	entries := ParseJournalRecords(rec)
	if len(entries) != 1 || entries[0].Cf != 0 || !bytes.Equal(entries[0].Key, []byte{9, 8, 7}) {
		t.Fatalf("parse = %#v", entries)
	}
}
