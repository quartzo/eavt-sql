// write.go — EAVT write path (save/retract, schema declaration, tx allocation,
// recovery).  Port of nim_eavt/eavt.nim write procs.  The hydrated cache and
// anchor index are read optimizations and are intentionally absent — unique
// lookups fall back to the CF-2 scan.
package eavt

import (
	"sort"
	"strconv"
	"time"

	"eavt-go/internal/memtable"
	"eavt-go/internal/sexpr"
)

// BatchWrite journals the CF-0 datoms and writes every CF to the memtable.
// CF-2 keys are additionally mirrored into the anchor hash (M7 O(1) unique
// lookup) and CF-0 keys into the hydrated cache (M6 read-your-writes).
func (e *Engine) BatchWrite(entries []EavtEntry) {
	if len(entries) == 0 {
		return
	}
	cfs := make([]memtable.CfKey, 0, len(entries))
	var durable []memtable.CfKey
	for _, en := range entries {
		if en.CF == 2 && len(en.Key) >= 20 {
			k := en.Key
			sf := BeUint64(k, len(k)-8)
			aid := BeUint32(k, 0)
			if sf&1 == 0 {
				e.Anchors.Put(aid, k[4:len(k)-16], DecodeEid(BeUint64(k, len(k)-16)))
			} else {
				e.Anchors.Del(aid, k[4:len(k)-16])
			}
		}
		cfs = append(cfs, memtable.CfKey{Cf: en.CF, Key: en.Key})
		if en.CF == 0 {
			durable = append(durable, memtable.CfKey{Cf: 0, Key: en.Key})
		}
	}
	if len(durable) > 0 {
		e.KV.JournalOnly(durable)
	}
	if e.HydEnabled {
		for _, d := range durable {
			e.Hyd.ApplyKey(d.Key)
		}
	}
	e.KV.BatchWrite(cfs, false)
}

func nowMicros() uint64 {
	now := time.Now()
	return uint64(now.Unix())*1_000_000 + uint64(now.Nanosecond()/1000)
}

// EavtSave saves one datom (retracting any existing active card-one value).
func (e *Engine) EavtSave(eid int64, attrName, value string, t int64) (int64, error) {
	attrID, err := e.Resolver.InternAttr(attrName)
	if err != nil {
		return 0, err
	}
	vt, ok := e.Resolver.ValueTypeFor(attrID)
	if !ok {
		vt = DbTypeString
	}
	many := e.Resolver.IsMany(attrID)
	mode := ValueTypeToEncodeMode(vt)
	encoded, err := encodeForMode(value, mode)
	if err != nil {
		return 0, err
	}
	indexed := e.Resolver.IsIndexed(attrID)
	if !many {
		prefix := append(EncodeEid(eid), byte(attrID>>24), byte(attrID>>16), byte(attrID>>8), byte(attrID))
		for _, ek := range e.ScanPrefix(0, prefix) {
			if len(ek) < 20 {
				continue
			}
			if BeUint64(ek, len(ek)-8)&1 != 0 {
				continue
			}
			e.BatchWrite(BuildEavtEntries(eid, attrID, ek[12:len(ek)-8], t, true, mode, indexed))
		}
	}
	e.BatchWrite(BuildEavtEntries(eid, attrID, encoded, t, false, mode, indexed))
	return eid, nil
}

// EavtRetract retracts one value.
func (e *Engine) EavtRetract(eid int64, attrName, value string, t int64) error {
	attrID, err := e.Resolver.InternAttr(attrName)
	if err != nil {
		return err
	}
	vt, ok := e.Resolver.ValueTypeFor(attrID)
	if !ok {
		vt = DbTypeString
	}
	mode := ValueTypeToEncodeMode(vt)
	encoded, err := encodeForMode(value, mode)
	if err != nil {
		return err
	}
	e.BatchWrite(BuildEavtEntries(eid, attrID, encoded, t, true, mode, e.Resolver.IsIndexed(attrID)))
	return nil
}

func encodeForMode(value string, mode EncodeMode) ([]byte, error) {
	if mode == EmRef {
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return nil, errf("REF value must be an entity id, got: %q", value)
		}
		return EncodeValue(value, mode, n)
	}
	return EncodeValue(value, mode, 0)
}

// AllocateTAndWriteTx allocates a tx entity and writes its db.txInstant datom.
func (e *Engine) AllocateTAndWriteTx() int64 {
	txEid, _ := e.Resolver.AllocateInPartition(PartTx)
	encoded, _ := EncodeValue(strconv.FormatUint(nowMicros(), 10), EmFixed, 0)
	e.BatchWrite(BuildEavtEntries(txEid, DbTxInstantAid, encoded, txEid, false, EmFixed, false))
	return txEid
}

