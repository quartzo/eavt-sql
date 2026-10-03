// Package e2e holds cross-component end-to-end tests: a real transactor
// served over a unix socket, a query-side replica consuming its replication
// stream, etc.
package e2e

import (
	"fmt"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"eavt-go/internal/client"
	"eavt-go/internal/edn"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/querysrv"
	"eavt-go/internal/replica"
	"eavt-go/internal/sexpr"
	"eavt-go/internal/transactor"
)

func startTransactor(t testing.TB, dir string) (*transactor.Engine, string) {
	t.Helper()
	e, err := transactor.NewEngineConfig(transactor.EngineConfig{DBPath: dir, BlobDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(e.Close)
	sock := filepath.Join(dir, "trans.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go e.Serve(c)
		}
	}()
	return e, sock
}

func kw(s string) msgpack.Value { return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(s)} }

func addOp(eid int64, attr string, v msgpack.Value) msgpack.Value {
	return msgpack.Array{kw("db/add"), msgpack.Int(eid), kw(attr), v}
}

func txRequest(ops ...msgpack.Value) []byte {
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: msgpack.Array(ops)},
	})
}

func schemaAndAlice(t testing.TB, gw *querysrv.Gateway) {
	t.Helper()
	schema := txRequest(
		addOp(0, "db/ident", kw("person/name")),
		addOp(0, "db/valueType", kw("db.type/string")),
		addOp(0, "db/cardinality", kw("db.cardinality/one")),
	)
	if _, err := gw.Forward(schema); err != nil {
		t.Fatal(err)
	}
	data := txRequest(addOp(-1, "person/name", msgpack.Str("Alice")))
	if _, err := gw.Forward(data); err != nil {
		t.Fatal(err)
	}
}

func replicaHasAlice(r *replica.ReplicaEngine) bool {
	for _, d := range r.Store.Eavt.ScanDatoms(0) {
		if d.AttrName == "person/name" && d.Value == sexpr.Str("Alice") && !d.Retracted {
			return true
		}
	}
	return false
}

func waitFor(t testing.TB, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s", what)
}

// TestReplicationE2E exercises the full transactor -> replica stream: a
// volatile write reaches the replica via the WAL flushed by the forwarded
// response, and survives a flush/root adoption.
func TestReplicationE2E(t *testing.T) {
	dir := t.TempDir()
	e, sock := startTransactor(t, dir)
	gw := querysrv.NewGatewayConfig(sock, replica.Config{Dir: dir})
	t.Cleanup(gw.Close)
	if gw.Replica == nil {
		t.Fatal("replica not opened")
	}

	// Wait for the downstream to connect before forwarding.
	waitFor(t, "downstream", func() bool { return gw.Connected() })

	schemaAndAlice(t, gw)
	waitFor(t, "Alice via WAL", func() bool { return replicaHasAlice(gw.Replica) })

	if err := e.KV.Flush(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "Alice after flush", func() bool { return replicaHasAlice(gw.Replica) })
}

// TestTransactorConcurrentClients runs many client connections writing txs
// concurrently (the transactor serializes writes with its engine lock) and
// checks every datom landed.  Run under -race.
func TestTransactorConcurrentClients(t *testing.T) {
	dir := t.TempDir()
	e, sock := startTransactor(t, dir)

	// Declare the schema once.
	setup, err := client.Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	if err := setup.TxData([]edn.Value{
		edn.List{edn.Keyword("db/add"), edn.Int(0), edn.Keyword("db/ident"), edn.Keyword("person/name")},
		edn.List{edn.Keyword("db/add"), edn.Int(0), edn.Keyword("db/valueType"), edn.Keyword("db.type/string")},
		edn.List{edn.Keyword("db/add"), edn.Int(0), edn.Keyword("db/cardinality"), edn.Keyword("db.cardinality/one")},
	}); err != nil {
		t.Fatal(err)
	}
	setup.Close()

	const clients, per = 8, 25
	var wg sync.WaitGroup
	errCh := make(chan error, clients)
	for c := 0; c < clients; c++ {
		wg.Add(1)
		go func(c int) {
			defer wg.Done()
			cl, err := client.Dial(sock)
			if err != nil {
				errCh <- err
				return
			}
			defer cl.Close()
			for i := 0; i < per; i++ {
				eid := int64(1000 + c*per + i)
				ops := []edn.Value{edn.List{
					edn.Keyword("db/add"), edn.Int(eid),
					edn.Keyword("person/name"), edn.Str(fmt.Sprintf("n-%d-%d", c, i)),
				}}
				if err := cl.TxData(ops); err != nil {
					errCh <- err
					return
				}
			}
		}(c)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatal(err)
		}
	}
	n := 0
	for _, d := range e.Store.Eavt.ScanDatoms(0) {
		if d.AttrName == "person/name" && !d.Retracted {
			n++
		}
	}
	if n != clients*per {
		t.Fatalf("datoms = %d, want %d", n, clients*per)
	}
}
