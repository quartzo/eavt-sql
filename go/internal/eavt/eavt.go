// eavt.go — read-oriented EAVT engine over the KVStore, plus the schema
// bootstrap used by the query server's replica.  Port of the read paths of
// nim_eavt/eavt.nim (write/tx paths live in the transactor).
package eavt

import (
	"bytes"
	"strings"
	"time"

	"eavt-go/internal/datalog"
	"eavt-go/internal/kvstore"
)

// ValueTypeToEncodeMode maps a db valueType to its encode mode.
func ValueTypeToEncodeMode(vt uint32) EncodeMode {
	switch vt {
	case DbTypeRef:
		return EmRef
	case DbTypeString, DbTypeKeyword:
		return EmVariable
	case DbTypeBoolean, DbTypeLong, DbTypeInstant, DbTypeFloat:
		return EmFixed
	case DbTypeBytes, DbTypeBlob:
		return EmBlob
	}
	return EmVariable
}

// ValueTypeFromName parses a value-type name.
func ValueTypeFromName(name string) uint32 {
	n := strings.ToLower(name)
	if strings.HasPrefix(n, ":db.type/") {
		n = n[len(":db.type/"):]
	}
	switch n {
	case "ref":
		return DbTypeRef
	case "string":
		return DbTypeString
	case "keyword":
		return DbTypeKeyword
	case "boolean":
		return DbTypeBoolean
	case "long":
		return DbTypeLong
	case "instant":
		return DbTypeInstant
	case "float":
		return DbTypeFloat
	case "bytes":
		return DbTypeBytes
	case "blob":
		return DbTypeBlob
	}
	return DbTypeString
}

// Engine is the read-side EAVT engine.
type Engine struct {
	KV       *kvstore.KVStore
	Resolver *Resolver

	cachedStats     *datalog.CompileStats
	cachedStatsTime time.Time
}

// NewEngine creates an engine and bootstraps its resolver.
func NewEngine(kv *kvstore.KVStore) *Engine {
	e := &Engine{KV: kv, Resolver: NewResolver()}
	e.BootstrapResolver()
	return e
}

// ── scans ────────────────────────────────────────────────────────────────

// ScanPrefix returns all keys in cf matching prefix (including retracted and
// historical versions), ascending.
func (e *Engine) ScanPrefix(cf int, prefix []byte) [][]byte {
	mc := e.KV.OpenScanCursor(cf)
	mc.Seek(prefix)
	var out [][]byte
	for {
		k, ok := mc.Next()
		if !ok {
			break
		}
		if !bytes.HasPrefix(k, prefix) {
			break
		}
		out = append(out, k)
	}
	return out
}

// ScanPrefixActive returns only active datoms (newest version per logical key).
func (e *Engine) ScanPrefixActive(cf int, prefix []byte) [][]byte {
	collected := e.ScanPrefix(cf, prefix)
	var kept [][]byte
	var lastPrefix []byte
	hasLast := false
	for j := len(collected) - 1; j >= 0; j-- {
		k := collected[j]
		if len(k) < 8 {
			continue
		}
		kp := k[:len(k)-8]
		if hasLast && bytes.Equal(kp, lastPrefix) {
			continue
		}
		sf := BeUint64(k, len(k)-8)
		if sf&1 == 0 {
			kept = append(kept, k)
		}
		lastPrefix = kp
		hasLast = true
	}
	out := make([][]byte, 0, len(kept))
	for j := len(kept) - 1; j >= 0; j-- {
		out = append(out, kept[j])
	}
	return out
}

// EstimateCount counts keys matching prefix (min 1).
func (e *Engine) EstimateCount(cf int, prefix []byte) int64 {
	n := int64(len(e.ScanPrefix(cf, prefix)))
	if n < 1 {
		return 1
	}
	return n
}

// ── accessors ────────────────────────────────────────────────────────────

// LookupAttr resolves an attribute name.
func (e *Engine) LookupAttr(name string) (uint32, bool) { return e.Resolver.LookupAttr(name) }

// AttrName returns the attribute name for an aid.
func (e *Engine) AttrName(aid uint32) string { return e.Resolver.AttrName(aid) }

// ValueTypeFor returns the db valueType for an aid.
func (e *Engine) ValueTypeFor(aid uint32) (uint32, bool) { return e.Resolver.ValueTypeFor(aid) }

// IsMany reports cardinality-many.
func (e *Engine) IsMany(aid uint32) bool { return e.Resolver.IsMany(aid) }

// IsUnique reports whether an aid is unique.
func (e *Engine) IsUnique(aid uint32) bool { return e.Resolver.IsUnique(aid) }

// IsDeclared reports whether an aid is declared.
func (e *Engine) IsDeclared(aid uint32) bool { return e.Resolver.IsDeclared(aid) }

// ── bootstrap ────────────────────────────────────────────────────────────

// bootstrapAidPrefix builds the 4-byte AEVT prefix for a schema aid.
func bootstrapAidPrefix(aid uint32) []byte {
	return []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
}

