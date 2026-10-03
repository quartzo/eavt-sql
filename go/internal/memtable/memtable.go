// Package memtable is the M8 run-ladder memtable: writes append O(1)
// self-contained records into the delta buffer; materialization sorts the
// delta into a frozen sorted run; runs merge past 8.  Port of nim_memtable
// (runs.nim + run_cursor.nim).  Go slices replace the arena/borrowed-key
// machinery (records are owned byte slices).
//
// Threading: a single mutex guards the ladder (buf/runs/draining/cfSize).
// Runs are IMMUTABLE once materialized, so a snapshot ([SnapshotRuns] /
// [FreezeAllCapture]) hands out *Run pointers that readers may iterate
// concurrently with later writes/flushes without holding the lock — this is
// the memtable half of the snapshot contract (nim_memtable's ARC-frozen
// runs).
package memtable

import (
	"sort"
	"sync"
)

const (
	MaxActiveRuns = 8
	MaxBufEntries = 65536
)

// Run is an immutable sorted list of records.
type Run struct {
	Records [][]byte // sorted by key
	KV      bool
}

// KvLookup is the result of a point lookup.
type KvLookup int

const (
	KvAbsent KvLookup = iota
	KvDeleted
	KvValue
)

// MemTable is the run ladder for all column families.
type MemTable struct {
	mu       sync.Mutex
	numCf    int
	gen      uint64
	runs     [][]*Run
	draining [][]*Run
	buf      [][][]byte
	cfSize   []int
}

// New creates a memtable with numCf column families.
func New(numCf int) *MemTable {
	if numCf <= 0 {
		panic("memtable: numCf must be > 0")
	}
	return &MemTable{
		numCf:    numCf,
		runs:     make([][]*Run, numCf),
		draining: make([][]*Run, numCf),
		buf:      make([][][]byte, numCf),
		cfSize:   make([]int, numCf),
	}
}

// NumCf returns the column-family count.
func (mt *MemTable) NumCf() int { return mt.numCf }

// Gen returns the generation counter (bumped on any ladder transition).
func (mt *MemTable) Gen() uint64 {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	return mt.gen
}

// RunCounts returns the total active and draining run counts across all CFs.
func (mt *MemTable) RunCounts() (active, draining int) {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for cf := 0; cf < mt.numCf; cf++ {
		active += len(mt.runs[cf])
		draining += len(mt.draining[cf])
	}
	return
}

// Size returns the active key bytes.
func (mt *MemTable) Size() uint64 {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	return mt.sizeLocked()
}

func (mt *MemTable) sizeLocked() uint64 {
	sz := 0
	for _, s := range mt.cfSize {
		sz += s
	}
	return uint64(sz)
}

// ── record accessors (unified layout, key at p+5) ────────────────────────

func recKlen(p []byte) int {
	return int(p[1])<<24 | int(p[2])<<16 | int(p[3])<<8 | int(p[4])
}

func recDeleted(p []byte) bool { return p[0]&1 != 0 }

func recKey(p []byte) []byte {
	klen := recKlen(p)
	return p[5 : 5+klen]
}

func recVlen(p []byte) int {
	klen := recKlen(p)
	o := 5 + klen
	return int(p[o])<<24 | int(p[o+1])<<16 | int(p[o+2])<<8 | int(p[o+3])
}

func recValue(p []byte) []byte {
	klen := recKlen(p)
	o := 9 + klen
	return p[o : o+recVlen(p)]
}

// CmpRec compares two records byte-lexicographically by key.
func CmpRec(a, b []byte) int { return CmpKeys(recKey(a), recKey(b)) }

// CmpKeys compares two byte keys.
func CmpKeys(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	}
	return 0
}

// ── write path ───────────────────────────────────────────────────────────

