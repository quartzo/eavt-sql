package kvstore

import (
	"bytes"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"eavt-go/internal/cursor"
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
	rec := journalRecord(0, []byte{9, 8, 7}, nil, false)
	entries := ParseJournalRecords(rec)
	if len(entries) != 1 || entries[0].Cf != 0 || !bytes.Equal(entries[0].Key, []byte{9, 8, 7}) {
		t.Fatalf("parse = %#v", entries)
	}
	// A value record's encoded length must match the parser's computed length.
	if vrec := journalRecord(10, []byte("k"), []byte("v"), false); journalRecordLenAt(vrec, 0) != len(vrec) {
		t.Fatalf("value record len mismatch: parser %d, encoded %d", journalRecordLenAt(vrec, 0), len(vrec))
	}
	// Tombstones carry vlen=0xFFFFFFFF and are rejected by the parser (as Nim).
	if d := journalRecordLenAt(journalRecord(10, []byte("k"), nil, true), 0); d != -1 {
		t.Fatalf("tombstone accepted by parser: %d", d)
	}
}

// TestKvNotJournaledThroughSink matches Nim: the WAL is CF-0-only, so a KV
// write with a sink installed must not emit a (misleading) WAL record nor a
// legacy journal file.
func TestKvNotJournaledThroughSink(t *testing.T) {
	kv := newStore(t)
	var got []memtable.CfKey
	kv.JournalSink = func(e []memtable.CfKey) { got = append(got, e...) }
	kv.PutKv(10, []byte("k"), []byte("v"))
	kv.DeleteKv(10, []byte("k"))
	if len(got) != 0 {
		t.Fatalf("sink received %#v, want none", got)
	}
	legacy := filepath.Join(kv.path, "journal", "journal")
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Fatalf("legacy journal created with sink installed")
	}
}

// TestPhasedFlushMatchesSync exercises capture/prepare/publish directly and
// verifies the in-flight flag and that data is readable after.
func TestPhasedFlushMatchesSync(t *testing.T) {
	kv := newStore(t)
	for i := 0; i < 100; i++ {
		kv.Put(0, []byte{byte(i)})
	}
	b, ok := kv.CaptureFlush()
	if !ok {
		t.Fatal("capture failed")
	}
	if !kv.FlushActive() {
		t.Fatal("flushActive not set during prepare")
	}
	trees, root, err := kv.PrepareFlush(b)
	if err != nil {
		t.Fatal(err)
	}
	kv.PublishFlush(b, trees, root)
	if kv.FlushActive() {
		t.Fatal("flushActive not cleared after publish")
	}
	if got, _ := kv.Get(0, []byte{50}); !got {
		t.Fatal("data missing after phased flush")
	}
	if n := len(scanKeys(t, kv, 0)); n != 100 {
		t.Fatalf("scan = %d, want 100", n)
	}
}

// TestSnapshotIsolation verifies a cursor keeps its snapshot across a
// concurrent flush (COW root + frozen runs).
func TestSnapshotIsolation(t *testing.T) {
	kv := newStore(t)
	for i := 0; i < 100; i++ {
		kv.Put(0, []byte{byte(i)})
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	old := kv.OpenScanCursor(0) // snapshot after the first flush (100 keys)
	// More writes + a second flush while the old cursor is still open.
	for i := 100; i < 150; i++ {
		kv.Put(0, []byte{byte(i)})
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	if n := len(drainCursor(old)); n != 100 {
		t.Fatalf("old cursor after flush = %d, want 100 (snapshot)", n)
	}
	fresh := kv.OpenScanCursor(0)
	if n := len(drainCursor(fresh)); n != 150 {
		t.Fatalf("fresh cursor = %d, want 150", n)
	}
}

func drainCursor(mc *cursor.MergedCursor) [][]byte {
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

// TestConcurrentWriteAndScan runs writers and scanner openers together.
func TestConcurrentWriteAndScan(t *testing.T) {
	kv := newStore(t)
	for i := 0; i < 200; i++ {
		kv.Put(0, []byte{byte(i), byte(i >> 8)})
	}
	if err := kv.Flush(); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		i := 0
		for {
			select {
			case <-stop:
				return
			default:
			}
			kv.Put(0, []byte{byte(i), byte(i >> 8), 0xAA})
			i++
		}
	}()
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				mc := kv.OpenScanCursor(0)
				for {
					if _, ok := mc.Next(); !ok {
						break
					}
				}
			}
		}()
	}
	time.Sleep(100 * time.Millisecond)
	close(stop)
	wg.Wait()
}

// TestConcurrentWriteAndFlush runs writers, a flusher and scanners together:
// writes keep landing on the active ladder while the frozen one is drained
// and published.
func TestConcurrentWriteAndFlush(t *testing.T) {
	kv := newStore(t)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		i := 0
		for {
			select {
			case <-stop:
				return
			default:
			}
			kv.Put(0, []byte{byte(i), byte(i >> 8), byte(i >> 16)})
			i++
		}
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			_ = kv.Flush()
		}
	}()
	for r := 0; r < 3; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				mc := kv.OpenScanCursor(0)
				for {
					if _, ok := mc.Next(); !ok {
						break
					}
				}
			}
		}()
	}
	time.Sleep(150 * time.Millisecond)
	close(stop)
	wg.Wait()
}

// TestAbortFlushReleasesCapture verifies a failed capture can be released so
// later flushes proceed.
func TestAbortFlushReleasesCapture(t *testing.T) {
	kv := newStore(t)
	kv.Put(0, []byte{1})
	if _, ok := kv.CaptureFlush(); !ok {
		t.Fatal("capture failed")
	}
	if !kv.FlushActive() {
		t.Fatal("flushActive not set")
	}
	kv.AbortFlush()
	if kv.FlushActive() {
		t.Fatal("flushActive not cleared after abort")
	}
	if _, ok := kv.CaptureFlush(); !ok {
		t.Fatal("capture after abort failed")
	}
	kv.AbortFlush()
}
