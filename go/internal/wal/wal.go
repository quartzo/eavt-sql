// Package wal is the segmented write-ahead log: a group-commit writer with
// segment rotation at flush-capture boundaries.  Port of eavt_transactor_nim/
// wal.nim (Go goroutines replace the chronos/chronos_file loop).
package wal

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"eavt-go/internal/memtable"
)

const (
	fsyncIntervalMs = 100
	segPrefix       = "journal."
	segDigits       = 5
)

type sealedSeg struct {
	idx      int
	path     string
	boundary int64
}

// Writer is the segmented WAL writer.
type Writer struct {
	mu           sync.Mutex
	dir          string
	segIdx       int
	f            *os.File
	offset       int64
	buf          []byte
	bufPos       int64
	logicalEnd   int64
	sealBoundary int64
	sealed       []sealedSeg
	stopped      bool
	durable      *atomic.Int64

	// OnWal is called (under the writer lock) with the WAL record bytes just
	// appended.  The callback must copy if it retains them.
	OnWal  func(data []byte)
	OnSeal func(segIdx int)
}

func segPath(dir string, idx int) string {
	return filepath.Join(dir, segPrefix+fmt.Sprintf("%0*d", segDigits, idx))
}

func openSeg(dir string, idx int) (*os.File, int64, error) {
	p := segPath(dir, idx)
	f, err := os.OpenFile(p, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, 0, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, st.Size(), nil
}

// Attach opens (or continues) the segmented WAL.
func Attach(dbPath string, durable *atomic.Int64) (*Writer, error) {
	dir := filepath.Join(dbPath, "journal")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	w := &Writer{dir: dir, sealBoundary: -1, durable: durable}
	maxIdx := -1
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasPrefix(name, segPrefix) {
			continue
		}
		if idx, err := strconv.Atoi(name[len(segPrefix):]); err == nil && idx > maxIdx {
			maxIdx = idx
		}
	}
	w.segIdx = maxIdx + 1
	f, off, err := openSeg(dir, w.segIdx)
	if err != nil {
		return nil, err
	}
	w.f = f
	w.offset = off
	go w.cycle()
	return w, nil
}

// Sink serializes journal entries into the WAL buffer (called under the
// engine lock on the write path).
func (w *Writer) Sink(entries []memtable.CfKey) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped {
		return
	}
	base := len(w.buf)
	total := 0
	for _, e := range entries {
		total += 10 + len(e.Key)
	}
	w.buf = append(w.buf, make([]byte, total)...)
	pos := base
	for _, e := range entries {
		klen := len(e.Key)
		totKlen := 1 + klen
		w.buf[pos] = byte(totKlen >> 24)
		w.buf[pos+1] = byte(totKlen >> 16)
		w.buf[pos+2] = byte(totKlen >> 8)
		w.buf[pos+3] = byte(totKlen)
		w.buf[pos+4] = e.Cf
		copy(w.buf[pos+5:], e.Key)
		w.buf[pos+5+klen] = 0
		w.buf[pos+6+klen] = 0
		w.buf[pos+7+klen] = 0
		w.buf[pos+8+klen] = 1
		w.buf[pos+9+klen] = 0
		pos += 10 + klen
	}
	w.logicalEnd += int64(total)
	if w.OnWal != nil && pos > base {
		w.OnWal(w.buf[base:pos])
	}
}

// Seal marks the current logical end as a segment boundary.
func (w *Writer) Seal() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.sealBoundary = w.logicalEnd
	return w.logicalEnd
}

// Drain flushes pending buffers to disk once.
func (w *Writer) Drain() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.drainLocked()
}

func (w *Writer) drainLocked() error {
	for {
		if w.sealBoundary >= 0 {
			split := 0
			if w.sealBoundary > w.bufPos {
				d := int(w.sealBoundary - w.bufPos)
				if d > len(w.buf) {
					d = len(w.buf)
				}
				split = d
			}
			if split > 0 {
				if _, err := w.f.WriteAt(w.buf[:split], w.offset); err != nil {
					return err
				}
				w.offset += int64(split)
				w.bufPos += int64(split)
				w.buf = w.buf[split:]
			}
			if w.bufPos >= w.sealBoundary {
				_ = w.f.Close()
				sealedIdx := w.segIdx
				w.sealed = append(w.sealed, sealedSeg{idx: sealedIdx, path: segPath(w.dir, sealedIdx), boundary: w.sealBoundary})
				w.segIdx++
				if w.OnSeal != nil {
					w.OnSeal(sealedIdx)
				}
				f, off, err := openSeg(w.dir, w.segIdx)
				if err != nil {
					return err
				}
				w.f = f
				w.offset = off
				w.sealBoundary = -1
			}
			if len(w.buf) == 0 {
				return nil
			}
			continue
		}
		if len(w.buf) == 0 {
			return nil
		}
		if _, err := w.f.WriteAt(w.buf, w.offset); err != nil {
			return err
		}
		w.offset += int64(len(w.buf))
		w.bufPos += int64(len(w.buf))
		w.buf = nil
		return nil
	}
}

func (w *Writer) deleteDurable() {
	w.mu.Lock()
	defer w.mu.Unlock()
	durable := int64(-1)
	if w.durable != nil {
		durable = w.durable.Load()
	}
	for len(w.sealed) > 0 && w.sealed[0].boundary <= durable {
		if err := os.Remove(w.sealed[0].path); err != nil {
			break
		}
		w.sealed = w.sealed[1:]
	}
}

func (w *Writer) cycle() {
	t := time.NewTicker(fsyncIntervalMs * time.Millisecond)
	defer t.Stop()
	for range t.C {
		w.mu.Lock()
		if w.stopped {
			w.mu.Unlock()
			return
		}
		if err := w.drainLocked(); err == nil {
			_ = w.f.Sync()
		}
		w.mu.Unlock()
		w.deleteDurable()
	}
}

// Stop drains, fsyncs and closes the WAL.
func (w *Writer) Stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped {
		return
	}
	w.stopped = true
	_ = w.drainLocked()
	_ = w.f.Sync()
	_ = w.f.Close()
}

// OpenTail returns a copy of the volatile (undrained) WAL buffer.
func (w *Writer) OpenTail() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.buf...)
}

// Segments lists all segment file paths (numerically sorted).
func Segments(dir string) []string {
	jdir := filepath.Join(dir, "journal")
	entries, err := os.ReadDir(jdir)
	if err != nil {
		return nil
	}
	type seg struct {
		idx  int
		path string
	}
	var segs []seg
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasPrefix(name, segPrefix) {
			continue
		}
		if idx, err := strconv.Atoi(name[len(segPrefix):]); err == nil {
			segs = append(segs, seg{idx: idx, path: filepath.Join(jdir, name)})
		}
	}
	sort.Slice(segs, func(i, j int) bool { return segs[i].idx < segs[j].idx })
	out := make([]string, len(segs))
	for i, s := range segs {
		out[i] = s.path
	}
	return out
}
