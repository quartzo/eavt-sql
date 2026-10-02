// Package eavt ports the EAVT engine: key encoding, resolver, hydrated cache
// and the read/write datom paths.  This file is nim_eavt/keys.nim.
package eavt

import (
	"encoding/binary"
	"math"
	"strconv"
	"strings"

	"eavt-go/internal/sexpr"
)

// EncodeMode selects the value encoding.
type EncodeMode int

const (
	EmRef EncodeMode = iota
	EmVariable
	EmBlob
	EmFixed
)

// ── suffix ───────────────────────────────────────────────────────────────

// EncodeSuffix packs (t, retracted) into the 8-byte ordering suffix.
func EncodeSuffix(t int64, retracted bool) uint64 {
	s := uint64(t) << 1
	if retracted {
		s |= 1
	}
	return s
}

// DecodeSuffix reverses EncodeSuffix.
func DecodeSuffix(encoded uint64) (int64, bool) {
	return int64(encoded >> 1), encoded&1 != 0
}

func storeBE64(p []byte, off int, v uint64) {
	binary.BigEndian.PutUint64(p[off:], v)
}

func storeBE32(p []byte, off int, v uint32) {
	binary.BigEndian.PutUint32(p[off:], v)
}

// ── value encodings ──────────────────────────────────────────────────────

// EncodeInt sign-flips an int64 for lexicographic ordering.
func EncodeInt(n int64) []byte {
	out := make([]byte, 8)
	binary.BigEndian.PutUint64(out, uint64(n)^(uint64(1)<<63))
	return out
}

// EncodeEid is EncodeInt for entity ids.
func EncodeEid(eid int64) []byte { return EncodeInt(eid) }

// EncodeFloat orders float64 values by flipping the sign bit (or all bits for
// negatives).
func EncodeFloat(f float64) []byte {
	x := math.Float64bits(f)
	if x>>63 == 1 {
		x = ^x
	} else {
		x ^= uint64(1) << 63
	}
	out := make([]byte, 8)
	binary.BigEndian.PutUint64(out, x)
	return out
}

func firstNul(s string) int {
	if i := strings.IndexByte(s, 0); i >= 0 {
		return i
	}
	return len(s)
}

// EncodeVariable encodes a string in 8-byte blocks + control byte.
func EncodeVariable(s string) []byte {
	n := firstNul(s)
	var out []byte
	for pos := 0; pos < n; pos += 8 {
		remaining := n - pos
		var block [8]byte
		if remaining > 8 {
			copy(block[:], s[pos:pos+8])
			out = append(out, block[:]...)
			out = append(out, 0xff)
		} else {
			copy(block[:], s[pos:pos+remaining])
			out = append(out, block[:]...)
			out = append(out, byte(remaining))
		}
	}
	return out
}

// EncodeVariableUnordered length-prefixes raw bytes.
func EncodeVariableUnordered(data []byte) []byte {
	out := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(out, uint32(len(data)))
	copy(out[4:], data)
	return out
}

// EncodeValue encodes v under mode.
func EncodeValue(v string, mode EncodeMode, refEid int64) ([]byte, error) {
	switch mode {
	case EmRef:
		return EncodeEid(refEid), nil
	case EmVariable:
		return EncodeVariable(v), nil
	case EmBlob:
		return EncodeVariableUnordered([]byte(v)), nil
	default: // EmFixed
		switch v {
		case "true":
			return EncodeInt(1), nil
		case "false":
			return EncodeInt(0), nil
		}
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return EncodeInt(n), nil
		}
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return EncodeFloat(f), nil
		}
		return nil, errf("cannot encode fixed value (not int/float): %q", v)
	}
}

// ── key builders ─────────────────────────────────────────────────────────

// BuildEavtKey builds [eid 8B][attr 4B][value][suffix 8B].
func BuildEavtKey(eid int64, attr uint32, valueEncoded []byte, t int64, retracted bool) []byte {
	sf := EncodeSuffix(t, retracted)
	out := make([]byte, 0, 8+4+len(valueEncoded)+8)
	out = append(out, EncodeEid(eid)...)
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], attr)
	out = append(out, a[:]...)
	out = append(out, valueEncoded...)
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], sf)
	out = append(out, s[:]...)
	return out
}

