// Package msgpack is a minimal MessagePack encoder/decoder, hand-rolled so
// that the application extension types (0x05 symbol, 0x06 keyword) round-trip.
// Decoding is fail-loud: truncated input, unknown format bytes and
// out-of-range lengths return an error.  Map keys are Value so integer keys
// (tx-report tempids) decode like any other key.
package msgpack

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// Ext type codes used by the Scheme wire (nim_scheme/wire.nim).
const (
	ExtSymbol  = 5
	ExtKeyword = 6
)

// Err is the base decode error.
var Err = errors.New("msgpack: decode error")

// Value is one MessagePack node.
type Value interface{ msgValue() }

type (
	Nil   struct{}
	Bool  bool
	Int   int64
	Float float64
	Str   string
	Bin   []byte
	Array []Value
	Pair  struct {
		Key, Value Value
	}
	Map []Pair
	Ext struct {
		Type int
		Data []byte
	}
	// Raw is already-encoded msgpack bytes emitted verbatim.
	Raw []byte
)

func (Nil) msgValue()   {}
func (Bool) msgValue()  {}
func (Int) msgValue()   {}
func (Float) msgValue() {}
func (Str) msgValue()   {}
func (Bin) msgValue()   {}
func (Array) msgValue() {}
func (Map) msgValue()   {}
func (Ext) msgValue()   {}
func (Raw) msgValue()   {}

// Encoder encodes to a growing buffer.
type Encoder struct{ buf bytes.Buffer }

func NewEncoder() *Encoder { return &Encoder{} }
func (e *Encoder) Bytes() []byte {
	return e.buf.Bytes()
}

func (e *Encoder) byte(b byte)    { e.buf.WriteByte(b) }
func (e *Encoder) bytes(b []byte) { e.buf.Write(b) }

func (e *Encoder) be16(v uint16) {
	var b [2]byte
	binary.BigEndian.PutUint16(b[:], v)
	e.bytes(b[:])
}
func (e *Encoder) be32(v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	e.bytes(b[:])
}
func (e *Encoder) be64(v uint64) {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], v)
	e.bytes(b[:])
}

func (e *Encoder) encodeInt(v int64) {
	switch {
	case v >= 0 && v <= 0x7f:
		e.byte(byte(v))
	case v < 0 && v >= -32:
		e.byte(byte(int8(v)))
	case v >= 0 && v <= 0xff:
		e.byte(0xcc)
		e.byte(byte(v))
	case v < 0 && v >= -128:
		e.byte(0xd0)
		e.byte(byte(int8(v)))
	case v >= 0 && v <= 0xffff:
		e.byte(0xcd)
		e.be16(uint16(v))
	case v < 0 && v >= -32768:
		e.byte(0xd1)
		e.be16(uint16(int16(v)))
	case v >= 0 && v <= 0xffffffff:
		e.byte(0xce)
		e.be32(uint32(v))
	case v < 0 && v >= math.MinInt32:
		e.byte(0xd2)
		e.be32(uint32(int32(v)))
	default:
		e.byte(0xd3)
		e.be64(uint64(v))
	}
}

func (e *Encoder) encodeStr(s string) {
	n := len(s)
	switch {
	case n <= 31:
		e.byte(0xa0 | byte(n))
	case n <= 0xff:
		e.byte(0xd9)
		e.byte(byte(n))
	case n <= 0xffff:
		e.byte(0xda)
		e.be16(uint16(n))
	default:
		e.byte(0xdb)
		e.be32(uint32(n))
	}
	e.buf.WriteString(s)
}

func (e *Encoder) encodeBin(b []byte) {
	n := len(b)
	switch {
	case n <= 0xff:
		e.byte(0xc4)
		e.byte(byte(n))
	case n <= 0xffff:
		e.byte(0xc5)
		e.be16(uint16(n))
	default:
		e.byte(0xc6)
		e.be32(uint32(n))
	}
	e.bytes(b)
}

