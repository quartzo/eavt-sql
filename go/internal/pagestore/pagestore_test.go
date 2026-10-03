package pagestore

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"

	"eavt-go/internal/blobstore"
)

// newFakeS3 is a minimal S3 endpoint for the backend tests.
func newFakeS3(t *testing.T) (*httptest.Server, map[string][]byte) {
	t.Helper()
	var mu sync.Mutex
	objects := map[string][]byte{}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("list-type") == "2" {
			prefix := r.URL.Query().Get("prefix")
			mu.Lock()
			var keys []string
			for k := range objects {
				if strings.HasPrefix(k, prefix) {
					keys = append(keys, k)
				}
			}
			mu.Unlock()
			sort.Strings(keys)
			var b strings.Builder
			b.WriteString(`<?xml version="1.0"?><ListBucketResult><IsTruncated>false</IsTruncated>`)
			for _, k := range keys {
				b.WriteString("<Contents><Key>" + k + "</Key></Contents>")
			}
			b.WriteString("</ListBucketResult>")
			_, _ = w.Write([]byte(b.String()))
			return
		}
		key := strings.TrimPrefix(r.URL.Path, "/test/")
		switch r.Method {
		case http.MethodPut:
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			objects[key] = body
			mu.Unlock()
			w.WriteHeader(200)
		case http.MethodGet:
			mu.Lock()
			v, ok := objects[key]
			mu.Unlock()
			if !ok {
				w.WriteHeader(404)
				return
			}
			_, _ = w.Write(v)
		case http.MethodDelete:
			mu.Lock()
			delete(objects, key)
			mu.Unlock()
			w.WriteHeader(204)
		default:
			w.WriteHeader(405)
		}
	})), objects
}

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func bigKeys(n int, prefix byte) [][]byte {
	out := make([][]byte, n)
	for i := 0; i < n; i++ {
		k := make([]byte, 32)
		k[0] = prefix
		k[1] = byte(i >> 24)
		k[2] = byte(i >> 16)
		k[3] = byte(i >> 8)
		k[4] = byte(i)
		for j := 5; j < 32; j++ {
			k[j] = byte('A' + (i % 26))
		}
		out[i] = k
	}
	return out
}

func wideKeys(n int) [][]byte {
	out := make([][]byte, n)
	for i := 0; i < n; i++ {
		k := make([]byte, 200)
		k[0] = byte(i >> 16)
		k[1] = byte(i >> 8)
		k[2] = byte(i)
		for j := 4; j < 200; j++ {
			k[j] = 'x'
		}
		out[i] = k
	}
	return out
}

func collect(c *Cursor) ([]string, error) {
	var out []string
	for !c.AtEnd {
		k, ok, err := c.Next()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
		out = append(out, string(k))
	}
	return out, nil
}

func TestPageCodecRoundTrip(t *testing.T) {
	keys := [][]byte{[]byte("apple"), []byte("apricot"), []byte("banana")}
	page := SerializePage(keys)
	got, err := DeserializePage(page)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || !bytes.Equal(got[0], keys[0]) || !bytes.Equal(got[2], keys[2]) {
		t.Fatalf("keys = %q", got)
	}
}

func TestEmptyTreeAtEnd(t *testing.T) {
	s := newTestStore(t)
	cur := NewCursor(s, 0, s.Trees()[0].RootUUID, s.Trees()[0].Height, false)
	if _, ok, _ := cur.Peek(); ok {
		t.Fatal("empty tree should be at end")
	}
	if err := cur.Seek([]byte{5}); err != nil {
		t.Fatal(err)
	}
	if !cur.AtEnd {
		t.Fatal("seek in empty tree should stay at end")
	}
}

func TestSingleLeafSeek(t *testing.T) {
	s := newTestStore(t)
	keys := bigKeys(2000, 0)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: keys}); err != nil {
		t.Fatal(err)
	}
	tree := s.Trees()[0]
	cur := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	if err := cur.Seek(keys[1000]); err != nil {
		t.Fatal(err)
	}
	k, ok, _ := cur.Peek()
	if !ok || !bytes.Equal(k, keys[1000]) {
		t.Fatalf("seek landed on %x", k)
	}
	// Seek before all.
	if err := cur.Seek([]byte{0, 0, 0, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if got, _ := collect(cur); len(got) != 2000 || got[0] != string(keys[0]) {
		t.Fatalf("scan after before-all = %d", len(got))
	}
	// Seek after all.
	cur2 := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	if err := cur2.Seek([]byte{0xFF}); err != nil {
		t.Fatal(err)
	}
	if !cur2.AtEnd {
		t.Fatal("seek after all should be at end")
	}
}

func TestMultiLeafSeekAndCross(t *testing.T) {
	s := newTestStore(t)
	keys := wideKeys(8000)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: keys}); err != nil {
		t.Fatal(err)
	}
	tree := s.Trees()[0]
	if tree.Height != 1 {
		t.Fatalf("height = %d, want 1", tree.Height)
	}
	cur := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	fwd, err := collect(cur)
	if err != nil {
		t.Fatal(err)
	}
	if len(fwd) != 8000 {
		t.Fatalf("forward scan = %d", len(fwd))
	}
	mid := 4000
	cur2 := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	if err := cur2.Seek(keys[mid]); err != nil {
		t.Fatal(err)
	}
	rest, err := collect(cur2)
	if err != nil {
		t.Fatal(err)
	}
	if len(rest) != 8000-mid || rest[0] != fwd[mid] {
		t.Fatalf("rest scan = %d, first match=%v", len(rest), rest[0] == fwd[mid])
	}
}

