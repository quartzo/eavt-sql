package wal

import (
	"os"
	"sync/atomic"
	"testing"

	"eavt-go/internal/kvstore"
	"eavt-go/internal/memtable"
)

func TestWalRoundTripAndRotation(t *testing.T) {
	dir := t.TempDir()
	durable := &atomic.Int64{}
	durable.Store(-1)
	w, err := Attach(dir, durable)
	if err != nil {
		t.Fatal(err)
	}
	w.Sink([]memtable.CfKey{
		{Cf: 0, Key: []byte{1, 2, 3}},
		{Cf: 0, Key: []byte{4, 5}},
	})
	w.Seal()
	w.Sink([]memtable.CfKey{{Cf: 0, Key: []byte{9}}})
	w.Stop()

	segs := Segments(dir)
	if len(segs) < 2 {
		t.Fatalf("expected rotation into >=2 segments, got %d", len(segs))
	}
	var all []byte
	for _, p := range segs {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		all = append(all, b...)
	}
	recs := kvstore.ParseJournalRecords(all)
	if len(recs) != 3 {
		t.Fatalf("parsed %d records, want 3", len(recs))
	}
	if string(recs[0].Key) != string([]byte{1, 2, 3}) || string(recs[2].Key) != string([]byte{9}) {
		t.Fatalf("records = %#v", recs)
	}
}

func TestDeleteDurable(t *testing.T) {
	dir := t.TempDir()
	durable := &atomic.Int64{}
	durable.Store(-1)
	w, err := Attach(dir, durable)
	if err != nil {
		t.Fatal(err)
	}
	w.Sink([]memtable.CfKey{{Cf: 0, Key: []byte{1}}})
	boundary := w.Seal()
	w.Sink([]memtable.CfKey{{Cf: 0, Key: []byte{2}}})
	w.Stop()

	if len(Segments(dir)) < 2 {
		t.Fatal("no rotation")
	}
	// Mark the sealed segment durable and run the delete pass.
	durable.Store(boundary)
	w.deleteDurable()
	if len(Segments(dir)) != 1 {
		t.Fatalf("durable segment not deleted: %d segments", len(Segments(dir)))
	}
}