func (mt *MemTable) appendRecLocked(cf, klen int, deleted bool, key, value []byte) {
	kv := cf >= 10
	vlen := 0
	if kv {
		vlen = len(value)
	}
	total := 5 + klen
	if kv {
		total += 4 + vlen
	}
	p := make([]byte, total)
	if deleted {
		p[0] |= 1
	}
	if kv {
		p[0] |= 2
	}
	p[1] = byte(klen >> 24)
	p[2] = byte(klen >> 16)
	p[3] = byte(klen >> 8)
	p[4] = byte(klen)
	copy(p[5:], key)
	if kv {
		o := 5 + klen
		p[o] = byte(vlen >> 24)
		p[o+1] = byte(vlen >> 16)
		p[o+2] = byte(vlen >> 8)
		p[o+3] = byte(vlen)
		copy(p[o+4:], value)
	}
	mt.buf[cf] = append(mt.buf[cf], p)
	mt.cfSize[cf] += klen
	if len(mt.buf[cf]) >= MaxBufEntries {
		mt.materializeLocked(cf)
		mt.maybeMergeLocked(cf)
	}
}

// Put appends a key-only record.
func (mt *MemTable) Put(cf int, key []byte) uint64 {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	mt.appendRecLocked(cf, len(key), false, key, nil)
	return mt.sizeLocked()
}

// PutKv appends a key-value record to a KV cf.
func (mt *MemTable) PutKv(cf int, key, value []byte) uint64 {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	mt.appendRecLocked(cf, len(key), false, key, value)
	return mt.sizeLocked()
}

// DeleteKv appends a tombstone.
func (mt *MemTable) DeleteKv(cf int, key []byte) {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	mt.appendRecLocked(cf, len(key), true, key, nil)
}

// Batch appends many key-only records.
func (mt *MemTable) Batch(entries []CfKey) uint64 {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for _, e := range entries {
		cf := int(e.Cf)
		if cf < 0 || cf >= mt.numCf {
			continue
		}
		mt.appendRecLocked(cf, len(e.Key), false, e.Key, nil)
	}
	return mt.sizeLocked()
}

// CfKey is a column family + key.
type CfKey struct {
	Cf  uint8
	Key []byte
}

// ── materialize / merge ──────────────────────────────────────────────────

func (mt *MemTable) materializeLocked(cf int) {
	if len(mt.buf[cf]) == 0 {
		return
	}
	bufSum := 0
	for _, p := range mt.buf[cf] {
		bufSum += recKlen(p)
	}
	order := make([]int, len(mt.buf[cf]))
	for i := range order {
		order[i] = i
	}
	buf := mt.buf[cf]
	sort.Slice(order, func(i, j int) bool {
		a, b := order[i], order[j]
		if c := CmpRec(buf[a], buf[b]); c != 0 {
			return c < 0
		}
		return a < b
	})
	var records [][]byte
	keptBytes := 0
	i := 0
	for i < len(order) {
		j := i
		for j+1 < len(order) && CmpRec(buf[order[j]], buf[order[j+1]]) == 0 {
			j++
		}
		win := buf[order[j]]
		records = append(records, win)
		keptBytes += recKlen(win)
		i = j + 1
	}
	mt.runs[cf] = append(mt.runs[cf], &Run{Records: records, KV: cf >= 10})
	mt.buf[cf] = nil
	mt.cfSize[cf] -= bufSum - keptBytes
	mt.gen++
}

func (mt *MemTable) maybeMergeLocked(cf int) {
	if len(mt.runs[cf]) <= MaxActiveRuns {
		return
	}
	var merged [][]byte
	var origin []int
	for ri, r := range mt.runs[cf] {
		for _, p := range r.Records {
			merged = append(merged, p)
			origin = append(origin, ri)
		}
	}
	order := make([]int, len(merged))
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(i, j int) bool {
		a, b := order[i], order[j]
		if c := CmpRec(merged[a], merged[b]); c != 0 {
			return c < 0
		}
		return origin[a] < origin[b]
	})
	var records [][]byte
	i := 0
	for i < len(order) {
		j := i
		for j+1 < len(order) && CmpRec(merged[order[j]], merged[order[j+1]]) == 0 {
			j++
		}
		records = append(records, merged[order[j]])
		i = j + 1
	}
	mt.runs[cf] = []*Run{{Records: records, KV: cf >= 10}}
	mt.gen++
}