// BootstrapResolver loads the user attribute schema from db.* datoms.
func (e *Engine) BootstrapResolver() {
	identMap := map[int64]string{}
	vtMap := map[int64]uint32{}
	cardMap := map[int64]bool{}
	uniqueSet := map[int64]bool{}

	for _, k := range e.ScanPrefix(1, bootstrapAidPrefix(DbIdentAid)) {
		if len(k) < 24 || BeUint32(k, 0) != DbIdentAid {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		en := DecodeEid(BeUint64(k, 4))
		if en < BootstrapFirstUserID {
			continue
		}
		if name := DecodeVariableStr(k, 12); name != "" {
			identMap[en] = name
		}
	}
	for _, k := range e.ScanPrefix(1, bootstrapAidPrefix(DbValueTypeAid)) {
		if len(k) < 28 || BeUint32(k, 0) != DbValueTypeAid {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		vtMap[DecodeEid(BeUint64(k, 4))] = uint32(DecodeInt64(BeUint64(k, 12)))
	}
	for _, k := range e.ScanPrefix(1, bootstrapAidPrefix(DbCardinalityAid)) {
		if len(k) < 28 || BeUint32(k, 0) != DbCardinalityAid {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		cardMap[DecodeEid(BeUint64(k, 4))] = uint32(DecodeInt64(BeUint64(k, 12))) == DbCardinalityManyAid
	}
	// WAL CF-0-only residue: schema datoms also appear as CF-0.
	for _, k := range e.ScanPrefix(0, nil) {
		if len(k) < 24 {
			continue
		}
		aid := BeUint32(k, 8)
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		en := DecodeEid(BeUint64(k, 0))
		switch aid {
		case DbIdentAid:
			if en >= BootstrapFirstUserID {
				if name := DecodeVariableStr(k, 12); name != "" {
					identMap[en] = name
				}
			}
		case DbValueTypeAid:
			if en >= BootstrapFirstUserID {
				vtMap[en] = uint32(DecodeInt64(BeUint64(k, 12)))
			}
		case DbCardinalityAid:
			if en >= BootstrapFirstUserID {
				cardMap[en] = uint32(DecodeInt64(BeUint64(k, 12))) == DbCardinalityManyAid
			}
		case DbUniqueAid:
			if en >= BootstrapFirstUserID {
				uniqueSet[en] = true
			}
		}
	}
	for _, k := range e.ScanPrefix(1, bootstrapAidPrefix(DbUniqueAid)) {
		if len(k) < 20 || BeUint32(k, 0) != DbUniqueAid {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		uniqueSet[DecodeEid(BeUint64(k, 4))] = true
	}
	for en, name := range identMap {
		vt, ok := vtMap[en]
		if !ok {
			vt = DbTypeString
		}
		e.Resolver.LoadUserAttr(name, en, vt, cardMap[en], uniqueSet[en], false)
	}
	e.SeedPartitionCounters()
}

// SeedPartitionCounters walks CF-0 to advance partition counters.
func (e *Engine) SeedPartitionCounters() {
	mc := e.KV.OpenScanCursor(0)
	targets := map[uint64]bool{}
	for _, p := range e.Resolver.KnownPartitions() {
		targets[p] = true
	}
	covered := map[uint64]bool{}
	for {
		k, ok := mc.Next()
		if !ok {
			break
		}
		if len(k) < 8 {
			continue
		}
		if BeUint64(k, len(k)-8)&1 == 1 {
			continue
		}
		en := DecodeEid(BeUint64(k, 0))
		p := PartitionOf(en)
		if targets[p] {
			e.Resolver.AdvancePast(en)
			covered[p] = true
		}
		if len(covered) >= len(targets) {
			break
		}
	}
}

// BuildCompileStats precomputes the schema snapshot (30s TTL cache).
func (e *Engine) BuildCompileStats() *datalog.CompileStats {
	now := time.Now()
	if e.cachedStats != nil && now.Sub(e.cachedStatsTime) < 30*time.Second &&
		len(e.cachedStats.AttrIDs) > 0 {
		return e.cachedStats
	}
	s := datalog.NewCompileStats()
	for name, aid := range e.Resolver.attrs {
		s.AttrIDs[name] = int32(aid)
		if vt, ok := e.Resolver.ValueTypeFor(aid); ok && vt == DbTypeRef {
			s.RefAttrs[name] = true
		}
		if e.Resolver.IsIndexed(aid) {
			s.IndexedAttrs[name] = true
		}
	}
	for _, index := range []string{"EAVT", "AEVT", "AVET", "VAET"} {
		cf := CfNameToID(strings.ToLower(index))
		s.IndexEstimates[index+":"] = float64(e.EstimateCount(cf, nil))
	}
	e.cachedStats = s
	e.cachedStatsTime = now
	return s
}

// DeriveIndexKeys reshuffles a CF-0 datom key into its derived index keys
// (CF-1 always, CF-2 if indexed, CF-3 if ref).
func DeriveIndexKeys(k []byte, indexed, isRef bool) []EavtEntry {
	if len(k) < 20 {
		return nil
	}
	aid := BeUint32(k, 8)
	a := []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
	var out []EavtEntry
	k1 := append(append([]byte{}, a...), k[0:8]...)
	k1 = append(k1, k[12:]...)
	out = append(out, EavtEntry{CF: 1, Key: k1})
	if indexed {
		k2 := append(append([]byte{}, a...), k[12:len(k)-8]...)
		k2 = append(k2, k[0:8]...)
		k2 = append(k2, k[len(k)-8:]...)
		out = append(out, EavtEntry{CF: 2, Key: k2})
	}
	if isRef {
		k3 := append([]byte{}, k[12:len(k)-8]...)
		k3 = append(k3, a...)
		k3 = append(k3, k[0:8]...)
		k3 = append(k3, k[len(k)-8:]...)
		out = append(out, EavtEntry{CF: 3, Key: k3})
	}
	return out
}

// InvalidateStats forces the next BuildCompileStats to rebuild.
func (e *Engine) InvalidateStats() { e.cachedStatsTime = time.Time{} }
