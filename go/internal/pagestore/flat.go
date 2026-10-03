// flat.go — leaf pages stored as one arena + offsets instead of a nested
// [][]byte.  Port of nim_page_store/page_store.nim (FlatLeafKeys/FlatLeafKV).
//
// The nested form cost ~270µs of allocator churn per leaf swap (freeing and
// creating thousands of small byte slices at every seek).  The arena decodes
// into ONE buffer + an offset array, and key reads are zero-copy views into
// it (leaf pages are immutable under COW, so a view is safe for as long as the
// cache entry — or the cursor holding it — lives; Go's GC keeps the whole
// backing array alive from an interior pointer).
package pagestore

// FlatLeaf is one immutable key-only leaf: concatenated keys + n+1 offsets
// (key i = buf[offs[i] : offs[i+1]]).
type FlatLeaf struct {
	buf  []byte
	offs []int32
}

// FlatLeafKV is one immutable key-value leaf (separate key/value arenas).
type FlatLeafKV struct {
	kbuf, vbuf   []byte
	koffs, voffs []int32
}

// Count returns the number of keys.
func (f *FlatLeaf) Count() int {
	if f == nil {
		return 0
	}
	return maxInt(len(f.offs)-1, 0)
}

// Key returns a zero-copy view of key i.
func (f *FlatLeaf) Key(i int) []byte { return f.buf[f.offs[i]:f.offs[i+1]] }

// Bytes reports the accounted size (arena + offsets + struct overhead).
func (f *FlatLeaf) Bytes() int { return len(f.buf) + len(f.offs)*4 + 48 }

// Count returns the number of pairs.
func (f *FlatLeafKV) Count() int {
	if f == nil {
		return 0
	}
	return maxInt(len(f.koffs)-1, 0)
}

// Key returns a zero-copy view of pair i's key.
func (f *FlatLeafKV) Key(i int) []byte { return f.kbuf[f.koffs[i]:f.koffs[i+1]] }

// Value returns a zero-copy view of pair i's value.
func (f *FlatLeafKV) Value(i int) []byte { return f.vbuf[f.voffs[i]:f.voffs[i+1]] }

// Pair returns zero-copy views of pair i.
func (f *FlatLeafKV) Pair(i int) ([2][]byte, bool) {
	if i < 0 || i+1 >= len(f.koffs) {
		return [2][]byte{}, false
	}
	return [2][]byte{f.Key(i), f.Value(i)}, true
}

// Bytes reports the accounted size.
func (f *FlatLeafKV) Bytes() int {
	return len(f.kbuf) + len(f.vbuf) + (len(f.koffs)+len(f.voffs))*4 + 64
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// DecodePageFlat decodes a leaf page into one arena (one allocation instead
// of one per key).  Validation and varint handling mirror DeserializePage.
func DecodePageFlat(data []byte) (*FlatLeaf, error) {
	if len(data) < 2 {
		return nil, errf("page too short")
	}
	count := int(uint16(data[0])<<8 | uint16(data[1]))
	f := &FlatLeaf{
		buf:  make([]byte, 0, count*16+64),
		offs: make([]int32, 0, count+1),
	}
	f.offs = append(f.offs, 0)
	offset := 2
	prevStart, prevEnd := 0, 0
	for i := 0; i < count; i++ {
		plenRaw, next1, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next1
		slen, next2, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next2
		extent := offset + slen
		if extent > len(data) {
			return nil, errf("truncated key: offset=%d slen=%d dataLen=%d", offset, slen, len(data))
		}
		plen := plenRaw
		if plen > prevEnd-prevStart {
			plen = prevEnd - prevStart
		}
		start := len(f.buf)
		// Reuse the previous key's prefix straight out of the arena: the
		// source always ends where the destination begins, so there is no
		// overlap to corrupt.
		f.buf = append(f.buf, f.buf[prevStart:prevStart+plen]...)
		f.buf = append(f.buf, data[offset:extent]...)
		offset = extent
		prevStart, prevEnd = start, len(f.buf)
		f.offs = append(f.offs, int32(len(f.buf)))
	}
	return f, nil
}

// DecodePageKvFlat decodes a key-value leaf into one arena per side.
func DecodePageKvFlat(data []byte) (*FlatLeafKV, error) {
	if len(data) < 2 {
		return nil, errf("page too short")
	}
	count := int(uint16(data[0])<<8 | uint16(data[1]))
	f := &FlatLeafKV{
		kbuf:  make([]byte, 0, count*16+64),
		vbuf:  make([]byte, 0, count*16+64),
		koffs: make([]int32, 0, count+1),
		voffs: make([]int32, 0, count+1),
	}
	f.koffs = append(f.koffs, 0)
	f.voffs = append(f.voffs, 0)
	offset := 2
	prevStart, prevEnd := 0, 0
	for i := 0; i < count; i++ {
		plenRaw, next1, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next1
		slen, next2, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next2
		keyEnd := offset + slen
		if keyEnd > len(data) {
			return nil, errf("truncated key")
		}
		plen := plenRaw
		if plen > prevEnd-prevStart {
			plen = prevEnd - prevStart
		}
		kstart := len(f.kbuf)
		f.kbuf = append(f.kbuf, f.kbuf[prevStart:prevStart+plen]...)
		f.kbuf = append(f.kbuf, data[offset:keyEnd]...)
		offset = keyEnd
		prevStart, prevEnd = kstart, len(f.kbuf)
		f.koffs = append(f.koffs, int32(len(f.kbuf)))

		vlen, next3, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next3
		valEnd := offset + vlen
		if valEnd > len(data) {
			return nil, errf("truncated value")
		}
		f.vbuf = append(f.vbuf, data[offset:valEnd]...)
		offset = valEnd
		f.voffs = append(f.voffs, int32(len(f.vbuf)))
	}
	return f, nil
}

// ToFlat packs nested keys into an arena (used by tests and callers that
// already hold a [][]byte).
func ToFlat(keys [][]byte) *FlatLeaf {
	n := len(keys)
	f := &FlatLeaf{offs: make([]int32, 0, n+1)}
	total := 0
	for _, k := range keys {
		total += len(k)
	}
	f.buf = make([]byte, 0, total)
	f.offs = append(f.offs, 0)
	for _, k := range keys {
		f.buf = append(f.buf, k...)
		f.offs = append(f.offs, int32(len(f.buf)))
	}
	return f
}
