// Package blobstore is the file-backed BlobStore: 2-level hex-sharded blobs
// under "<path>/blobs", plus named roots "<path>/blobs/root_*".  Port of
// nim_blobstore/file/file_backend.nim.
package blobstore

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ID is a 16-byte blob identifier.
type ID [16]byte

const hexChars = "0123456789abcdef"

// FileBlobStore is a file-backed blob store.
type FileBlobStore struct {
	base     string
	readOnly bool
}

// New creates a file blob store rooted at path (blobs live in path/blobs).
func New(path string, readOnly bool) (*FileBlobStore, error) {
	s := &FileBlobStore{base: filepath.Join(path, "blobs"), readOnly: readOnly}
	if !readOnly {
		if err := os.MkdirAll(s.base, 0o755); err != nil {
			return nil, fmt.Errorf("createDir %s: %w", s.base, err)
		}
	}
	return s, nil
}

// Base returns the blobs directory.
func (s *FileBlobStore) Base() string { return s.base }

func (s *FileBlobStore) failReadOnly() error {
	if s.readOnly {
		return fmt.Errorf("read-only")
	}
	return nil
}

func idToHex(id ID) string {
	out := make([]byte, 32)
	for i, b := range id {
		out[i*2] = hexChars[b>>4]
		out[i*2+1] = hexChars[b&0x0f]
	}
	return string(out)
}

func hexToID(s string) (ID, bool) {
	var id ID
	if len(s) != 32 {
		return id, false
	}
	for i := 0; i < 16; i++ {
		hi, ok1 := hexNibble(s[i*2])
		lo, ok2 := hexNibble(s[i*2+1])
		if !ok1 || !ok2 {
			return id, false
		}
		id[i] = hi<<4 | lo
	}
	return id, true
}

func hexNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

func (s *FileBlobStore) path(id ID) string {
	hex := idToHex(id)
	return filepath.Join(s.base, hex[0:2], hex[2:4], hex)
}

func writeAtomic(path string, data []byte) error {
	parent := filepath.Dir(path)
	if parent != "" && parent != "." {
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return fmt.Errorf("createDir %s: %w", parent, err)
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmp, path, err)
	}
	return nil
}

// Put stores data under a fresh random id.
func (s *FileBlobStore) Put(data []byte) (ID, error) {
	var id ID
	if err := s.failReadOnly(); err != nil {
		return id, err
	}
	if _, err := rand.Read(id[:]); err != nil {
		return id, fmt.Errorf("urandom: %w", err)
	}
	if err := writeAtomic(s.path(id), data); err != nil {
		return id, fmt.Errorf("put: %w", err)
	}
	return id, nil
}

// PutAt stores data under a caller-chosen id.
func (s *FileBlobStore) PutAt(id ID, data []byte) error {
	if err := s.failReadOnly(); err != nil {
		return err
	}
	if err := writeAtomic(s.path(id), data); err != nil {
		return fmt.Errorf("putAt: %w", err)
	}
	return nil
}

// Get returns the blob, or (nil, false) when absent.
func (s *FileBlobStore) Get(id ID) ([]byte, bool, error) {
	path := s.path(id)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("get: %w", err)
	}
	return data, true, nil
}

// Delete removes a blob (best-effort when absent).
func (s *FileBlobStore) Delete(id ID) error {
	if err := s.failReadOnly(); err != nil {
		return err
	}
	path := s.path(id)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("delete: %w", err)
	}
	return nil
}

// List returns all blob ids.
func (s *FileBlobStore) List() ([]ID, error) {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []ID
	for _, e1 := range entries {
		if !e1.IsDir() {
			continue
		}
		shard1, err := os.ReadDir(filepath.Join(s.base, e1.Name()))
		if err != nil {
			continue
		}
		for _, e2 := range shard1 {
			if !e2.IsDir() {
				continue
			}
			shard2, err := os.ReadDir(filepath.Join(s.base, e1.Name(), e2.Name()))
			if err != nil {
				continue
			}
			for _, e3 := range shard2 {
				if e3.IsDir() || strings.HasSuffix(e3.Name(), ".tmp") {
					continue
				}
				if id, ok := hexToID(e3.Name()); ok {
					out = append(out, id)
				}
			}
		}
	}
	return out, nil
}

// PutRoot writes a named root.
func (s *FileBlobStore) PutRoot(name string, data []byte) error {
	if err := s.failReadOnly(); err != nil {
		return err
	}
	if err := writeAtomic(filepath.Join(s.base, name), data); err != nil {
		return fmt.Errorf("putRoot: %w", err)
	}
	return nil
}

// GetRoot returns a named root, or (nil, false) when absent.
func (s *FileBlobStore) GetRoot(name string) ([]byte, bool, error) {
	data, err := os.ReadFile(filepath.Join(s.base, name))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("getRoot: %w", err)
	}
	return data, true, nil
}

// ListRoots returns the sorted names of roots ("root_*").
func (s *FileBlobStore) ListRoots() ([]string, error) {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(name, "root_") && !strings.HasSuffix(name, ".tmp") {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out, nil
}

// DeleteRoot removes a named root.
func (s *FileBlobStore) DeleteRoot(name string) error {
	if err := s.failReadOnly(); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(s.base, name)); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("deleteRoot: %w", err)
	}
	return nil
}
