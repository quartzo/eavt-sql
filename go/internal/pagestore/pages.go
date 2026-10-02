// Package pagestore — leaf page serialization (prefix-compressed,
// varint-encoded).  Port of nim_page_store/pages.nim.
package pagestore

import "fmt"

func errf(format string, a ...any) error { return fmt.Errorf(format, a...) }

// MaxRawSize is the page split threshold.
const MaxRawSize = 512 * 1024

// CommonPrefixLen returns the length of the shared prefix of a and b.
func CommonPrefixLen(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	i := 0
	for i < n && a[i] == b[i] {
		i++
	}
	return i
}

// WriteVarint appends value as an unsigned LEB128 varint.
func WriteVarint(buf []byte, value int) []byte {
	v := uint64(value)
	for {
		b := byte(v & 0x7f)
		v >>= 7
		if v == 0 {
			return append(buf, b)
		}
		buf = append(buf, b|0x80)
	}
}

// ReadVarint decodes one varint at offset, returning (value, newOffset).
func ReadVarint(data []byte, offset int) (int, int, error) {
	shift := 0
	value := 0
	for {
		if offset >= len(data) {
			return 0, 0, errf("truncated varint")
		}
		b := data[offset]
		offset++
		value |= int(b&0x7f) << shift
		if b&0x80 == 0 {
			return value, offset, nil
		}
		shift += 7
		if shift >= 64 {
			return 0, 0, errf("varint too long")
		}
	}
}

// SerializePage serializes sorted keys with prefix compression.
func SerializePage(keys [][]byte) []byte {
	out := make([]byte, 0, len(keys)*8)
	count := uint16(len(keys))
	out = append(out, byte(count>>8), byte(count))
	var prev []byte
	for _, key := range keys {
		plen := CommonPrefixLen(prev, key)
		suffix := key[plen:]
		out = WriteVarint(out, plen)
		out = WriteVarint(out, len(suffix))
		out = append(out, suffix...)
		prev = key
	}
	return out
}

// DeserializePage decodes a leaf page.
func DeserializePage(data []byte) ([][]byte, error) {
	if len(data) < 2 {
		return nil, errf("page too short")
	}
	count := int(uint16(data[0])<<8 | uint16(data[1]))
	out := make([][]byte, 0, count)
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
		extent := offset + slen
		if extent > len(data) {
			return nil, errf("truncated key: offset=%d slen=%d dataLen=%d", offset, slen, len(data))
		}
		plen := plenRaw
		if plen > len(prev) {
			plen = len(prev)
		}
		key := make([]byte, 0, plen+slen)
		key = append(key, prev[:plen]...)
		key = append(key, data[offset:extent]...)
		offset = extent
		prev = key
		out = append(out, key)
	}
	return out, nil
}

// BuildPages splits sorted keys into leaves; returns (firstKey, pageBytes).
func BuildPages(keys [][]byte) [][2][]byte {
	if len(keys) == 0 {
		return nil
	}
	if len(keys) == 1 {
		return [][2][]byte{{keys[0], SerializePage(keys)}}
	}
	total := 0
	for _, k := range keys {
		total += len(k)
	}
	if total <= MaxRawSize {
		return [][2][]byte{{keys[0], SerializePage(keys)}}
	}
	mid := len(keys) / 2
	return append(BuildPages(keys[:mid]), BuildPages(keys[mid:])...)
}

// SerializePageKv serializes key-value pairs with prefix compression.
func SerializePageKv(pairs [][2][]byte) []byte {
	out := make([]byte, 0, len(pairs)*16)
	count := uint16(len(pairs))
	out = append(out, byte(count>>8), byte(count))
	var prev []byte
	for _, p := range pairs {
		key, value := p[0], p[1]
		plen := CommonPrefixLen(prev, key)
		suffix := key[plen:]
		out = WriteVarint(out, plen)
		out = WriteVarint(out, len(suffix))
		out = append(out, suffix...)
		out = WriteVarint(out, len(value))
		out = append(out, value...)
		prev = key
	}
	return out
}

// DeserializePageKv decodes a key-value leaf page.
func DeserializePageKv(data []byte) ([][2][]byte, error) {
	if len(data) < 2 {
		return nil, errf("page too short")
	}
	count := int(uint16(data[0])<<8 | uint16(data[1]))
	out := make([][2][]byte, 0, count)
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
		keyEnd := offset + slen
		if keyEnd > len(data) {
			return nil, errf("truncated key")
		}
		plen := plenRaw
		if plen > len(prev) {
			plen = len(prev)
		}
		key := make([]byte, 0, plen+slen)
		key = append(key, prev[:plen]...)
		key = append(key, data[offset:keyEnd]...)
		offset = keyEnd
		vlen, next3, err := ReadVarint(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next3
		valEnd := offset + vlen
		if valEnd > len(data) {
			return nil, errf("truncated value")
		}
		value := make([]byte, vlen)
		copy(value, data[offset:valEnd])
		offset = valEnd
		prev = key
		out = append(out, [2][]byte{key, value})
	}
	return out, nil
}

// BuildPagesKv splits key-value pairs into leaves.
func BuildPagesKv(pairs [][2][]byte) [][2][]byte {
	if len(pairs) == 0 {
		return nil
	}
	if len(pairs) == 1 {
		return [][2][]byte{{pairs[0][0], SerializePageKv(pairs)}}
	}
	total := 0
	for _, p := range pairs {
		total += len(p[0]) + len(p[1])
	}
	if total <= MaxRawSize {
		return [][2][]byte{{pairs[0][0], SerializePageKv(pairs)}}
	}
	mid := len(pairs) / 2
	return append(BuildPagesKv(pairs[:mid]), BuildPagesKv(pairs[mid:])...)
}