// BuildAevtKey builds [attr 4B][eid 8B][value][suffix 8B].
func BuildAevtKey(attr uint32, eid int64, valueEncoded []byte, t int64, retracted bool) []byte {
	sf := EncodeSuffix(t, retracted)
	out := make([]byte, 0, 4+8+len(valueEncoded)+8)
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], attr)
	out = append(out, a[:]...)
	out = append(out, EncodeEid(eid)...)
	out = append(out, valueEncoded...)
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], sf)
	out = append(out, s[:]...)
	return out
}

// BuildAvetKey builds [attr 4B][value][eid 8B][suffix 8B].
func BuildAvetKey(attr uint32, valueEncoded []byte, eid int64, t int64, retracted bool) []byte {
	sf := EncodeSuffix(t, retracted)
	out := make([]byte, 0, 4+len(valueEncoded)+8+8)
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], attr)
	out = append(out, a[:]...)
	out = append(out, valueEncoded...)
	out = append(out, EncodeEid(eid)...)
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], sf)
	out = append(out, s[:]...)
	return out
}

// BuildVaetKey builds [value][attr 4B][eid 8B][suffix 8B].
func BuildVaetKey(valueEncoded []byte, attr uint32, eid int64, t int64, retracted bool) []byte {
	sf := EncodeSuffix(t, retracted)
	out := make([]byte, 0, len(valueEncoded)+4+8+8)
	out = append(out, valueEncoded...)
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], attr)
	out = append(out, a[:]...)
	out = append(out, EncodeEid(eid)...)
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], sf)
	out = append(out, s[:]...)
	return out
}

// EavtEntry is one generated index key.
type EavtEntry struct {
	CF  uint8
	Key []byte
}

// BuildEavtEntries generates the CF-0 datom plus index keys.
func BuildEavtEntries(eid int64, attr uint32, encodedValue []byte, t int64, retracted bool, mode EncodeMode, indexed bool) []EavtEntry {
	sf := EncodeSuffix(t, retracted)
	ex := uint64(eid) ^ (uint64(1) << 63)
	vlen := len(encodedValue)
	klen := 8 + 4 + vlen + 8

	// CF 0: eavt
	p := make([]byte, klen)
	storeBE64(p, 0, ex)
	storeBE32(p, 8, attr)
	copy(p[12:], encodedValue)
	storeBE64(p, 12+vlen, sf)
	out := []EavtEntry{{CF: 0, Key: p}}

	// CF 1: aevt
	p = make([]byte, klen)
	storeBE32(p, 0, attr)
	storeBE64(p, 4, ex)
	copy(p[12:], encodedValue)
	storeBE64(p, 12+vlen, sf)
	out = append(out, EavtEntry{CF: 1, Key: p})

	avet := func() {
		p = make([]byte, klen)
		storeBE32(p, 0, attr)
		copy(p[4:], encodedValue)
		storeBE64(p, 4+vlen, ex)
		storeBE64(p, 12+vlen, sf)
		out = append(out, EavtEntry{CF: 2, Key: p})
	}
	if mode == EmRef {
		// CF 3: vaet
		p = make([]byte, klen)
		copy(p[0:], encodedValue)
		storeBE32(p, vlen, attr)
		storeBE64(p, vlen+4, ex)
		storeBE64(p, vlen+12, sf)
		out = append(out, EavtEntry{CF: 3, Key: p})
		if indexed {
			avet()
		}
	} else if indexed {
		avet()
	}
	return out
}

// ── decoding ─────────────────────────────────────────────────────────────

// DecodeInt64 reverses EncodeInt.
func DecodeInt64(raw uint64) int64 { return int64(raw ^ (uint64(1) << 63)) }

// DecodeEid reverses EncodeEid.
func DecodeEid(raw uint64) int64 { return DecodeInt64(raw) }

// DecodeFloat64 reverses EncodeFloat.
func DecodeFloat64(raw uint64) float64 {
	x := raw
	if x>>63 == 1 {
		x ^= uint64(1) << 63
	} else {
		x = ^x
	}
	return math.Float64frombits(x)
}

