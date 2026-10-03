package hydrated

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func k(eid int64, aid uint32, v string, t int64) []byte {
	return kret(eid, aid, v, t, false)
}

func kret(eid int64, aid uint32, v string, t int64, ret bool) []byte {
	key := make([]byte, 12+len(v)+8)
	binary.BigEndian.PutUint64(key[0:], uint64(eid)^(uint64(1)<<63))
	binary.BigEndian.PutUint32(key[8:], aid)
	copy(key[12:], v)
	sf := uint64(t) << 1
	if ret {
		sf |= 1
	}
	binary.BigEndian.PutUint64(key[12+len(v):], sf)
	return key
}

func eidPrefix(eid int64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(eid)^(uint64(1)<<63))
	return b[:]
}

func eidAttrPrefix(eid int64, aid uint32) []byte {
	p := eidPrefix(eid)
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], aid)
	return append(p, b[:]...)
}

func TestProbeMembership(t *testing.T) {
	h := New(DefaultMaxBytes)
	if h.Probe(42) {
		t.Fatal("empty set must miss")
	}
	if s := h.Stats(); s.Misses != 1 || s.Hits != 0 {
		t.Fatalf("stats = %+v", s)
	}
	h.HydrateEmpty(42)
	if !h.Probe(42) || h.Len() != 1 {
		t.Fatal("hydrateEmpty membership")
	}
	if len(h.LookupRange(42, eidPrefix(42))) != 0 {
		t.Fatal("empty entry range must be empty")
	}
}

func TestHydrateInstallsFullSet(t *testing.T) {
	h := New(DefaultMaxBytes)
	ks := [][]byte{k(7, 100, "aa", 1), k(7, 101, "bb", 2)}
	h.Hydrate(7, ks)
	if !h.Probe(7) {
		t.Fatal("probe after hydrate")
	}
	if s := h.Stats(); s.Hydrations != 1 {
		t.Fatalf("hydrations = %d", s.Hydrations)
	}
	if h.EntryBytes(7) != len(ks[0])+len(ks[1]) {
		t.Fatalf("entryBytes = %d", h.EntryBytes(7))
	}
}

func TestLookupRange(t *testing.T) {
	h := New(DefaultMaxBytes)
	h.Hydrate(7, [][]byte{k(7, 100, "aa", 1), k(7, 101, "bb", 2), k(7, 102, "cc", 3)})
	h.Hydrate(9, [][]byte{k(9, 100, "zz", 5)})

	if got := h.LookupRange(7, eidPrefix(7)); len(got) != 3 {
		t.Fatalf("full eid = %d", len(got))
	}
	got := h.LookupRange(7, eidAttrPrefix(7, 101))
	if len(got) != 1 || !bytes.Equal(got[0], k(7, 101, "bb", 2)) {
		t.Fatalf("eid+attr = %v", got)
	}
	if len(h.LookupRange(7, eidPrefix(9))) != 0 {
		t.Fatal("foreign eid prefix within entry must be empty")
	}
	if len(h.LookupRange(1234, eidPrefix(1234))) != 0 {
		t.Fatal("unknown eid")
	}
}

func TestHasAttrKey(t *testing.T) {
	h := New(DefaultMaxBytes)
	h.Hydrate(7, [][]byte{k(7, 100, "aa", 1), k(7, 102, "cc", 3)})
	if !h.HasAttrKey(7, 100) || !h.HasAttrKey(7, 102) {
		t.Fatal("present attrs must hit")
	}
	if h.HasAttrKey(7, 101) {
		t.Fatal("absent attr must miss")
	}
	if h.HasAttrKey(8, 100) {
		t.Fatal("unknown eid must miss")
	}
}

