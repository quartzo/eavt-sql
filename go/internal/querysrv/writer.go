// writer.go — per-connection response writer for the query server.
//
// The request-reading loop enqueues frames and keeps reading; a dedicated
// goroutine drains the queue to the client socket in a single writev.
//
// Why this exists: reading and writing the same socket from one goroutine
// couples the two directions.  A client that is still sending (and has not
// started reading responses) fills the socket buffers, the write blocks, the
// read loop stops, and both sides deadlock — measured end to end with
// `tests/bench_client_split.py --depth 16` (client stuck in send, gateway
// stuck in WriteFrame).  With the writer below, the read loop only waits when
// the queue crosses its byte cap; at that point blocking IS the correct
// behavior: the client exceeded the queue policy and the socket window
// carries the backpressure the rest of the way (memory stays bounded).
//
// The queue mirrors replication.Subscriber (mutex + draining flag + one
// writev) — that path already proved the wakeup math: writing the frames
// back-to-back makes the reader wake once instead of once per frame.
package querysrv

import (
	"encoding/binary"
	"errors"
	"net"
	"os"
	"strconv"
	"sync"

	"eavt-go/internal/downstream"
	"eavt-go/internal/logutil"
)

// defaultClientQueueMax is the response-queue cap per connection, mirroring
// replication.BacklogMaxBytes: a policy constant, not a protocol negotiation.
const defaultClientQueueMax = 64 << 20 // 64 MiB

// clientQueueMaxBytes is the active cap.  It is set from
// EAVT_CLIENT_QUEUE_MAX (bytes) at init so tests and operators can shrink it;
// tests assign it directly to exercise the blocking path.
var clientQueueMaxBytes int64 = defaultClientQueueMax

func init() {
	if v := os.Getenv("EAVT_CLIENT_QUEUE_MAX"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			clientQueueMaxBytes = n
		}
	}
}

var errClientGone = errors.New("client connection closed")

// frameWriter owns every byte written to one client connection.  A single
// drain goroutine writes, so frames from different handlers can never
// interleave (streamProgram emits N chunks; errors may fire in between).
type frameWriter struct {
	cond *sync.Cond
	mu   sync.Mutex

	conn     net.Conn
	queue    [][]byte
	bytes    int64
	maxBytes int64

	draining bool
	closed   bool
	warned   bool // log the first blocked producer only
}

func newFrameWriter(conn net.Conn, maxBytes int64) *frameWriter {
	w := &frameWriter{conn: conn, maxBytes: maxBytes}
	w.cond = sync.NewCond(&w.mu)
	return w
}

// enqueue appends a frame and returns immediately while the queue is below
// maxBytes (the reader loop never waits on the client).  At or above the cap
// it blocks until the drain frees space — that is the backpressure point:
// the reader stops, the socket window closes, and the client's send blocks.
func (w *frameWriter) enqueue(frame []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	for !w.closed && w.bytes >= w.maxBytes {
		if !w.warned {
			w.warned = true
			logutil.Warn("querysrv", "response queue at cap; blocking the request loop until the client reads")
		}
		w.cond.Wait()
	}
	if w.closed {
		return errClientGone
	}
	w.queue = append(w.queue, frame)
	w.bytes += int64(len(frame))
	if !w.draining {
		w.draining = true
		go w.drain()
	}
	return nil
}

// drain writes queued frames until empty.  It takes the whole queue in one
// shot and clears the byte counter before writing, so producers enqueue into
// the next batch while this one is on the wire (the cap is a high-water mark,
// not a lock over the syscall).
func (w *frameWriter) drain() {
	for {
		w.mu.Lock()
		if w.closed || len(w.queue) == 0 {
			w.draining = false
			w.mu.Unlock()
			return
		}
		frames := w.queue
		w.queue = nil
		w.bytes = 0
		w.cond.Broadcast() // wake producers waiting for space
		w.mu.Unlock()

		if err := writeFrames(w.conn, frames); err != nil {
			w.close()
			return
		}
	}
}

// close marks the writer dead and releases every producer waiting for space.
// Pending frames are dropped: the reader loop only leaves on a socket error,
// i.e. the peer is gone.
func (w *frameWriter) close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	w.queue = nil
	w.bytes = 0
	w.cond.Broadcast()
	w.mu.Unlock()
}

// pendingBytes reports the queued response bytes (tests/observability).
func (w *frameWriter) pendingBytes() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.bytes
}

// writeFrames emits every frame with one writev: 4-byte big-endian length
// header + body, same framing as downstream.WriteFrame (net.Buffers loops
// until all buffers are written).
func writeFrames(conn net.Conn, frames [][]byte) error {
	if len(frames) == 1 {
		return writeOne(conn, frames[0])
	}
	hdrs := make([][4]byte, len(frames))
	var bufs net.Buffers
	for i, body := range frames {
		binary.BigEndian.PutUint32(hdrs[i][:], uint32(len(body)))
		bufs = append(bufs, hdrs[i][:])
		if len(body) > 0 {
			bufs = append(bufs, body)
		}
	}
	_, err := bufs.WriteTo(conn)
	return err
}

func writeOne(conn net.Conn, body []byte) error {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(body)))
	if len(body) == 0 {
		_, err := conn.Write(hdr[:])
		return err
	}
	bufs := net.Buffers{hdr[:], body}
	_, err := bufs.WriteTo(conn)
	return err
}

// clientConn pairs a client socket with its writer.  Handlers take this
// instead of net.Conn so every response goes through the queue — a raw
// net.Conn in a handler signature would be a footgun (an inline write next to
// a queued one interleaves frames).
type clientConn struct {
	w *frameWriter
}

func newClientConn(conn net.Conn) *clientConn {
	return &clientConn{w: newFrameWriter(conn, clientQueueMaxBytes)}
}

func (c *clientConn) writeFrame(frame []byte) error { return c.w.enqueue(frame) }

func (c *clientConn) writeError(msg string) {
	_ = c.w.enqueue(downstream.ErrorFrame(msg))
}
