// Package pagestore is a COW B-tree page store over the file blobstore:
// zstd-compressed leaf/index pages, prefix-compressed with varints.  Port of
// nim_page_store (read + commit paths; GC/stats deferred).
package pagestore

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// UUID is a 16-byte page/root identifier.
type UUID [16]byte

// CfTree is one column family's B-tree metadata.
type CfTree struct {
	RootUUID  UUID
	Height    uint8
	NumLeaves uint32
}

var rootMagic = [4]byte{0x45, 0x56, 0x54, 0x31} // "EVT1"

const (
	rootVersion      = 2
	IndexPageMaxSize = 512 * 1024
)

// EmptyTree returns a tree with no root.
func EmptyTree() CfTree { return CfTree{} }

// CmpSeq compares two byte slices lexicographically.
func CmpSeq(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
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

// SerializeRoot encodes the CF trees into a root blob.
func SerializeRoot(trees []CfTree) []byte {
	out := make([]byte, 0, 8+len(trees)*21)
	out = append(out, rootMagic[:]...)
	out = append(out, byte(rootVersion>>8), byte(rootVersion))
	nc := uint16(len(trees))
	out = append(out, byte(nc>>8), byte(nc))
	for _, t := range trees {
		out = append(out, t.RootUUID[:]...)
		out = append(out, t.Height)
		nl := t.NumLeaves
		out = append(out, byte(nl>>24), byte(nl>>16), byte(nl>>8), byte(nl))
	}
	return out
}

// DeserializeRoot decodes a root blob.
func DeserializeRoot(data []byte) ([]CfTree, error) {
	if len(data) < 8 || data[0] != rootMagic[0] || data[1] != rootMagic[1] ||
		data[2] != rootMagic[2] || data[3] != rootMagic[3] {
		return nil, errf("invalid root magic")
	}
	version := uint16(data[4])<<8 | uint16(data[5])
	if version != rootVersion {
		return nil, errf("unsupported root version %d", version)
	}
	numCf := int(uint16(data[6])<<8 | uint16(data[7]))
	if len(data) < 8+numCf*21 {
		return nil, errf("truncated root")
	}
	out := make([]CfTree, 0, numCf)
	off := 8
	for i := 0; i < numCf; i++ {
		var uuid UUID
		copy(uuid[:], data[off:off+16])
		off += 16
		height := data[off]
		off++
		nl := uint32(data[off])<<24 | uint32(data[off+1])<<16 | uint32(data[off+2])<<8 | uint32(data[off+3])
		off += 4
		out = append(out, CfTree{RootUUID: uuid, Height: height, NumLeaves: nl})
	}
	return out, nil
}

// IndexEntry is one (boundaryKey, childUUID) pair.
type IndexEntry struct {
	Key  []byte
	UUID UUID
}

// SerializeIndexPage encodes index entries with prefix compression.
func SerializeIndexPage(entries []IndexEntry) []byte {
	out := make([]byte, 0, len(entries)*40)
	count := uint16(len(entries))
	out = append(out, byte(count>>8), byte(count))
	var prev []byte
	for _, e := range entries {
		plen := CommonPrefixLen(prev, e.Key)
		suffix := e.Key[plen:]
		out = WriteVarint(out, plen)
		out = WriteVarint(out, len(suffix))
		out = append(out, suffix...)
		out = append(out, e.UUID[:]...)
		prev = e.Key
	}
	return out
}

// DeserializeIndexPage decodes an index page.
func DeserializeIndexPage(data []byte) ([]IndexEntry, error) {
	if len(data) < 2 {
		return nil, errf("index page too short")
	}
	count := int(uint16(data[0])<<8 | uint16(data[1]))
	out := make([]IndexEntry, 0, count)
	offset := 2
	var prev []byte
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
		if offset+slen+16 > len(data) {
			return nil, errf("truncated index entry")
		}
		plen := plenRaw
		if plen > len(prev) {
			plen = len(prev)
		}
		key := make([]byte, 0, plen+slen)
		key = append(key, prev[:plen]...)
		key = append(key, data[offset:offset+slen]...)
		offset += slen
		var uuid UUID
		copy(uuid[:], data[offset:offset+16])
		offset += 16
		prev = key
		out = append(out, IndexEntry{Key: key, UUID: uuid})
	}
	return out, nil
}

// SplitIndexEntries splits index entries into serialized pages.
func SplitIndexEntries(entries []IndexEntry) [][]byte {
	if len(entries) == 0 {
		return nil
	}
	total := SerializeIndexPage(entries)
	if len(total) <= IndexPageMaxSize || len(entries) == 1 {
		return [][]byte{total}
	}
	mid := len(entries) / 2
	return append(SplitIndexEntries(entries[:mid]), SplitIndexEntries(entries[mid:])...)
}

// MakeRootName builds a time-ordered (newest-first lexicographic) root name.
func MakeRootName() string {
	now := time.Now()
	ts := now.Unix()*1_000_000_000 + int64(now.Nanosecond())
	neg := uint64(^ts + 1)
	return fmt.Sprintf("root_%016x", neg)
}

// ParseRootUs decodes the timestamp embedded in a root name (0 when invalid).
func ParseRootUs(name string) int64 {
	if !strings.HasPrefix(name, "root_") {
		return 0
	}
	bits, err := strconv.ParseUint(name[5:], 16, 64)
	if err != nil {
		return 0
	}
	return -int64(bits)
}

func partitionPoint(entries []IndexEntry, target []byte) int {
	lo, hi := 0, len(entries)
	for lo < hi {
		mid := (lo + hi) >> 1
		if CmpSeq(entries[mid].Key, target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// PrefixEnd returns the exclusive upper bound for a prefix, if any.
func PrefixEnd(prefix []byte) ([]byte, bool) {
	e := append([]byte(nil), prefix...)
	for len(e) > 0 {
		last := e[len(e)-1]
		if last < 0xff {
			e[len(e)-1] = last + 1
			return e, true
		}
		e = e[:len(e)-1]
	}
	return nil, false
}

// FindPrefixRange returns the [start, end) index range covering a prefix.
func FindPrefixRange(entries []IndexEntry, prefix []byte) (int, int) {
	if len(prefix) == 0 {
		return 0, len(entries)
	}
	pe, hasPE := PrefixEnd(prefix)
	s := partitionPoint(entries, prefix)
	startIdx := 0
	if s > 0 {
		startIdx = s - 1
	}
	endIdx := len(entries)
	if hasPE {
		endIdx = partitionPoint(entries, pe)
	}
	if endIdx < startIdx {
		startIdx = endIdx
	}
	return startIdx, endIdx
}

func uuidToHex(u UUID) string {
	const hex = "0123456789abcdef"
	out := make([]byte, 32)
	for i, b := range u {
		out[i*2] = hex[b>>4]
		out[i*2+1] = hex[b&0x0f]
	}
	return string(out)
}
