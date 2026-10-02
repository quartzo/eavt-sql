// Package transactor is the data server: it owns the read-write engine, the
// segmented WAL and the replication hub, and serves tx/scheme/schema/admin/kv
// requests.  Port of eavt_transactor_nim/{connection,server,shared_engine}.nim.
package transactor

import (
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"eavt-go/internal/datalog"
	"eavt-go/internal/downstream"
	"eavt-go/internal/engine"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/query"
	"eavt-go/internal/replication"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
	"eavt-go/internal/wal"
)

// Engine is the transactor's shared state.
type Engine struct {
	KV    *kvstore.KVStore
	Store *engine.QueryStore
	Wal   *wal.Writer
	Hub   *replication.Hub
	Path  string

	mu sync.Mutex // serializes every engine/WAL access
}

// NewEngine opens the data dir, bootstraps the schema and attaches the WAL.
func NewEngine(dbPath, blobDir string) (*Engine, error) {
	kv, err := kvstore.New(kvstore.Config{Path: dbPath, NumCf: 64, PageCacheSize: 536870912})
	if err != nil {
		return nil, err
	}
	e := &Engine{KV: kv, Store: engine.New(kv), Path: dbPath, Hub: replication.NewHub(blobDir)}
	e.Store.Eavt.BootstrapSystemAttrs()
	e.Store.Eavt.BootstrapResolver()
	e.Store.Eavt.RecoverWriteState()

	durable := &atomic.Int64{}
	durable.Store(-1)
	w, err := wal.Attach(dbPath, durable)
	if err != nil {
		return nil, err
	}
	e.Wal = w
	kv.JournalSink = w.Sink
	kv.JournalSeal = w.Seal
	kv.WalDurableUpTo = durable
	w.OnWal = e.Hub.BroadcastWal
	w.OnSeal = e.Hub.BroadcastSeal
	kv.OnFlushPublish = func(root string, maxT int64) {
		e.Hub.BroadcastRoot(root, maxT)
		// Post-flush auto-GC: cheap root-only check, then a full pass.
		if e.KV.PS.HasOldRoots(e.KV.GcMaxAgeSecs, e.KV.GcMaxRootCount) {
			_, _ = e.KV.PS.GcFull(e.KV.GcMaxAgeSecs, e.KV.GcMaxRootCount, false)
		}
	}
	return e, nil
}

// Close stops the WAL and closes the store.
func (e *Engine) Close() {
	if e.Wal != nil {
		e.Wal.Stop()
	}
	if e.KV != nil {
		e.KV.Close()
	}
}

// Serve handles one connection until it closes.
func (e *Engine) Serve(conn net.Conn) {
	defer conn.Close()
	isReplication := false
	for {
		raw, err := downstream.ReadFrame(conn)
		if err != nil {
			return
		}
		v, err := msgpack.Unmarshal(raw)
		if err != nil {
			continue
		}
		m, ok := v.(msgpack.Map)
		if !ok {
			continue
		}
		if !isReplication && memberStr(m, "type") == "replicate" {
			isReplication = true
			sub := e.Hub.Register(conn)
			sealed := wal.Segments(e.Path)
			var tail []byte
			if e.Wal != nil {
				tail = e.Wal.OpenTail()
			}
			e.Hub.SendSnapshot(sub, sealed, tail, e.KV.PS.CurrentRoot())
			continue
		}
		e.processFrame(conn, m, v, memberStr(m, "id"))
	}
}

func (e *Engine) writeFrameQueued(conn net.Conn, body []byte) {
	if sub := e.Hub.Find(conn); sub != nil && !sub.Closed() {
		sub.EnqueueResponse(body)
		return
	}
	_ = downstream.WriteFrame(conn, body)
}