// EncodeArrayHeader writes an array header for n elements.
func (e *Encoder) EncodeArrayHeader(n int) {
	switch {
	case n <= 15:
		e.byte(0x90 | byte(n))
	case n <= 0xffff:
		e.byte(0xdc)
		e.be16(uint16(n))
	default:
		e.byte(0xdd)
		e.be32(uint32(n))
	}
}

// EncodeMapHeader writes a map header for n pairs.
func (e *Encoder) EncodeMapHeader(n int) {
	switch {
	case n <= 15:
		e.byte(0x80 | byte(n))
	case n <= 0xffff:
		e.byte(0xde)
		e.be16(uint16(n))
	default:
		e.byte(0xdf)
		e.be32(uint32(n))
	}
}

func (e *Encoder) encodeExt(ty int, data []byte) {
	n := len(data)
	fixext := func(base byte) {
		e.byte(base)
		e.byte(byte(ty & 0xff))
		e.bytes(data)
	}
	switch n {
	case 1:
		fixext(0xd4)
	case 2:
		fixext(0xd5)
	case 4:
		fixext(0xd6)
	case 8:
		fixext(0xd7)
	case 16:
		fixext(0xd8)
	default:
		switch {
		case n <= 0xff:
			e.byte(0xc7)
			e.byte(byte(n))
		case n <= 0xffff:
			e.byte(0xc8)
			e.be16(uint16(n))
		default:
			e.byte(0xc9)
			e.be32(uint32(n))
		}
		e.byte(byte(ty & 0xff))
		e.bytes(data)
	}
}

// Encode appends the msgpack encoding of v.
func (e *Encoder) Encode(v Value) {
	switch x := v.(type) {
	case nil, Nil:
		e.byte(0xc0)
	case Bool:
		if x {
			e.byte(0xc3)
		} else {
			e.byte(0xc2)
		}
	case Int:
		e.encodeInt(int64(x))
	case Float:
		e.byte(0xcb)
		e.be64(math.Float64bits(float64(x)))
	case Str:
		e.encodeStr(string(x))
	case Bin:
		e.encodeBin(x)
	case Array:
		e.EncodeArrayHeader(len(x))
		for _, item := range x {
			e.Encode(item)
		}
	case Map:
		e.EncodeMapHeader(len(x))
		for _, p := range x {
			e.Encode(p.Key)
			e.Encode(p.Value)
		}
	case Ext:
		e.encodeExt(x.Type, x.Data)
	case Raw:
		e.bytes(x)
	default:
		panic(fmt.Sprintf("msgpack: cannot encode %T", v))
	}
}

// Marshal encodes a single value.
func Marshal(v Value) []byte {
	e := NewEncoder()
	e.Encode(v)
	return e.Bytes()
}

// ── decode ────────────────────────────────────────────────────────────────

// Decoder reads from a byte slice.
type Decoder struct {
	buf   []byte
	pos   int
	limit int
}

// NewDecoder returns a decoder over the whole buffer.
func NewDecoder(b []byte) *Decoder { return &Decoder{buf: b, limit: len(b)} }

// NewDecoderAt returns a decoder over the slot [start, limit).
func NewDecoderAt(b []byte, start, limit int) *Decoder {
	return &Decoder{buf: b, pos: start, limit: limit}
}

// Pos returns the current read offset.
func (d *Decoder) Pos() int { return d.pos }

func (d *Decoder) u8() (byte, error) {
	if d.pos >= d.limit {
		return 0, fmt.Errorf("%w: truncated", Err)
	}
	b := d.buf[d.pos]
	d.pos++
	return b, nil
}

func (d *Decoder) u16() (uint16, error) {
	if d.pos+2 > d.limit {
		return 0, fmt.Errorf("%w: truncated", Err)
	}
	v := binary.BigEndian.Uint16(d.buf[d.pos:])
	d.pos += 2
	return v, nil
}

func (d *Decoder) u32() (uint32, error) {
	if d.pos+4 > d.limit {
		return 0, fmt.Errorf("%w: truncated", Err)
	}
	v := binary.BigEndian.Uint32(d.buf[d.pos:])
	d.pos += 4
	return v, nil
}

