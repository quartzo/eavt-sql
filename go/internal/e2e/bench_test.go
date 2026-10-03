package e2e

import (
	"net"
	"os"
	"path/filepath"
	"testing"

	"eavt-go/internal/downstream"
	"eavt-go/internal/eavt"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/querysrv"
	"eavt-go/internal/replica"
	"eavt-go/internal/transactor"
)

// txFrame is the exact shape of the bench's upsert probe:
// client.tx([[Kw("db/add"), eid, Kw("empresa.capital_social"), 1000.0]])
func txFrame(eid int64) []byte {
	kw := func(s string) msgpack.Value {
		return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(s)}
	}
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: msgpack.Array{
			msgpack.Array{kw("db/add"), msgpack.Int(eid),
				kw("empresa/capital_social"), msgpack.Float(1000.0)},
		}},
	})
}

// BenchmarkTxUpsertStack is the full Go path the probe measures: client →
// query server (forward) → transactor → response, over real unix sockets.
func BenchmarkTxUpsertStack(b *testing.B) {
	dir := b.TempDir()
	e, err := transactor.NewEngineConfig(transactor.EngineConfig{
		DBPath: dir, BlobDir: dir,
	})
	if err != nil {
		b.Fatal(err)
	}
	defer e.Close()
	e.KV.FlushThreshold = 1 << 62

	tsock := filepath.Join(dir, "t.sock")
	tln, err := net.Listen("unix", tsock)
	if err != nil {
		b.Fatal(err)
	}
	defer tln.Close()
	go func() {
		for {
			c, err := tln.Accept()
			if err != nil {
				return
			}
			go e.Serve(c)
		}
	}()

	qsock := filepath.Join(dir, "q.sock")
	gw := querysrv.NewGatewayConfig(tsock, replica.Config{Dir: dir})
	qln, err := net.Listen("unix", qsock)
	if err != nil {
		b.Fatal(err)
	}
	defer qln.Close()
	go func() {
		for {
			c, err := qln.Accept()
			if err != nil {
				return
			}
			go gw.ServeClient(c)
		}
	}()
	waitFor(b, "downstream", func() bool { return gw.Connected() })

	// Declare the attribute and seed the target entity (in-process; the
	// benchmark only measures the wire tx path).
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("empresa/capital_social", eavt.DbTypeFloat, false, false); err != nil {
		b.Fatal(err)
	}
	eid := e.Store.Eavt.AllocateEntityId()
	if _, err := e.Store.Eavt.EavtSave(eid, "empresa/capital_social", "1000", 1); err != nil {
		b.Fatal(err)
	}
	_ = eid

	conn, err := net.Dial("unix", qsock)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	frame := txFrame(eid)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := downstream.WriteFrame(conn, frame); err != nil {
			b.Fatal(err)
		}
		if _, err := downstream.ReadFrame(conn); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkTxUpsertRemote drives a RUNNING query server over UDS with the same
// wire protocol the probe uses.  Set EAVT_PROBE_SOCK to point it at a
// (Nim or Go) stack, so the server-side cost can be compared apples to
// apples with an identical client.  Skips when the variable is unset.
func BenchmarkTxUpsertRemote(b *testing.B) {
	sock := os.Getenv("EAVT_PROBE_SOCK")
	if sock == "" {
		b.Skip("EAVT_PROBE_SOCK not set")
	}
	conn, err := net.Dial("unix", sock)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	kw := func(s string) msgpack.Value {
		return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(s)}
	}
	send := func(ops []msgpack.Value) {
		if err := downstream.WriteFrame(conn, msgpack.Marshal(msgpack.Map{
			{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
			{Key: msgpack.Str("txdata"), Value: msgpack.Array(ops)},
		})); err != nil {
			b.Fatal(err)
		}
		if _, err := downstream.ReadFrame(conn); err != nil {
			b.Fatal(err)
		}
	}
	// Schema (literal eids, no tempid) + seed entity.
	send([]msgpack.Value{
		msgpack.Array{kw("db/add"), msgpack.Int(1000), kw("db/ident"), kw("empresa/capital_social")},
		msgpack.Array{kw("db/add"), msgpack.Int(1000), kw("db/valueType"), kw("db.type/float")},
		msgpack.Array{kw("db/add"), msgpack.Int(1000), kw("db/cardinality"), kw("db.cardinality/one")},
	})
	send([]msgpack.Value{
		msgpack.Array{kw("db/add"), msgpack.Int(1001), kw("db/ident"), kw("empresa/cnpj_base")},
		msgpack.Array{kw("db/add"), msgpack.Int(1001), kw("db/valueType"), kw("db.type/string")},
		msgpack.Array{kw("db/add"), msgpack.Int(1001), kw("db/cardinality"), kw("db.cardinality/one")},
		msgpack.Array{kw("db/add"), msgpack.Int(1001), kw("db/unique"), kw("db.unique/identity")},
	})
	// Allocate the seed entity through a tempid so the server hydates it
	// (literal eids are never hydrated and fall back to the KV scan).
	body := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: msgpack.Array{msgpack.Array{
			kw("db/add"), msgpack.Int(-1), kw("empresa/cnpj_base"), msgpack.Str("41273589")}}},
	})
	if err := downstream.WriteFrame(conn, body); err != nil {
		b.Fatal(err)
	}
	resp, err := downstream.ReadFrame(conn)
	if err != nil {
		b.Fatal(err)
	}
	eid := tempidOf(resp, -1)
	frame := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: msgpack.Array{msgpack.Array{
			kw("db/add"), msgpack.Int(eid), kw("empresa/capital_social"), msgpack.Float(1000.0)}}},
	})
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := downstream.WriteFrame(conn, frame); err != nil {
			b.Fatal(err)
		}
		if _, err := downstream.ReadFrame(conn); err != nil {
			b.Fatal(err)
		}
	}
}

// tempidOf extracts tempids[id] from a tx-report frame.
func tempidOf(resp []byte, id int64) int64 {
	v, err := msgpack.Unmarshal(resp)
	if err != nil {
		return 0
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		return 0
	}
	tm, ok := msgpack.Member(m, msgpack.Str("tempids"))
	if !ok {
		return 0
	}
	mm, ok := tm.(msgpack.Map)
	if !ok {
		return 0
	}
	for _, p := range mm {
		if k, ok := p.Key.(msgpack.Int); ok && int64(k) == id {
			if e, ok := p.Value.(msgpack.Int); ok {
				return int64(e)
			}
		}
	}
	return 0
}

// BenchmarkAdminForwardRemote forwards a read-only admin request (no WAL, no
// replication frame) — the control for BenchmarkTxUpsertRemote, so the
// replication-delivery cost can be isolated.
func BenchmarkAdminForwardRemote(b *testing.B) {
	sock := os.Getenv("EAVT_PROBE_SOCK")
	if sock == "" {
		b.Skip("EAVT_PROBE_SOCK not set")
	}
	conn, err := net.Dial("unix", sock)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	frame := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("admin")},
		{Key: msgpack.Str("command"), Value: msgpack.Str("status")},
	})
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := downstream.WriteFrame(conn, frame); err != nil {
			b.Fatal(err)
		}
		if _, err := downstream.ReadFrame(conn); err != nil {
			b.Fatal(err)
		}
	}
}
