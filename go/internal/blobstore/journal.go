// journal.go — sequential file-backed journal.  Port of
// nim_blobstore/journal/journal_backend.nim.
//
// The on-disk file lives at `<path>/journal/journal`.  Frame format
// (big-endian, matching the Rust `JournalFile`):
//
//	[u32 klen][key bytes][u32 vlen][value bytes]
//
// NOTE: the Go WAL + legacy datom journal supersede the page store's use of
// this marker journal, so it is provided as a standalone, tested primitive
// and is not wired into the page-store commit path (unlike Nim, which
// truncates it after each commit — a no-op there since nothing appends).
package blobstore

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
)

// Journal is a sequential append-only frame log.
type Journal struct {
	path string
}

// NewJournal opens (creating the directory for) a journal at path.
func NewJournal(path string) (*Journal, error) {
	if path == "" {
		return nil, fmt.Errorf("journal path is empty")
	}
	if err := os.MkdirAll(filepath.Join(path, "journal"), 0o755); err != nil {
		return nil, fmt.Errorf("cannot create journal directory: %w", err)
	}
	return &Journal{path: path}, nil
}

func (j *Journal) fullPath() string { return filepath.Join(j.path, "journal", "journal") }

// Append writes one [klen][key][vlen][value] frame.
func (j *Journal) Append(key, value []byte) error {
	if j == nil {
		return fmt.Errorf("journal not open")
	}
	f, err := os.OpenFile(j.fullPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("journal append: %w", err)
	}
	defer f.Close()
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(key)))
	if _, err := f.Write(hdr[:]); err != nil {
		return err
	}
	if _, err := f.Write(key); err != nil {
		return err
	}
	binary.BigEndian.PutUint32(hdr[:], uint32(len(value)))
	if _, err := f.Write(hdr[:]); err != nil {
		return err
	}
	if _, err := f.Write(value); err != nil {
		return err
	}
	return nil
}

// Entry is one decoded journal frame.
type Entry struct {
	Key   []byte
	Value []byte
}

// ReadAll decodes every frame; a truncated/trailing-garbage file is an error.
func (j *Journal) ReadAll() ([]Entry, error) {
	data, err := os.ReadFile(j.fullPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("journal read: %w", err)
	}
	var out []Entry
	pos := 0
	for pos+4 <= len(data) {
		klen := int(binary.BigEndian.Uint32(data[pos:]))
		pos += 4
		if pos+klen > len(data) {
			return nil, fmt.Errorf("journal read: truncated key")
		}
		key := append([]byte(nil), data[pos:pos+klen]...)
		pos += klen
		if pos+4 > len(data) {
			return nil, fmt.Errorf("journal read: truncated vlen")
		}
		vlen := int(binary.BigEndian.Uint32(data[pos:]))
		pos += 4
		if pos+vlen > len(data) {
			return nil, fmt.Errorf("journal read: truncated value")
		}
		val := append([]byte(nil), data[pos:pos+vlen]...)
		pos += vlen
		out = append(out, Entry{Key: key, Value: val})
	}
	if pos < len(data) {
		return nil, fmt.Errorf("journal read: trailing garbage after last frame")
	}
	return out, nil
}

// Truncate removes the journal file (best-effort when absent).
func (j *Journal) Truncate() error {
	if j == nil {
		return nil
	}
	if err := os.Remove(j.fullPath()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("journal truncate: %w", err)
	}
	return nil
}

// Len returns the journal file size in bytes (0 when absent).
func (j *Journal) Len() uint64 {
	info, err := os.Stat(j.fullPath())
	if err != nil {
		return 0
	}
	return uint64(info.Size())
}

// Close releases the journal (no-op; present for API parity).
func (j *Journal) Close() {}
