// Package downstream is the multiplexed query-server <-> transactor connection:
// one socket carries forwarded requests AND the replication event stream.
// Frames with an "ev" key are events; frames with an "id" key are responses.
// Port of eavt_query_nim/downstream.nim.
package downstream

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"eavt-go/internal/msgpack"
)

const maxFrame = 100_000_000

// eventQueueSize bounds the replication-event backlog.  The reader enqueues
// events and a dedicated applier drains them in order, so a slow snapshot
// apply (sealed-segment file reads) never blocks the socket reader.
const eventQueueSize = 256

// Conn is the multiplexed downstream connection.
type Conn struct {
	path    string
	onEvent func(frame []byte)
	evCh    chan []byte

	mu        sync.Mutex
	conn      net.Conn
	connected bool
	nextID    uint64
	pending   map[string]chan []byte

	writeMu sync.Mutex
}

// Open creates and starts the connection (reconnect loop in the background).
func Open(path string, onEvent func(frame []byte)) *Conn {
	c := &Conn{path: path, onEvent: onEvent, evCh: make(chan []byte, eventQueueSize), pending: map[string]chan []byte{}}
	go c.eventLoop()
	go c.connectLoop()
	return c
}

// eventLoop applies replication events in arrival order.
func (c *Conn) eventLoop() {
	for frame := range c.evCh {
		if c.onEvent != nil {
			c.onEvent(frame)
		}
	}
}

// dropEvents clears queued events (called on disconnect: the reconnect
// re-snapshots, so stale frames must not be applied).
func (c *Conn) dropEvents() {
	for {
		select {
		case <-c.evCh:
		default:
			return
		}
	}
}

// Connected reports whether the downstream link is currently up.
func (c *Conn) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Conn) connectLoop() {
	for {
		conn, err := net.Dial("unix", c.path)
		if err != nil {
			time.Sleep(time.Second)
			continue
		}
		c.mu.Lock()
		c.conn = conn
		c.connected = true
		c.mu.Unlock()
		_ = c.sendFrame([]byte{0x81, 0xa4, 't', 'y', 'p', 'e', 0xa9, 'r', 'e', 'p', 'l', 'i', 'c', 'a', 't', 'e'})
		c.readerLoop(conn)
		c.mu.Lock()
		c.connected = false
		c.conn = nil
		for id, ch := range c.pending {
			close(ch)
			delete(c.pending, id)
		}
		c.mu.Unlock()
		c.dropEvents()
		_ = conn.Close()
		time.Sleep(time.Second)
	}
}

func (c *Conn) readerLoop(conn net.Conn) {
	for {
		frame, err := readFrame(conn)
		if err != nil {
			return
		}
		v, err := msgpack.Unmarshal(frame)
		if err != nil {
			continue
		}
		m, ok := v.(msgpack.Map)
		if !ok {
			continue
		}
		if _, isEv := msgpack.Member(m, msgpack.Str("ev")); isEv {
			if c.onEvent != nil {
				c.evCh <- frame
			}
			continue
		}
		if idv, ok := msgpack.Member(m, msgpack.Str("id")); ok {
			if id, ok := idv.(msgpack.Str); ok {
				c.deliver(string(id), frame, mapMore(m))
			}
		}
	}
}

func (c *Conn) deliver(id string, frame []byte, more bool) {
	c.mu.Lock()
	ch, ok := c.pending[id]
	if !ok {
		c.mu.Unlock()
		return
	}
	if !more {
		delete(c.pending, id)
	}
	c.mu.Unlock()
	ch <- frame
}

func mapMore(m msgpack.Map) bool {
	if v, ok := msgpack.Member(m, msgpack.Str("more")); ok {
		if b, ok := v.(msgpack.Bool); ok {
			return bool(b)
		}
	}
	return false
}

func (c *Conn) register(raw []byte) (string, chan []byte, error) {
	c.mu.Lock()
	if !c.connected {
		c.mu.Unlock()
		return "", nil, errors.New("transactor disconnected")
	}
	c.nextID++
	id := itoa(c.nextID)
	ch := make(chan []byte)
	c.pending[id] = ch
	c.mu.Unlock()

	body, err := injectID(raw, id)
	if err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return "", nil, err
	}
	if err := c.sendFrame(body); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return "", nil, err
	}
	return id, ch, nil
}

func injectID(raw []byte, id string) ([]byte, error) {
	v, err := msgpack.Unmarshal(raw)
	if err != nil {
		return nil, err
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		return nil, errors.New("request must be a map")
	}
	m = append(m, msgpack.Pair{Key: msgpack.Str("id"), Value: msgpack.Str(id)})
	return msgpack.Marshal(m), nil
}

// Request forwards a raw request and relays response frames to relay.
func (c *Conn) Request(raw []byte, relay func([]byte) error) error {
	id, ch, err := c.register(raw)
	if err != nil {
		return err
	}
	for {
		frame, ok := <-ch
		if !ok {
			return errors.New("transactor disconnected")
		}
		if relay != nil {
			if err := relay(frame); err != nil {
				c.mu.Lock()
				delete(c.pending, id)
				c.mu.Unlock()
				return err
			}
		}
		v, err := msgpack.Unmarshal(frame)
		if err != nil {
			return nil
		}
		if m, ok := v.(msgpack.Map); ok && !mapMore(m) {
			return nil
		}
	}
}

// RequestCollect sends a request and returns all response frames concatenated
// as framed bytes.
func (c *Conn) RequestCollect(raw []byte) ([]byte, error) {
	_, ch, err := c.register(raw)
	if err != nil {
		return nil, err
	}
	var out []byte
	for {
		frame, ok := <-ch
		if !ok {
			return out, nil
		}
		var hdr [4]byte
		binary.BigEndian.PutUint32(hdr[:], uint32(len(frame)))
		out = append(out, hdr[:]...)
		out = append(out, frame...)
		v, err := msgpack.Unmarshal(frame)
		if err == nil {
			if m, ok := v.(msgpack.Map); ok && !mapMore(m) {
				return out, nil
			}
		}
	}
}

// Close tears down the connection.
func (c *Conn) Close() {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

func (c *Conn) sendFrame(body []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return errors.New("disconnected")
	}
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(body)))
	if _, err := conn.Write(hdr); err != nil {
		return err
	}
	if len(body) > 0 {
		if _, err := conn.Write(body); err != nil {
			return err
		}
	}
	return nil
}

func readFrame(conn net.Conn) ([]byte, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr)
	if n == 0 || n > maxFrame {
		return nil, errors.New("bad frame length")
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(conn, body); err != nil {
		return nil, err
	}
	return body, nil
}

// WriteFrame writes a framed msgpack body to a transport.
func WriteFrame(conn net.Conn, body []byte) error {
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(body)))
	if _, err := conn.Write(hdr); err != nil {
		return err
	}
	if len(body) > 0 {
		_, err := conn.Write(body)
		return err
	}
	return nil
}

// ReadFrame reads one framed msgpack body.
func ReadFrame(conn net.Conn) ([]byte, error) { return readFrame(conn) }

// ErrorFrame builds a {"error": msg, "more": false} frame body.
func ErrorFrame(msg string) []byte {
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("error"), Value: msgpack.Str(msg)},
		{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
	})
}

// RelayError writes an error frame, ignoring failures.
func RelayError(conn net.Conn, msg string) {
	_ = WriteFrame(conn, ErrorFrame(msg))
}

func itoa(n uint64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
