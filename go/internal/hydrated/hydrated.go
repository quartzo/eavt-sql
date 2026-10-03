// Package hydrated is a RAM-resident read cache of "hydrated" eids for the
// EAVT CF-0 (M6).  Port of nim_eavt/hydrated.nim.
//
// A hydrated eid has its COMPLETE set of active CF-0 datom keys in memory;
// ScanPrefixActive serves any CF-0 scan anchored at a hydrated eid entirely
// from here (no PageStore descent, no merge).  The memtable remains the
// source of truth — this is a pure read cache kept current by the write path
// (applyKey) and read-time hydration.
//
// The Nim version is single-threaded by construction (event loop) and exposes
// an entry ref to the cursor.  The Go port runs reads concurrently with writes
// (goroutine-per-connection), so the set owns a mutex and exposes only
// owned-copy operations — callers never hold an entry across calls.
package hydrated

import "sync"

// DefaultMaxBytes is the default cache budget (cfg `hydrated_max_bytes`).
const DefaultMaxBytes = 256 * 1024 * 1024

type entry struct {
	eid        int64
	buf        []byte  // concatenated ACTIVE CF-0 keys, ascending
	offs       []int32 // start offset of each key (len = number of keys)
	bytes      int
	prev, next *entry
}

// Stats is a snapshot of the cache counters.
type Stats struct {
	Len        int
	Bytes      int
	Hits       int64
	Misses     int64
	Hydrations int64
	Rejected   int64
	Evictions  int64
}

// Set is an LRU-bounded set of hydrated eids.  Safe for concurrent use.
type Set struct {
	mu       sync.RWMutex
	index    map[int64]*entry
	head     *entry // sentinel: head.next = MRU
	tail     *entry // sentinel: tail.prev = LRU
	maxBytes int
	curBytes int
	hits     int64
	misses   int64
	hydrat   int64
	rejected int64
	evict    int64
}

// New creates a hydrated set with the given byte budget.
func New(maxBytes int) *Set {
	head := &entry{}
	tail := &entry{}
	head.next = tail
	tail.prev = head
	return &Set{
		index:    make(map[int64]*entry),
		head:     head,
		tail:     tail,
		maxBytes: maxBytes,
	}
}

// Len returns the number of hydrated eids.
func (h *Set) Len() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.index)
}

// Stats returns a snapshot of the counters.
func (h *Set) Stats() Stats {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return Stats{
		Len: len(h.index), Bytes: h.curBytes,
		Hits: h.hits, Misses: h.misses, Hydrations: h.hydrat,
		Rejected: h.rejected, Evictions: h.evict,
	}
}

// ── LRU plumbing (caller holds mu) ────────────────────────────────────────

func (h *Set) unlink(e *entry) {
	e.prev.next = e.next
	e.next.prev = e.prev
}

func (h *Set) pushFront(e *entry) {
	e.next = h.head.next
	e.prev = h.head
	h.head.next.prev = e
	h.head.next = e
}

func (h *Set) touch(e *entry) {
	h.unlink(e)
	h.pushFront(e)
}

// ── flat-buffer helpers (caller holds mu) ─────────────────────────────────

func keyStart(e *entry, i int) int { return int(e.offs[i]) }

func keyEnd(e *entry, i int) int {
	if i+1 < len(e.offs) {
		return int(e.offs[i+1])
	}
	return len(e.buf)
}

func keyLenAt(e *entry, i int) int { return keyEnd(e, i) - keyStart(e, i) }

func cmpFullAt(e *entry, i int, key []byte) int {
	start := keyStart(e, i)
	klen := keyLenAt(e, i)
	n := klen
	if len(key) < n {
		n = len(key)
	}
	for j := 0; j < n; j++ {
		if e.buf[start+j] != key[j] {
			if e.buf[start+j] < key[j] {
				return -1
			}
			return 1
		}
	}
	switch {
	case klen < len(key):
		return -1
	case klen > len(key):
		return 1
	}
	return 0
}

func cmpPrefixAt(e *entry, i int, key []byte) int {
	start := keyStart(e, i)
	klen := keyLenAt(e, i)
	alen := klen - 8
	blen := len(key) - 8
	n := alen
	if blen < n {
		n = blen
	}
	for j := 0; j < n; j++ {
		if e.buf[start+j] != key[j] {
			if e.buf[start+j] < key[j] {
				return -1
			}
			return 1
		}
	}
	switch {
	case alen < blen:
		return -1
	case alen > blen:
		return 1
	}
	return 0
}

