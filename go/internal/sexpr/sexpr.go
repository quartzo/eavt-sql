// Package sexpr is the Scheme S-expression AST + wire encoder, mirroring
// nim_scheme/scheme.nim's SExpr and wire.nim's writeSExprWire: int/float/str/
// bool/void/list map onto native msgpack; symbol -> ext 0x05, keyword -> ext
// 0x06.  The compile gate is byte-identity with the Nim compiler's wire
// output.
package sexpr

import (
	"fmt"

	"eavt-go/internal/msgpack"
)

// Expr is one Scheme S-expression node.
type Expr interface{ isExpr() }

type (
	Int      int64
	Float    float64
	Str      string
	Bool     bool
	Void     struct{}
	Bytes    []byte
	Symbol   string
	Keyword  string
	List     []Expr
	Resource int
)

func (Int) isExpr()      {}
func (Float) isExpr()    {}
func (Str) isExpr()      {}
func (Bool) isExpr()     {}
func (Void) isExpr()     {}
func (Bytes) isExpr()    {}
func (Symbol) isExpr()   {}
func (Keyword) isExpr()  {}
func (List) isExpr()     {}
func (Resource) isExpr() {}

// ToWire encodes an expression to the wire msgpack form.
func ToWire(e Expr) []byte {
	enc := msgpack.NewEncoder()
	encodeWire(enc, e)
	return enc.Bytes()
}

func encodeWire(enc *msgpack.Encoder, e Expr) {
	switch x := e.(type) {
	case Int:
		enc.Encode(msgpack.Int(int64(x)))
	case Float:
		enc.Encode(msgpack.Float(float64(x)))
	case Str:
		enc.Encode(msgpack.Str(string(x)))
	case Bool:
		enc.Encode(msgpack.Bool(bool(x)))
	case Void:
		enc.Encode(msgpack.Nil{})
	case Symbol:
		enc.Encode(msgpack.Ext{Type: msgpack.ExtSymbol, Data: []byte(x)})
	case Keyword:
		enc.Encode(msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(x)})
	case Bytes:
		enc.Encode(msgpack.Bin(x))
	case List:
		enc.EncodeArrayHeader(len(x))
		for _, item := range x {
			encodeWire(enc, item)
		}
	case Resource:
		panic("sexpr: cannot encode sResource on the wire")
	default:
		panic("sexpr: unencodable node")
	}
}

// MaxWireDepth is the container nesting cap for wire decoding
// (nim_scheme/msgpack_scan.nim MaxDepth).
const MaxWireDepth = 64

// UnmarshalWire decodes a wire program body (native msgpack; symbol ext 0x05,
// keyword ext 0x06) into an Expr.  Maps and unknown ext types are rejected.
func UnmarshalWire(data []byte) (Expr, error) {
	v, err := msgpack.Unmarshal(data)
	if err != nil {
		return nil, err
	}
	return wireFromValue(v, 0)
}

func wireFromValue(v msgpack.Value, depth int) (Expr, error) {
	if depth > MaxWireDepth {
		return nil, fmt.Errorf("wire node nesting deeper than %d", MaxWireDepth)
	}
	switch x := v.(type) {
	case msgpack.Int:
		return Int(x), nil
	case msgpack.Float:
		return Float(x), nil
	case msgpack.Str:
		return Str(x), nil
	case msgpack.Bool:
		return Bool(x), nil
	case msgpack.Nil, nil:
		return Void{}, nil
	case msgpack.Bin:
		return Bytes(append([]byte(nil), x...)), nil
	case msgpack.Array:
		items := make([]Expr, len(x))
		for i, e := range x {
			child, err := wireFromValue(e, depth+1)
			if err != nil {
				return nil, err
			}
			items[i] = child
		}
		return List(items), nil
	case msgpack.Ext:
		switch x.Type {
		case msgpack.ExtSymbol:
			return Symbol(string(x.Data)), nil
		case msgpack.ExtKeyword:
			return Keyword(string(x.Data)), nil
		}
		return nil, fmt.Errorf("unknown ext type 0x%02x in wire program", x.Type)
	case msgpack.Map:
		return nil, fmt.Errorf("maps are not allowed inside a wire program")
	}
	return nil, fmt.Errorf("unexpected value in wire program")
}

// ToPlainValue maps an expression to its plain msgpack form (response rows):
// symbols/keywords degrade to strings, lists to arrays.
func ToPlainValue(e Expr) msgpack.Value {
	switch v := e.(type) {
	case Int:
		return msgpack.Int(int64(v))
	case Float:
		return msgpack.Float(float64(v))
	case Str:
		return msgpack.Str(string(v))
	case Symbol:
		return msgpack.Str(string(v))
	case Keyword:
		return msgpack.Str(string(v))
	case Bool:
		return msgpack.Bool(bool(v))
	case Bytes:
		return msgpack.Bin(v)
	case Void:
		return msgpack.Nil{}
	case List:
		arr := make(msgpack.Array, len(v))
		for i, it := range v {
			arr[i] = ToPlainValue(it)
		}
		return arr
	}
	return msgpack.Nil{}
}
