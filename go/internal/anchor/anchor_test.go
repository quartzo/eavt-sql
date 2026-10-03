package anchor

import (
	"fmt"
	"strings"
	"testing"
)

func val(v string) []byte { return []byte(v) }

func TestPutProbe(t *testing.T) {
	idx := New(DefaultMaxBytes)
	idx.Put(100, val("cnpj_12345678"), 42)
	if eid, ok := idx.Probe(100, val("cnpj_12345678")); !ok || eid != 42 {
		t.Fatalf("probe = %d,%v", eid, ok)
	}
	s := idx.Stats()
	if s.Len != 1 || s.Hits != 1 || s.Misses != 0 {
		t.Fatalf("stats = %+v", s)
	}
	if _, ok := idx.Probe(100, val("x")); ok {
		t.Fatal("absent must miss")
	}
	if idx.Stats().Misses != 1 {
		t.Fatal("miss not counted")
	}
}

func TestRePutLastWriteWins(t *testing.T) {
	idx := New(DefaultMaxBytes)
	idx.Put(100, val("dup"), 1)
	idx.Put(100, val("dup"), 2)
	if idx.Len() != 1 {
		t.Fatalf("len = %d", idx.Len())
	}
	if eid, _ := idx.Probe(100, val("dup")); eid != 2 {
		t.Fatalf("eid = %d", eid)
	}
}

func TestDistinctAidsNoCollision(t *testing.T) {
	idx := New(DefaultMaxBytes)
	idx.Put(100, val("v"), 1)
	idx.Put(200, val("v"), 2)
	if eid, _ := idx.Probe(100, val("v")); eid != 1 {
		t.Fatalf("100 -> %d", eid)
	}
	if eid, _ := idx.Probe(200, val("v")); eid != 2 {
		t.Fatalf("200 -> %d", eid)
	}
}

func TestEmptyValue(t *testing.T) {
	idx := New(DefaultMaxBytes)
	idx.Put(100, nil, 7)
	if eid, ok := idx.Probe(100, nil); !ok || eid != 7 {
		t.Fatalf("empty value probe = %d,%v", eid, ok)
	}
}

func TestDel(t *testing.T) {
	idx := New(DefaultMaxBytes)
	idx.Put(100, val("gone"), 1)
	idx.Del(100, val("gone"))
	if _, ok := idx.Probe(100, val("gone")); ok {
		t.Fatal("del must remove")
	}
	if idx.Len() != 0 || idx.Stats().Bytes != 0 {
		t.Fatalf("len=%d bytes=%d", idx.Len(), idx.Stats().Bytes)
	}
}

func TestDelRePutReusesRec(t *testing.T) {
	idx := New(DefaultMaxBytes)
	for i := 1; i <= 50; i++ {
		idx.Put(100, val("reuse"), int64(i))
		idx.Del(100, val("reuse"))
	}
	idx.Put(100, val("reuse"), 99)
	if idx.Len() != 1 {
		t.Fatalf("len = %d", idx.Len())
	}
	if eid, _ := idx.Probe(100, val("reuse")); eid != 99 {
		t.Fatalf("eid = %d", eid)
	}
	if idx.Stats().Recs > 3 {
		t.Fatalf("recs = %d, want free-list reuse", idx.Stats().Recs)
	}
}

func TestAllTombstonesThenPut(t *testing.T) {
	idx := New(DefaultMaxBytes)
	for i := 1; i <= 40; i++ {
		idx.Put(100, val(fmt.Sprintf("k%d", i)), 1)
	}
	for i := 1; i <= 40; i++ {
		idx.Del(100, val(fmt.Sprintf("k%d", i)))
	}
	if idx.Len() != 0 || idx.Stats().Tombs != 40 {
		t.Fatalf("len=%d tombs=%d", idx.Len(), idx.Stats().Tombs)
	}
	idx.Put(100, val("novo"), 5)
	if eid, ok := idx.Probe(100, val("novo")); !ok || eid != 5 {
		t.Fatalf("post-tombstone put = %d,%v", eid, ok)
	}
}