func findKeyPos(e *entry, key []byte) int {
	lo, hi := 0, len(e.offs)
	for lo < hi {
		mid := (lo + hi) >> 1
		if cmpPrefixAt(e, mid, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(e.offs) && cmpPrefixAt(e, lo, key) == 0 {
		return lo
	}
	return -1
}

func replaceKeyAt(e *entry, pos int, key []byte) {
	start := keyStart(e, pos)
	next := keyEnd(e, pos)
	delta := len(key) - (next - start)
	if delta != 0 {
		tail := len(e.buf) - next
		if delta > 0 {
			e.buf = append(e.buf, make([]byte, delta)...)
		}
		if tail > 0 {
			copy(e.buf[next+delta:], e.buf[next:next+tail])
		}
		if delta < 0 {
			e.buf = e.buf[:len(e.buf)+delta]
		}
		for j := pos + 1; j < len(e.offs); j++ {
			e.offs[j] += int32(delta)
		}
	}
	copy(e.buf[start:], key)
}

func insertKeyAt(e *entry, idx int, key []byte) {
	ins := len(e.buf)
	if idx < len(e.offs) {
		ins = keyStart(e, idx)
	}
	e.buf = append(e.buf, make([]byte, len(key))...)
	tail := len(e.buf) - ins - len(key)
	if tail > 0 {
		copy(e.buf[ins+len(key):], e.buf[ins:ins+tail])
	}
	copy(e.buf[ins:], key)
	e.offs = append(e.offs, 0)
	copy(e.offs[idx+1:], e.offs[idx:])
	e.offs[idx] = int32(ins)
	for j := idx + 1; j < len(e.offs); j++ {
		e.offs[j] += int32(len(key))
	}
}

func removeKeyAt(e *entry, pos int) int {
	start := keyStart(e, pos)
	next := keyEnd(e, pos)
	oldLen := next - start
	tail := len(e.buf) - next
	if tail > 0 {
		copy(e.buf[start:], e.buf[next:next+tail])
	}
	e.buf = e.buf[:len(e.buf)-oldLen]
	copy(e.offs[pos:], e.offs[pos+1:])
	e.offs = e.offs[:len(e.offs)-1]
	for j := pos; j < len(e.offs); j++ {
		e.offs[j] -= int32(oldLen)
	}
	return oldLen
}

// ── reads ─────────────────────────────────────────────────────────────────

// Contains reports membership without LRU touch or accounting.
func (h *Set) Contains(eid int64) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.index[eid]
	return ok
}

// Probe is the fast-path gate: membership + LRU touch + hit/miss accounting.
func (h *Set) Probe(eid int64) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if e, ok := h.index[eid]; ok {
		h.touch(e)
		h.hits++
		return true
	}
	h.misses++
	return false
}

// ProbeComplete is an alias of Probe (M6: every entry is complete).
func (h *Set) ProbeComplete(eid int64) bool { return h.Probe(eid) }

// EntryBytes is the byte size of one hydrated entry (0 when absent).
func (h *Set) EntryBytes(eid int64) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if e, ok := h.index[eid]; ok {
		return e.bytes
	}
	return 0
}

// KeyCount returns the number of active CF-0 keys for eid (0 when absent).
func (h *Set) KeyCount(eid int64) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if e, ok := h.index[eid]; ok {
		return len(e.offs)
	}
	return 0
}

func beUint64(b []byte, off int) uint64 {
	return uint64(b[off])<<56 | uint64(b[off+1])<<48 | uint64(b[off+2])<<40 |
		uint64(b[off+3])<<32 | uint64(b[off+4])<<24 | uint64(b[off+5])<<16 |
		uint64(b[off+6])<<8 | uint64(b[off+7])
}

func decodeEID(x uint64) int64 { return int64(x ^ (uint64(1) << 63)) }

func cmpAttrAt(e *entry, i int, pfx []byte) int {
	start := keyStart(e, i)
	klen := keyLenAt(e, i)
	n := klen
	if 12 < n {
		n = 12
	}
	for j := 0; j < n; j++ {
		if e.buf[start+j] != pfx[j] {
			if e.buf[start+j] < pfx[j] {
				return -1
			}
			return 1
		}
	}
	if klen < 12 {
		return -1
	}
	return 0
}

// HasAttrKey reports whether the hydrated entry has an active CF-0 key for
// (eid, attrID).  Exact under the complete+current invariant.
func (h *Set) HasAttrKey(eid int64, aid uint32) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	e, ok := h.index[eid]
	if !ok {
		return false
	}
	var pfx [12]byte
	ex := uint64(eid) ^ (uint64(1) << 63)
	pfx[0] = byte(ex >> 56)
	pfx[1] = byte(ex >> 48)
	pfx[2] = byte(ex >> 40)
	pfx[3] = byte(ex >> 32)
	pfx[4] = byte(ex >> 24)
	pfx[5] = byte(ex >> 16)
	pfx[6] = byte(ex >> 8)
	pfx[7] = byte(ex)
	pfx[8] = byte(aid >> 24)
	pfx[9] = byte(aid >> 16)
	pfx[10] = byte(aid >> 8)
	pfx[11] = byte(aid)
	lo, hi := 0, len(e.offs)
	for lo < hi {
		mid := (lo + hi) >> 1
		if cmpAttrAt(e, mid, pfx[:]) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(e.offs) && cmpAttrAt(e, lo, pfx[:]) == 0
}