func (d *Decoder) u64() (uint64, error) {
	if d.pos+8 > d.limit {
		return 0, fmt.Errorf("%w: truncated", Err)
	}
	v := binary.BigEndian.Uint64(d.buf[d.pos:])
	d.pos += 8
	return v, nil
}

func (d *Decoder) take(n int) ([]byte, error) {
	if n < 0 || d.pos+n > d.limit {
		return nil, fmt.Errorf("%w: truncated", Err)
	}
	b := d.buf[d.pos : d.pos+n]
	d.pos += n
	return b, nil
}

// DecodeValue decodes one value, advancing the decoder.
func (d *Decoder) DecodeValue() (Value, error) {
	b, err := d.u8()
	if err != nil {
		return nil, err
	}
	switch {
	case b <= 0x7f:
		return Int(int64(b)), nil
	case b >= 0xe0:
		return Int(int64(int8(b))), nil
	case b >= 0x90 && b <= 0x9f:
		return d.decodeArray(int(b & 0x0f))
	case b >= 0xa0 && b <= 0xbf:
		s, err := d.take(int(b & 0x1f))
		if err != nil {
			return nil, err
		}
		return Str(string(s)), nil
	case b >= 0x80 && b <= 0x8f:
		return d.decodeMap(int(b & 0x0f))
	}

	switch b {
	case 0xc0:
		return Nil{}, nil
	case 0xc2:
		return Bool(false), nil
	case 0xc3:
		return Bool(true), nil
	case 0xc4, 0xc5, 0xc6:
		n, hdr, err := d.lenOf(b, false)
		if err != nil {
			return nil, err
		}
		body, err := d.take(n)
		if err != nil {
			return nil, err
		}
		_ = hdr
		return Bin(append([]byte(nil), body...)), nil
	case 0xc7, 0xc8, 0xc9:
		n, hdr, err := d.lenOf(b, false)
		if err != nil {
			return nil, err
		}
		ty, err := d.u8()
		if err != nil {
			return nil, err
		}
		_ = hdr
		body, err := d.take(n)
		if err != nil {
			return nil, err
		}
		return Ext{Type: int(ty), Data: append([]byte(nil), body...)}, nil
	case 0xca:
		v, err := d.u32()
		if err != nil {
			return nil, err
		}
		return Float(float64(math.Float32frombits(v))), nil
	case 0xcb:
		v, err := d.u64()
		if err != nil {
			return nil, err
		}
		return Float(math.Float64frombits(v)), nil
	case 0xcc:
		v, err := d.u8()
		if err != nil {
			return nil, err
		}
		return Int(int64(v)), nil
	case 0xcd:
		v, err := d.u16()
		if err != nil {
			return nil, err
		}
		return Int(int64(v)), nil
	case 0xce:
		v, err := d.u32()
		if err != nil {
			return nil, err
		}
		return Int(int64(v)), nil
	case 0xcf:
		v, err := d.u64()
		if err != nil {
			return nil, err
		}
		return Int(int64(v)), nil
	case 0xd0:
		v, err := d.u8()
		if err != nil {
			return nil, err
		}
		return Int(int64(int8(v))), nil
	case 0xd1:
		v, err := d.u16()
		if err != nil {
			return nil, err
		}
		return Int(int64(int16(v))), nil
	case 0xd2:
		v, err := d.u32()
		if err != nil {
			return nil, err
		}
		return Int(int64(int32(v))), nil
	case 0xd3:
		v, err := d.u64()
		if err != nil {
			return nil, err
		}
		return Int(int64(v)), nil
	case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8:
		n := 1 << (b - 0xd4)
		return d.decodeExtN(n)
	case 0xd9, 0xda, 0xdb:
		n, _, err := d.lenOf(b, false)
		if err != nil {
			return nil, err
		}
		body, err := d.take(n)
		if err != nil {
			return nil, err
		}
		return Str(string(body)), nil
	case 0xdc, 0xdd:
		n, _, err := d.lenOf(b, false)
		if err != nil {
			return nil, err
		}
		return d.decodeArray(n)
	case 0xde, 0xdf:
		n, _, err := d.lenOf(b, false)
		if err != nil {
			return nil, err
		}
		return d.decodeMap(n)
	}
	return nil, fmt.Errorf("%w: unknown format byte 0x%02x at pos %d", Err, b, d.pos-1)
}