func TestGrowthBeyondMinSlots(t *testing.T) {
	idx := New(DefaultMaxBytes)
	for i := 1; i <= 3000; i++ {
		idx.Put(100, val(fmt.Sprintf("chave_%d", i)), int64(i))
	}
	if idx.Len() != 3000 {
		t.Fatalf("len = %d", idx.Len())
	}
	if idx.Stats().Capacity <= 1024 {
		t.Fatal("capacity must grow")
	}
	for i := 1; i <= 3000; i++ {
		if eid, ok := idx.Probe(100, val(fmt.Sprintf("chave_%d", i))); !ok || eid != int64(i) {
			t.Fatalf("probe chave_%d = %d,%v", i, eid, ok)
		}
	}
	if idx.Stats().Rehashes < 2 {
		t.Fatalf("rehashes = %d", idx.Stats().Rehashes)
	}
}

func TestRehashCompactsArena(t *testing.T) {
	idx := New(DefaultMaxBytes)
	for i := 1; i <= 400; i++ {
		idx.Put(100, val(fmt.Sprintf("v%d", i)), int64(i))
	}
	for i := 1; i <= 300; i++ {
		idx.Del(100, val(fmt.Sprintf("v%d", i)))
	}
	cur := idx.Stats().Bytes
	idx.RehashForTest()
	if idx.Stats().Arena >= cur {
		t.Fatalf("arena %d not < curBytes %d", idx.Stats().Arena, cur)
	}
	for i := 301; i <= 400; i++ {
		if eid, ok := idx.Probe(100, val(fmt.Sprintf("v%d", i))); !ok || eid != int64(i) {
			t.Fatalf("probe v%d = %d,%v", i, eid, ok)
		}
	}
}

func TestBudgetEvictsLRUTail(t *testing.T) {
	idx := New(4 * 40)
	for i := 1; i <= 6; i++ {
		idx.Put(100, val(fmt.Sprintf("k%d", i)), int64(i))
	}
	if idx.Len() >= 6 || idx.Stats().Evictions == 0 {
		t.Fatalf("len=%d evictions=%d", idx.Len(), idx.Stats().Evictions)
	}
	for i := 1; i <= 6; i++ {
		if eid, ok := idx.Probe(100, val(fmt.Sprintf("k%d", i))); ok && eid != int64(i) {
			t.Fatalf("survivor k%d wrong eid %d", i, eid)
		}
	}
}

func TestTouchProtectsHot(t *testing.T) {
	idx := New(256)
	for i := 1; i <= 3; i++ {
		idx.Put(100, val(fmt.Sprintf("hot%d", i)), int64(i))
	}
	for round := 1; round <= 3; round++ {
		for i := 1; i <= 3; i++ {
			idx.Probe(100, val(fmt.Sprintf("hot%d", i)))
		}
		idx.Put(100, val(fmt.Sprintf("cold%d", round)), int64(round))
	}
	for i := 1; i <= 3; i++ {
		if _, ok := idx.Probe(100, val(fmt.Sprintf("hot%d", i))); !ok {
			t.Fatalf("hot%d evicted", i)
		}
	}
}

func TestOversizedRejected(t *testing.T) {
	idx := New(64)
	before := idx.Stats().Rejected
	idx.Put(100, []byte(strings.Repeat("x", 196)), 1)
	if idx.Stats().Rejected != before+1 || idx.Len() != 0 {
		t.Fatal("oversized must be rejected")
	}
}

func TestClear(t *testing.T) {
	idx := New(DefaultMaxBytes)
	for i := 1; i <= 50; i++ {
		idx.Put(100, val(fmt.Sprintf("k%d", i)), int64(i))
	}
	idx.Clear()
	if idx.Len() != 0 || idx.Stats().Bytes != 0 {
		t.Fatal("clear must reset")
	}
	idx.Put(100, val("novo"), 9)
	if eid, ok := idx.Probe(100, val("novo")); !ok || eid != 9 {
		t.Fatalf("post-clear put = %d,%v", eid, ok)
	}
}
