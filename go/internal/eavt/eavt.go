// eavt.go — read-oriented EAVT engine over the KVStore, plus the schema
// bootstrap used by the query server's replica.  Port of the read paths of
// nim_eavt/eavt.nim (write/tx paths live in the transactor).
package eavt

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"eavt-go/internal/anchor"
	"eavt-go/internal/datalog"
	"eavt-go/internal/hydrated"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/logutil"
	"eavt-go/internal/perf"
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
	// M6: RAM read cache of complete CF-0 key sets per eid.
	Hyd *hydrated.Set
	// M7: packed [aid+val] -> eid mirror for UNIQUE attrs.
	Anchors    *anchor.Index
	HydEnabled bool

	statsMu         sync.Mutex
	cachedStats     *datalog.CompileStats
	cachedStatsTime time.Time

	// scan counters/diagnostics (atomic; the Nim spCounters + eavtScanDiag).
	spCount  int64
	spKeysIn int64
	spOpenNS int64
	spSeekNS int64
	spIterNS int64

	diagEnabled bool
	diagCalls   int64
	diagSeekNS  int64
	diagIterNS  int64
}

// ScanPerf is the cumulative scan counter snapshot (spCounters).
type ScanPerf struct {
	Calls  int64
	Keys   int64
	OpenNS int64
	SeekNS int64
	IterNS int64
}

// ScanStats returns (calls, key count) — kept for the stats command.
func (e *Engine) ScanStats() (calls, keys int64) {
	return atomic.LoadInt64(&e.spCount), atomic.LoadInt64(&e.spKeysIn)
}

// ScanPerf returns the full scan counter snapshot.
func (e *Engine) ScanPerf() ScanPerf {
	return ScanPerf{
		Calls:  atomic.LoadInt64(&e.spCount),
		Keys:   atomic.LoadInt64(&e.spKeysIn),
		OpenNS: atomic.LoadInt64(&e.spOpenNS),
		SeekNS: atomic.LoadInt64(&e.spSeekNS),
		IterNS: atomic.LoadInt64(&e.spIterNS),
	}
}

// ResetScanCounters zeroes the scan counters.
func (e *Engine) ResetScanCounters() {
	atomic.StoreInt64(&e.spCount, 0)
	atomic.StoreInt64(&e.spKeysIn, 0)
	atomic.StoreInt64(&e.spOpenNS, 0)
	atomic.StoreInt64(&e.spSeekNS, 0)
	atomic.StoreInt64(&e.spIterNS, 0)
}

// SetScanDiag toggles the eavtScanDiag diagnostics.
func (e *Engine) SetScanDiag(v bool) { e.diagEnabled = v }

// ScanDiag returns the eavtScanDiag counters (cf != 0 scans).
func (e *Engine) ScanDiag() (calls, seekNS, iterNS int64) {
	return atomic.LoadInt64(&e.diagCalls), atomic.LoadInt64(&e.diagSeekNS), atomic.LoadInt64(&e.diagIterNS)
}

// hydratedDefaults mirrors nim_eavt/eavt.nim's default budgets.
const defaultMaxBytes = 256 * 1024 * 1024

// NewEngine creates an engine and bootstraps its resolver.
func NewEngine(kv *kvstore.KVStore) *Engine {
	hydMax := defaultMaxBytes
	if v := os.Getenv("EAVT_HYDRATED_MAX_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			hydMax = n
		}
	}
	anchorMax := defaultMaxBytes
	if v := os.Getenv("EAVT_ANCHOR_INDEX_MAX_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			anchorMax = n
		}
	}
	enabled := os.Getenv("EAVT_HYDRATED_ENABLED") != "false"
	e := &Engine{
		KV:          kv,
		Resolver:    NewResolver(),
		Hyd:         hydrated.New(hydMax),
		Anchors:     anchor.New(anchorMax),
		HydEnabled:  enabled,
		diagEnabled: os.Getenv("EAVT_SCAN_DIAG") == "true",
	}
	e.BootstrapResolver()
	return e
}

// ── scans ────────────────────────────────────────────────────────────────

// ScanPrefix returns all keys in cf matching prefix (including retracted and
// historical versions), ascending.
func (e *Engine) ScanPrefix(cf int, prefix []byte) [][]byte {
	atomic.AddInt64(&e.spCount, 1)
	perfOn := perf.Enabled()
	var t time.Time
	if perfOn {
		t = time.Now()
	}
	mc := e.KV.OpenScanCursor(cf)
	if perfOn {
		atomic.AddInt64(&e.spOpenNS, int64(time.Since(t)))
		t = time.Now()
	}
	mc.Seek(prefix)
	if perfOn {
		atomic.AddInt64(&e.spSeekNS, int64(time.Since(t)))
		t = time.Now()
	}
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
	if perfOn {
		atomic.AddInt64(&e.spIterNS, int64(time.Since(t)))
	}
	atomic.AddInt64(&e.spKeysIn, int64(len(out)))
	return out
}

// ScanPrefixActive returns only active datoms (newest version per logical key).
func (e *Engine) ScanPrefixActive(cf int, prefix []byte) [][]byte {
	// M6 hydrated fast path: a CF-0 scan anchored at a hydrated eid is
	// answered entirely from the in-memory key set (complete + current).
	if e.HydEnabled && cf == 0 && len(prefix) >= 8 {
		eid := DecodeEid(BeUint64(prefix, 0))
		if e.Hyd.ProbeComplete(eid) {
			return e.Hyd.LookupRange(eid, prefix)
		}
	}
	diag := e.diagEnabled && cf != 0
	var tSeek time.Time
	if diag {
		tSeek = time.Now()
	}
	collected := e.ScanPrefix(cf, prefix)
	var tIter time.Time
	if diag {
		tIter = time.Now()
	}
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
	if diag {
		atomic.AddInt64(&e.diagSeekNS, int64(tIter.Sub(tSeek)))
		atomic.AddInt64(&e.diagIterNS, int64(time.Since(tIter)))
		n := atomic.AddInt64(&e.diagCalls, 1)
		if n%2000 == 0 {
			logutil.Info("scandiag", fmt.Sprintf("cf=%d calls=%d seekUs=%d iterUs=%d keys=%d",
				cf, n, atomic.LoadInt64(&e.diagSeekNS)/n/1000, atomic.LoadInt64(&e.diagIterNS)/n/1000, len(out)))
		}
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
	e.statsMu.Lock()
	defer e.statsMu.Unlock()
	now := time.Now()
	if e.cachedStats != nil && now.Sub(e.cachedStatsTime) < 30*time.Second &&
		len(e.cachedStats.AttrIDs) > 0 {
		return e.cachedStats
	}
	s := datalog.NewCompileStats()
	for name, aid := range e.Resolver.AttrsSnapshot() {
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
func (e *Engine) InvalidateStats() {
	e.statsMu.Lock()
	e.cachedStatsTime = time.Time{}
	e.statsMu.Unlock()
}
