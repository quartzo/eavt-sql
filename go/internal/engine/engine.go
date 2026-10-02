// Package engine ties the KVStore + EAVT engine to the Scheme VM and scanner:
// QueryStore (EngineOps) + QuerySession/StreamingSession.  Port of the
// read path of nim_query/query/engine.nim.
package engine

import (
	"strconv"

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
}

// New creates a QueryStore and bootstraps its resolver.
func New(kv *kvstore.KVStore) *QueryStore {
	return &QueryStore{Eavt: eavt.NewEngine(kv), KV: kv, symtab: scheme.NewSymTab()}
}

// OpenCursor opens a merged scan cursor over a CF.
func (q *QueryStore) OpenCursor(cfID uint32, prefix []byte) cursor.Cursor {
	return q.KV.OpenScanCursor(int(cfID))
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
	return eavt.DecodeStoredValue(k[12:len(k)-8], vt), true
}

// LookupEntity resolves an entity by a unique attribute value (CF-2 scan).
func (q *QueryStore) LookupEntity(attrName string, value sexpr.Expr) (int64, bool) {
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
	prefix := []byte{byte(aid >> 24), byte(aid >> 16), byte(aid >> 8), byte(aid)}
	prefix = append(prefix, encoded...)
	keys := q.Eavt.ScanPrefixActive(2, prefix)
	if len(keys) > 0 && len(keys[0]) >= 20 {
		return eavt.DecodeEid(eavt.BeUint64(keys[0], len(keys[0])-16)), true
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