func (e *Engine) writeResponse(conn net.Conn, id string, columns []string, rows [][]sexpr.Expr, more bool, errMsg string) {
	var fields []msgpack.Pair
	if id != "" {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("id"), Value: msgpack.Str(id)})
	}
	if errMsg != "" {
		fields = append(fields,
			msgpack.Pair{Key: msgpack.Str("error"), Value: msgpack.Str(errMsg)},
			msgpack.Pair{Key: msgpack.Str("more"), Value: msgpack.Bool(false)})
	} else {
		cols := make(msgpack.Array, len(columns))
		for i, c := range columns {
			cols[i] = msgpack.Str(c)
		}
		arr := make(msgpack.Array, len(rows))
		for i, row := range rows {
			r := make(msgpack.Array, len(row))
			for j, cell := range row {
				r[j] = sexpr.ToPlainValue(cell)
			}
			arr[i] = r
		}
		fields = append(fields,
			msgpack.Pair{Key: msgpack.Str("columns"), Value: cols},
			msgpack.Pair{Key: msgpack.Str("rows"), Value: arr},
			msgpack.Pair{Key: msgpack.Str("more"), Value: msgpack.Bool(more)})
	}
	e.writeFrameQueued(conn, msgpack.Marshal(msgpack.Map(fields)))
}

func (e *Engine) processFrame(conn net.Conn, m msgpack.Map, v msgpack.Value, id string) {
	typ := memberStr(m, "type")
	switch typ {
	case "tx":
		e.execTx(conn, v, id)
	case "scheme":
		e.execScheme(conn, m, id)
	case "schema":
		e.handleSchema(conn, id)
	case "admin":
		e.handleAdmin(conn, memberStr(m, "command"), id)
	case "kv":
		e.handleKv(conn, m, id)
	default:
		e.writeResponse(conn, id, nil, nil, false, "unknown request type: "+typ)
	}
}

func (e *Engine) execTx(conn net.Conn, v msgpack.Value, id string) {
	e.mu.Lock()
	txops, err := scheme.TxOpsFromValue(v, e.Store.Symtab())
	if err != nil {
		e.mu.Unlock()
		e.writeResponse(conn, id, nil, nil, false, err.Error())
		return
	}
	report, err := query.TransactTx(e.Store, txops)
	e.mu.Unlock()
	if err != nil {
		e.writeResponse(conn, id, nil, nil, false, err.Error())
		return
	}
	tempids := make(msgpack.Map, 0, len(report.Tempids))
	for tid, eid := range report.Tempids {
		tempids = append(tempids, msgpack.Pair{Key: msgpack.Int(tid), Value: msgpack.Int(eid)})
	}
	var fields []msgpack.Pair
	if id != "" {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("id"), Value: msgpack.Str(id)})
	}
	fields = append(fields,
		msgpack.Pair{Key: msgpack.Str("tempids"), Value: tempids},
		msgpack.Pair{Key: msgpack.Str("tx"), Value: msgpack.Int(report.Tx)},
		msgpack.Pair{Key: msgpack.Str("more"), Value: msgpack.Bool(false)})
	e.writeFrameQueued(conn, msgpack.Marshal(msgpack.Map(fields)))
}