// EnsureMaterialized materializes the delta before scans.
func (mt *MemTable) EnsureMaterialized(cf int) {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	mt.materializeLocked(cf)
	mt.maybeMergeLocked(cf)
}

// MaybeCapBuf materializes incrementally past the delta cap.
func (mt *MemTable) MaybeCapBuf(cf int) {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	if len(mt.buf[cf]) >= MaxBufEntries {
		mt.materializeLocked(cf)
		mt.maybeMergeLocked(cf)
	}
}

// MaterializeAll materializes every CF.
func (mt *MemTable) MaterializeAll() {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for cf := 0; cf < mt.numCf; cf++ {
		mt.materializeLocked(cf)
		mt.maybeMergeLocked(cf)
	}
}

// SnapshotRuns materializes the delta and returns the immutable run set for a
// CF (draining first, then active).  The returned *Run values are immutable;
// the caller iterates them without holding the lock.
func (mt *MemTable) SnapshotRuns(cf int) []*Run {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	mt.materializeLocked(cf)
	mt.maybeMergeLocked(cf)
	out := make([]*Run, 0, len(mt.draining[cf])+len(mt.runs[cf]))
	out = append(out, mt.draining[cf]...)
	out = append(out, mt.runs[cf]...)
	return out
}

// FreezeAllCapture captures the live ladder: delta → run, active → draining,
// fresh generation, and returns the captured draining runs per CF (immutable)
// so a flush can drain them off the lock.
func (mt *MemTable) FreezeAllCapture() [][]*Run {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for cf := 0; cf < mt.numCf; cf++ {
		mt.materializeLocked(cf)
		mt.maybeMergeLocked(cf)
	}
	captured := make([][]*Run, mt.numCf)
	for cf := 0; cf < mt.numCf; cf++ {
		mt.draining[cf] = mt.runs[cf]
		mt.runs[cf] = nil
		mt.buf[cf] = nil
		mt.cfSize[cf] = 0
		captured[cf] = append([]*Run(nil), mt.draining[cf]...)
	}
	mt.gen++
	return captured
}

// Publish discards draining runs after a flush.
func (mt *MemTable) Publish() {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for cf := 0; cf < mt.numCf; cf++ {
		mt.draining[cf] = nil
	}
	mt.gen++
}

// Clear drops everything.
func (mt *MemTable) Clear() {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	for cf := 0; cf < mt.numCf; cf++ {
		mt.runs[cf] = nil
		mt.draining[cf] = nil
		mt.buf[cf] = nil
		mt.cfSize[cf] = 0
	}
	mt.gen++
}

// ── point lookups ────────────────────────────────────────────────────────

func (mt *MemTable) findBufLocked(cf int, key []byte) []byte {
	for i := len(mt.buf[cf]) - 1; i >= 0; i-- {
		p := mt.buf[cf][i]
		if CmpKeys(recKey(p), key) == 0 {
			return p
		}
	}
	return nil
}