func TestApplyKey(t *testing.T) {
	h := New(DefaultMaxBytes)
	h.HydrateEmpty(42)
	h.ApplyKey(k(42, 200, "late", 10))
	h.ApplyKey(k(42, 100, "early", 11))
	got := h.LookupRange(42, eidPrefix(42))
	if len(got) != 2 || !bytes.Equal(got[0], k(42, 100, "early", 11)) || !bytes.Equal(got[1], k(42, 200, "late", 10)) {
		t.Fatalf("sorted upsert = %v", got)
	}
	// same datom, newer t replaces in place
	h.ApplyKey(k(42, 100, "early", 99))
	if got := h.LookupRange(42, eidPrefix(42)); len(got) != 2 || !bytes.Equal(got[0], k(42, 100, "early", 99)) {
		t.Fatalf("replace = %v", got)
	}
	// different value is a distinct datom (card-many semantics)
	h.ApplyKey(k(42, 100, "other", 1))
	if len(h.LookupRange(42, eidPrefix(42))) != 3 {
		t.Fatal("distinct values must coexist")
	}
	// retract removes
	h.ApplyKey(kret(42, 100, "other", 2, true))
	if len(h.LookupRange(42, eidAttrPrefix(42, 100))) != 1 {
		t.Fatal("retract must remove")
	}
	// non-member eids ignored
	h.ApplyKey(k(55, 1, "x", 1))
	if h.Len() != 1 {
		t.Fatal("applyKey must ignore non-members")
	}
}

func TestApplyKeyRetractToZeroBytes(t *testing.T) {
	h := New(DefaultMaxBytes)
	h.HydrateEmpty(42)
	h.ApplyKey(k(42, 300, "gone", 1))
	if len(h.LookupRange(42, eidPrefix(42))) != 1 {
		t.Fatal("pre-retract")
	}
	h.ApplyKey(kret(42, 300, "gone", 2, true))
	if len(h.LookupRange(42, eidPrefix(42))) != 0 || h.Stats().Bytes != 0 {
		t.Fatalf("post-retract bytes = %d", h.Stats().Bytes)
	}
}

func TestLRUEviction(t *testing.T) {
	h := New(50)
	h.Hydrate(1, [][]byte{k(1, 100, "a", 1)})
	h.Hydrate(2, [][]byte{k(2, 100, "b", 1)})
	h.Probe(1) // touch 1 -> 2 is LRU
	h.Hydrate(3, [][]byte{k(3, 100, "c", 1)})
	if h.Contains(2) || !h.Contains(1) || !h.Contains(3) {
		t.Fatal("LRU eviction order wrong")
	}
	if h.Stats().Evictions < 1 {
		t.Fatal("evictions not counted")
	}
}

func TestEvictionNeverEvictsIncoming(t *testing.T) {
	h := New(60)
	h.Hydrate(5, [][]byte{k(5, 100, "r", 1)})
	big := [][]byte{k(9, 100, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 1)}
	if len(big[0]) != 50 {
		t.Fatalf("key len = %d", len(big[0]))
	}
	h.Hydrate(9, big)
	if !h.Contains(9) || h.Contains(5) {
		t.Fatal("incoming must survive, resident must evict")
	}
}

func TestOversizedRejected(t *testing.T) {
	h := New(16)
	before := h.Stats().Rejected
	h.Hydrate(8, [][]byte{k(8, 100, "this-key-is-far-too-big-for-the-budget", 1)})
	if h.Stats().Rejected != before+1 || h.Contains(8) {
		t.Fatal("oversized entry must be rejected")
	}
}

func TestTouchProtectsHot(t *testing.T) {
	h := New(50)
	h.Hydrate(1, [][]byte{k(1, 100, "a", 1)})
	h.Hydrate(2, [][]byte{k(2, 100, "b", 1)})
	for i := 0; i < 5; i++ {
		h.Probe(1)
	}
	h.Hydrate(3, [][]byte{k(3, 100, "c", 1)})
	if !h.Contains(1) || h.Contains(2) || !h.Contains(3) {
		t.Fatal("hot entry must be protected")
	}
}

func TestEvictAndClear(t *testing.T) {
	h := New(DefaultMaxBytes)
	h.Hydrate(1, [][]byte{k(1, 100, "a", 1)})
	h.Hydrate(2, [][]byte{k(2, 100, "b", 1)})
	h.Evict(1)
	if h.Contains(1) || !h.Contains(2) {
		t.Fatal("evictEid must drop exactly one")
	}
	h.Clear()
	if h.Len() != 0 || h.Stats().Bytes != 0 {
		t.Fatal("clear must reset")
	}
}
