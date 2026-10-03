package blobstore

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestJournalAppendReadTruncate(t *testing.T) {
	dir := t.TempDir()
	j, err := NewJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	if j.Len() != 0 {
		t.Fatalf("empty len = %d", j.Len())
	}
	if err := j.Append([]byte("k1"), []byte("v1")); err != nil {
		t.Fatal(err)
	}
	if err := j.Append([]byte("k2"), nil); err != nil {
		t.Fatal(err)
	}
	if err := j.Append(nil, []byte("v3")); err != nil {
		t.Fatal(err)
	}
	entries, err := j.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 ||
		!bytes.Equal(entries[0].Key, []byte("k1")) || !bytes.Equal(entries[0].Value, []byte("v1")) ||
		!bytes.Equal(entries[1].Key, []byte("k2")) || len(entries[1].Value) != 0 ||
		len(entries[2].Key) != 0 || !bytes.Equal(entries[2].Value, []byte("v3")) {
		t.Fatalf("entries = %#v", entries)
	}
	if j.Len() == 0 {
		t.Fatal("len should be non-zero after appends")
	}
	if err := j.Truncate(); err != nil {
		t.Fatal(err)
	}
	if entries, _ := j.ReadAll(); len(entries) != 0 {
		t.Fatalf("after truncate = %#v", entries)
	}
}

func TestJournalTrailingGarbage(t *testing.T) {
	dir := t.TempDir()
	j, err := NewJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := j.Append([]byte("k"), []byte("v")); err != nil {
		t.Fatal(err)
	}
	// Append one stray byte -> trailing garbage.
	f, err := os.OpenFile(filepath.Join(dir, "journal", "journal"), os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.Write([]byte{0x00})
	_ = f.Close()
	if _, err := j.ReadAll(); err == nil {
		t.Fatal("trailing garbage must error")
	}
}