func (e *Engine) execScheme(conn net.Conn, m msgpack.Map, id string) {
	mode := memberStr(m, "mode")
	if mode != "query" && mode != "exec" {
		e.writeResponse(conn, id, nil, nil, false, "unknown scheme mode: "+mode)
		return
	}
	progVal, ok := msgpack.Member(m, msgpack.Str("program"))
	if !ok {
		e.writeResponse(conn, id, nil, nil, false, "scheme request is missing program")
		return
	}
	body, err := sexpr.UnmarshalWire(msgpack.Marshal(progVal))
	if err != nil {
		e.writeResponse(conn, id, nil, nil, false, "bad program wire ("+err.Error()+")")
		return
	}
	var params []sexpr.Expr
	if a, ok := msgpack.Member(m, msgpack.Str("params")); ok {
		if arr, ok := a.(msgpack.Array); ok {
			for _, p := range arr {
				if ex, err := sexpr.UnmarshalWire(msgpack.Marshal(p)); err == nil {
					params = append(params, ex)
				}
			}
		}
	}
	prog := scheme.Program{Body: body}
	if mode == "query" {
		e.mu.Lock()
		sess := engine.NewQuerySession(e.Store, prog, params, 1, 0, false)
		stream := engine.NewStreamingSession(sess)
		for {
			rows, more, err := stream.NextBatch(100)
			e.mu.Unlock()
			if err != nil {
				e.writeResponse(conn, id, nil, nil, false, err.Error())
				return
			}
			e.writeResponse(conn, id, nil, rows, more, "")
			if !more {
				return
			}
			e.mu.Lock()
		}
	}
	// exec
	e.mu.Lock()
	tx := e.Store.AllocateTx()
	sess := engine.NewQuerySession(e.Store, prog, params, tx, 0, false)
	r, err := sess.ExecuteProgram()
	e.mu.Unlock()
	if err != nil {
		e.writeResponse(conn, id, nil, nil, false, err.Error())
		return
	}
	if l, ok := r.(sexpr.List); ok && len(l) >= 2 && l[0] == sexpr.Symbol("result") {
		e.writeResponse(conn, id, nil, [][]sexpr.Expr{l[1:]}, false, "")
		return
	}
	e.writeResponse(conn, id, nil, nil, false, "unexpected result: "+scheme.String(r))
}

func (e *Engine) handleSchema(conn net.Conn, id string) {
	e.mu.Lock()
	stats := e.Store.Eavt.BuildCompileStats()
	e.mu.Unlock()
	data := datalog.EncodeCompileStats(stats)
	var fields []msgpack.Pair
	if id != "" {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("id"), Value: msgpack.Str(id)})
	}
	fields = append(fields,
		msgpack.Pair{Key: msgpack.Str("schema"), Value: msgpack.Raw(data)},
		msgpack.Pair{Key: msgpack.Str("more"), Value: msgpack.Bool(false)})
	e.writeFrameQueued(conn, msgpack.Marshal(msgpack.Map(fields)))
}

func (e *Engine) handleAdmin(conn net.Conn, command, id string) {
	if strings.HasPrefix(command, "dump") {
		parts := strings.Fields(command)
		index := "EAVT"
		if len(parts) >= 2 {
			index = strings.ToUpper(parts[1])
		}
		cf := 0
		switch index {
		case "AEVT":
			cf = 1
		case "AVET":
			cf = 2
		case "VAET":
			cf = 3
		}
		e.mu.Lock()
		datoms := e.Store.Eavt.ScanDatoms(cf)
		e.mu.Unlock()
		var rows [][]sexpr.Expr
		for _, d := range datoms {
			if d.Retracted {
				continue
			}
			rows = append(rows, []sexpr.Expr{
				sexpr.Int(d.E),
				sexpr.Str(d.AttrName + "(" + strconv.FormatUint(uint64(d.A), 10) + ")"),
				d.Value,
				sexpr.Int(d.T),
			})
			if len(rows) >= 100 {
				e.writeResponse(conn, id, []string{"e", "attr", "value", "t"}, rows, true, "")
				rows = nil
			}
		}
		e.writeResponse(conn, id, []string{"e", "attr", "value", "t"}, rows, false, "")
		return
	}
	var output string
	switch command {
	case "flush":
		if e.KV.ReadOnly {
			output = "error: read-only"
		} else {
			go func() {
				e.mu.Lock()
				defer e.mu.Unlock()
				_ = e.KV.Flush()
			}()
			output = "ok: flush requested"
		}
	case "flush-sync":
		if e.KV.ReadOnly {
			output = "error: read-only"
		} else {
			e.mu.Lock()
			_ = e.KV.Flush()
			e.mu.Unlock()
			output = "ok: flushed"
		}
	case "gc", "gc-dry":
		if e.KV.ReadOnly {
			output = "error: read-only"
		} else {
			e.mu.Lock()
			rep, err := e.KV.PS.GcFull(e.KV.GcMaxAgeSecs, e.KV.GcMaxRootCount, command == "gc-dry")
			e.mu.Unlock()
			if err != nil {
				output = "error: " + err.Error()
			} else {
				output = gcReportText(rep)
			}
		}
	case "status":
		output = "memtable: " + strconv.FormatUint(e.KV.MemtableSize(), 10) + " bytes"
	case "memtable":
		output = strconv.FormatUint(e.KV.MemtableSize(), 10)
	default:
		output = "unknown admin command: " + command
	}
	var fields []msgpack.Pair
	if id != "" {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("id"), Value: msgpack.Str(id)})
	}
	fields = append(fields,
		msgpack.Pair{Key: msgpack.Str("output"), Value: msgpack.Str(output)},
		msgpack.Pair{Key: msgpack.Str("more"), Value: msgpack.Bool(false)})
	e.writeFrameQueued(conn, msgpack.Marshal(msgpack.Map(fields)))
}

