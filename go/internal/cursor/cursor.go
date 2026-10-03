// Package query holds the execution layer: cursor merge, scanner, hostfns
// and the engine.  This file ports nim_query/query/cursor.nim (MergedCursor +
// MinHeap + the Cursor dispatch), without the hydrated-entry optimization
// (added in the EAVT stage).
package cursor

import (
	"eavt-go/internal/hydrated"
	"eavt-go/internal/memtable"
	"eavt-go/internal/pagestore"
)

// Cursor is a forward cursor over a key source.
type Cursor interface {
	Valid() bool
	CurrentKey() ([]byte, bool)
	CurrentPair() ([2][]byte, bool)
	Step()
	Seek(target []byte)
	Invalidate()
}

// ── MinHeap ──────────────────────────────────────────────────────────────

type heapEntry struct {
	key []byte
	src int
}

type minHeap struct{ data []heapEntry }

func (h *minHeap) len() int { return len(h.data) }

func (h *minHeap) push(e heapEntry) {
	h.data = append(h.data, e)
	i := len(h.data) - 1
	for i > 0 {
		p := (i - 1) >> 1
		if pagestore.CmpSeq(h.data[i].key, h.data[p].key) < 0 {
			h.data[i], h.data[p] = h.data[p], h.data[i]
			i = p
		} else {
			break
		}
	}
}

func (h *minHeap) pop() heapEntry {
	result := h.data[0]
	h.data[0] = h.data[len(h.data)-1]
	h.data = h.data[:len(h.data)-1]
	i := 0
	for {
		l := 2*i + 1
		if l >= len(h.data) {
			break
		}
		smallest := i
		if pagestore.CmpSeq(h.data[l].key, h.data[smallest].key) < 0 {
			smallest = l
		}
		r := l + 1
		if r < len(h.data) && pagestore.CmpSeq(h.data[r].key, h.data[smallest].key) < 0 {
			smallest = r
		}
		if smallest != i {
			h.data[i], h.data[smallest] = h.data[smallest], h.data[i]
			i = smallest
		} else {
			break
		}
	}
	return result
}

// ── concrete cursors ─────────────────────────────────────────────────────

type pageStoreCursor struct{ ps *pagestore.Cursor }

// NewPageStoreCursor wraps a page-store cursor.
func NewPageStoreCursor(ps *pagestore.Cursor) Cursor { return &pageStoreCursor{ps: ps} }

func (c *pageStoreCursor) Valid() bool { return !c.ps.AtEnd }
func (c *pageStoreCursor) CurrentKey() ([]byte, bool) {
	k, ok, _ := c.ps.Peek()
	return k, ok
}
func (c *pageStoreCursor) CurrentPair() ([2][]byte, bool) {
	p, ok, _ := c.ps.PeekKv()
	return p, ok
}
func (c *pageStoreCursor) Step()         { c.ps.Next() }
func (c *pageStoreCursor) Seek(t []byte) { c.ps.Seek(t) }
func (c *pageStoreCursor) Invalidate()   { c.ps.AtEnd = true }

type runCursorC struct{ c *memtable.RunCursor }

// NewRunCursor wraps a key-only run cursor (tombstones included).
func NewRunCursor(rc *memtable.RunCursor) Cursor { return &runCursorC{c: rc} }

func (c *runCursorC) Valid() bool { return !c.c.AtEnd() }
func (c *runCursorC) CurrentKey() ([]byte, bool) {
	return c.c.Peek()
}
func (c *runCursorC) CurrentPair() ([2][]byte, bool) { return [2][]byte{}, false }
func (c *runCursorC) Step()                          { c.c.Next() }
func (c *runCursorC) Seek(t []byte)                  { c.c.Seek(t) }
func (c *runCursorC) Invalidate()                    { c.c.SetAtEnd(true) }

type runKvCursorC struct{ c *memtable.RunCursor }

