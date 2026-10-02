// Package querysrv implements the query server's two sockets: the client
// gateway (datalog compile+execute locally, forwards writes) and the internal
// executor socket (scheme-local + schema + forwarding).  Port of
// eavt_query_nim/{connection,shared}.nim (read path; explain deferred).
package querysrv

import (
	"net"
	"strings"
	"sync"
	"time"

	"eavt-go/internal/datalog"
	"eavt-go/internal/downstream"
	"eavt-go/internal/edn"
	"eavt-go/internal/engine"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/replica"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

const schemaTTL = 30 * time.Second
const batchSize = 100

// Gateway is the shared query-server state.
//
// The KVStore/MemTable/engine are NOT internally synchronized (the Nim query
// server runs a single event loop).  Go serves a goroutine per connection, so
// a single mutex serializes every replica/engine access — query execution,
// WAL/snapshot apply and stats rebuild — reproducing the single-loop
// semantics.
type Gateway struct {
	Replica *replica.ReplicaEngine
	Conn    *downstream.Conn

	mu        sync.Mutex
	stats     *datalog.CompileStats
	fetchedAt time.Time
}

// NewGateway creates the gateway state.
func NewGateway(downstreamPath, dataPath string) *Gateway {
	g := &Gateway{}
	g.Replica = replica.Open(dataPath)
	if g.Replica != nil {
		g.Conn = downstream.Open(downstreamPath, func(frame []byte) {
			g.onReplicationEvent(frame)
		})
	}
	return g
}

// GetSnapshot returns the (cached) CompileStats for query compilation.
func (g *Gateway) GetSnapshot() *datalog.CompileStats {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stats != nil && g.Replica != nil && !g.Replica.SchemaDirty &&
		time.Since(g.fetchedAt) < schemaTTL && len(g.stats.AttrIDs) > 0 {
		return g.stats
	}
	if g.Replica != nil {
		g.stats = g.Replica.GetStats()
		g.Replica.SchemaDirty = false
		g.fetchedAt = time.Now()
	}
	return g.stats
}

// InvalidateSnapshot forces a stats rebuild on the next compile.
func (g *Gateway) InvalidateSnapshot() {
	g.mu.Lock()
	g.fetchedAt = time.Time{}
	g.mu.Unlock()
}

// ── replication events ───────────────────────────────────────────────────

func (g *Gateway) onReplicationEvent(frame []byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	v, err := msgpack.Unmarshal(frame)
	if err != nil {
		return
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		return
	}
	ev := memberStr(m, "ev")
	switch ev {
	case "snapshot":
		var sealed []string
		if a, ok := msgpack.Member(m, msgpack.Str("sealed")); ok {
			if arr, ok := a.(msgpack.Array); ok {
				for _, e := range arr {
					if s, ok := e.(msgpack.Str); ok {
						sealed = append(sealed, string(s))
					}
				}
			}
		}
		var tail []byte
		if a, ok := msgpack.Member(m, msgpack.Str("openTail")); ok {
			tail = valueBytes(a)
		}
		g.Replica.ApplySnapshot(sealed, tail, memberStr(m, "root"))
	case "wal":
		var data []byte
		if a, ok := msgpack.Member(m, msgpack.Str("data")); ok {
			data = valueBytes(a)
		}
		g.Replica.ApplyWal(data)
	case "seal":
		g.Replica.ApplySeal()
	case "root":
		maxT := int64(-1)
		if a, ok := msgpack.Member(m, msgpack.Str("maxT")); ok {
			if i, ok := a.(msgpack.Int); ok {
				maxT = int64(i)
			}
		}
		g.Replica.ApplyRoot(memberStr(m, "name"), maxT)
	}
}

func valueBytes(v msgpack.Value) []byte {
	switch x := v.(type) {
	case msgpack.Bin:
		return append([]byte(nil), x...)
	case msgpack.Array:
		out := make([]byte, 0, len(x))
		for _, e := range x {
			if i, ok := e.(msgpack.Int); ok {
				out = append(out, byte(int64(i)))
			}
		}
		return out
	}
	return nil
}

// ── connection dispatch ──────────────────────────────────────────────────

// ServeClient handles the client-facing socket.
func (g *Gateway) ServeClient(conn net.Conn) { g.serve(conn, false) }

// ServeInternal handles the internal executor socket.
func (g *Gateway) ServeInternal(conn net.Conn) { g.serve(conn, true) }

func (g *Gateway) serve(conn net.Conn, internal bool) {
	defer conn.Close()
	for {
		raw, err := downstream.ReadFrame(conn)
		if err != nil {
			return
		}
		v, err := msgpack.Unmarshal(raw)
		if err != nil {
			downstream.RelayError(conn, "parse error: request must be an object")
			continue
		}
		m, ok := v.(msgpack.Map)
		if !ok {
			downstream.RelayError(conn, "parse error: request must be an object")
			continue
		}
		typ := memberStr(m, "type")
		if internal {
			switch typ {
			case "datalog":
				g.handleDatalog(conn, raw, m)
			case "scheme-local":
				g.handleSchemeLocal(conn, m)
			case "schema":
				g.handleSchema(conn)
			case "tx", "admin", "kv", "scheme":
				g.forward(conn, raw)
			default:
				downstream.RelayError(conn, "internal socket: unknown request type: "+typ)
			}
			continue
		}
		switch typ {
		case "datalog":
			g.handleDatalog(conn, raw, m)
		case "schema":
			g.handleSchema(conn)
		case "tx", "admin", "kv", "scheme":
			g.forward(conn, raw)
		case "":
			downstream.RelayError(conn, "parse error: request must be an object with a type")
		default:
			downstream.RelayError(conn, "unknown request type: "+typ)
		}
	}
}

func (g *Gateway) handleDatalog(conn net.Conn, raw []byte, m msgpack.Map) {
	query := memberStr(m, "query")
	if query == "" {
		downstream.RelayError(conn, "datalog request missing query field")
		return
	}
	var params []sexpr.Expr
	if a, ok := msgpack.Member(m, msgpack.Str("params")); ok {
		if arr, ok := a.(msgpack.Array); ok {
			for _, p := range arr {
				if e, err := wireValue(p); err == nil {
					params = append(params, e)
				}
			}
		}
	}
	if strings.Contains(query, ":db/add") || strings.Contains(query, ":db/retract") {
		g.forwardTxData(conn, query)
		return
	}
	if memberBool(m, "explain") {
		g.handleExplain(conn, query)
		return
	}
	if g.Replica == nil {
		downstream.RelayError(conn, "replica unavailable")
		return
	}
	prog, findVars, err := g.compile(query)
	if err != nil {
		downstream.RelayError(conn, err.Error())
		return
	}
	g.streamProgram(conn, prog, params, findVars)
}

func (g *Gateway) compile(query string) (scheme.Program, []string, error) {
	attempt := func() (scheme.Program, []string, error) {
		stats := g.GetSnapshot()
		prog, fv, err := datalog.CompileDatalogQuery(query, stats)
		if err != nil {
			return scheme.Program{}, nil, err
		}
		return scheme.Program{Body: prog}, fv, nil
	}
	p, fv, err := attempt()
	if err != nil && strings.Contains(err.Error(), "attribute resolution failed") {
		g.InvalidateSnapshot()
		g.refreshResolver()
		return attempt()
	}
	return p, fv, err
}

func (g *Gateway) refreshResolver() {
	g.mu.Lock()
	if g.Replica != nil {
		g.Replica.RefreshResolverOnSchemaWal()
	}
	g.mu.Unlock()
}

func (g *Gateway) handleExplain(conn net.Conn, query string) {
	if g.Replica == nil {
		downstream.RelayError(conn, "replica unavailable")
		return
	}
	attempt := func() (*datalog.CompileResult, error) {
		return datalog.CompileDatalogQueryResult(query, g.GetSnapshot())
	}
	res, err := attempt()
	if err != nil && strings.Contains(err.Error(), "attribute resolution failed") {
		g.InvalidateSnapshot()
		g.refreshResolver()
		res, err = attempt()
	}
	if err != nil {
		downstream.RelayError(conn, err.Error())
		return
	}
	explainStr := datalog.RenderExplain(res)
	frame := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("columns"), Value: msgpack.Array{}},
		{Key: msgpack.Str("rows"), Value: msgpack.Array{msgpack.Array{msgpack.Str(explainStr)}}},
		{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
	})
	_ = downstream.WriteFrame(conn, frame)
}