func TestCowsnapshotPinned(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(10, 0)}); err != nil {
		t.Fatal(err)
	}
	tree := s.Trees()[0]
	cur := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: bigKeys(10, 1)}); err != nil {
		t.Fatal(err)
	}
	got, _ := collect(cur)
	if len(got) != 10 {
		t.Fatalf("pinned cursor saw %d keys, want 10", len(got))
	}
	cur2 := NewCursor(s, 0, s.Trees()[0].RootUUID, s.Trees()[0].Height, false)
	got2, _ := collect(cur2)
	if len(got2) != 20 {
		t.Fatalf("fresh cursor saw %d keys, want 20", len(got2))
	}
}

func TestKvCommitAndScan(t *testing.T) {
	s := newTestStore(t)
	pairs := [][2][]byte{
		{[]byte("k1"), []byte("v1")},
		{[]byte("k2"), []byte("v2")},
		{[]byte("k3"), []byte("v3")},
	}
	if _, err := s.CommitMergeKv(map[int][][2][]byte{10: pairs}, nil); err != nil {
		t.Fatal(err)
	}
	cur := NewCursor(s, 10, s.Trees()[10].RootUUID, s.Trees()[10].Height, true)
	var got [][2][]byte
	for !cur.AtEnd {
		p, ok, err := cur.NextKv()
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			break
		}
		got = append(got, p)
	}
	if len(got) != 3 || string(got[1][0]) != "k2" || string(got[1][1]) != "v2" {
		t.Fatalf("kv scan = %q", got)
	}
	if v, ok, _ := s.KeyExistsKv(10, []byte("k3")); !ok || string(v) != "v3" {
		t.Fatalf("KeyExistsKv = %q %v", v, ok)
	}
}

// TestPooledMergeIntoExistingTree exercises the blob pool on the merge path:
// a second merge into a populated tree must write leaf/index pages through the
// worker pool and yield the full union.
func TestPooledMergeIntoExistingTree(t *testing.T) {
	s := newTestStore(t)
	keys := wideKeys(8000)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: keys}); err != nil {
		t.Fatal(err)
	}
	extra := make([][]byte, 4000)
	for i := range extra {
		k := append([]byte(nil), keys[i*2]...)
		k[3] = 1 // interleave within the same 3-byte prefix group
		extra[i] = k
	}
	if _, err := s.CommitMergeMap(map[int][][]byte{0: extra}); err != nil {
		t.Fatal(err)
	}
	tree := s.Trees()[0]
	cur := NewCursor(s, 0, tree.RootUUID, tree.Height, false)
	got, err := collect(cur)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 12000 {
		t.Fatalf("scan = %d, want 12000", len(got))
	}
}

// TestPageStoreS3Backend exercises the pagestore over the S3 backend against a
// minimal in-process S3 (writes pages/roots, reopens and reads back).
func TestPageStoreS3Backend(t *testing.T) {
	srv, _ := newFakeS3(t)
	defer srv.Close()
	cfg := Config{
		Backend: "s3", Path: t.TempDir(), NumCf: 8, PageCacheSize: 1 << 20,
		S3: blobstore.S3Config{Endpoint: srv.URL, Bucket: "test", AccessKey: "a", SecretKey: "s", PathStyle: true},
	}
	s, err := Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	keys := wideKeys(4000)
	if _, err := s.CommitMergeMap(map[int][][]byte{0: keys}); err != nil {
		t.Fatal(err)
	}
	_ = s.Close()

	s2, err := Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	tree := s2.Trees()[0]
	cur := NewCursor(s2, 0, tree.RootUUID, tree.Height, false)
	got, err := collect(cur)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4000 {
		t.Fatalf("scan = %d, want 4000", len(got))
	}
}
