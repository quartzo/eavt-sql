// Package anchor is a packed hash [aid+val] -> eid for UNIQUE attrs (M7).
// Port of nim_eavt/anchor_index.nim.
//
// Records live in a byte arena + stable-index rec slice (no per-key
// allocation); probe is zero-alloc (FNV-1a over aid+val, equality by memcmp
// into the arena); LRU eviction under maxBytes.  A never-cached or evicted
// anchor falls back to the CF-2 scan, which is always correct — the index is
// a write-through mirror kept current by the write path and recovery.
//
// The Nim version is single-threaded; the Go port owns a mutex so it can be
// probed concurrently with writes.
package anchor

import "sync"

const (
	// DefaultMaxBytes is the default index budget (cfg `anchor_index_max_bytes`).
	DefaultMaxBytes = 256 * 1024 * 1024
	minSlots        = 1024
	maxKeyLen       = 32000
	emptySlot       = -1
	tombSlot        = -2
	// recSize is sizeof(AnchorRec) in the Nim layout, used for the byte budget.
	recSize = 40
)

type rec struct {
	off     int32
	klen    int16
	slotPos int32
	eid     int64
	prev    int32
	next    int32
	live    bool
}

// Stats is a snapshot of the index counters.
type Stats struct {
	Len       int
	Bytes     int
	Capacity  int
	Tombs     int
	Recs      int
	Arena     int
	Hits      int64
	Misses    int64
	Evictions int64
	Rehashes  int64
	Rejected  int64
}

// Index is a packed hash from (aid, value) to eid.  Safe for concurrent use.
type Index struct {
	mu       sync.RWMutex
	slots    []int32
	mask     int
	live     int
	tombs    int
	recs     []rec
	free     []int32
	arena    []byte
	head     int32
	tail     int32
	maxBytes int
	curBytes int
	hits     int64
	misses   int64
	evict    int64
	rehashes int64
	rejected int64
}

// New creates an anchor index with the given byte budget.
func New(maxBytes int) *Index {
	return &Index{
		slots:    []int32{emptySlot, emptySlot},
		mask:     1,
		head:     -1,
		tail:     -1,
		maxBytes: maxBytes,
	}
}

// Len returns the number of live anchors.
func (idx *Index) Len() int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return idx.live
}

// Stats returns a snapshot of the counters.
func (idx *Index) Stats() Stats {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return Stats{
		Len: idx.live, Bytes: idx.curBytes, Capacity: len(idx.slots),
		Tombs: idx.tombs, Recs: len(idx.recs), Arena: len(idx.arena),
		Hits: idx.hits, Misses: idx.misses, Evictions: idx.evict,
		Rehashes: idx.rehashes, Rejected: idx.rejected,
	}
}

// RehashForTest exposes a same-size rehash (compaction) for tests.
func (idx *Index) RehashForTest() {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	idx.rehash(len(idx.slots))
}

// ── hash / comparison (caller holds mu) ───────────────────────────────────

func fnv(aid uint32, val []byte) uint64 {
	h := uint64(0xcbf29ce484222325)
	h = (h ^ uint64(byte(aid>>24))) * 0x100000001b3
	h = (h ^ uint64(byte(aid>>16))) * 0x100000001b3
	h = (h ^ uint64(byte(aid>>8))) * 0x100000001b3
	h = (h ^ uint64(byte(aid))) * 0x100000001b3
	for _, b := range val {
		h = (h ^ uint64(b)) * 0x100000001b3
	}
	return h
}

func (idx *Index) keyEq(r int32, aid uint32, val []byte) bool {
	rec := &idx.recs[r]
	if int(rec.klen) != 4+len(val) {
		return false
	}
	off := int(rec.off)
	if idx.arena[off] != byte(aid>>24) || idx.arena[off+1] != byte(aid>>16) ||
		idx.arena[off+2] != byte(aid>>8) || idx.arena[off+3] != byte(aid) {
		return false
	}
	for i, b := range val {
		if idx.arena[off+4+i] != b {
			return false
		}
	}
	return true
}

// ── intrusive LRU (caller holds mu) ───────────────────────────────────────

func (idx *Index) lruUnlink(i int32) {
	r := &idx.recs[i]
	if r.prev >= 0 {
		idx.recs[r.prev].next = r.next
	} else {
		idx.head = r.next
	}
	if r.next >= 0 {
		idx.recs[r.next].prev = r.prev
	} else {
		idx.tail = r.prev
	}
	r.prev = -1
	r.next = -1
}

func (idx *Index) lruPush(i int32) {
	idx.recs[i].prev = -1
	idx.recs[i].next = idx.head
	if idx.head >= 0 {
		idx.recs[idx.head].prev = i
	} else {
		idx.tail = i
	}
	idx.head = i
}

func (idx *Index) touch(i int32) {
	if idx.head != i {
		idx.lruUnlink(i)
		idx.lruPush(i)
	}
}

// ── probe / slot search (caller holds mu) ─────────────────────────────────

func (idx *Index) findSlot(aid uint32, val []byte, h uint64) (pos int, r int32, tomb int) {
	r = -1
	tomb = -1
	p := int(h & uint64(idx.mask))
	for {
		s := idx.slots[p]
		if s == emptySlot {
			if tomb >= 0 {
				pos = tomb
			} else {
				pos = p
			}
			return
		}
		if s == tombSlot {
			if tomb < 0 {
				tomb = p
			}
		} else if idx.keyEq(s, aid, val) {
			pos = p
			r = s
			return
		}
		p = (p + 1) & idx.mask
	}
}

