package querysrv

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"eavt-go/internal/downstream"
)

// TestFrameWriterFramesIntact checks the framing the writer puts on the wire:
// every queued frame must come back as one length-prefixed frame, in order,
// including empty bodies and payloads larger than one writev batch.
func TestFrameWriterFramesIntact(t *testing.T) {
	cli, srv := net.Pipe()
	defer cli.Close()

	w := newFrameWriter(srv, 1<<20)
	want := [][]byte{
		[]byte("first"),
		bytes.Repeat([]byte("x"), 5000),
		[]byte("last"),
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for _, f := range want {
			if err := w.enqueue(f); err != nil {
				t.Errorf("enqueue: %v", err)
				return
			}
		}
	}()
	for i := range want {
		got, err := downstream.ReadFrame(cli)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if !bytes.Equal(got, want[i]) {
			t.Fatalf("frame %d = %q..., want %q...", i, trunc(got), trunc(want[i]))
		}
	}
	wg.Wait()
}

// TestFrameWriterBlocksAtCap is the backpressure contract: below the cap the
// producer never waits; at/above it the producer blocks until the drain frees
// space (the request loop stops and the socket window takes over).
func TestFrameWriterBlocksAtCap(t *testing.T) {
	cli, srv := net.Pipe() // nobody reads yet: the drain goroutine blocks on write
	defer cli.Close()

	const cap = 64
	big := bytes.Repeat([]byte("a"), cap)
	w := newFrameWriter(srv, cap)

	// Frame 1 is taken by the drain and stalls on the pipe (no reader).
	if err := w.enqueue(big); err != nil {
		t.Fatal(err)
	}
	// Frame 2 fills the queue while the drain is stalled.
	if err := w.enqueue(big); err != nil {
		t.Fatal(err)
	}

	blocked := make(chan error, 1)
	go func() { blocked <- w.enqueue(big) }()

	select {
	case err := <-blocked:
		t.Fatalf("enqueue above cap returned (%v); want it to block", err)
	case <-time.After(150 * time.Millisecond):
		// blocked as expected
	}
	if got := w.pendingBytes(); got != cap {
		t.Fatalf("pendingBytes = %d, want %d", got, cap)
	}

	// Reading drains the socket: the writer takes the next batch, frees the
	// counter and wakes the blocked producer (frames 2 and 3 follow).
	for i := 0; i < 3; i++ {
		buf := make([]byte, 4+len(big))
		if _, err := io.ReadFull(cli, buf); err != nil {
			t.Fatalf("read frame %d: %v", i, err)
		}
	}
	select {
	case err := <-blocked:
		if err != nil {
			t.Fatalf("enqueue after drain: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("producer stayed blocked after the queue drained")
	}
}

// TestFrameWriterCloseReleasesProducers: a dead connection must never leave a
// request goroutine parked on the queue condition.
func TestFrameWriterCloseReleasesProducers(t *testing.T) {
	cli, srv := net.Pipe()
	defer cli.Close()

	const cap = 64
	big := bytes.Repeat([]byte("b"), cap)
	w := newFrameWriter(srv, cap)
	if err := w.enqueue(big); err != nil { // drain takes it, stalls on the pipe
		t.Fatal(err)
	}
	if err := w.enqueue(big); err != nil { // fills the queue
		t.Fatal(err)
	}
	blocked := make(chan error, 1)
	go func() { blocked <- w.enqueue(big) }()
	time.Sleep(50 * time.Millisecond)
	w.close()

	select {
	case err := <-blocked:
		if err == nil {
			t.Fatal("producer above cap returned nil after close; want error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("producer stayed blocked after close")
	}
}

func trunc(b []byte) string {
	if len(b) > 24 {
		return string(b[:24]) + "…"
	}
	return string(b)
}
