// write.go — QueryStore write methods: EngineOps implementation for the
// executor (save/retract/lookup/declare) and the flat tx interpreter.
// Port of the write paths of nim_query/query/engine.nim.
package engine

import (
	"bytes"
	"strconv"
	"time"

	"eavt-go/internal/eavt"
	"eavt-go/internal/perf"
	"eavt-go/internal/query"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

// Symtab returns the interned keyword table.
func (q *QueryStore) Symtab() *scheme.SymTab { return q.symtab }

// AllocateTx allocates a tx entity and writes its db.txInstant datom.
func (q *QueryStore) AllocateTx() int64 { return q.Eavt.AllocateTAndWriteTx() }

// AllocateTxDeferred allocates a tx entity without the txInstant datom.
func (q *QueryStore) AllocateTxDeferred() int64 { return q.Eavt.AllocateTDeferred() }

// AllocateInPartition reserves an entity id.
func (q *QueryStore) AllocateInPartition(pid uint64) int64 { return q.Eavt.AllocateInPartition(pid) }

// IsUniqueByID reports whether an aid is unique.
func (q *QueryStore) IsUniqueByID(aid uint32) bool { return q.Eavt.Resolver.IsUnique(aid) }

// BatchLookupAvet does batched unique-index lookups.
func (q *QueryStore) BatchLookupAvet(keys [][]byte) []int64 { return q.Eavt.BatchLookupAvet(keys) }

// DeclarePartition registers a custom partition.
func (q *QueryStore) DeclarePartition(name string, t int64) uint64 {
	return q.Eavt.DeclarePartition(name)
}

// DeclareAttrFromSQL declares an attribute by type name.
func (q *QueryStore) DeclareAttrFromSQL(attr, typeName string, many, unique bool, t int64) error {
	vt := eavt.ValueTypeFromName(typeName)
	_, _, err := q.Eavt.EavtDeclareAttr(attr, vt, many, unique)
	return err
}

func encodeSaveValue(val sexpr.Expr, vt uint32, mode eavt.EncodeMode, eid int64) ([]byte, error) {
	packed := sexprToValueForType(val, vt)
	if mode == eavt.EmRef {
		n, err := strconv.ParseInt(packed, 10, 64)
		if err != nil {
			return nil, scheme.EvalError("REF value must be an entity id, got: \"" + packed + "\"")
		}
		return eavt.EncodeValue(packed, mode, n)
	}
	return eavt.EncodeValue(packed, mode, eid)
}

func encodeSaveValueSlot(val scheme.TxWSlot, vt uint32, mode eavt.EncodeMode, eid int64, tab *scheme.SymTab) ([]byte, error) {
	packed := query.SlotToValueForType(val, vt, tab)
	if mode == eavt.EmRef {
		n, err := strconv.ParseInt(packed, 10, 64)
		if err != nil {
			return nil, scheme.EvalError("REF value must be an entity id, got: \"" + packed + "\"")
		}
		return eavt.EncodeValue(packed, mode, n)
	}
	return eavt.EncodeValue(packed, mode, eid)
}

func eidAttrPrefix(eid int64, aid uint32) []byte {
	return append(eavt.EncodeEid(eid), byte(aid>>24), byte(aid>>16), byte(aid>>8), byte(aid))
}

func (q *QueryStore) saveResolvedEncodedInto(eid int64, attrID, vt uint32, many, indexed bool,
	mode eavt.EncodeMode, encoded []byte, t int64, entries *[]eavt.EavtEntry) {
	perfOn := perf.Enabled()
	var t0 time.Time
	if perfOn {
		t0 = time.Now()
	}
	if !many {
		prefix := eidAttrPrefix(eid, attrID)
		var t1 time.Time
		if perfOn {
			t1 = time.Now()
			q.perf.saveRetractPrefix.Add(int64(t1.Sub(t0)))
			q.perf.saveRetractScans.Add(1)
		}
		keys := q.Eavt.ScanPrefixActive(0, prefix)
		var t2 time.Time
		if perfOn {
			t2 = time.Now()
			q.perf.saveRetractSeek.Add(int64(t2.Sub(t1)))
		}
		for _, ek := range keys {
			if len(ek) < 20 {
				continue
			}
			*entries = append(*entries, eavt.BuildEavtEntries(eid, attrID, ek[12:len(ek)-8], t, true, mode, indexed)...)
			if perfOn {
				q.perf.saveRetractCount.Add(1)
			}
		}
		if perfOn {
			q.perf.saveRetractApply.Add(int64(time.Since(t2)))
		}
	}
	if perfOn {
		q.perf.saveRetractScanNS.Add(int64(time.Since(t0)))
		t0 = time.Now()
	}
	*entries = append(*entries, eavt.BuildEavtEntries(eid, attrID, encoded, t, false, mode, indexed)...)
	if perfOn {
		q.perf.saveBuildEntries.Add(int64(time.Since(t0)))
	}
}

// SaveWithT saves one datom for an SExpr value.
func (q *QueryStore) SaveWithT(eid int64, attr string, val sexpr.Expr, t, asOf int64) error {
	q.saveCount.Add(1)
	perfOn := perf.Enabled()
	var t0, t1 time.Time
	if perfOn {
		t0 = time.Now()
	}
	aid, ok := q.Eavt.LookupAttr(attr)
	if !ok {
		return scheme.EvalError("save to undeclared attr: " + attr)
	}
	if perfOn {
		t1 = time.Now()
		q.perf.saveLookupAttrNS.Add(int64(t1.Sub(t0)))
	}
	vt, _ := q.Eavt.ValueTypeFor(aid)
	many := q.Eavt.Resolver.IsMany(aid)
	mode := eavt.ValueTypeToEncodeMode(vt)
	indexed := q.Eavt.Resolver.IsIndexed(aid)
	if perfOn {
		t0 = time.Now()
		q.perf.saveTypeCheckNS.Add(int64(t0.Sub(t1)))
	}
	encoded, err := encodeSaveValue(val, vt, mode, eid)
	if err != nil {
		return err
	}
	if perfOn {
		t1 = time.Now()
		q.perf.saveEncodeNS.Add(int64(t1.Sub(t0)))
	}
	var entries []eavt.EavtEntry
	q.saveResolvedEncodedInto(eid, aid, vt, many, indexed, mode, encoded, t, &entries)
	if perfOn {
		t0 = time.Now()
	}
	q.Eavt.BatchWrite(entries)
	if perfOn {
		q.perf.saveBatchWriteNS.Add(int64(time.Since(t0)))
	}
	return nil
}

// SaveManyWithT saves many (eid, value) pairs for one attribute.
func (q *QueryStore) SaveManyWithT(attr string, pairs []query.Pair, t, asOf int64) error {
	q.saveCount.Add(int64(len(pairs)))
	aid, ok := q.Eavt.LookupAttr(attr)
	if !ok {
		return scheme.EvalError("save-many to undeclared attr: " + attr)
	}
	vt, _ := q.Eavt.ValueTypeFor(aid)
	many := q.Eavt.Resolver.IsMany(aid)
	mode := eavt.ValueTypeToEncodeMode(vt)
	indexed := q.Eavt.Resolver.IsIndexed(aid)

	bulk := true
	if !many && len(pairs) > 1 {
		seen := map[int64]bool{}
		for _, p := range pairs {
			if seen[p.Eid] {
				bulk = false
				break
			}
			seen[p.Eid] = true
		}
	}
	if !bulk {
		for _, p := range pairs {
			encoded, err := encodeSaveValue(p.Val, vt, mode, p.Eid)
			if err != nil {
				return err
			}
			var entries []eavt.EavtEntry
			q.saveResolvedEncodedInto(p.Eid, aid, vt, many, indexed, mode, encoded, t, &entries)
			q.Eavt.BatchWrite(entries)
		}
		return nil
	}
	var all []eavt.EavtEntry
	for _, p := range pairs {
		encoded, err := encodeSaveValue(p.Val, vt, mode, p.Eid)
		if err != nil {
			return err
		}
		q.saveResolvedEncodedInto(p.Eid, aid, vt, many, indexed, mode, encoded, t, &all)
	}
	q.Eavt.BatchWrite(all)
	return nil
}

// Retract retracts one datom for an SExpr value.
func (q *QueryStore) Retract(eid int64, attr string, val sexpr.Expr, t, asOf int64) error {
	q.saveCount.Add(1)
	aid, ok := q.Eavt.LookupAttr(attr)
	if !ok {
		return nil
	}
	vt, _ := q.Eavt.ValueTypeFor(aid)
	mode := eavt.ValueTypeToEncodeMode(vt)
	encoded, err := encodeSaveValue(val, vt, mode, eid)
	if err != nil {
		return err
	}
	q.Eavt.BatchWrite(eavt.BuildEavtEntries(eid, aid, encoded, t, true, mode, q.Eavt.Resolver.IsIndexed(aid)))
	return nil
}

func (q *QueryStore) opIsSchema(op *scheme.TxWOp) bool {
	tab := q.symtab
	return !op.IsRetract &&
		(op.AttrSym == uint32(tab.DbIdent) || op.AttrSym == uint32(tab.DbType) ||
			op.AttrSym == uint32(tab.DbCardinality) || op.AttrSym == uint32(tab.DbUnique))
}

func effVal(op *scheme.TxWOp) scheme.TxWSlot {
	if op.V.Kind == scheme.TskInt && op.V.I < 0 {
		return scheme.TxWSlot{Kind: scheme.TskInt, I: op.VResolved}
	}
	if op.V.Kind == scheme.TskLookupRef {
		return scheme.TxWSlot{Kind: scheme.TskInt, I: op.VResolved}
	}
	return op.V
}

type opMeta struct {
	attrID  uint32
	vt      uint32
	mode    eavt.EncodeMode
	many    bool
	indexed bool
}

// SaveBatchEdn applies all data ops of a flat tx in one batch (plus the
// deferred db.txInstant datom).
func (q *QueryStore) SaveBatchEdn(txops []scheme.TxWOp, t int64) {
	q.saveCount.Add(int64(len(txops)))
	metaCache := map[uint32]opMeta{}
	metaFor := func(aid uint32) opMeta {
		if m, ok := metaCache[aid]; ok {
			return m
		}
		vt, _ := q.Eavt.ValueTypeFor(aid)
		m := opMeta{attrID: aid, vt: vt, mode: eavt.ValueTypeToEncodeMode(vt),
			many: q.Eavt.Resolver.IsMany(aid), indexed: q.Eavt.Resolver.IsIndexed(aid)}
		metaCache[aid] = m
		return m
	}
	entries := q.Eavt.TxInstantEntry(t)
	for i := range txops {
		op := &txops[i]
		if op.IsRetract || op.AttrId == 0 || q.opIsSchema(op) {
			continue
		}
		m := metaFor(op.AttrId)
		encoded, err := encodeSaveValueSlot(effVal(op), m.vt, m.mode, op.E.I, q.symtab)
		if err != nil {
			continue
		}
		q.saveResolvedEncodedInto(op.E.I, m.attrID, m.vt, m.many, m.indexed, m.mode, encoded, t, &entries)
	}
	perfOn := perf.Enabled()
	var t0 time.Time
	if perfOn {
		t0 = time.Now()
	}
	q.Eavt.BatchWrite(entries)
	if perfOn {
		q.perf.saveBatchWriteNS.Add(int64(time.Since(t0)))
	}
}

// RetractBatch applies all retract ops of a flat tx in one batch.
func (q *QueryStore) RetractBatch(txops []scheme.TxWOp, t int64) {
	q.saveCount.Add(int64(len(txops)))
	var entries []eavt.EavtEntry
	for i := range txops {
		op := &txops[i]
		if !op.IsRetract || op.AttrId == 0 {
			continue
		}
		vt, _ := q.Eavt.ValueTypeFor(op.AttrId)
		mode := eavt.ValueTypeToEncodeMode(vt)
		encoded, err := encodeSaveValueSlot(op.V, vt, mode, op.E.I, q.symtab)
		if err != nil {
			continue
		}
		entries = append(entries, eavt.BuildEavtEntries(op.E.I, op.AttrId, encoded, t, true, mode, q.Eavt.Resolver.IsIndexed(op.AttrId))...)
	}
	if len(entries) > 0 {
		perfOn := perf.Enabled()
		var t0 time.Time
		if perfOn {
			t0 = time.Now()
		}
		q.Eavt.BatchWrite(entries)
		if perfOn {
			q.perf.saveBatchWriteNS.Add(int64(time.Since(t0)))
		}
	}
}

// HasDatomW reports whether (eid, attrID, val) is currently asserted.
func (q *QueryStore) HasDatomW(eid int64, attrID uint32, val scheme.TxWSlot) bool {
	vt, _ := q.Eavt.ValueTypeFor(attrID)
	mode := eavt.ValueTypeToEncodeMode(vt)
	encoded, err := encodeSaveValueSlot(val, vt, mode, eid, q.symtab)
	if err != nil {
		return false
	}
	// Hydrated fast path: a hydrated eid is authoritative for its CF-0 set —
	// no key for (eid, attrID) means the datom cannot exist (bulk-load hot
	// path); with keys present, membership is checked in memory.
	if q.Eavt.HydEnabled && q.Eavt.Hyd.ProbeComplete(eid) {
		if !q.Eavt.Hyd.HasAttrKey(eid, attrID) {
			return false
		}
		prefix := append(eidAttrPrefix(eid, attrID), encoded...)
		for _, k := range q.Eavt.Hyd.LookupRange(eid, prefix) {
			if len(k) >= 20 && bytes.Equal(k[12:len(k)-8], encoded) {
				return true
			}
		}
		return false
	}
	for _, k := range q.Eavt.ScanPrefixActive(0, eidAttrPrefix(eid, attrID)) {
		if len(k) >= 20 && bytes.Equal(k[12:len(k)-8], encoded) {
			return true
		}
	}
	return false
}

// LookupEntityW resolves an entity by a unique attribute value (flat slot).
func (q *QueryStore) LookupEntityW(attrName string, value scheme.TxWSlot) (int64, bool) {
	q.lookupCount.Add(1)
	perfOn := perf.Enabled()
	var t0 time.Time
	if perfOn {
		t0 = time.Now()
	}
	aid, ok := q.Eavt.LookupAttr(attrName)
	if !ok {
		return 0, false
	}
	vt, _ := q.Eavt.ValueTypeFor(aid)
	mode := eavt.ValueTypeToEncodeMode(vt)
	encoded, err := eavt.EncodeValue(query.SlotToValueForType(value, vt, q.symtab), mode, 0)
	if err != nil {
		return 0, false
	}
	// M7: anchor probe first (unflushed), CF-2 scan fallback (committed).
	if eid, ok := q.Eavt.Anchors.Probe(aid, encoded); ok {
		q.Eavt.HydrateEID(eid)
		if perfOn {
			q.perf.lookupNS.Add(int64(time.Since(t0)))
		}
		return eid, true
	}
	prefix := append([]byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}, encoded...)
	tScan := t0
	if perfOn {
		tScan = time.Now()
	}
	for _, k := range q.Eavt.ScanPrefixActive(2, prefix) {
		if len(k) >= 20 {
			eid := eavt.DecodeEid(eavt.BeUint64(k, len(k)-16))
			q.Eavt.HydrateEID(eid)
			if perfOn {
				q.perf.lookupScanNS.Add(int64(time.Since(tScan)))
				q.perf.lookupNS.Add(int64(time.Since(t0)))
			}
			return eid, true
		}
	}
	if perfOn {
		q.perf.lookupScanNS.Add(int64(time.Since(tScan)))
		q.perf.lookupNS.Add(int64(time.Since(t0)))
	}
	return 0, false
}
