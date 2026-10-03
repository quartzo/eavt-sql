package blobstore

import (
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
)

// fakeS3 is a minimal S3 endpoint that stores objects in a map and supports
// PUT/GET/DELETE + ListObjectsV2.  It requires the SigV4 headers to be present
// (does not verify the signature).
func fakeS3(t *testing.T) *httptest.Server {
	t.Helper()
	var mu sync.Mutex
	objects := map[string][]byte{}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" || r.Header.Get("x-amz-date") == "" {
			http.Error(w, "missing auth", http.StatusForbidden)
			return
		}
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
			b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated>`)
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
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			mu.Lock()
			v, ok := objects[key]
			mu.Unlock()
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			_, _ = w.Write(v)
		case http.MethodDelete:
			mu.Lock()
			delete(objects, key)
			mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
}

func newTestS3(t *testing.T) (*S3BlobStore, *httptest.Server) {
	t.Helper()
	srv := fakeS3(t)
	b, err := NewS3(S3Config{
		Endpoint: srv.URL, Bucket: "test", AccessKey: "ak", SecretKey: "sk", PathStyle: true,
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	return b, srv
}

func TestS3BackendRoundTrip(t *testing.T) {
	b, srv := newTestS3(t)
	defer srv.Close()

	id, err := b.Put([]byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	got, ok, err := b.Get(id)
	if err != nil || !ok || string(got) != "hello" {
		t.Fatalf("get = %q %v %v", got, ok, err)
	}
	if err := b.PutRoot("root_1", []byte("R")); err != nil {
		t.Fatal(err)
	}
	if gr, ok, err := b.GetRoot("root_1"); err != nil || !ok || string(gr) != "R" {
		t.Fatalf("getroot = %q %v %v", gr, ok, err)
	}
	roots, err := b.ListRoots()
	if err != nil || len(roots) != 1 || roots[0] != "root_1" {
		t.Fatalf("roots = %v %v", roots, err)
	}
	list, err := b.List()
	if err != nil || len(list) != 1 || list[0] != id {
		t.Fatalf("list = %v %v", list, err)
	}
	if err := b.Delete(id); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := b.Get(id); ok {
		t.Fatal("delete left the blob")
	}
	// Missing key is (nil, false, nil), not an error.
	if _, ok, err := b.Get(ID{9}); err != nil || ok {
		t.Fatalf("missing get = %v %v", ok, err)
	}
	if err := b.DeleteRoot("root_1"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := b.GetRoot("root_1"); ok {
		t.Fatal("deleteRoot left the root")
	}
}

func TestS3ReadOnlyRejectsWrites(t *testing.T) {
	srv := fakeS3(t)
	defer srv.Close()
	b, err := NewS3(S3Config{
		Endpoint: srv.URL, Bucket: "test", AccessKey: "ak", SecretKey: "sk", PathStyle: true,
	}, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.Put([]byte("x")); err == nil {
		t.Fatal("put on read-only must fail")
	}
	if err := b.PutRoot("r", nil); err == nil {
		t.Fatal("putRoot on read-only must fail")
	}
}

func TestS3MissingConfig(t *testing.T) {
	if _, err := NewS3(S3Config{Bucket: "b", AccessKey: "a", SecretKey: "s"}, false); err == nil {
		t.Fatal("missing endpoint must fail")
	}
	if _, err := NewS3(S3Config{Endpoint: "http://x", AccessKey: "a", SecretKey: "s"}, false); err == nil {
		t.Fatal("missing bucket must fail")
	}
}