// BeUint64 reads a big-endian uint64 at start.
func BeUint64(data []byte, start int) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = (v << 8) | uint64(data[start+i])
	}
	return v
}

// BeUint32 reads a big-endian uint32 at start.
func BeUint32(data []byte, start int) uint32 {
	var v uint32
	for i := 0; i < 4; i++ {
		v = (v << 8) | uint32(data[start+i])
	}
	return v
}

// DecodeVariableStr decodes an 8+1 block encoded string.
func DecodeVariableStr(data []byte, start int) string {
	var b []byte
	pos := start
	for pos+9 <= len(data) {
		control := data[pos+8]
		b = append(b, data[pos:pos+8]...)
		if control != 0xff {
			valid := int(control)
			if valid < 8 {
				b = b[:len(b)-(8-valid)]
			}
			return string(b)
		}
		pos += 9
	}
	return string(b)
}

// DecodeStoredValue decodes a stored EAVT value with its db valueType.
func DecodeStoredValue(data []byte, vt uint32) sexpr.Expr {
	switch vt {
	case DbTypeRef:
		if len(data) >= 8 {
			return sexpr.Int(DecodeInt64(BeUint64(data, 0)))
		}
		return sexpr.Int(0)
	case DbTypeBoolean:
		if len(data) >= 8 {
			return sexpr.Bool(DecodeInt64(BeUint64(data, 0)) != 0)
		}
		return sexpr.Bool(false)
	case DbTypeLong, DbTypeInstant:
		if len(data) >= 8 {
			return sexpr.Int(DecodeInt64(BeUint64(data, 0)))
		}
		return sexpr.Int(0)
	case DbTypeFloat:
		if len(data) >= 8 {
			return sexpr.Float(DecodeFloat64(BeUint64(data, 0)))
		}
		return sexpr.Float(0)
	case DbTypeBytes, DbTypeBlob:
		if len(data) >= 4 {
			n := int(uint32(data[0])<<24 | uint32(data[1])<<16 | uint32(data[2])<<8 | uint32(data[3]))
			m := n
			if m > len(data)-4 {
				m = len(data) - 4
			}
			b := make([]byte, m)
			copy(b, data[4:4+m])
			return sexpr.Bytes(b)
		}
		return sexpr.Bytes{}
	default:
		return sexpr.Str(DecodeVariableStr(data, 0))
	}
}

// EncodeFixed encodes int/float/bool with sign-flip for ordering.
func EncodeFixed(val sexpr.Expr) []byte {
	out := make([]byte, 8)
	switch v := val.(type) {
	case sexpr.Int:
		binary.BigEndian.PutUint64(out, uint64(int64(v))^(uint64(1)<<63))
	case sexpr.Float:
		x := math.Float64bits(float64(v))
		if x>>63 == 1 {
			x = ^x
		} else {
			x ^= uint64(1) << 63
		}
		binary.BigEndian.PutUint64(out, x)
	case sexpr.Bool:
		if bool(v) {
			out[0] = 0x80
		}
	}
	return out
}

// EncodeBoundValue encodes a value for scanner prefix building.
func EncodeBoundValue(val sexpr.Expr) []byte {
	switch v := val.(type) {
	case sexpr.Str:
		return EncodeVariable(string(v))
	case sexpr.Keyword:
		return EncodeVariable(string(v))
	case sexpr.Bytes:
		return EncodeVariableUnordered(v)
	default:
		return EncodeFixed(val)
	}
}

// CfNameToID maps an index name to its CF.
func CfNameToID(name string) int {
	switch strings.ToLower(name) {
	case "eavt":
		return 0
	case "aevt":
		return 1
	case "avet":
		return 2
	case "vaet":
		return 3
	}
	return 0
}

// IndexOrder returns the key order for an index name.
func IndexOrder(index string) []string {
	switch strings.ToLower(index) {
	case "eavt":
		return []string{"e", "a", "v"}
	case "aevt":
		return []string{"a", "e", "v"}
	case "avet":
		return []string{"a", "v", "e"}
	case "vaet":
		return []string{"v", "a", "e"}
	}
	return []string{"e", "a", "v"}
}