func findRun(r *Run, key []byte) []byte {
	lo, hi := 0, len(r.Records)
	for lo < hi {
		mid := (lo + hi) >> 1
		if CmpKeys(recKey(r.Records[mid]), key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(r.Records) && CmpKeys(recKey(r.Records[lo]), key) == 0 {
		return r.Records[lo]
	}
	return nil
}

// LookupKv resolves a key across buf -> runs -> draining (newest first).
func (mt *MemTable) LookupKv(cf int, key []byte) KvLookup {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	return mt.lookupKvLocked(cf, key)
}

func (mt *MemTable) lookupKvLocked(cf int, key []byte) KvLookup {
	if b := mt.findBufLocked(cf, key); b != nil {
		if recDeleted(b) {
			return KvDeleted
		}
		return KvValue
	}
	for i := len(mt.runs[cf]) - 1; i >= 0; i-- {
		if p := findRun(mt.runs[cf][i], key); p != nil {
			if recDeleted(p) {
				return KvDeleted
			}
			return KvValue
		}
	}
	for i := len(mt.draining[cf]) - 1; i >= 0; i-- {
		if p := findRun(mt.draining[cf][i], key); p != nil {
			if recDeleted(p) {
				return KvDeleted
			}
			return KvValue
		}
	}
	return KvAbsent
}

// GetValue returns the active value for a KV key.
func (mt *MemTable) GetValue(cf int, key []byte) ([]byte, bool) {
	mt.mu.Lock()
	defer mt.mu.Unlock()
	if mt.lookupKvLocked(cf, key) != KvValue {
		return nil, false
	}
	if b := mt.findBufLocked(cf, key); b != nil && !recDeleted(b) {
		return copyBytes(recValue(b)), true
	}
	for i := len(mt.runs[cf]) - 1; i >= 0; i-- {
		if p := findRun(mt.runs[cf][i], key); p != nil && !recDeleted(p) {
			return copyBytes(recValue(p)), true
		}
	}
	for i := len(mt.draining[cf]) - 1; i >= 0; i-- {
		if p := findRun(mt.draining[cf][i], key); p != nil && !recDeleted(p) {
			return copyBytes(recValue(p)), true
		}
	}
	return nil, false
}

// ContainsAny reports whether the key is present (including tombstones).
func (mt *MemTable) ContainsAny(cf int, key []byte) bool {
	return mt.LookupKv(cf, key) != KvAbsent
}

func copyBytes(b []byte) []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

// ── drain (flush) — k-way sobre runs congelados, newest-wins ─────────────

// DrainSorted merges runs (old -> new) into ascending deduped keys.
func DrainSorted(runs []*Run) [][]byte {
	k := len(runs)
	if k == 0 {
		return nil
	}
	heads := make([]int, k)
	var out [][]byte
	for {
		best := -1
		for i := 0; i < k; i++ {
			if heads[i] >= len(runs[i].Records) {
				continue
			}
			if best < 0 {
				best = i
				continue
			}
			c := CmpRec(runs[i].Records[heads[i]], runs[best].Records[heads[best]])
			if c < 0 || (c == 0 && i > best) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		win := runs[best].Records[heads[best]]
		out = append(out, copyBytes(recKey(win)))
		heads[best]++
		for i := 0; i < k; i++ {
			if i == best {
				continue
			}
			for heads[i] < len(runs[i].Records) && CmpRec(runs[i].Records[heads[i]], win) == 0 {
				heads[i]++
			}
		}
	}
	return out
}

// DrainKvSorted returns active pairs and tombstones, newest-wins.
func DrainKvSorted(runs []*Run) (pairs [][2][]byte, deleted [][]byte) {
	k := len(runs)
	if k == 0 {
		return nil, nil
	}
	heads := make([]int, k)
	for {
		best := -1
		for i := 0; i < k; i++ {
			if heads[i] >= len(runs[i].Records) {
				continue
			}
			if best < 0 {
				best = i
				continue
			}
			c := CmpRec(runs[i].Records[heads[i]], runs[best].Records[heads[best]])
			if c < 0 || (c == 0 && i > best) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		win := runs[best].Records[heads[best]]
		key := copyBytes(recKey(win))
		if recDeleted(win) {
			deleted = append(deleted, key)
		} else {
			pairs = append(pairs, [2][]byte{key, copyBytes(recValue(win))})
		}
		heads[best]++
		for i := 0; i < k; i++ {
			if i == best {
				continue
			}
			for heads[i] < len(runs[i].Records) && CmpRec(runs[i].Records[heads[i]], win) == 0 {
				heads[i]++
			}
		}
	}
	return pairs, deleted
}