// AllocateTDeferred allocates a tx entity without writing its db.txInstant.
func (e *Engine) AllocateTDeferred() int64 {
	txEid, _ := e.Resolver.AllocateInPartition(PartTx)
	return txEid
}

// TxInstantEntry builds the deferred db.txInstant datom for a txEid.
func (e *Engine) TxInstantEntry(txEid int64) []EavtEntry {
	encoded, _ := EncodeValue(strconv.FormatUint(nowMicros(), 10), EmFixed, 0)
	return BuildEavtEntries(txEid, DbTxInstantAid, encoded, txEid, false, EmFixed, false)
}

// ResolveAsOfTx resolves an as-of timestamp (micros) to the newest tx <= it.
func (e *Engine) ResolveAsOfTx(asOfUs uint64) (uint64, bool) {
	if asOfUs == ^uint64(0) {
		return 0, false
	}
	if asOfUs>>44 == PartTx {
		return asOfUs, true
	}
	prefix := []byte{0, 0, 0, byte(DbTxInstantAid)}
	var bestTx, bestInst uint64
	found := false
	for _, k := range e.ScanPrefix(1, prefix) {
		if len(k) < 28 || BeUint32(k, 0) != DbTxInstantAid {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		us := DecodeInt64(BeUint64(k, 12))
		if us < 0 {
			continue
		}
		usU := uint64(us)
		if usU <= asOfUs && (!found || usU > bestInst) {
			bestTx = BeUint64(k, 4)
			bestInst = usU
			found = true
		}
	}
	return bestTx, found
}

// EavtDeclareAttr declares an attribute and persists its schema datoms.
func (e *Engine) EavtDeclareAttr(name string, valueType uint32, many, unique bool) (uint32, bool, error) {
	canonical, err := NormalizeAttr(name)
	if err != nil {
		return 0, false, err
	}
	aid, isNew, err := e.Resolver.DeclareAttr(canonical, valueType, many)
	if err != nil {
		return 0, false, err
	}
	if unique {
		e.Resolver.SetUnique(aid, true)
	}
	if isNew {
		t, _ := e.Resolver.AllocateInPartition(PartTx)
		aeid := int64(aid)
		ident, _ := EncodeValue(canonical, EmVariable, 0)
		e.BatchWrite(BuildEavtEntries(aeid, DbIdentAid, ident, aeid, false, EmVariable, true))
		vtEnc, _ := EncodeValue(strconv.FormatUint(uint64(valueType), 10), EmFixed, 0)
		e.BatchWrite(BuildEavtEntries(aeid, DbValueTypeAid, vtEnc, t, false, EmFixed, true))
		cardID := DbCardinalityOneAid
		if many {
			cardID = DbCardinalityManyAid
		}
		cardEnc, _ := EncodeValue(strconv.FormatUint(uint64(cardID), 10), EmFixed, 0)
		e.BatchWrite(BuildEavtEntries(aeid, DbCardinalityAid, cardEnc, t, false, EmFixed, true))
	}
	if unique {
		t, _ := e.Resolver.AllocateInPartition(PartTx)
		enc, _ := EncodeValue(strconv.FormatUint(uint64(DbUniqueIdentityAid), 10), EmFixed, 0)
		e.BatchWrite(BuildEavtEntries(int64(aid), DbUniqueAid, enc, t, false, EmFixed, true))
	}
	return aid, isNew, nil
}

// BootstrapSystemAttrs writes EAVT datoms for the built-in schema (once).
func (e *Engine) BootstrapSystemAttrs() {
	for _, k := range e.ScanPrefix(1, []byte{0, 0, 0, byte(DbIdentAid)}) {
		if len(k) >= 24 && DecodeEid(BeUint64(k, 4)) == int64(DbIdentAid) {
			return
		}
	}
	tx, _ := e.Resolver.AllocateInPartition(PartTx)
	for _, s := range BootstrapSchema {
		var vt uint32
		switch {
		case s.Name == "db/ident" || s.Name == "db.part/id":
			vt = DbTypeString
		case s.Name == "db/txInstant":
			vt = DbTypeInstant
		case s.Name == "db/isComponent" || s.Name == "db/index" || s.Name == "db/fulltext" || s.Name == "db/noHistory":
			vt = DbTypeBoolean
		default:
			vt = DbTypeRef
		}
		var uniqueID uint32
		switch s.Name {
		case "db/unique/value":
			uniqueID = DbUniqueValueAid
		case "db/unique/identity":
			uniqueID = DbUniqueIdentityAid
		}
		eid := int64(s.Aid)
		ident, _ := EncodeValue(s.Name, EmVariable, 0)
		e.BatchWrite(BuildEavtEntries(eid, DbIdentAid, ident, tx, false, EmVariable, true))
		vtEnc, _ := EncodeValue("", EmRef, int64(vt))
		e.BatchWrite(BuildEavtEntries(eid, DbValueTypeAid, vtEnc, tx, false, EmRef, true))
		cardEnc, _ := EncodeValue("", EmRef, int64(DbCardinalityOneAid))
		e.BatchWrite(BuildEavtEntries(eid, DbCardinalityAid, cardEnc, tx, false, EmRef, true))
		if uniqueID != 0 {
			uEnc, _ := EncodeValue("", EmRef, int64(uniqueID))
			e.BatchWrite(BuildEavtEntries(eid, DbUniqueAid, uEnc, tx, false, EmRef, true))
		}
	}
}

// AllocateInPartition reserves a user/partition entity id.  New entities
// start hydrated (empty): their first saves mirror into the fast path.
func (e *Engine) AllocateInPartition(pid uint64) int64 {
	eid, _ := e.Resolver.AllocateInPartition(pid)
	if e.HydEnabled {
		e.Hyd.HydrateEmpty(eid)
	}
	return eid
}

// AllocateEntityId reserves a user entity id.
func (e *Engine) AllocateEntityId() int64 { return e.AllocateInPartition(PartUser) }

// HydrateEID installs the full active CF-0 key set for eid (read-time
// hydration).  No-op when disabled or already hydrated; phantom (no datom)
// entities are left unhydrated.
func (e *Engine) HydrateEID(eid int64) {
	if !e.HydEnabled || e.Hyd.Contains(eid) {
		return
	}
	ks := e.ScanPrefixActive(0, EncodeEid(eid))
	if len(ks) > 0 {
		e.Hyd.Hydrate(eid, ks)
	}
}

// BatchWriteForeign routes datom/index keys that are NOT arena-owned (replica
// WAL frames, tests) through the write path so the anchor/hydrated mirrors
// stay current.  No journaling happens on a read-only replica.
func (e *Engine) BatchWriteForeign(entries []EavtEntry) {
	if len(entries) == 0 {
		return
	}
	owned := make([]EavtEntry, 0, len(entries))
	for _, en := range entries {
		k := make([]byte, len(en.Key))
		copy(k, en.Key)
		owned = append(owned, EavtEntry{CF: en.CF, Key: k})
	}
	e.BatchWrite(owned)
}

// DeclarePartition registers a custom partition.
func (e *Engine) DeclarePartition(name string) uint64 { return e.Resolver.DeclarePartition(name) }

// PartitionIDFor resolves a partition name.
func (e *Engine) PartitionIDFor(name string) (uint64, bool) { return e.Resolver.PartitionIDFor(name) }

// BatchLookupAvet does batched unique-index lookups (positional results;
// 0 = not found — entity ids are always non-zero).
func (e *Engine) BatchLookupAvet(keys [][]byte) []int64 {
	out := make([]int64, len(keys))
	if len(keys) == 0 {
		return out
	}
	// M7: hash probe first (unflushed anchors); misses fall to the CF-2 scan.
	var missIdx []int
	var missKeys [][]byte
	for i, k := range keys {
		if len(k) > 4 {
			if eid, ok := e.Anchors.Probe(BeUint32(k, 0), k[4:]); ok {
				out[i] = eid
				continue
			}
		}
		missIdx = append(missIdx, i)
		missKeys = append(missKeys, k)
	}
	if len(missIdx) == 0 {
		return out
	}
	order := make([]int, len(missKeys))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return CmpBytes(missKeys[order[a]], missKeys[order[b]]) < 0 })
	lastIdx := -1
	for oi := range order {
		mi := order[oi]
		if lastIdx >= 0 && CmpBytes(missKeys[order[lastIdx]], missKeys[mi]) == 0 {
			out[missIdx[mi]] = out[missIdx[order[lastIdx]]]
			continue
		}
		res := e.ScanPrefixActive(2, missKeys[mi])
		if len(res) > 0 && len(res[0]) >= 20 {
			out[missIdx[mi]] = DecodeEid(BeUint64(res[0], len(res[0])-16))
		}
		lastIdx = oi
	}
	return out
}