// lenOf reads the length field that follows header b.  hdr is the number of
// bytes consumed for the length itself (unused by callers; kept for parity
// with the reference implementation).
func (d *Decoder) lenOf(b byte, _ bool) (n, hdr int, err error) {
	switch b {
	case 0xc4, 0xc7, 0xd9:
		v, e := d.u8()
		return int(v), 1, e
	case 0xc5, 0xc8, 0xda, 0xdc, 0xde:
		v, e := d.u16()
		return int(v), 2, e
	case 0xc6, 0xc9, 0xdb, 0xdd, 0xdf:
		v, e := d.u32()
		return int(v), 4, e
	}
	return 0, 0, fmt.Errorf("%w: bad length header 0x%02x", Err, b)
}

func (d *Decoder) decodeExtN(n int) (Value, error) {
	ty, err := d.u8()
	if err != nil {
		return nil, err
	}
	body, err := d.take(n)
	if err != nil {
		return nil, err
	}
	return Ext{Type: int(ty), Data: append([]byte(nil), body...)}, nil
}

func (d *Decoder) decodeArray(n int) (Value, error) {
	if n < 0 {
		return nil, fmt.Errorf("%w: negative array length", Err)
	}
	arr := make(Array, 0, n)
	for i := 0; i < n; i++ {
		v, err := d.DecodeValue()
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
	}
	return arr, nil
}

func (d *Decoder) decodeMap(n int) (Value, error) {
	if n < 0 {
		return nil, fmt.Errorf("%w: negative map length", Err)
	}
	m := make(Map, 0, n)
	for i := 0; i < n; i++ {
		k, err := d.DecodeValue()
		if err != nil {
			return nil, err
		}
		v, err := d.DecodeValue()
		if err != nil {
			return nil, err
		}
		m = append(m, Pair{Key: k, Value: v})
	}
	return m, nil
}

// Unmarshal decodes exactly one value and requires the whole buffer to be
// consumed (fail-loud on trailing content).
func Unmarshal(b []byte) (Value, error) {
	d := NewDecoder(b)
	v, err := d.DecodeValue()
	if err != nil {
		return nil, err
	}
	if d.pos != len(b) {
		return nil, fmt.Errorf("%w: trailing content at pos %d", Err, d.pos)
	}
	return v, nil
}

// Member looks up key in a Map (keys compared by structural equality).
func Member(m Map, key Value) (Value, bool) {
	for _, p := range m {
		if Equal(p.Key, key) {
			return p.Value, true
		}
	}
	return nil, false
}

// Equal is structural equality for the subset of values the client inspects.
func Equal(a, b Value) bool {
	switch x := a.(type) {
	case Str:
		y, ok := b.(Str)
		return ok && x == y
	case Int:
		y, ok := b.(Int)
		return ok && x == y
	case Bool:
		y, ok := b.(Bool)
		return ok && x == y
	case Nil:
		_, ok := b.(Nil)
		return ok
	case Float:
		y, ok := b.(Float)
		return ok && x == y
	case Bin:
		y, ok := b.(Bin)
		return ok && bytes.Equal(x, y)
	case Ext:
		y, ok := b.(Ext)
		return ok && x.Type == y.Type && bytes.Equal(x.Data, y.Data)
	}
	return false
}

// UnmarshalMust is Unmarshal that panics on error (tests).
func UnmarshalMust(b []byte) Value {
	v, err := Unmarshal(b)
	if err != nil {
		panic(err)
	}
	return v
}
