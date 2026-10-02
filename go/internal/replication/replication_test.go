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