// LookupEntityByValue resolves an entity by a unique attribute value.
func (e *Engine) LookupEntityByValue(attrName, value string) (int64, bool) {
	aid, ok := e.LookupAttr(attrName)
	if !ok {
		return 0, false
	}
	vt, _ := e.ValueTypeFor(aid)
	mode := ValueTypeToEncodeMode(vt)
	encoded, err := EncodeValue(value, mode, 0)
	if err != nil {
		return 0, false
	}
	// M7: anchor probe first (O(1)); CF-2 scan fallback.
	if eid, ok := e.Anchors.Probe(aid, encoded); ok {
		e.HydrateEID(eid)
		return eid, true
	}
	prefix := append([]byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}, encoded...)
	for _, k := range e.ScanPrefixActive(2, prefix) {
		if len(k) >= 20 {
			eid := DecodeEid(BeUint64(k, len(k)-16))
			e.HydrateEID(eid)
			return eid, true
		}
	}
	return 0, false
}

// LookupValueStr returns the first active string value for (eid, attrName).
func (e *Engine) LookupValueStr(eid int64, attrName string) (string, bool) {
	aid, ok := e.LookupAttr(attrName)
	if !ok {
		return "", false
	}
	prefix := append(EncodeEid(eid), byte(aid>>24), byte(aid>>16), byte(aid>>8), byte(aid))
	for _, k := range e.ScanPrefixActive(0, prefix) {
		if len(k) < 20 {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		vt, _ := e.ValueTypeFor(aid)
		v := DecodeStoredValue(k[12:len(k)-8], vt)
		if str, ok := v.(sexpr.Str); ok {
			return string(str), true
		}
		return "", false
	}
	return "", false
}

// RecoverWriteState rebuilds derived index keys for the CF-0 replay residue.
func (e *Engine) RecoverWriteState() {
	var derived []memtable.CfKey
	for _, k := range e.ScanPrefix(0, nil) {
		if len(k) < 20 {
			continue
		}
		aid := BeUint32(k, 8)
		if aid == DbTxInstantAid {
			continue
		}
		retracted := BeUint64(k, len(k)-8)&1 == 1
		indexed := e.Resolver.IsIndexed(aid)
		isRef := false
		if !retracted {
			if vt, ok := e.Resolver.ValueTypeFor(aid); ok && vt == DbTypeRef {
				isRef = true
			}
		}
		for _, d := range DeriveIndexKeys(k, indexed, isRef) {
			derived = append(derived, memtable.CfKey{Cf: d.CF, Key: d.Key})
		}
		if !retracted && indexed {
			// M7 anchor rebuild: [aid][val] -> eid for the O(1) probe.
			e.Anchors.Put(aid, k[12:len(k)-8], DecodeEid(BeUint64(k, 0)))
		}
	}
	e.KV.ApplyJournalRecordsExpanded(derived)
}

// CmpBytes is a lexicographic byte comparator.
func CmpBytes(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
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

// Datom is one decoded EAVT datom (admin dump).
type Datom struct {
	E         int64
	A         uint32
	AttrName  string
	Value     sexpr.Expr
	T         int64
	Retracted bool
}

// ScanDatoms decodes all keys of a CF into datoms (port of scanDatoms).
func (e *Engine) ScanDatoms(cf int) []Datom {
	mc := e.KV.OpenScanCursor(cf)
	var out []Datom
	for {
		key, ok := mc.Next()
		if !ok {
			break
		}
		if len(key) < 20 {
			continue
		}
		t, retracted := DecodeSuffix(BeUint64(key, len(key)-8))
		var eid int64
		var aid uint32
		var vStart, vEnd int
		switch cf {
		case 0:
			eid = DecodeEid(BeUint64(key, 0))
			aid = BeUint32(key, 8)
			vStart, vEnd = 12, len(key)-8
		case 1:
			aid = BeUint32(key, 0)
			eid = DecodeEid(BeUint64(key, 4))
			vStart, vEnd = 12, len(key)-8
		case 2:
			aid = BeUint32(key, 0)
			vStart, vEnd = 4, len(key)-16
			eid = DecodeEid(BeUint64(key, len(key)-16))
		case 3:
			vStart, vEnd = 0, len(key)-20
			eid = DecodeEid(BeUint64(key, len(key)-12))
			aid = BeUint32(key, len(key)-16)
		default:
			continue
		}
		if vEnd <= vStart {
			continue
		}
		vt, _ := e.ValueTypeFor(aid)
		out = append(out, Datom{
			E: eid, A: aid, AttrName: e.AttrName(aid),
			Value: DecodeStoredValue(key[vStart:vEnd], vt), T: t, Retracted: retracted,
		})
	}
	return out
}
