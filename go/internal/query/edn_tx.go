// edn_tx.go — native interpreter for Datomic-style EDN transactions (flat
// TxWOp form).  Port of nim_query/query/edn_tx.nim.
package query

import (
	"fmt"
	"strconv"
	"strings"

	"eavt-go/internal/eavt"
	"eavt-go/internal/numfmt"
	"eavt-go/internal/scheme"
)

// PartUser is the user partition.
const PartUser uint64 = 4

// TxError is a transaction error.
type TxError string

func (e TxError) Error() string { return string(e) }

func txErr(msg string) error { return TxError(msg) }

// TxReport is the result of a transaction.
type TxReport struct {
	Tempids map[int64]int64
	Tx      int64
}

const maxTxAttrs = 128

type attrE struct {
	sym      uint32
	name     string
	attrID   uint32
	unique   bool
	declared bool
	vt       uint32
	mode     eavt.EncodeMode
}

var dbValueTypes = []string{"string", "long", "float", "boolean", "bytes", "blob", "keyword", "ref", "instant"}

func vtFromKeyword(kw string) (string, error) {
	n := strings.ToLower(kw)
	if strings.HasPrefix(n, "db.type/") {
		vt := n[len("db.type/"):]
		for _, v := range dbValueTypes {
			if v == vt {
				return vt, nil
			}
		}
		return "", txErr("tx: unknown :db/valueType keyword: :" + n)
	}
	return "", txErr("tx: :db/valueType must be a :db.type/* keyword: :" + n)
}

func isSchemaAttrKw(kw string) bool {
	switch kw {
	case "db/ident", "db/valueType", "db/cardinality", "db/unique":
		return true
	}
	return false
}

func isSchemaGroupOp(tab *scheme.SymTab, op *scheme.TxWOp) bool {
	if op.IsRetract {
		return false
	}
	return op.AttrSym == uint32(tab.DbIdent) || op.AttrSym == uint32(tab.DbType) ||
		op.AttrSym == uint32(tab.DbCardinality) || op.AttrSym == uint32(tab.DbUnique)
}

func sameSlotEntity(a, b scheme.TxWSlot) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case scheme.TskInt:
		return a.I == b.I
	case scheme.TskKw:
		return a.Sym == b.Sym
	}
	return false
}

func slotRepr(tab *scheme.SymTab, v scheme.TxWSlot) string {
	switch v.Kind {
	case scheme.TskInt:
		return strconv.FormatInt(v.I, 10)
	case scheme.TskFloat:
		return numfmt.FloatString(v.F)
	case scheme.TskBool:
		if v.B {
			return "true"
		}
		return "false"
	case scheme.TskStr:
		return "\"" + v.S + "\""
	case scheme.TskKw:
		return ":" + tab.SymName(scheme.SymId(v.Sym))
	case scheme.TskBytes:
		return fmt.Sprintf("<bytes:%d>", len(v.Bin))
	case scheme.TskLookupRef:
		return "[:" + tab.SymName(scheme.SymId(v.Sym)) + " " + slotRepr(tab, *v.RefVal) + "]"
	}
	return "nil"
}

func applySchemaGroupTx(ops EngineOps, tab *scheme.SymTab, txops []scheme.TxWOp, seedOp int, t int64) error {
	ident := ""
	vtName := "string"
	many := false
	unique := false
	for j := range txops {
		op := &txops[j]
		if op.IsRetract || !isSchemaGroupOp(tab, op) {
			continue
		}
		if !sameSlotEntity(op.E, txops[seedOp].E) {
			continue
		}
		switch op.AttrSym {
		case uint32(tab.DbIdent):
			if op.V.Kind != scheme.TskKw {
				return txErr("tx: :db/ident value must be a keyword: " + tab.SymName(scheme.SymId(op.V.Sym)))
			}
			ident = tab.SymName(scheme.SymId(op.V.Sym))
		case uint32(tab.DbType):
			var err error
			vtName, err = vtFromKeyword(tab.SymName(scheme.SymId(op.V.Sym)))
			if err != nil {
				return err
			}
		case uint32(tab.DbCardinality):
			v := tab.SymName(scheme.SymId(op.V.Sym))
			switch v {
			case "db.cardinality/many":
				many = true
			case "db.cardinality/one":
				many = false
			default:
				return txErr("tx: unknown :db/cardinality keyword: :" + v)
			}
		case uint32(tab.DbUnique):
			v := tab.SymName(scheme.SymId(op.V.Sym))
			if v == "db.unique/identity" || v == "db.unique/value" {
				unique = true
			} else {
				return txErr("tx: unknown :db/unique keyword: :" + v)
			}
		}
	}
	if ident == "" {
		return txErr("tx: schema entity has no :db/ident")
	}
	return ops.DeclareAttrFromSQL(ident, vtName, many, unique, t)
}

