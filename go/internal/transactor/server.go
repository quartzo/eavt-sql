// Package transactor is the data server: it owns the read-write engine, the
// segmented WAL and the replication hub, and serves tx/scheme/schema/admin/kv
// requests.  Port of eavt_transactor_nim/{connection,server,shared_engine}.nim.
package transactor

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"eavt-go/internal/datalog"
	"eavt-go/internal/downstream"
	"eavt-go/internal/engine"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/logutil"
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

	// mu serializes transaction application (tx / scheme exec), the short
	// capture and publish windows of a flush, and GC — mirroring the Nim
	// single-loop for writes.  Reads (scheme query, kv get/scan, dump,
	// schema) and the flush's blob I/O run without it: cursors pin a snapshot
	// and the memtable keeps the active ladder while the frozen (draining)
	// one is drained, released only at publish.
	mu sync.Mutex

	// Flush driver (the Nim AsyncFlusher's single-flight + coalescing): a
	// background worker drains one capture at a time; requests arriving during
	// a drain collapse into one follow-up pass.
	flushMu    sync.Mutex
	flushCond  *sync.Cond
	flushing   bool
	flushAgain bool

	// stopCh stops the periodic memledger (nil when disabled); stopOnce
	// makes Close idempotent without racing the reader.
	stopCh   chan struct{}
	stopOnce sync.Once
}

// NewEngine opens the data dir, bootstraps the schema and attaches the WAL.
func NewEngine(dbPath, blobDir string) (*Engine, error) {
	kvCfg := kvstore.Config{Path: dbPath, NumCf: 64, PageCacheSize: 536870912}
	if v := os.Getenv("EAVT_FLUSH_THRESHOLD"); v != "" {
		if n, err := strconv.ParseUint(v, 10, 64); err == nil {
			kvCfg.FlushThreshold = n
		}
	}
	kv, err := kvstore.New(kvCfg)
	if err != nil {
		return nil, err
	}
	e := &Engine{KV: kv, Path: dbPath, Hub: replication.NewHub(blobDir)}
	e.flushCond = sync.NewCond(&e.flushMu)

	// Attach the WAL and install the sink BEFORE bootstrap so the system-attr
	// datoms go through the WAL (durable + replicated), not the legacy journal.
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

	e.Store = engine.New(kv)
	e.Store.Eavt.BootstrapSystemAttrs()
	e.Store.Eavt.BootstrapResolver()
	e.Store.Eavt.RecoverWriteState()

	// Auto-flush on threshold crossing (armed by batchWrite/putKv), driven by
	// the single-flight background flusher.
	kv.OnFlushRequest = e.requestFlush

	// Permanent memory instrument (M9): RSS + per-component bytes every 10s.
	if os.Getenv("EAVT_MEM_LEDGER") != "0" {
		e.stopCh = make(chan struct{})
		go e.memLedgerLoop()
	}
	return e, nil
}

// memLedgerLoop logs the memory ledger until Close.
func (e *Engine) memLedgerLoop() {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-e.stopCh:
			return
		case <-t.C:
			logutil.Info("memledger", e.memLedgerLine())
		}
	}
}

// rssKB reads the resident set size from /proc/self/statm (Linux).
func rssKB() int64 {
	data, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0
	}
	pages, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return pages * int64(os.Getpagesize()) / 1024
}

// memLedgerLine is the one-line memory snapshot (memledger + admin stats).
func (e *Engine) memLedgerLine() string {
	mib := func(b int) int64 { return int64(b) / 1048576 }
	hs := e.Store.Eavt.Hyd.Stats()
	as := e.Store.Eavt.Anchors.Stats()
	active, draining := e.KV.MT.RunCounts()
	return fmt.Sprintf(
		"rss=%dMB hyd=%dMB/%deids anchor=%dMB/%dentries mt=%dMB runs=%d+%d gen=%d flushActive=%v",
		rssKB()/1024, mib(hs.Bytes), hs.Len, mib(as.Bytes), as.Len,
		int64(e.KV.MemtableSize())/1048576, active, draining, e.KV.MT.Gen(), e.KV.FlushActive())
}

// treeText reports per-column-family page-store trees (the REPL `.tree`).
func (e *Engine) treeText() string {
	trees := e.KV.PS.Trees()
	var zero [16]byte
	var sb strings.Builder
	for cf, t := range trees {
		if t.NumLeaves == 0 && t.Height == 0 && t.RootUUID == zero {
			continue
		}
		fmt.Fprintf(&sb, "cf=%d height=%d leaves=%d root=%x\n", cf, t.Height, t.NumLeaves, t.RootUUID)
	}
	if sb.Len() == 0 {
		return "no committed trees"
	}
	return strings.TrimRight(sb.String(), "\n")
}