// NewRunKvCursor wraps a run cursor for KV scans (skips tombstones).
func NewRunKvCursor(rc *memtable.RunCursor) Cursor { return &runKvCursorC{c: rc} }

func (c *runKvCursorC) Valid() bool { return !c.c.AtEnd() }
func (c *runKvCursorC) CurrentKey() ([]byte, bool) {
	p, ok := c.c.PeekKv()
	if !ok {
		return nil, false
	}
	return p[0], true
}
func (c *runKvCursorC) CurrentPair() ([2][]byte, bool) { return c.c.PeekKv() }
func (c *runKvCursorC) Step()                          { c.c.NextKv() }
func (c *runKvCursorC) Seek(t []byte)                  { c.c.Seek(t) }
func (c *runKvCursorC) Invalidate()                    { c.c.SetAtEnd(true) }

type mockCursor struct {
	keys [][]byte
	pos  int
}

// NewMockCursor creates a cursor over an in-memory sorted key slice.
func NewMockCursor(keys [][]byte) Cursor { return &mockCursor{keys: keys} }

func (c *mockCursor) Valid() bool { return c.pos < len(c.keys) }
func (c *mockCursor) CurrentKey() ([]byte, bool) {
	if c.pos < len(c.keys) {
		return c.keys[c.pos], true
	}
	return nil, false
}
func (c *mockCursor) CurrentPair() ([2][]byte, bool) { return [2][]byte{}, false }
func (c *mockCursor) Step()                          { c.pos++ }
func (c *mockCursor) Seek(target []byte) {
	lo, hi := 0, len(c.keys)
	for lo < hi {
		mid := (lo + hi) >> 1
		k := c.keys[mid]
		f := prefixCmp(k, target)
		if f < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	c.pos = lo
}
func (c *mockCursor) Invalidate() { c.pos = len(c.keys) }

// hydCursor iterates a hydrated entry's key set (M1/M6).  The keys are an
// owned snapshot taken at seek time — a concurrent mirrored write cannot
// mutate the slice under the cursor (the entry itself is copy-on-read).
type hydCursor struct {
	keys [][]byte
	pos  int
}

func (c *hydCursor) Valid() bool { return c.pos < len(c.keys) }
func (c *hydCursor) CurrentKey() ([]byte, bool) {
	if c.pos < len(c.keys) {
		return c.keys[c.pos], true
	}
	return nil, false
}
func (c *hydCursor) CurrentPair() ([2][]byte, bool) { return [2][]byte{}, false }
func (c *hydCursor) Step()                          { c.pos++ }
func (c *hydCursor) Seek(target []byte) {
	lo, hi := 0, len(c.keys)
	for lo < hi {
		mid := (lo + hi) >> 1
		if pagestore.CmpSeq(c.keys[mid], target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	c.pos = lo
}
func (c *hydCursor) Invalidate() { c.pos = len(c.keys) }

func beUint64Local(b []byte, off int) uint64 {
	return uint64(b[off])<<56 | uint64(b[off+1])<<48 | uint64(b[off+2])<<40 |
		uint64(b[off+3])<<32 | uint64(b[off+4])<<24 | uint64(b[off+5])<<16 |
		uint64(b[off+6])<<8 | uint64(b[off+7])
}

func decodeEIDLocal(x uint64) int64 { return int64(x ^ (uint64(1) << 63)) }

// prefixCmp compares k against target over target's length: -1 when k < target.
func prefixCmp(k, target []byte) int {
	for i := 0; i < len(target); i++ {
		if i >= len(k) {
			return -1
		}
		if k[i] < target[i] {
			return -1
		}
		if k[i] > target[i] {
			return 1
		}
	}
	return 0
}

// ── MergedCursor ─────────────────────────────────────────────────────────

// MergedCursor merges several sorted sources (page store + runs).
type MergedCursor struct {
	sources []Cursor
	heap    minHeap
	lastKey []byte
	hasLast bool
	atEnd   bool
	curKey  []byte
	hasKey  bool
	curPair [2][]byte
	hasPair bool

	IsKv       bool
	CF         int
	PSRootUUID pagestore.UUID
	PSHeight   uint8
	RunGen     uint64

	// M1/M6 hyd mode: a CF-0 seek anchored at a hydrated eid is served from
	// the entry's key set; base sources are parked for a later non-hydrated
	// seek.
	Hyd         *hydrated.Set
	hydMode     bool
	hydCursor   Cursor
	baseSources []Cursor
}

// NewMergedCursor builds a merged cursor and seeds the heap.
func NewMergedCursor(sources []Cursor) *MergedCursor {
	mc := &MergedCursor{sources: sources}
	for i, src := range sources {
		if src.Valid() {
			if k, ok := src.CurrentKey(); ok {
				mc.heap.push(heapEntry{key: k, src: i})
			}
		}
	}
	return mc
}

// AddSource adds a source before iteration starts.
func (mc *MergedCursor) AddSource(src Cursor) {
	mc.sources = append(mc.sources, src)
	if src.Valid() {
		if k, ok := src.CurrentKey(); ok {
			mc.heap.push(heapEntry{key: k, src: len(mc.sources) - 1})
		}
	}
}

func (mc *MergedCursor) advance() {
	if mc.atEnd {
		return
	}
	for mc.heap.len() > 0 {
		e := mc.heap.pop()
		if mc.hasLast && pagestore.CmpSeq(e.key, mc.lastKey) == 0 {
			src := mc.sources[e.src]
			if src.Valid() {
				src.Step()
				if src.Valid() {
					if nk, ok := src.CurrentKey(); ok {
						mc.heap.push(heapEntry{key: nk, src: e.src})
					}
				}
			}
			continue
		}
		mc.lastKey = e.key
		mc.hasLast = true
		mc.curKey = e.key
		mc.hasKey = true
		if mc.IsKv {
			mc.curPair, mc.hasPair = mc.sources[e.src].CurrentPair()
		}
		src := mc.sources[e.src]
		src.Step()
		if src.Valid() {
			if nk, ok := src.CurrentKey(); ok {
				mc.heap.push(heapEntry{key: nk, src: e.src})
			}
		}
		return
	}
	mc.atEnd = true
	mc.hasKey = false
	mc.hasPair = false
}

func (mc *MergedCursor) ensure() {
	if !mc.hasKey && !mc.atEnd && !mc.hasPair {
		mc.advance()
	}
}

// Peek returns the current key.
func (mc *MergedCursor) Peek() ([]byte, bool) {
	mc.ensure()
	if mc.atEnd {
		return nil, false
	}
	return mc.curKey, mc.hasKey
}

// Next returns the current key and advances.
func (mc *MergedCursor) Next() ([]byte, bool) {
	mc.ensure()
	k, ok := mc.curKey, mc.hasKey
	mc.hasKey = false
	mc.advance()
	return k, ok
}

// PeekKv returns the current pair.
func (mc *MergedCursor) PeekKv() ([2][]byte, bool) {
	mc.ensure()
	if mc.atEnd {
		return [2][]byte{}, false
	}
	return mc.curPair, mc.hasPair
}

// NextKv returns the current pair and advances.
func (mc *MergedCursor) NextKv() ([2][]byte, bool) {
	mc.ensure()
	p, ok := mc.curPair, mc.hasPair
	mc.hasPair = false
	mc.advance()
	return p, ok
}

// Seek repositions every source at the first key >= target.
func (mc *MergedCursor) Seek(target []byte) {
	// M6 hyd branch: a CF-0 seek anchored at a hydrated eid is served
	// exclusively by the entry (complete + current, kept read-your-writes by
	// the write-path mirror).
	if mc.Hyd != nil && mc.CF == 0 && len(target) >= 8 {
		eid := decodeEIDLocal(beUint64Local(target, 0))
		if mc.Hyd.ProbeComplete(eid) {
			keys := mc.Hyd.KeysFrom(eid, target)
			if !mc.hydMode {
				mc.baseSources = mc.sources
				mc.hydMode = true
			}
			hc := &hydCursor{keys: keys}
			mc.hydCursor = hc
			mc.sources = []Cursor{hc}
			mc.heap.data = nil
			if hc.Valid() {
				if k, ok := hc.CurrentKey(); ok {
					mc.heap.push(heapEntry{key: k, src: 0})
				}
			}
			mc.lastKey = nil
			mc.hasLast = false
			mc.atEnd = false
			mc.hasKey = false
			mc.hasPair = false
			mc.advance()
			return
		}
		if mc.hydMode {
			// Exit hyd mode: seek anchors at a non-hydrated eid.
			mc.sources = mc.baseSources
			mc.hydMode = false
		}
	}
	for _, src := range mc.sources {
		src.Seek(target)
	}
	mc.heap.data = nil
	for i, src := range mc.sources {
		if src.Valid() {
			if k, ok := src.CurrentKey(); ok {
				mc.heap.push(heapEntry{key: k, src: i})
			}
		}
	}
	mc.lastKey = nil
	mc.hasLast = false
	mc.atEnd = false
	mc.hasKey = false
	mc.hasPair = false
	mc.advance()
}

// ── Cursor interface over MergedCursor ───────────────────────────────────

func (mc *MergedCursor) Valid() bool { return !mc.atEnd }

func (mc *MergedCursor) CurrentKey() ([]byte, bool) { return mc.Peek() }

func (mc *MergedCursor) CurrentPair() ([2][]byte, bool) { return mc.PeekKv() }

func (mc *MergedCursor) Step() { mc.Next() }

func (mc *MergedCursor) Invalidate() { mc.atEnd = true }

// Update repoints the page source and re-collects runs when the generation
// changed.
func (mc *MergedCursor) Update(psRootUUID pagestore.UUID, psHeight uint8,
	draining, active []*memtable.Run, runGen uint64) {
	// In hyd mode the base sources are parked — update their roots so a later
	// exit resumes from current state.
	src := mc.sources
	if mc.hydMode {
		src = mc.baseSources
	}
	if len(src) > 0 {
		if pc, ok := src[0].(*pageStoreCursor); ok {
			if mc.PSRootUUID != psRootUUID {
				pc.ps.Update(psRootUUID, psHeight)
				mc.PSRootUUID = psRootUUID
				mc.PSHeight = psHeight
			}
		}
	}
	if mc.RunGen != runGen {
		mc.RunGen = runGen
		if len(src) > 1 {
			src = src[:1]
		}
		for _, r := range draining {
			if mc.IsKv {
				src = append(src, NewRunKvCursor(memtable.NewRunCursor(r)))
			} else {
				src = append(src, NewRunCursor(memtable.NewRunCursor(r)))
			}
		}
		for _, r := range active {
			if mc.IsKv {
				src = append(src, NewRunKvCursor(memtable.NewRunCursor(r)))
			} else {
				src = append(src, NewRunCursor(memtable.NewRunCursor(r)))
			}
		}
		if mc.hydMode {
			mc.baseSources = src
		} else {
			mc.sources = src
		}
	}
	mc.heap.data = nil
	mc.lastKey = nil
	mc.hasLast = false
	mc.hasKey = false
	mc.hasPair = false
	mc.atEnd = false
}

// invalidCursor is never valid; the initial cursor before SetCursor.
type invalidCursor struct{}

func (invalidCursor) Valid() bool                    { return false }
func (invalidCursor) CurrentKey() ([]byte, bool)     { return nil, false }
func (invalidCursor) CurrentPair() ([2][]byte, bool) { return [2][]byte{}, false }
func (invalidCursor) Step()                          {}
func (invalidCursor) Seek([]byte)                    {}
func (invalidCursor) Invalidate()                    {}

// Invalid returns a cursor that is never valid.
func Invalid() Cursor { return invalidCursor{} }
