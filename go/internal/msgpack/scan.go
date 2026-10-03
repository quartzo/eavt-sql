// scan.go — zero-copy top-level msgpack map helpers.  Port of
// nim_scheme/msgpack_scan.nim (injectTopPair / mapCountAndHeaderLen).
package msgpack

import "fmt"

// mapCountAndHeaderLen returns the element count and the header length of a
// top-level msgpack map: (count, 1|3|5, true), or false when the value is
// not a map or the header is truncated.
func mapCountAndHeaderLen(raw []byte) (int, int, bool) {
	if len(raw) == 0 {
		return 0, 0, false
	}
	b := raw[0]
	if b >= 0x80 && b <= 0x8f {
		return int(b & 0x0f), 1, true
	}
	if b == 0xde {
		if len(raw) < 3 {
			return 0, 0, false
		}
		return int(raw[1])<<8 | int(raw[2]), 3, true
	}
	if b == 0xdf {
		if len(raw) < 5 {
			return 0, 0, false
		}
		return int(raw[1])<<24 | int(raw[2])<<16 | int(raw[3])<<8 | int(raw[4]), 5, true
	}
	return 0, 0, false
}

// encodeStr encodes s as one msgpack str (fixstr / str8 / str16 / str32).
func encodeStr(s string) []byte {
	n := len(s)
	switch {
	case n < 32:
		out := make([]byte, 0, 1+n)
		out = append(out, 0xa0|byte(n))
		return append(out, s...)
	case n <= 0xff:
		out := make([]byte, 0, 2+n)
		out = append(out, 0xd9, byte(n))
		return append(out, s...)
	case n <= 0xffff:
		out := make([]byte, 0, 3+n)
		out = append(out, 0xda, byte(n>>8), byte(n))
		return append(out, s...)
	default:
		out := make([]byte, 0, 5+n)
		out = append(out, 0xdb, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
		return append(out, s...)
	}
}

// InjectTopPair appends (key, val) to a top-level msgpack map WITHOUT decoding
// it: the original bytes are preserved verbatim and only the element count in
// the header is patched (growing fixmap → map16 → map32 as needed).  Unlike a
// decode/re-encode this keeps the payload's byte order and integer widths
// identical, and costs O(len(key)+len(val)) instead of O(payload).
func InjectTopPair(raw []byte, key, val string) ([]byte, error) {
	count, hdr, ok := mapCountAndHeaderLen(raw)
	if !ok {
		return nil, fmt.Errorf("msgpack: not a top-level map (or truncated header)")
	}
	var header []byte
	switch hdr {
	case 1:
		if count < 15 {
			header = []byte{byte(0x80 | (count + 1))}
		} else {
			header = []byte{0xde, 0x00, 0x10} // 15 -> promote to map16(16)
		}
	case 3:
		if count < 0xffff {
			n := count + 1
			header = []byte{0xde, byte(n >> 8), byte(n)}
		} else {
			header = []byte{0xdf, 0x00, 0x01, 0x00, 0x00} // promote to map32(65536)
		}
	default: // 5 (map32)
		if count == int(^uint32(0)) {
			return nil, fmt.Errorf("msgpack: map32 count overflow")
		}
		n := uint32(count + 1)
		header = []byte{0xdf, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)}
	}
	out := make([]byte, 0, len(header)+len(raw)-hdr+3*len(key)+len(val)+8)
	out = append(out, header...)
	out = append(out, raw[hdr:]...)
	out = append(out, encodeStr(key)...)
	out = append(out, encodeStr(val)...)
	return out, nil
}
