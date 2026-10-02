package pagestore

import (
	"encoding/binary"
	"testing"
)

func u64le(rep []byte, off int) uint64 { return binary.LittleEndian.Uint64(rep[off:]) }

func blobCount(t *testing.T, s *Store) int {
	t.Helper()
	ids, err := s.blobs.List()
	if err != nil {
		t.Fatal(err)
	}
	return len(ids)
}

func TestGcRemovesOrphans(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(50, 0)}); err != nil {
		t.Fatal(err)
	}
	// Orphan blob referenced by no root.
	if _, err := s.blobs.Put([]byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	before := blobCount(t, s)
	rep, err := s.GcFull(0, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if u64le(rep, 24) != 1 {
		t.Fatalf("blobs_removed = %d, want 1", u64le(rep, 24))
	}
	if got := blobCount(t, s); got != before-1 {
		t.Fatalf("blob count %d -> %d, want %d", before, got, before-1)
	}
	// Live data survives.
	cur := NewCursor(s, 0, s.Trees()[0].RootUUID, s.Trees()[0].Height, false)
	if keys, _ := collect(cur); len(keys) != 50 {
		t.Fatalf("live keys = %d, want 50", len(keys))
	}
}

func TestGcDryRunPreserves(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(10, 0)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(10, 1)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.blobs.Put([]byte{9}); err != nil {
		t.Fatal(err)
	}
	rootsBefore, _ := s.blobs.ListRoots()
	blobsBefore := blobCount(t, s)
	rep, err := s.GcFull(0, 0, true)
	if err != nil {
		t.Fatal(err)
	}
	if rep[40] != 1 {
		t.Fatal("dry_run flag not set")
	}
	rootsAfter, _ := s.blobs.ListRoots()
	if len(rootsAfter) != len(rootsBefore) || blobCount(t, s) != blobsBefore {
		t.Fatal("dry run changed the store")
	}
}

func TestGcCountKeepsNewest(t *testing.T) {
	s := newTestStore(t)
	for i := 0; i < 5; i++ {
		if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(3, byte(i))}); err != nil {
			t.Fatal(err)
		}
	}
	roots, _ := s.blobs.ListRoots()
	if len(roots) != 6 { // initial + 5 commits
		t.Fatalf("roots = %d, want 6", len(roots))
	}
	if _, err := s.GcFull(43200, 3, false); err != nil {
		t.Fatal(err)
	}
	roots, _ = s.blobs.ListRoots()
	if len(roots) != 3 {
		t.Fatalf("roots after count-GC = %d, want 3", len(roots))
	}
}

func TestHasOldRoots(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(3, 0)}); err != nil {
		t.Fatal(err)
	}
	if s.HasOldRoots(43200, 10) {
		t.Fatal("no old roots within window")
	}
	if !s.HasOldRoots(0, 0) {
		t.Fatal("age 0 should see an older-than-latest root")
	}
}
