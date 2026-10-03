// Package engine ties the KVStore + EAVT engine to the Scheme VM and scanner:
// QueryStore (EngineOps) + QuerySession/StreamingSession.  Port of the
// read path of nim_query/query/engine.nim.
package engine

import (
	"strconv"
	"sync/atomic"
	"time"

	"eavt-go/internal/cursor"
	"eavt-go/internal/eavt"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/perf"
	"eavt-go/internal/query"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

// perfStats holds the optional nanosecond buckets (Nim perfCounters).
type perfStats struct {
	saveLookupAttrNS  atomic.Int64
	saveTypeCheckNS   atomic.Int64
	saveEncodeNS      atomic.Int64
	saveRetractScanNS atomic.Int64
	saveRetractPrefix atomic.Int64
	saveRetractSeek   atomic.Int64
	saveRetractApply  atomic.Int64
	saveRetractCount  atomic.Int64
	saveRetractScans  atomic.Int64
	saveBuildEntries  atomic.Int64
	saveBatchWriteNS  atomic.Int64
	lookupNS          atomic.Int64
	lookupScanNS      atomic.Int64
	execWallNS        atomic.Int64
	decodeNS          atomic.Int64
	decodeCount       atomic.Int64
}

// QueryStore implements query.EngineOps over a KVStore + EAVT engine.
type QueryStore struct {
	Eavt   *eavt.Engine
	KV     *kvstore.KVStore
	symtab *scheme.SymTab

	saveCount   atomic.Int64
	lookupCount atomic.Int64
	execCount   atomic.Int64

	perf perfStats
}

// SavePerf is the QueryStore timing snapshot.
type SavePerf struct {
	Saves           int64
	LookupAttrNS    int64
	TypeCheckNS     int64
	EncodeNS        int64
	RetractScanNS   int64
	RetractPrefixNS int64
	RetractSeekNS   int64
	RetractApplyNS  int64
	RetractCount    int64
	RetractScans    int64
	BuildEntriesNS  int64
	BatchWriteNS    int64
	Lookups         int64
	LookupNS        int64
	LookupScanNS    int64
	Execs           int64
	ExecWallNS      int64
	DecodeNS        int64
	DecodeCount     int64
}

// Counters returns cumulative (saves, lookups, execs).
func (q *QueryStore) Counters() (saves, lookups, execs int64) {
	return q.saveCount.Load(), q.lookupCount.Load(), q.execCount.Load()
}

// SavePerf returns the timing snapshot.
func (q *QueryStore) SavePerf() SavePerf {
	return SavePerf{
		Saves:           q.saveCount.Load(),
		LookupAttrNS:    q.perf.saveLookupAttrNS.Load(),
		TypeCheckNS:     q.perf.saveTypeCheckNS.Load(),
		EncodeNS:        q.perf.saveEncodeNS.Load(),
		RetractScanNS:   q.perf.saveRetractScanNS.Load(),
		RetractPrefixNS: q.perf.saveRetractPrefix.Load(),
		RetractSeekNS:   q.perf.saveRetractSeek.Load(),
		RetractApplyNS:  q.perf.saveRetractApply.Load(),
		RetractCount:    q.perf.saveRetractCount.Load(),
		RetractScans:    q.perf.saveRetractScans.Load(),
		BuildEntriesNS:  q.perf.saveBuildEntries.Load(),
		BatchWriteNS:    q.perf.saveBatchWriteNS.Load(),
		Lookups:         q.lookupCount.Load(),
		LookupNS:        q.perf.lookupNS.Load(),
		LookupScanNS:    q.perf.lookupScanNS.Load(),
		Execs:           q.execCount.Load(),
		ExecWallNS:      q.perf.execWallNS.Load(),
		DecodeNS:        q.perf.decodeNS.Load(),
		DecodeCount:     q.perf.decodeCount.Load(),
	}
}

// AddDecode records msgpack→SExpr decode time (set by the transactor loop).
func (q *QueryStore) AddDecode(ns int64) {
	q.perf.decodeNS.Add(ns)
	q.perf.decodeCount.Add(1)
}

// ResetCounters zeroes the engine request counters and timing buckets.
func (q *QueryStore) ResetCounters() {
	q.saveCount.Store(0)
	q.lookupCount.Store(0)
	q.execCount.Store(0)
	for _, c := range []*atomic.Int64{
		&q.perf.saveLookupAttrNS, &q.perf.saveTypeCheckNS, &q.perf.saveEncodeNS,
		&q.perf.saveRetractScanNS, &q.perf.saveRetractPrefix, &q.perf.saveRetractSeek,
		&q.perf.saveRetractApply, &q.perf.saveRetractCount, &q.perf.saveRetractScans,
		&q.perf.saveBuildEntries, &q.perf.saveBatchWriteNS, &q.perf.lookupNS,
		&q.perf.lookupScanNS, &q.perf.execWallNS, &q.perf.decodeNS, &q.perf.decodeCount,
	} {
		c.Store(0)
	}
}

// New creates a QueryStore and bootstraps its resolver.
func New(kv *kvstore.KVStore) *QueryStore {
	return &QueryStore{Eavt: eavt.NewEngine(kv), KV: kv, symtab: scheme.NewSymTab()}
}

// OpenCursor opens a merged scan cursor over a CF.  CF-0 cursors are wired to
// the hydrated set (M6) for eid-anchored fast-path seeks, EXCEPT for history
// (as-of) scans: a hydrated entry holds only ACTIVE keys, so using it would
// hide older versions needed to reconstruct the value as of a past tx.
func (q *QueryStore) OpenCursor(cfID uint32, prefix []byte, history bool) cursor.Cursor {
	mc := q.KV.OpenScanCursor(int(cfID))
	if cfID == 0 && q.Eavt.HydEnabled && !history {
		mc.Hyd = q.Eavt.Hyd
	}
	return mc
}

// LookupAttr resolves an attribute name.
func (q *QueryStore) LookupAttr(name string) (uint32, bool) { return q.Eavt.LookupAttr(name) }

// AttrName returns the name for an aid.
func (q *QueryStore) AttrName(aid uint32) string { return q.Eavt.AttrName(aid) }

// ValueTypeFor returns the db valueType for an aid.
func (q *QueryStore) ValueTypeFor(aid uint32) (uint32, bool) { return q.Eavt.ValueTypeFor(aid) }

// IsUniqueAttr reports whether an attribute is unique.
func (q *QueryStore) IsUniqueAttr(name string) bool {
	aid, ok := q.Eavt.LookupAttr(name)
	return ok && q.Eavt.IsUnique(aid)
}

// LookupValue returns the first active value for (eid, attr).
func (q *QueryStore) LookupValue(eid int64, attrName string) (sexpr.Expr, bool) {
	aid, ok := q.Eavt.LookupAttr(attrName)
	if !ok {
		return nil, false
	}
	prefix := append(eavt.EncodeEid(eid), byte(aid>>24), byte(aid>>16), byte(aid>>8), byte(aid))
	keys := q.Eavt.ScanPrefixActive(0, prefix)
	if len(keys) == 0 {
		return nil, false
	}
	k := keys[0]
	if len(k) < 20 {
		return nil, false
	}
	vt, _ := q.Eavt.ValueTypeFor(aid)
	q.Eavt.HydrateEID(eid)
	return eavt.DecodeStoredValue(k[12:len(k)-8], vt), true
}

// LookupEntity resolves an entity by a unique attribute value.  M7: anchor
// probe first (O(1)); CF-2 scan fallback.
func (q *QueryStore) LookupEntity(attrName string, value sexpr.Expr) (int64, bool) {
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
	packed := sexprToValueForType(value, vt)
	encoded, err := eavt.EncodeValue(packed, mode, 0)
	if err != nil {
		return 0, false
	}
	if eid, ok := q.Eavt.Anchors.Probe(aid, encoded); ok {
		q.Eavt.HydrateEID(eid)
		if perfOn {
			q.perf.lookupNS.Add(int64(time.Since(t0)))
		}
		return eid, true
	}
	prefix := []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
	prefix = append(prefix, encoded...)
	tScan := t0
	if perfOn {
		tScan = time.Now()
	}
	keys := q.Eavt.ScanPrefixActive(2, prefix)
	if len(keys) > 0 && len(keys[0]) >= 20 {
		eid := eavt.DecodeEid(eavt.BeUint64(keys[0], len(keys[0])-16))
		q.Eavt.HydrateEID(eid)
		if perfOn {
			q.perf.lookupScanNS.Add(int64(time.Since(tScan)))
			q.perf.lookupNS.Add(int64(time.Since(t0)))
		}
		return eid, true
	}
	if perfOn {
		q.perf.lookupScanNS.Add(int64(time.Since(tScan)))
		q.perf.lookupNS.Add(int64(time.Since(t0)))
	}
	return 0, false
}

func sexprToPackedValue(val sexpr.Expr) string {
	switch v := val.(type) {
	case sexpr.Void:
		return ""
	case sexpr.Int:
		return strconv.FormatInt(int64(v), 10)
	case sexpr.Float:
		return strconv.FormatFloat(float64(v), 'g', -1, 64)
	case sexpr.Str:
		return string(v)
	case sexpr.Keyword:
		return string(v)
	case sexpr.Bool:
		if bool(v) {
			return "true"
		}
		return "false"
	case sexpr.Bytes:
		return string(v)
	}
	return ""
}

func sexprToValueForType(val sexpr.Expr, vt uint32) string {
	switch vt {
	case query.DbTypeBoolean:
		if b, ok := val.(sexpr.Bool); ok {
			if bool(b) {
				return "1"
			}
			return "0"
		}
		return "0"
	case query.DbTypeBytes, query.DbTypeBlob:
		if b, ok := val.(sexpr.Bytes); ok {
			return string(b)
		}
		return "0"
	}
	return sexprToPackedValue(val)
}

// ── sessions ─────────────────────────────────────────────────────────────

// QuerySession runs a compiled Scheme program.
type QuerySession struct {
	Store   *QueryStore
	Host    *query.SchemeHostFns
	Program scheme.Program
}

// NewQuerySession creates a session for a program.
func NewQuerySession(store *QueryStore, program scheme.Program, params []sexpr.Expr, tx int64, asOfTx int64, hasAsOfTx bool) *QuerySession {
	host := query.NewSchemeHostFns(store, params, tx, asOfTx, hasAsOfTx)
	return &QuerySession{Store: store, Host: host, Program: program}
}

// ExecuteProgram runs the program to completion (non-streaming).
func (s *QuerySession) ExecuteProgram() (sexpr.Expr, error) {
	s.Store.execCount.Add(1)
	perfOn := perf.Enabled()
	var t0 time.Time
	if perfOn {
		t0 = time.Now()
	}
	r, err := scheme.Eval(s.Program, scheme.NewEnvironment(), s.Host)
	if perfOn {
		s.Store.perf.execWallNS.Add(int64(time.Since(t0)))
	}
	return r, err
}

// StreamingSession is a yield/resume VM session.
type StreamingSession struct {
	VM   *scheme.VmSession
	Host *query.SchemeHostFns
}

// NewStreamingSession wraps a query session for streaming.
func NewStreamingSession(proto *QuerySession) *StreamingSession {
	return &StreamingSession{VM: scheme.NewVmSession(proto.Program), Host: proto.Host}
}

// NextBatch returns up to maxRows rows and whether more remain.
func (s *StreamingSession) NextBatch(maxRows int) ([][]sexpr.Expr, bool, error) {
	return s.VM.NextBatch(s.Host, maxRows)
}
