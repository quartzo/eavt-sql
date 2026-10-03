package replication

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	"eavt-go/internal/msgpack"
)

func readFrame(t *testing.T, conn net.Conn) []byte {
	t.Helper()
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		t.Fatal(err)
	}
	n := binary.BigEndian.Uint32(hdr)
	body := make([]byte, n)
	if _, err := io.ReadFull(conn, body); err != nil {
		t.Fatal(err)
	}
	return body
}

func TestFrameBuilders(t *testing.T) {
	v, _ := msgpack.Unmarshal(WalFrame([]byte{1, 2}))
	m := v.(msgpack.Map)
	if ev, _ := msgpack.Member(m, msgpack.Str("ev")); ev != msgpack.Str("wal") {
		t.Fatalf("wal frame = %#v", m)
	}
	v, _ = msgpack.Unmarshal(RootFrame("root_x", 7))
	m = v.(msgpack.Map)
	if mt, _ := msgpack.Member(m, msgpack.Str("maxT")); mt != msgpack.Int(7) {
		t.Fatalf("root frame = %#v", m)
	}
}

// TestHubOrdering checks the structural invariant: WAL bytes generated before
// a response precede that response on the wire.
func TestHubOrdering(t *testing.T) {
	h := NewHub("/tmp/blobs")
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	sub := h.Register(b)

	h.BroadcastWal([]byte{1, 2, 3})
	sub.EnqueueResponse([]byte("response-body"))

	a.SetReadDeadline(time.Now().Add(2 * time.Second))
	f1 := readFrame(t, a)
	v, err := msgpack.Unmarshal(f1)
	if err != nil {
		t.Fatal(err)
	}
	m := v.(msgpack.Map)
	if ev, _ := msgpack.Member(m, msgpack.Str("ev")); ev != msgpack.Str("wal") {
		t.Fatalf("first frame ev = %#v", ev)
	}
	if d, _ := msgpack.Member(m, msgpack.Str("data")); string(d.(msgpack.Bin)) != string([]byte{1, 2, 3}) {
		t.Fatalf("wal data = %#v", d)
	}
	f2 := readFrame(t, a)
	if string(f2) != "response-body" {
		t.Fatalf("second frame = %q", f2)
	}
}

// TestBacklogCreditsOnWrite: backlog must track PENDING bytes.  Without the
// credit on write it is a cumulative total, so any writer that ever pushes
// 64 MiB through the subscriber trips BacklogMaxBytes and the subscriber is
// closed spuriously (this is exactly what broke a bulk load_receita run).
// The Nim subscriber credits the frame as it writes it.
func TestBacklogCreditsOnWrite(t *testing.T) {
	h := NewHub("")
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	s := h.Register(server)

	// Keep the pipe draining (net.Pipe is synchronous).
	go func() {
		buf := make([]byte, 64*1024)
		for {
			if _, err := client.Read(buf); err != nil {
				return
			}
		}
	}()

	// 70 x 1 MiB of WAL traffic, flushed into frames as we go (the pattern of
	// the real system: appendWal, then an EnqueueResponse flushes the buf).
	payload := make([]byte, 1*1024*1024)
	for i := 0; i < 70; i++ {
		s.appendWal(payload)
		s.EnqueueResponse(nil)
		time.Sleep(time.Millisecond)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		pending, backlog, closed := len(s.queue), s.backlog, s.closed
		s.mu.Unlock()
		if !closed && pending == 0 && backlog == 0 {
			return
		}
		if closed {
			t.Fatalf("subscriber closed after %d MiB of traffic (pending=%d backlog=%d): the write credit is missing",
				70, pending, backlog)
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("queue never drained")
}