// Probe returns the eid for (aid, val), touching the LRU on hit.
func (idx *Index) Probe(aid uint32, val []byte) (int64, bool) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	if idx.live == 0 {
		idx.misses++
		return 0, false
	}
	_, r, _ := idx.findSlot(aid, val, fnv(aid, val))
	if r >= 0 {
		idx.touch(r)
		idx.hits++
		return idx.recs[r].eid, true
	}
	idx.misses++
	return 0, false
}

// ── removal (caller holds mu) ─────────────────────────────────────────────

func (idx *Index) killRec(r int32) {
	rc := &idx.recs[r]
	idx.slots[rc.slotPos] = tombSlot
	idx.tombs++
	idx.lruUnlink(r)
	rc.live = false
	rc.prev = -1
	rc.next = -1
	rc.slotPos = emptySlot
	idx.free = append(idx.free, r)
	idx.live--
	idx.curBytes -= int(rc.klen) + 8 + recSize + 4
}

// Del removes the anchor (tombstone + LRU unlink + free-list).
func (idx *Index) Del(aid uint32, val []byte) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	if idx.live == 0 {
		return
	}
	_, r, _ := idx.findSlot(aid, val, fnv(aid, val))
	if r >= 0 {
		idx.killRec(r)
	}
}

// ── rehash (caller holds mu) ──────────────────────────────────────────────

func (idx *Index) fnvAt(off, klen int) uint64 {
	h := uint64(0xcbf29ce484222325)
	for i := 0; i < klen; i++ {
		h = (h ^ uint64(idx.arena[off+i])) * 0x100000001b3
	}
	return h
}

func (idx *Index) rehash(newCap int) {
	newSlots := make([]int32, newCap)
	for i := range newSlots {
		newSlots[i] = emptySlot
	}
	total := 0
	for r := range idx.recs {
		if idx.recs[r].live {
			total += int(idx.recs[r].klen)
		}
	}
	newArena := make([]byte, total)
	write := 0
	for r := range idx.recs {
		rc := &idx.recs[r]
		if !rc.live {
			continue
		}
		klen := int(rc.klen)
		h := idx.fnvAt(int(rc.off), klen)
		p := int(h & uint64(newCap-1))
		for newSlots[p] != emptySlot {
			p = (p + 1) & (newCap - 1)
		}
		newSlots[p] = int32(r)
		rc.slotPos = int32(p)
		if klen > 0 {
			copy(newArena[write:], idx.arena[int(rc.off):int(rc.off)+klen])
		}
		rc.off = int32(write)
		write += klen
	}
	idx.slots = newSlots
	idx.mask = newCap - 1
	idx.arena = newArena
	idx.tombs = 0
	idx.rehashes++
}

// ── insertion (caller holds mu) ───────────────────────────────────────────

func (idx *Index) evictUntilFits(incoming int) {
	for idx.curBytes+incoming > idx.maxBytes && idx.live > 0 {
		v := idx.tail
		if v < 0 {
			break
		}
		idx.killRec(v)
		idx.evict++
	}
}

// Put is a write-through upsert: existing -> update eid + touch; new -> insert
// with budget admission (LRU evict).  A key larger than the whole budget is
// rejected (the CF-2 scan fallback covers it).
func (idx *Index) Put(aid uint32, val []byte, eid int64) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	if 4+len(val) > maxKeyLen {
		idx.rejected++
		return
	}
	klen := 4 + len(val)
	entryBytes := klen + 8 + recSize + 4
	if (idx.live+idx.tombs+1)*10 >= len(idx.slots)*7 {
		if idx.tombs > idx.live/4 {
			idx.rehash(len(idx.slots))
		} else {
			nc := len(idx.slots) * 2
			if nc < minSlots {
				nc = minSlots
			}
			idx.rehash(nc)
		}
	}
	pos, r, _ := idx.findSlot(aid, val, fnv(aid, val))
	if r >= 0 {
		idx.recs[r].eid = eid
		idx.touch(r)
		return
	}
	if entryBytes > idx.maxBytes {
		idx.rejected++
		return
	}
	var nr int32
	if len(idx.free) > 0 {
		nr = idx.free[len(idx.free)-1]
		idx.free = idx.free[:len(idx.free)-1]
	} else {
		idx.recs = append(idx.recs, rec{})
		nr = int32(len(idx.recs) - 1)
	}
	p := pos
	idx.evictUntilFits(entryBytes)
	rc := &idx.recs[nr]
	rc.off = int32(len(idx.arena))
	rc.klen = int16(klen)
	rc.slotPos = int32(p)
	rc.eid = eid
	rc.live = true
	idx.arena = append(idx.arena, make([]byte, klen)...)
	off := int(rc.off)
	idx.arena[off] = byte(aid >> 24)
	idx.arena[off+1] = byte(aid >> 16)
	idx.arena[off+2] = byte(aid >> 8)
	idx.arena[off+3] = byte(aid)
	copy(idx.arena[off+4:], val)
	idx.slots[p] = nr
	idx.live++
	idx.curBytes += entryBytes
	idx.lruPush(nr)
}

// Clear drops every anchor.
func (idx *Index) Clear() {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	idx.slots = make([]int32, minSlots)
	for i := range idx.slots {
		idx.slots[i] = emptySlot
	}
	idx.mask = minSlots - 1
	idx.live = 0
	idx.tombs = 0
	idx.recs = nil
	idx.free = nil
	idx.arena = nil
	idx.head = -1
	idx.tail = -1
	idx.curBytes = 0
}
