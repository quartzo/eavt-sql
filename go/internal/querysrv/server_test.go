package querysrv

import (
	"bytes"
	"net"
	"path/filepath"
	"testing"
	"time"

	"eavt-go/internal/downstream"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/replica"
)

// TestServeKeepsReadingWhileClientIsSilent is the regression for the
// read/write coupling that deadlocked pipelining clients: the gateway must
// keep accepting requests while the client is not reading responses.
//
// Before the per-connection writer, the request loop and the response write
// shared one goroutine, so once the socket buffers filled the loop stopped
// reading and both sides hung — measured with
// `tests/bench_client_split.py --depth 16` (client in send, gateway in
// WriteFrame).  Here the client sends requests until the responses far
// exceed the kernel socket buffers (~200 KB) and only then reads them back.
func TestServeKeepsReadingWhileClientIsSilent(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "q.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	replicaDir := filepath.Join(dir, "replica")
	// Lay the store down first: the replica attaches read-only (in production
	// the transactor created the directory and the query server attaches).
	kvc, err := kvstore.New(kvstore.Config{Path: replicaDir, NumCf: 64})
	if err != nil {
		t.Fatalf("create replica store: %v", err)
	}
	if err := kvc.Close(); err != nil {
		t.Fatalf("close replica store: %v", err)
	}
	// Order matters: conn.Close (below) before ln.Close before gw.Close, so
	// no serve goroutine touches a closed replica.
	gw := NewGatewayConfig(filepath.Join(dir, "no-such-downstream.sock"),
		replica.Config{Dir: replicaDir})
	if gw.Replica == nil {
		if _, err := kvstore.New(kvstore.Config{
			Path: replicaDir, ReadOnly: true, ReplayOff: true, NumCf: 64,
		}); err != nil {
			t.Fatalf("replica read-only open: %v", err)
		}
		t.Fatal("replica is nil although a read-only open succeeds")
	}
	defer gw.Close()
	defer ln.Close()

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go gw.ServeClient(c)
		}
	}()

	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	req := msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("schema")},
	})

	// Calibrate: one round trip to learn the response size, so the silent
	// phase is guaranteed to overflow the kernel socket buffers.
	if err := downstream.WriteFrame(conn, req); err != nil {
		t.Fatal(err)
	}
	resp, err := downstream.ReadFrame(conn)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(resp, []byte("schema")) {
		t.Fatalf("first response is not a schema frame: %d bytes", len(resp))
	}
	n := 400*1024/len(resp) + 200
	if n < 300 {
		n = 300
	}
	t.Logf("schema frame = %d B → %d silent requests = %d KiB of responses (> kernel buffers)",
		len(resp), n, n*len(resp)/1024)

	// Send everything without reading a single response.
	sent := make(chan error, 1)
	go func() {
		for i := 0; i < n; i++ {
			if err := downstream.WriteFrame(conn, req); err != nil {
				sent <- err
				return
			}
		}
		sent <- nil
	}()
	select {
	case err := <-sent:
		if err != nil {
			t.Fatalf("sending %d requests: %v", n, err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("request loop stopped reading while the client was silent — " +
			"read path is still coupled to response writes")
	}

	// Now drain: every request was accepted, so every answer must come back.
	for i := 0; i < n; i++ {
		if _, err := downstream.ReadFrame(conn); err != nil {
			t.Fatalf("response %d/%d: %v", i, n, err)
		}
	}
}