func SlotToValueForType(v scheme.TxWSlot, vt uint32) string {
	switch vt {
	case eavt.DbTypeBoolean:
		if v.Kind == scheme.TskBool {
			if v.B {
				return "1"
			}
			return "0"
		}
		return "0"
	case eavt.DbTypeBytes, eavt.DbTypeBlob:
		if v.Kind == scheme.TskBytes {
			return string(v.Bin)
		}
		return "0"
	}
	return slotToPackedValue(v)
}

func slotToPackedValue(v scheme.TxWSlot) string {
	switch v.Kind {
	case scheme.TskInt:
		return strconv.FormatInt(v.I, 10)
	case scheme.TskFloat:
		return numfmt.FloatString(v.F)
	case scheme.TskStr, scheme.TskKw:
		return v.S
	case scheme.TskBool:
		if v.B {
			return "true"
		}
		return "false"
	case scheme.TskBytes:
		return string(v.Bin)
	}
	return ""
}

// TransactTx executes one flat tx (decoded from the wire).
func TransactTx(ops EngineOps, txops []scheme.TxWOp) (TxReport, error) {
	if len(txops) == 0 {
		return TxReport{}, txErr("tx: empty txdata")
	}
	tab := ops.Symtab()

	cache := make([]attrE, maxTxAttrs)
	intern := func(sym uint32, name string) int32 {
		start := int(sym % maxTxAttrs)
		for k := 0; k < maxTxAttrs; k++ {
			j := (start + k) % maxTxAttrs
			if cache[j].sym == 0 {
				cache[j].sym = sym
				cache[j].name = name
				return int32(j)
			}
			if cache[j].sym == sym {
				return int32(j)
			}
		}
		return -2
	}

	txSlot := make([]int32, len(txops))
	var minTid, maxTid int64
	haveTids := false
	for i := range txops {
		op := &txops[i]
		if op.AttrSym == 0 {
			txSlot[i] = -1
		} else {
			txSlot[i] = intern(op.AttrSym, tab.SymName(scheme.SymId(op.AttrSym)))
		}
		if op.E.Kind == scheme.TskInt && op.E.I < 0 {
			if !haveTids || op.E.I < minTid {
				minTid = op.E.I
			}
			if !haveTids || op.E.I > maxTid {
				maxTid = op.E.I
			}
			haveTids = true
		}
		if op.V.Kind == scheme.TskInt && op.V.I < 0 {
			if !haveTids || op.V.I < minTid {
				minTid = op.V.I
			}
			if !haveTids || op.V.I > maxTid {
				maxTid = op.V.I
			}
			haveTids = true
		}
	}

	txEid := ops.AllocateTxDeferred()
	t := txEid

	// Schema ops first.
	for i := range txops {
		if !txops[i].IsRetract && txops[i].AttrSym == uint32(tab.DbIdent) {
			if err := applySchemaGroupTx(ops, tab, txops, i, t); err != nil {
				return TxReport{}, err
			}
		}
	}

	// Refresh the attr cache (one resolver call per distinct attr).
	for j := 0; j < maxTxAttrs; j++ {
		if cache[j].sym != 0 && !cache[j].declared {
			if aid, ok := ops.LookupAttr(cache[j].name); ok {
				cache[j].attrID = aid
				cache[j].unique = ops.IsUniqueByID(aid)
				vt, _ := ops.ValueTypeFor(aid)
				cache[j].vt = vt
				cache[j].mode = eavt.ValueTypeToEncodeMode(vt)
				cache[j].declared = true
			}
		}
	}

	var lookupKeys [][]byte
	lookupOwner := make([]int, len(txops))
	for i := range lookupOwner {
		lookupOwner[i] = -1
	}
	keyFor := func(aid, vt uint32, mode eavt.EncodeMode, v scheme.TxWSlot) []byte {
		key := []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
		enc, _ := eavt.EncodeValue(SlotToValueForType(v, vt), mode, 0)
		return append(key, enc...)
	}
	slotOf := func(sym uint32, name string) int32 {
		existing := intern(sym, name)
		if existing == -2 {
			return -2
		}
		if !cache[existing].declared {
			if aid, ok := ops.LookupAttr(name); ok {
				cache[existing].attrID = aid
				cache[existing].unique = ops.IsUniqueByID(aid)
				vt, _ := ops.ValueTypeFor(aid)
				cache[existing].vt = vt
				cache[existing].mode = eavt.ValueTypeToEncodeMode(vt)
				cache[existing].declared = true
			}
		}
		return existing
	}

	for i := range txops {
		op := &txops[i]
		if !op.IsRetract && op.E.Kind == scheme.TskInt && op.E.I < 0 && op.AttrSym != 0 {
			aSlot := txSlot[i]
			var cSlot int32
			switch {
			case aSlot >= 0:
				cSlot = aSlot
			case aSlot == -2:
				cSlot = -2
			default:
				cSlot = -1
			}
			isUnique := false
			if cSlot >= 0 {
				isUnique = cache[cSlot].unique
			} else if cSlot == -2 {
				isUnique = ops.IsUniqueAttr(tab.SymName(scheme.SymId(op.AttrSym)))
			}
			if isUnique && cSlot >= 0 {
				lookupKeys = append(lookupKeys, keyFor(cache[cSlot].attrID, cache[cSlot].vt, cache[cSlot].mode, op.V))
				lookupOwner[i] = len(lookupKeys) - 1
			}
		}
		if op.E.Kind == scheme.TskLookupRef {
			name := tab.SymName(scheme.SymId(op.E.Sym))
			cSlot := slotOf(op.E.Sym, name)
			if cSlot >= 0 && cache[cSlot].declared && cache[cSlot].unique {
				lookupKeys = append(lookupKeys, keyFor(cache[cSlot].attrID, cache[cSlot].vt, cache[cSlot].mode, *op.E.RefVal))
				lookupOwner[i] = len(lookupKeys) - 1
			}
		}
		if op.V.Kind == scheme.TskLookupRef {
			name := tab.SymName(scheme.SymId(op.V.Sym))
			cSlot := slotOf(op.V.Sym, name)
			if cSlot >= 0 && cache[cSlot].declared && cache[cSlot].unique {
				lookupKeys = append(lookupKeys, keyFor(cache[cSlot].attrID, cache[cSlot].vt, cache[cSlot].mode, *op.V.RefVal))
				lookupOwner[i] = len(lookupKeys) - 1
			}
		}
	}

	lookupResults := ops.BatchLookupAvet(lookupKeys)

	// Resolve tempids before any write.
	resolved := map[int64]int64{}
	var anchorOp []int32
	var anchorEid []int64
	var fresh []bool
	if haveTids {
		span := int(maxTid - minTid + 1)
		if span > 1_000_000 {
			return TxReport{}, txErr("tx: tempid span too large (max 1000000): " + strconv.Itoa(span))
		}
		anchorOp = make([]int32, span)
		anchorEid = make([]int64, span)
		fresh = make([]bool, span)
		for i := range txops {
			op := &txops[i]
			if op.IsRetract || op.E.Kind != scheme.TskInt || op.E.I >= 0 {
				continue
			}
			if lookupOwner[i] < 0 {
				continue
			}
			idx := int(op.E.I - minTid)
			if anchorOp[idx] == 0 {
				anchorOp[idx] = int32(i + 1)
			}
		}
		for i := range txops {
			op := &txops[i]
			if op.E.Kind != scheme.TskInt || op.E.I >= 0 {
				continue
			}
			idx := int(op.E.I - minTid)
			if anchorEid[idx] != 0 {
				continue
			}
			var eid int64
			aop := anchorOp[idx]
			if aop != 0 && lookupOwner[aop-1] >= 0 {
				if lookupResults[lookupOwner[aop-1]] != 0 {
					eid = lookupResults[lookupOwner[aop-1]]
				} else {
					eid = ops.AllocateInPartition(PartUser)
				}
			} else {
				eid = ops.AllocateInPartition(PartUser)
			}
			anchorEid[idx] = eid
			fresh[idx] = true
			resolved[op.E.I] = eid
		}
	}

	// Apply pass.
	for i := range txops {
		op := &txops[i]
		aSlot := txSlot[i]
		if isSchemaGroupOp(tab, op) {
			continue
		}
		if op.IsRetract {
			if op.E.Kind == scheme.TskKw && op.E.Sym == uint32(tab.DbCurrentTx) {
				return TxReport{}, txErr("tx: :db/retract on :db/current-tx is not allowed (§6)")
			}
			if op.AttrSym == 0 {
				return TxReport{}, txErr("tx: expected keyword for attribute")
			}
			if op.V.Kind == scheme.TskKw || op.V.Kind == scheme.TskLookupRef ||
				(op.V.Kind == scheme.TskInt && op.V.I < 0) {
				return TxReport{}, txErr("tx: :db/retract requires a concrete scalar value (§4)")
			}
			if op.E.Kind == scheme.TskInt && op.E.I < 0 {
				return TxReport{}, txErr("tx: :db/retract does not take a tempid (§4)")
			}
		}
		switch {
		case aSlot >= 0:
			if !cache[aSlot].declared && !op.IsRetract {
				return TxReport{}, TxError("save to undeclared attr: " + cache[aSlot].name)
			}
			op.AttrId = cache[aSlot].attrID
		case aSlot == -2:
			aid, ok := ops.LookupAttr(tab.SymName(scheme.SymId(op.AttrSym)))
			if ok {
				op.AttrId = aid
			} else {
				op.AttrId = 0
			}
			if !ok && !op.IsRetract {
				return TxReport{}, TxError("save to undeclared attr: " + tab.SymName(scheme.SymId(op.AttrSym)))
			}
		}

		switch op.E.Kind {
		case scheme.TskInt:
			if op.E.I < 0 {
				op.E.I = anchorEid[int(op.E.I-minTid)]
			}
		case scheme.TskKw:
			if op.E.Sym == uint32(tab.DbCurrentTx) {
				op.E = scheme.TxWSlot{Kind: scheme.TskInt, I: txEid}
			} else {
				return TxReport{}, txErr("tx: cannot resolve e slot: :" + tab.SymName(scheme.SymId(op.E.Sym)))
			}
		case scheme.TskLookupRef:
			ki := lookupOwner[i]
			found := int64(0)
			if ki >= 0 {
				found = lookupResults[ki]
			}
			if found == 0 {
				return TxReport{}, txErr("tx: lookup ref [:" + tab.SymName(scheme.SymId(op.E.Sym)) + " " +
					slotRepr(tab, *op.E.RefVal) + "] did not match any entity")
			}
			op.E = scheme.TxWSlot{Kind: scheme.TskInt, I: found}
		default:
			return TxReport{}, txErr("tx: cannot resolve e slot: " + slotRepr(tab, op.E))
		}

		if op.V.Kind == scheme.TskInt && op.V.I < 0 {
			if !haveTids || op.V.I < minTid || op.V.I > maxTid {
				return TxReport{}, txErr("tx: tempid " + strconv.FormatInt(op.V.I, 10) + " referenced in v slot but never allocated")
			}
			idx := int(op.V.I - minTid)
			if idx < 0 || idx >= len(anchorEid) || anchorEid[idx] == 0 {
				return TxReport{}, txErr("tx: tempid " + strconv.FormatInt(op.V.I, 10) + " referenced in v slot but never allocated")
			}
			op.VResolved = anchorEid[idx]
		} else if op.V.Kind == scheme.TskLookupRef {
			ki := lookupOwner[i]
			found := int64(0)
			if ki >= 0 {
				found = lookupResults[ki]
			}
			if found == 0 {
				return TxReport{}, txErr("tx: lookup ref [:" + tab.SymName(scheme.SymId(op.V.Sym)) + " " +
					slotRepr(tab, *op.V.RefVal) + "] did not match any entity")
			}
			op.VResolved = found
		}

		if !op.IsRetract && op.AttrId != 0 {
			isFresh := false
			if haveTids && op.E.I >= 0 {
				fi := int(op.E.I - minTid)
				if fi >= 0 && fi < len(fresh) && fresh[fi] {
					isFresh = true
				}
			}
			if !isFresh {
				vEff := op.V
				if op.V.Kind == scheme.TskInt && op.V.I < 0 {
					vEff = scheme.TxWSlot{Kind: scheme.TskInt, I: op.VResolved}
				} else if op.V.Kind == scheme.TskLookupRef {
					vEff = scheme.TxWSlot{Kind: scheme.TskInt, I: op.VResolved}
				}
				if ops.HasDatomW(op.E.I, op.AttrId, vEff) {
					op.AttrId = 0
				}
			}
		}
	}

	ops.SaveBatchEdn(txops, t)
	ops.RetractBatch(txops, t)
	return TxReport{Tempids: resolved, Tx: t}, nil
}
