package memtable

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func (mt *MemTable) runsOf(cf int) []*Run {
	return mt.SnapshotRuns(cf)
}

func TestPutAndSize(t *testing.T) {
	mt := New(2)
	if mt.Put(0, []byte{1, 2, 3}) == 0 {
		t.Fatal("size should grow")
	}
	mt2 := New(1)
	mt2.Put(0, []byte{1})
	mt2.Put(0, []byte{2, 3})
	mt2.Put(0, []byte{4})
	if mt2.Size() != 4 {
		t.Fatalf("size = %d, want 4", mt2.Size())
	}
	mt2.Clear()
	if mt2.Size() != 0 {
		t.Fatal("clear should reset size")
	}
}

func TestBatch(t *testing.T) {
	mt := New(1)
	sz := mt.Batch([]CfKey{
		{Cf: 0, Key: []byte{1}},
		{Cf: 0, Key: []byte{2}},
		{Cf: 0, Key: []byte{3}},
	})
	if sz != 3 {
		t.Fatalf("batch size = %d", sz)
	}
}

func TestMaterializeAndCursor(t *testing.T) {
	mt := New(1)
	mt.Put(0, []byte{3})
	mt.Put(0, []byte{1})
	mt.Put(0, []byte{2})
	mt.MaterializeAll()
	if len(mt.runsOf(0)) != 1 {
		t.Fatalf("runs = %d", len(mt.runsOf(0)))
	}
	c := NewRunCursor(mt.runsOf(0)[0])
	for _, want := range [][]byte{{1}, {2}, {3}} {
		got, ok := c.Next()
		if !ok || !bytes.Equal(got, want) {
			t.Fatalf("next = %v, want %v", got, want)
		}
	}
	if _, ok := c.Next(); ok {
		t.Fatal("expected end")
	}
}

func TestMaterializeDedup(t *testing.T) {
	mt := New(1)
	mt.Put(0, []byte{7})
	mt.Put(0, []byte{7})
	mt.MaterializeAll()
	if len(mt.runsOf(0)[0].Records) != 1 {
		t.Fatal("dedup failed")
	}
	if mt.Size() != 1 {
		t.Fatalf("size = %d", mt.Size())
	}
}

func TestSeek(t *testing.T) {
	mt := New(1)
	for i := 1; i <= 50; i++ {
		mt.Put(0, []byte{byte(i)})
	}
	mt.MaterializeAll()
	c := NewRunCursor(mt.runsOf(0)[0])
	c.Seek([]byte{30})
	k, ok := c.Peek()
	if !ok || k[0] < 30 {
		t.Fatalf("seek landed on %v", k)
	}
	c2 := NewRunCursor(mt.runsOf(0)[0])
	c2.Seek([]byte{99, 99})
	if _, ok := c2.Peek(); ok || !c2.AtEnd() {
		t.Fatal("seek past end should be at end")
	}
}

func TestLadderMerge(t *testing.T) {
	mt := New(1)
	for round := 1; round <= 9; round++ {
		for i := 0; i < 5; i++ {
			mt.Put(0, []byte{byte(round), byte(i)})
		}
		mt.MaterializeAll()
	}
	if len(mt.runsOf(0)) != 1 {
		t.Fatalf("ladder should merge to 1 run, got %d", len(mt.runsOf(0)))
	}
	c := NewRunCursor(mt.runsOf(0)[0])
	count := 0
	var prev []byte
	for {
		k, ok := c.Next()
		if !ok {
			break
		}
		if prev != nil && CmpKeys(prev, k) >= 0 {
			t.Fatalf("not strictly ascending: %v then %v", prev, k)
		}
		prev = k
		count++
	}
	if count != 45 {
		t.Fatalf("count = %d, want 45", count)
	}
}

func TestRecency(t *testing.T) {
	mt := New(12)
	mt.PutKv(10, []byte{1}, []byte{100})
	mt.MaterializeAll()
	mt.PutKv(10, []byte{1}, []byte{200})
	if v, ok := mt.GetValue(10, []byte{1}); !ok || !bytes.Equal(v, []byte{200}) {
		t.Fatalf("delta should win: %v %v", v, ok)
	}
	mt.DeleteKv(10, []byte{1})
	if _, ok := mt.GetValue(10, []byte{1}); ok {
		t.Fatal("tombstone should hide value")
	}
	if !mt.ContainsAny(10, []byte{1}) {
		t.Fatal("tombstone should still be present")
	}
}

func TestFreezePublish(t *testing.T) {
	mt := New(12)
	mt.PutKv(10, []byte{1}, []byte{100})
	mt.FreezeAllCapture()
	if len(mt.SnapshotRuns(10)) != 1 {
		t.Fatal("freeze should move runs to draining")
	}
	if v, ok := mt.GetValue(10, []byte{1}); !ok || !bytes.Equal(v, []byte{100}) {
		t.Fatal("draining should remain readable")
	}
	mt.Publish()
	if _, ok := mt.GetValue(10, []byte{1}); ok {
		t.Fatal("publish should drop draining")
	}
}

func TestDrainSorted(t *testing.T) {
	mt := New(1)
	mt.Put(0, []byte{1})
	mt.Put(0, []byte{5})
	mt.MaterializeAll()
	mt.Put(0, []byte{2})
	mt.Put(0, []byte{9})
	mt.MaterializeAll()
	got := DrainSorted(mt.SnapshotRuns(0), nil)
	want := [][]byte{{1}, {2}, {5}, {9}}
	if len(got) != len(want) {
		t.Fatalf("drain = %v", got)
	}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("drain[%d] = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestDrainKvSorted(t *testing.T) {
	mt := New(12)
	mt.PutKv(10, []byte{1}, []byte{10})
	mt.PutKv(10, []byte{2}, []byte{20})
	mt.DeleteKv(10, []byte{2})
	mt.MaterializeAll()
	pairs, deleted := DrainKvSorted(mt.SnapshotRuns(10), nil)
	if len(pairs) != 1 || !bytes.Equal(pairs[0][0], []byte{1}) || !bytes.Equal(pairs[0][1], []byte{10}) {
		t.Fatalf("pairs = %v", pairs)
	}
	if len(deleted) != 1 || !bytes.Equal(deleted[0], []byte{2}) {
		t.Fatalf("deleted = %v", deleted)
	}
}

// TestDrainSortedYields checks the drain calls the loop-fairness callback
// every DrainChunkBytes of output (Nim slices the drain the same way).
func TestDrainSortedYields(t *testing.T) {
	mt := New(1)
	const n = 4000
	for i := 0; i < n; i++ {
		k := make([]byte, 100)
		binary.BigEndian.PutUint64(k, uint64(i))
		mt.Put(0, k)
	}
	mt.MaterializeAll()
	yields := 0
	got := DrainSorted(mt.SnapshotRuns(0), func() { yields++ })
	if len(got) != n {
		t.Fatalf("drain = %d keys, want %d", len(got), n)
	}
	want := n * 100 / DrainChunkBytes
	if yields < want {
		t.Fatalf("yields = %d, want >= %d", yields, want)
	}
	if keys := DrainSorted(mt.SnapshotRuns(0), nil); len(keys) != n {
		t.Fatalf("nil-yield drain = %d keys", len(keys))
	}
}