// LookupRange returns owned copies of all stored keys starting with prefix,
// ascending.  The caller must have probed membership for the eid.
func (h *Set) LookupRange(eid int64, prefix []byte) [][]byte {
	h.mu.RLock()
	defer h.mu.RUnlock()
	e, ok := h.index[eid]
	if !ok {
		return nil
	}
	lo, hi := 0, len(e.offs)
	for lo < hi {
		mid := (lo + hi) >> 1
		if cmpFullAt(e, mid, prefix) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	var out [][]byte
	for i := lo; i < len(e.offs); i++ {
		start := keyStart(e, i)
		klen := keyLenAt(e, i)
		if klen < len(prefix) {
			break
		}
		match := true
		for j := 0; j < len(prefix); j++ {
			if e.buf[start+j] != prefix[j] {
				match = false
				break
			}
		}
		if !match {
			break
		}
		cp := make([]byte, klen)
		copy(cp, e.buf[start:start+klen])
		out = append(out, cp)
	}
	return out
}

// KeysFrom returns owned copies of every stored key for eid that is >=
// target, ascending (first-key-at-or-after seek over the flat buffer).  The
// caller must have probed membership.
func (h *Set) KeysFrom(eid int64, target []byte) [][]byte {
	h.mu.RLock()
	defer h.mu.RUnlock()
	e, ok := h.index[eid]
	if !ok {
		return nil
	}
	lo, hi := 0, len(e.offs)
	for lo < hi {
		mid := (lo + hi) >> 1
		if cmpFullAt(e, mid, target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	var out [][]byte
	for i := lo; i < len(e.offs); i++ {
		start := keyStart(e, i)
		klen := keyLenAt(e, i)
		cp := make([]byte, klen)
		copy(cp, e.buf[start:start+klen])
		out = append(out, cp)
	}
	return out
}

// ── writes ────────────────────────────────────────────────────────────────

// ApplyKey mirrors one CF-0 write (already filtered by the caller).  No-op
// when the eid is not hydrated: active suffix upserts, retracted removes.
func (h *Set) ApplyKey(key []byte) {
	if len(key) < 20 {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.index) == 0 {
		return
	}
	klen := len(key)
	eid := decodeEID(beUint64(key, 0))
	e, ok := h.index[eid]
	if !ok {
		return
	}
	sf := beUint64(key, klen-8)
	pos := findKeyPos(e, key)
	if sf&1 == 0 {
		if pos >= 0 {
			oldLen := keyLenAt(e, pos)
			replaceKeyAt(e, pos, key)
			delta := klen - oldLen
			h.curBytes += delta
			e.bytes += delta
		} else {
			idx := len(e.offs)
			for idx > 0 && cmpFullAt(e, idx-1, key) > 0 {
				idx--
			}
			insertKeyAt(e, idx, key)
			h.curBytes += klen
			e.bytes += klen
		}
	} else if pos >= 0 {
		oldLen := removeKeyAt(e, pos)
		h.curBytes -= oldLen
		e.bytes -= oldLen
	}
}

// ── insertion / eviction ──────────────────────────────────────────────────

func (h *Set) drop(eid int64, e *entry) {
	delete(h.index, eid)
	h.unlink(e)
	h.curBytes -= e.bytes
}

func (h *Set) evictLruUntilFits(incoming int) {
	for h.curBytes+incoming > h.maxBytes && len(h.index) > 0 {
		victim := h.tail.prev
		if victim == h.head {
			break
		}
		h.drop(victim.eid, victim)
		h.evict++
	}
}

// HydrateEmpty marks a freshly allocated entity as hydrated (empty until its
// first save).
func (h *Set) HydrateEmpty(eid int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if e, ok := h.index[eid]; ok {
		h.touch(e)
		return
	}
	e := &entry{eid: eid}
	h.index[eid] = e
	h.pushFront(e)
}

// Hydrate installs the complete active CF-0 key set for eid.  keys must be
// the ascending output of ScanPrefixActive(0, encodeEid(eid)).
func (h *Set) Hydrate(eid int64, keys [][]byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if e, ok := h.index[eid]; ok {
		h.touch(e)
		return
	}
	total := 0
	for _, k := range keys {
		total += len(k)
	}
	if total > h.maxBytes {
		h.rejected++
		return
	}
	h.evictLruUntilFits(total)
	e := &entry{eid: eid, bytes: total}
	for _, k := range keys {
		e.offs = append(e.offs, int32(len(e.buf)))
		e.buf = append(e.buf, k...)
	}
	h.index[eid] = e
	h.pushFront(e)
	h.curBytes += total
	h.hydrat++
}

// Evict removes an entry explicitly (replica WAL invalidation seam).
func (h *Set) Evict(eid int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if e, ok := h.index[eid]; ok {
		h.drop(eid, e)
	}
}

// Clear drops every entry.
func (h *Set) Clear() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.index = make(map[int64]*entry)
	h.head.next = h.tail
	h.tail.prev = h.head
	h.curBytes = 0
}
