// Package engine ties the KVStore + EAVT engine to the Scheme VM and scanner:
// QueryStore (EngineOps) + QuerySession/StreamingSession.  Port of the
// read path of nim_query/query/engine.nim.
package engine

import (
	"strconv"
	"sync/atomic"

	"eavt-go/internal/cursor"
	"eavt-go/internal/eavt"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/query"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

// QueryStore implements query.EngineOps over a KVStore + EAVT engine.
type QueryStore struct {
	Eavt   *eavt.Engine
	KV     *kvstore.KVStore
	symtab *scheme.SymTab

	saveCount   atomic.Int64
	lookupCount atomic.Int64
	execCount   atomic.Int64
}

// Counters returns cumulative (saves, lookups, execs).
func (q *QueryStore) Counters() (saves, lookups, execs int64) {
	return q.saveCount.Load(), q.lookupCount.Load(), q.execCount.Load()
}

// ResetCounters zeroes the engine request counters.
func (q *QueryStore) ResetCounters() {
	q.saveCount.Store(0)
	q.lookupCount.Store(0)
	q.execCount.Store(0)
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
		return eid, true
	}
	prefix := []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
	prefix = append(prefix, encoded...)
	keys := q.Eavt.ScanPrefixActive(2, prefix)
	if len(keys) > 0 && len(keys[0]) >= 20 {
		eid := eavt.DecodeEid(eavt.BeUint64(keys[0], len(keys[0])-16))
		q.Eavt.HydrateEID(eid)
		return eid, true
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
	return scheme.Eval(s.Program, scheme.NewEnvironment(), s.Host)
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
