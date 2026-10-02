// Package memtable is the M8 run-ladder memtable: writes append O(1)
// self-contained records into the delta buffer; materialization sorts the
// delta into a frozen sorted run; runs merge past 8.  Port of nim_memtable
// (runs.nim + run_cursor.nim).  Go slices replace the arena/borrowed-key
// machinery (records are owned byte slices).
package memtable

import "sort"

const (
	MaxActiveRuns = 8
	MaxBufEntries = 65536
)

// Run is an immutable sorted list of records.
type Run struct {
	Records [][]byte // sorted by key
	KV      bool
	// Key counts for size accounting are not needed here.
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

// Size returns the active key bytes.
func (mt *MemTable) Size() uint64 {
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

func recIsKV(p []byte) bool { return p[0]&2 != 0 }

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
func CmpRec(a, b []byte) int {
	return CmpKeys(recKey(a), recKey(b))
}

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

func (mt *MemTable) appendRec(cf, klen int, deleted bool, key, value []byte) uint64 {
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
		mt.Materialize(cf)
		mt.MaybeMerge(cf)
	}
	return mt.Size()
}

// Put appends a key-only record.
func (mt *MemTable) Put(cf int, key []byte) uint64 {
	if cf < 0 || cf >= mt.numCf {
		panic("memtable: invalid cf")
	}
	return mt.appendRec(cf, len(key), false, key, nil)
}

// PutKv appends a key-value record to a KV cf.
func (mt *MemTable) PutKv(cf int, key, value []byte) uint64 {
	if cf < 0 || cf >= mt.numCf {
		panic("memtable: invalid cf")
	}
	return mt.appendRec(cf, len(key), false, key, value)
}

// DeleteKv appends a tombstone.
func (mt *MemTable) DeleteKv(cf int, key []byte) {
	if cf < 0 || cf >= mt.numCf {
		panic("memtable: invalid cf")
	}
	mt.appendRec(cf, len(key), true, key, nil)
}

// Batch appends many key-only records.
func (mt *MemTable) Batch(entries []CfKey) uint64 {
	for _, e := range entries {
		cf := int(e.Cf)
		if cf < 0 || cf >= mt.numCf {
			continue
		}
		mt.Put(cf, e.Key)
	}
	return mt.Size()
}

// CfKey is a column family + key.
type CfKey struct {
	Cf  uint8
	Key []byte
}

// ── materialize / merge ──────────────────────────────────────────────────

func (mt *MemTable) Materialize(cf int) {
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

func (mt *MemTable) MaybeMerge(cf int) {
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
	mt.Materialize(cf)
	mt.MaybeMerge(cf)
}

// MaybeCapBuf materializes incrementally past the delta cap.
func (mt *MemTable) MaybeCapBuf(cf int) {
	if len(mt.buf[cf]) >= MaxBufEntries {
		mt.Materialize(cf)
		mt.MaybeMerge(cf)
	}
}

// MaterializeAll materializes every CF.
func (mt *MemTable) MaterializeAll() {
	for cf := 0; cf < mt.numCf; cf++ {
		mt.Materialize(cf)
		mt.MaybeMerge(cf)
	}
}

// ── capture / publish ────────────────────────────────────────────────────

// FreezeAll captures: delta -> run, active -> draining, new generation.
func (mt *MemTable) FreezeAll() {
	mt.MaterializeAll()
	for cf := 0; cf < mt.numCf; cf++ {
		mt.draining[cf] = mt.runs[cf]
		mt.runs[cf] = nil
		mt.buf[cf] = nil
		mt.cfSize[cf] = 0
	}
	mt.gen++
}

// Publish discards draining runs after a flush.
func (mt *MemTable) Publish() {
	for cf := 0; cf < mt.numCf; cf++ {
		mt.draining[cf] = nil
	}
	mt.gen++
}

// Clear drops everything.
func (mt *MemTable) Clear() {
	for cf := 0; cf < mt.numCf; cf++ {
		mt.runs[cf] = nil
		mt.draining[cf] = nil
		mt.buf[cf] = nil
		mt.cfSize[cf] = 0
	}
	mt.gen++
}

// ── point lookups ────────────────────────────────────────────────────────

func (mt *MemTable) findBuf(cf int, key []byte) []byte {
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
	if b := mt.findBuf(cf, key); b != nil {
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
	if mt.LookupKv(cf, key) != KvValue {
		return nil, false
	}
	if b := mt.findBuf(cf, key); b != nil && !recDeleted(b) {
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

// ── drain ────────────────────────────────────────────────────────────────

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

// Runs exposes the active runs for a CF (read-only; for the cursor).
func (mt *MemTable) Runs(cf int) []*Run { return mt.runs[cf] }

// Draining exposes the draining runs for a CF.
func (mt *MemTable) Draining(cf int) []*Run { return mt.draining[cf] }

// Gen returns the generation counter.
func (mt *MemTable) Gen() uint64 { return mt.gen }