func (g *Gateway) handleSchemeLocal(conn net.Conn, m msgpack.Map) {
	if mode := memberStr(m, "mode"); mode != "" && mode != "query" {
		downstream.RelayError(conn, "scheme-local: only mode \"query\" is served locally; exec goes to the transactor")
		return
	}
	progVal, ok := msgpack.Member(m, msgpack.Str("program"))
	if !ok {
		downstream.RelayError(conn, "scheme-local: request is missing program")
		return
	}
	progBytes := msgpack.Marshal(progVal)
	body, err := sexpr.UnmarshalWire(progBytes)
	if err != nil {
		downstream.RelayError(conn, "scheme-local: bad program wire ("+err.Error()+")")
		return
	}
	var params []sexpr.Expr
	if a, ok := msgpack.Member(m, msgpack.Str("params")); ok {
		if arr, ok := a.(msgpack.Array); ok {
			for _, p := range arr {
				if e, err := wireValue(p); err == nil {
					params = append(params, e)
				}
			}
		}
	}
	var columns []string
	if a, ok := msgpack.Member(m, msgpack.Str("columns")); ok {
		if arr, ok := a.(msgpack.Array); ok {
			for _, c := range arr {
				if s, ok := c.(msgpack.Str); ok {
					columns = append(columns, string(s))
				}
			}
		}
	}
	if g.Replica == nil {
		downstream.RelayError(conn, "replica unavailable")
		return
	}
	g.streamProgram(conn, scheme.Program{Body: body}, params, columns)
}

