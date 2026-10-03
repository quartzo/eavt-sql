package client

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"testing"

	"eavt-go/internal/msgpack"
)

// fakeServer accepts one connection and dispatches requests through handle.
func fakeServer(t *testing.T, handle func(req msgpack.Map, send func(msgpack.Value))) (*Client, func()) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		send := func(m msgpack.Value) {
			body := msgpack.Marshal(m)
			hdr := make([]byte, 4)
			binary.BigEndian.PutUint32(hdr, uint32(len(body)))
			conn.Write(hdr)
			conn.Write(body)
		}
		for {
			hdr := make([]byte, 4)
			if _, err := io.ReadFull(conn, hdr); err != nil {
				return
			}
			n := binary.BigEndian.Uint32(hdr)
			body := make([]byte, n)
			if _, err := io.ReadFull(conn, body); err != nil {
				return
			}
			v, err := msgpack.Unmarshal(body)
			if err != nil {
				return
			}
			m, _ := v.(msgpack.Map)
			handle(m, send)
		}
	}()
	c, err := Dial(path)
	if err != nil {
		t.Fatal(err)
	}
	return c, func() {
		c.Close()
		ln.Close()
		<-done
	}
}

func TestDatalogStreaming(t *testing.T) {
	client, cleanup := fakeServer(t, func(req msgpack.Map, send func(msgpack.Value)) {
		send(msgpack.Map{
			{Key: msgpack.Str("columns"), Value: msgpack.Array{msgpack.Str("v")}},
			{Key: msgpack.Str("rows"), Value: msgpack.Array{msgpack.Array{msgpack.Str("a")}}},
			{Key: msgpack.Str("more"), Value: msgpack.Bool(true)},
		})
		send(msgpack.Map{
			{Key: msgpack.Str("columns"), Value: msgpack.Array{}},
			{Key: msgpack.Str("rows"), Value: msgpack.Array{msgpack.Array{msgpack.Str("b")}}},
			{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
		})
	})
	defer cleanup()

	chunks, err := client.DatalogAll("[:find ?v :where [?e :a ?v]]")
	if err != nil {
		t.Fatal(err)
	}
	if len(chunks) != 2 {
		t.Fatalf("got %d chunks, want 2", len(chunks))
	}
	if got := chunks[0].Rows[0][0]; got != "a" {
		t.Errorf("chunk0 row = %q", got)
	}
	if got := chunks[1].Rows[0][0]; got != "b" {
		t.Errorf("chunk1 row = %q", got)
	}
}

// A single error frame must be consumed exactly once so the next request on
// the same connection stays in sync (an earlier front got this wrong).
func TestErrorThenSuccess(t *testing.T) {
	n := 0
	client, cleanup := fakeServer(t, func(req msgpack.Map, send func(msgpack.Value)) {
		n++
		if n == 1 {
			send(msgpack.Map{
				{Key: msgpack.Str("error"), Value: msgpack.Str("datalog: bad")},
				{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
			})
			return
		}
		send(msgpack.Map{
			{Key: msgpack.Str("rows"), Value: msgpack.Array{msgpack.Array{msgpack.Int(7)}}},
			{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
		})
	})
	defer cleanup()

	if _, err := client.DatalogAll("bad"); err == nil {
		t.Fatal("expected error on first query")
	} else if _, ok := err.(*ServerError); !ok {
		t.Fatalf("expected *ServerError, got %T: %v", err, err)
	}
	chunks, err := client.DatalogAll("good")
	if err != nil {
		t.Fatalf("second query failed (stream desync): %v", err)
	}
	if len(chunks) != 1 || chunks[0].Rows[0][0] != "7" {
		t.Fatalf("second query rows = %#v", chunks)
	}
}

func TestAdminOutput(t *testing.T) {
	client, cleanup := fakeServer(t, func(req msgpack.Map, send func(msgpack.Value)) {
		if typ, _ := msgpack.Member(req, msgpack.Str("type")); fmt.Sprint(typ) != "admin" {
			send(msgpack.Map{{Key: msgpack.Str("error"), Value: msgpack.Str("wrong type")}})
			return
		}
		send(msgpack.Map{{Key: msgpack.Str("output"), Value: msgpack.Str("ok")}})
	})
	defer cleanup()
	out, err := client.Admin("status")
	if err != nil || out != "ok" {
		t.Fatalf("Admin = %q, %v", out, err)
	}
}