func (e *Engine) handleKv(conn net.Conn, m msgpack.Map, id string) {
	op := memberStr(m, "op")
	cf := 0
	if c, ok := msgpack.Member(m, msgpack.Str("cf")); ok {
		if n, ok := c.(msgpack.Int); ok {
			cf = int(int64(n))
		}
	}
	key := bytesField(m, "key")
	value := bytesField(m, "value")
	switch op {
	case "put":
		e.mu.Lock()
		e.KV.PutKv(cf, key, value)
		e.mu.Unlock()
		e.writeResponse(conn, id, nil, nil, false, "")
	case "get":
		e.mu.Lock()
		val, ok, _ := e.KV.GetKv(cf, key)
		e.mu.Unlock()
		if ok {
			e.writeResponse(conn, id, nil, [][]sexpr.Expr{{sexpr.Bytes(val)}}, false, "")
		} else {
			e.writeResponse(conn, id, nil, nil, false, "")
		}
	case "scan":
		e.mu.Lock()
		mc := e.KV.OpenScanCursorKv(cf)
		var rows [][]sexpr.Expr
		for {
			p, ok := mc.NextKv()
			if !ok {
				break
			}
			rows = append(rows, []sexpr.Expr{sexpr.Bytes(p[0]), sexpr.Bytes(p[1])})
			if len(rows) >= 100 {
				e.mu.Unlock()
				e.writeResponse(conn, id, []string{"key", "value"}, rows, true, "")
				rows = nil
				e.mu.Lock()
			}
		}
		e.mu.Unlock()
		e.writeResponse(conn, id, []string{"key", "value"}, rows, false, "")
	case "delete":
		e.mu.Lock()
		e.KV.DeleteKv(cf, key)
		e.mu.Unlock()
		e.writeResponse(conn, id, nil, nil, false, "")
	default:
		e.writeResponse(conn, id, nil, nil, false, "unknown kv op: "+op)
	}
}

func gcReportText(rep []byte) string {
	if len(rep) < 41 {
		return "gc: no report"
	}
	u64 := func(off int) uint64 { return binary.LittleEndian.Uint64(rep[off:]) }
	return "roots_scanned=" + strconv.FormatUint(u64(0), 10) +
		" roots_removed=" + strconv.FormatUint(u64(8), 10) +
		" blobs_scanned=" + strconv.FormatUint(u64(16), 10) +
		" blobs_removed=" + strconv.FormatUint(u64(24), 10) +
		" live_blobs=" + strconv.FormatUint(u64(32), 10) +
		" dry_run=" + strconv.Itoa(int(rep[40]))
}

func bytesField(m msgpack.Map, key string) []byte {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		switch x := v.(type) {
		case msgpack.Str:
			return []byte(x)
		case msgpack.Bin:
			return append([]byte(nil), x...)
		}
	}
	return nil
}

func memberStr(m msgpack.Map, key string) string {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if s, ok := v.(msgpack.Str); ok {
			return string(s)
		}
	}
	return ""
}

// DefaultDataDir resolves the default data directory.
func DefaultDataDir() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "eavt", "db")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt", "db")
}
