package transactor

import (
	"io"
	"net"
	"path/filepath"
	"testing"
	"time"

	"eavt-go/internal/downstream"
	"eavt-go/internal/eavt"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/scheme"
)

// discardConn is a net.Conn that swallows writes (no syscall) so the benchmark
// measures the server's compute, not socket traffic.
type discardConn struct{}

func (discardConn) Read(p []byte) (int, error)         { return 0, io.EOF }
func (discardConn) Write(p []byte) (int, error)        { return len(p), nil }
func (discardConn) Close() error                       { return nil }
func (discardConn) LocalAddr() net.Addr                { return dummyAddr{} }
func (discardConn) RemoteAddr() net.Addr               { return dummyAddr{} }
func (discardConn) SetDeadline(t time.Time) error      { return nil }
func (discardConn) SetReadDeadline(t time.Time) error  { return nil }
func (discardConn) SetWriteDeadline(t time.Time) error { return nil }

type dummyAddr struct{}

func (dummyAddr) Network() string { return "bench" }
func (dummyAddr) String() string  { return "bench" }

// txFrame builds the exact request shape of the bench's upsert probe:
// client.tx([[Kw("db/add"), eid, Kw("empresa.capital_social"), 1000.0]]).
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

func newBenchEngine(tb testing.TB) (*Engine, int64) {
	tb.Helper()
	dir := tb.TempDir()
	e, err := NewEngineConfig(EngineConfig{
		DBPath: filepath.Join(dir, "db"), BlobDir: filepath.Join(dir, "blobs"),
	})
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(e.Close)
	// No auto-flush churn while benchmarking.
	e.KV.FlushThreshold = 1 << 62
	if _, _, err := e.Store.Eavt.EavtDeclareAttr("empresa/capital_social",
		eavt.DbTypeFloat, false, false); err != nil {
		tb.Fatal(err)
	}
	eid := e.Store.Eavt.AllocateEntityId()
	if _, err := e.Store.Eavt.EavtSave(eid, "empresa/capital_social", "1000", 1); err != nil {
		tb.Fatal(err)
	}
	return e, eid
}

// BenchmarkTxUpsert is the server-side cost of one upsert tx (decode +
// TransactTx + response encode), the shape the bench's upsert probe measures
// end-to-end through the Python client.
func BenchmarkTxUpsert(b *testing.B) {
	e, eid := newBenchEngine(b)
	frame := txFrame(eid)
	conn := discardConn{}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		v, err := msgpack.Unmarshal(frame)
		if err != nil {
			b.Fatal(err)
		}
		e.execTx(conn, v, "")
	}
}

// BenchmarkTxOpsDecode isolates the msgpack → TxWOp decode.
func BenchmarkTxOpsDecode(b *testing.B) {
	e, eid := newBenchEngine(b)
	frame := txFrame(eid)
	tab := e.Store.Symtab()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		v, err := msgpack.Unmarshal(frame)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := scheme.TxOpsFromValue(v, tab); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkTxUpsertUDS is the full server path (Serve → Unmarshal → execTx →
// writeFrame) over a real unix socket, i.e. the same work the bench's upsert
// probe pays on the server side (the Python client adds its own overhead on
// top for both stacks).
func BenchmarkTxUpsertUDS(b *testing.B) {
	e, eid := newBenchEngine(b)
	sock := filepath.Join(b.TempDir(), "b.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		b.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go e.Serve(c)
		}
	}()
	conn, err := net.Dial("unix", sock)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	frame := txFrame(eid)
	if err := downstream.WriteFrame(conn, frame); err != nil {
		b.Fatal(err)
	}
	if _, err := downstream.ReadFrame(conn); err != nil {
		b.Fatal(err)
	}
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