// statsText returns the observability snapshot for the admin `stats` command.
func (e *Engine) statsText() string {
	saves, lookups, execs := e.Store.Counters()
	scans, scanKeys := e.Store.Eavt.ScanStats()
	batches, written := e.KV.WriteStats()
	hs := e.Store.Eavt.Hyd.Stats()
	as := e.Store.Eavt.Anchors.Stats()
	return fmt.Sprintf("%s\ncounters: saves=%d lookups=%d execs=%d scans=%d scanKeys=%d batchWrites=%d writtenKeys=%d\nhyd: bytes=%d eids=%d hits=%d misses=%d hydrations=%d rejected=%d evictions=%d\nanchor: bytes=%d entries=%d hits=%d misses=%d rehashes=%d rejected=%d evictions=%d",
		e.memLedgerLine(), saves, lookups, execs, scans, scanKeys, batches, written,
		hs.Bytes, hs.Len, hs.Hits, hs.Misses, hs.Hydrations, hs.Rejected, hs.Evictions,
		as.Bytes, as.Len, as.Hits, as.Misses, as.Rehashes, as.Rejected, as.Evictions)
}

// requestFlush arms the single-flight background flusher.  Requests arriving
// while a drain is in progress are coalesced into one follow-up pass.
func (e *Engine) requestFlush() {
	e.flushMu.Lock()
	if e.flushing {
		e.flushAgain = true
		e.flushMu.Unlock()
		return
	}
	e.flushing = true
	e.flushMu.Unlock()
	go e.flushLoop()
}

func (e *Engine) flushLoop() {
	for {
		e.runFlush()
		e.flushMu.Lock()
		if !e.flushAgain {
			e.flushing = false
			e.flushCond.Broadcast()
			e.flushMu.Unlock()
			return
		}
		e.flushAgain = false
		e.flushMu.Unlock()
	}
}

// flushSync waits for every pending/queued flush to complete.
func (e *Engine) flushSync() {
	e.requestFlush()
	e.flushMu.Lock()
	for e.flushing {
		e.flushCond.Wait()
	}
	e.flushMu.Unlock()
}

// runFlush does capture (under the lock) + prepare (off-lock, heavy blob I/O
// + blob pool) + publish (under the lock), so a flush does not block the
// engine for its whole duration.  On a prepare failure the frozen capture is
// discarded and the WAL residue is re-applied at the next bootstrap.
func (e *Engine) runFlush() {
	e.mu.Lock()
	b, ok := e.KV.CaptureFlush()
	e.mu.Unlock()
	if !ok {
		return
	}
	trees, root, err := e.KV.PrepareFlush(b)
	if err != nil {
		logutil.Error("transactor", fmt.Sprintf("flush prepare failed: %v; capture discarded", err))
		e.mu.Lock()
		e.KV.AbortFlush()
		e.mu.Unlock()
		return
	}
	e.mu.Lock()
	e.KV.PublishFlush(b, trees, root)
	e.mu.Unlock()
}

// Close stops the WAL, the memledger and closes the store.
func (e *Engine) Close() {
	if e.stopCh != nil {
		e.stopOnce.Do(func() { close(e.stopCh) })
	}
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
		// Queries run against the snapshot pinned by their cursors; no engine
		// lock is needed (WAL apply and flush prepare run concurrently).
		sess := engine.NewQuerySession(e.Store, prog, params, 1, 0, false)
		stream := engine.NewStreamingSession(sess)
		for {
			rows, more, err := stream.NextBatch(100)
			if err != nil {
				e.writeResponse(conn, id, nil, nil, false, err.Error())
				return
			}
			e.writeResponse(conn, id, nil, rows, more, "")
			if !more {
				return
			}
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
	stats := e.Store.Eavt.BuildCompileStats()
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
		datoms := e.Store.Eavt.ScanDatoms(cf)
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
			e.requestFlush()
			output = "ok: flush requested"
		}
	case "flush-sync":
		if e.KV.ReadOnly {
			output = "error: read-only"
		} else {
			e.flushSync()
			output = "ok: flushed"
		}
	case "gc", "gc-dry":
		if e.KV.ReadOnly {
			output = "error: read-only"
		} else {
			e.mu.Lock()
			if e.KV.FlushActive() {
				e.mu.Unlock()
				output = "error: flush in progress"
				break
			}
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
	case "tree":
		output = e.treeText()
	case "stats":
		output = e.statsText()
	case "stats-reset":
		e.Store.ResetCounters()
		e.Store.Eavt.ResetScanCounters()
		e.KV.ResetWriteCounters()
		output = "ok: counters reset"
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
		e.KV.PutKv(cf, key, value)
		e.writeResponse(conn, id, nil, nil, false, "")
	case "get":
		val, ok, _ := e.KV.GetKv(cf, key)
		if ok {
			e.writeResponse(conn, id, nil, [][]sexpr.Expr{{sexpr.Bytes(val)}}, false, "")
		} else {
			e.writeResponse(conn, id, nil, nil, false, "")
		}
	case "scan":
		mc := e.KV.OpenScanCursorKv(cf)
		var rows [][]sexpr.Expr
		for {
			p, ok := mc.NextKv()
			if !ok {
				break
			}
			rows = append(rows, []sexpr.Expr{sexpr.Bytes(p[0]), sexpr.Bytes(p[1])})
			if len(rows) >= 100 {
				e.writeResponse(conn, id, []string{"key", "value"}, rows, true, "")
				rows = nil
			}
		}
		e.writeResponse(conn, id, []string{"key", "value"}, rows, false, "")
	case "delete":
		e.KV.DeleteKv(cf, key)
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
