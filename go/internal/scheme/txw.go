package scheme

import (
	"fmt"

	"eavt-go/internal/msgpack"
)

// TxWSlotKind classifies a flat tx-op slot.
type TxWSlotKind int

const (
	TskMissing TxWSlotKind = iota
	TskInt
	TskFloat
	TskBool
	TskStr
	TskKw
	TskBytes
	TskLookupRef
)

// TxWSlot is one flat tx-op value.
type TxWSlot struct {
	Kind   TxWSlotKind
	I      int64
	F      float64
	B      bool
	S      string
	Sym    uint32
	Bin    []byte
	RefVal *TxWSlot
}

// TxWOp is one flat tx operation.
type TxWOp struct {
	IsRetract bool
	E         TxWSlot
	AttrSym   uint32
	V         TxWSlot
	AttrId    uint32
	VResolved int64
}

func txSlotFromValue(v msgpack.Value, tab *SymTab) (TxWSlot, error) {
	switch x := v.(type) {
	case msgpack.Int:
		return TxWSlot{Kind: TskInt, I: int64(x)}, nil
	case msgpack.Float:
		return TxWSlot{Kind: TskFloat, F: float64(x)}, nil
	case msgpack.Str:
		return TxWSlot{Kind: TskStr, S: string(x)}, nil
	case msgpack.Bin:
		return TxWSlot{Kind: TskBytes, Bin: append([]byte(nil), x...)}, nil
	case msgpack.Bool:
		return TxWSlot{Kind: TskBool, B: bool(x)}, nil
	case msgpack.Nil:
		return TxWSlot{Kind: TskMissing}, nil
	case msgpack.Ext:
		switch x.Type {
		case msgpack.ExtKeyword:
			return TxWSlot{Kind: TskKw, Sym: uint32(tab.InternSym(string(x.Data)))}, nil
		case msgpack.ExtSymbol:
			return TxWSlot{Kind: TskStr, S: string(x.Data)}, nil
		}
		return TxWSlot{}, fmt.Errorf("wire: unknown ext type 0x%02x in tx op", x.Type)
	case msgpack.Array:
		if len(x) != 2 {
			return TxWSlot{}, fmt.Errorf("wire: tx lookup ref must be a 2-element array")
		}
		attr, err := txSlotFromValue(x[0], tab)
		if err != nil {
			return TxWSlot{}, err
		}
		if attr.Kind != TskKw {
			return TxWSlot{}, fmt.Errorf("wire: tx lookup ref attr must be a keyword")
		}
		val, err := txSlotFromValue(x[1], tab)
		if err != nil {
			return TxWSlot{}, err
		}
		ref := val
		return TxWSlot{Kind: TskLookupRef, Sym: attr.Sym, RefVal: &ref}, nil
	}
	return TxWSlot{}, fmt.Errorf("wire: unexpected value in tx op")
}

// TxOpsFromValue decodes the top-level "txdata" array into flat TxWOp records.
func TxOpsFromValue(v msgpack.Value, tab *SymTab) ([]TxWOp, error) {
	m, ok := v.(msgpack.Map)
	if !ok {
		return nil, fmt.Errorf("wire: tx request must be a map")
	}
	td, ok := msgpack.Member(m, msgpack.Str("txdata"))
	if !ok {
		return nil, fmt.Errorf("wire: tx request is missing txdata")
	}
	arr, ok := td.(msgpack.Array)
	if !ok {
		return nil, fmt.Errorf("wire: txdata must be an array")
	}
	out := make([]TxWOp, 0, len(arr))
	for _, opv := range arr {
		op, err := txOpFromValue(opv, tab)
		if err != nil {
			return nil, err
		}
		out = append(out, op)
	}
	return out, nil
}

// TxOpsFromMsgpack decodes raw request bytes into flat TxWOp records.
func TxOpsFromMsgpack(data []byte, tab *SymTab) ([]TxWOp, error) {
	v, err := msgpack.Unmarshal(data)
	if err != nil {
		return nil, err
	}
	return TxOpsFromValue(v, tab)
}

func txOpFromValue(v msgpack.Value, tab *SymTab) (TxWOp, error) {
	arr, ok := v.(msgpack.Array)
	if !ok || len(arr) != 4 {
		return TxWOp{}, fmt.Errorf("wire: tx op must be a 4-element vector")
	}
	var op TxWOp
	head, err := txSlotFromValue(arr[0], tab)
	if err != nil {
		return TxWOp{}, err
	}
	if head.Kind != TskKw {
		return TxWOp{}, fmt.Errorf("wire: tx op must start with a keyword")
	}
	switch head.Sym {
	case uint32(tab.DbAdd):
		op.IsRetract = false
	case uint32(tab.DbRetract):
		op.IsRetract = true
	default:
		return TxWOp{}, fmt.Errorf("wire: tx: unknown op keyword: :%s", tab.SymName(SymId(head.Sym)))
	}
	if op.E, err = txSlotFromValue(arr[1], tab); err != nil {
		return TxWOp{}, err
	}
	attr, err := txSlotFromValue(arr[2], tab)
	if err != nil {
		return TxWOp{}, err
	}
	if attr.Kind == TskKw {
		op.AttrSym = attr.Sym
	}
	if op.V, err = txSlotFromValue(arr[3], tab); err != nil {
		return TxWOp{}, err
	}
	return op, nil
}