func (g *Gateway) handleSchema(conn net.Conn) {
	if g.Replica == nil {
		downstream.RelayError(conn, "replica unavailable")
		return
	}
	stats := g.GetSnapshot()
	frame := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("schema"), Value: msgpack.Raw(datalog.EncodeCompileStats(stats))},
		{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
	})
	_ = downstream.WriteFrame(conn, frame)
}

// ── execution ────────────────────────────────────────────────────────────

func (g *Gateway) streamProgram(conn net.Conn, prog scheme.Program, params []sexpr.Expr, columns []string) {
	sess := engine.NewQuerySession(g.Replica.Store, prog, params, 1, 0, false)
	stream := engine.NewStreamingSession(sess)
	first := true
	for {
		// Only the VM step touches the replica; serialize it, then release the
		// lock before the (blocking) network write so WAL apply and other
		// queries can interleave between batches.
		g.mu.Lock()
		rows, more, err := stream.NextBatch(batchSize)
		g.mu.Unlock()
		if err != nil {
			downstream.RelayError(conn, err.Error())
			return
		}
		cols := msgpack.Array{}
		if first {
			for _, c := range columns {
				cols = append(cols, msgpack.Str(c))
			}
		}
		arr := make(msgpack.Array, len(rows))
		for i, row := range rows {
			rarr := make(msgpack.Array, len(row))
			for j, cell := range row {
				rarr[j] = sexpr.ToPlainValue(cell)
			}
			arr[i] = rarr
		}
		frame := msgpack.Marshal(msgpack.Map{
			{Key: msgpack.Str("columns"), Value: cols},
			{Key: msgpack.Str("rows"), Value: arr},
			{Key: msgpack.Str("more"), Value: msgpack.Bool(more)},
		})
		if err := downstream.WriteFrame(conn, frame); err != nil {
			return
		}
		first = false
		if !more {
			return
		}
	}
}

// ── forwarding ───────────────────────────────────────────────────────────

func (g *Gateway) forward(conn net.Conn, raw []byte) {
	if g.Conn == nil || !g.Conn.Connected() {
		downstream.RelayError(conn, "transactor disconnected")
		return
	}
	err := g.Conn.Request(raw, func(frame []byte) error {
		return downstream.WriteFrame(conn, frame)
	})
	if err != nil {
		downstream.RelayError(conn, err.Error())
	}
}

func (g *Gateway) forwardTxData(conn net.Conn, query string) {
	ops, err := edn.ReadVector(query)
	if err != nil {
		downstream.RelayError(conn, "EDN parse: "+err.Error())
		return
	}
	wire := make(msgpack.Array, len(ops))
	for i, op := range ops {
		wire[i] = ednToMsgpack(op)
	}
	req := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: wire},
	})
	g.forward(conn, req)
}

func ednToMsgpack(v edn.Value) msgpack.Value {
	switch x := v.(type) {
	case edn.Int:
		return msgpack.Int(int64(x))
	case edn.Float:
		return msgpack.Float(float64(x))
	case edn.Str:
		return msgpack.Str(string(x))
	case edn.Bool:
		return msgpack.Bool(bool(x))
	case edn.Nil:
		return msgpack.Nil{}
	case edn.Keyword:
		return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(x)}
	case edn.Symbol:
		return msgpack.Ext{Type: msgpack.ExtSymbol, Data: []byte(x)}
	case edn.List:
		arr := make(msgpack.Array, len(x))
		for i, e := range x {
			arr[i] = ednToMsgpack(e)
		}
		return arr
	}
	return msgpack.Nil{}
}

func wireValue(v msgpack.Value) (sexpr.Expr, error) {
	return sexpr.UnmarshalWire(msgpack.Marshal(v))
}

// ── small helpers ────────────────────────────────────────────────────────

func memberStr(m msgpack.Map, key string) string {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if s, ok := v.(msgpack.Str); ok {
			return string(s)
		}
	}
	return ""
}

func memberBool(m msgpack.Map, key string) bool {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if b, ok := v.(msgpack.Bool); ok {
			return bool(b)
		}
	}
	return false
}
