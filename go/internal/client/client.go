// Package client is the UDS client for the eavt query server: 4-byte
// big-endian length framing over MessagePack, mirroring
// eavt_transactor_nim/client.nim.  Streaming responses
// ({"rows": [...], "more": bool}) are collected into chunks; row values
// convert to display strings exactly like the Nim REPL's parseValue path.
package client

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"

	"eavt-go/internal/edn"
	"eavt-go/internal/msgpack"
)

const maxFrame = 100_000_000

// ServerError is an error frame returned by the server ({"error": msg}).
type ServerError struct{ Msg string }

func (e *ServerError) Error() string { return e.Msg }

// DisconnectedError signals a broken connection.
type DisconnectedError struct{ Msg string }

func (e *DisconnectedError) Error() string { return e.Msg }

// Client is a connected UDS client.
type Client struct {
	conn net.Conn
	path string
}

// DefaultSocketPath mirrors getSocketPath() in the Nim client.
func DefaultSocketPath() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "eavt", "eavt-query.sock")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, ".local", "state", "eavt", "eavt-query.sock")
}

// Dial connects to the given socket path.
func Dial(path string) (*Client, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, err
	}
	return &Client{conn: conn, path: path}, nil
}

// Close closes the connection.
func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	return err
}

// Path returns the socket path this client connected to.
func (c *Client) Path() string { return c.path }

func (c *Client) sendFrame(body []byte) error {
	if c.conn == nil {
		return &DisconnectedError{Msg: "server disconnected (closed)"}
	}
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(body)))
	if _, err := c.conn.Write(hdr); err != nil {
		return &DisconnectedError{Msg: "server disconnected (send)"}
	}
	if len(body) > 0 {
		if _, err := c.conn.Write(body); err != nil {
			return &DisconnectedError{Msg: "server disconnected (send body)"}
		}
	}
	return nil
}

func (c *Client) recvFrame() ([]byte, error) {
	if c.conn == nil {
		return nil, &DisconnectedError{Msg: "server disconnected (closed)"}
	}
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(c.conn, hdr); err != nil {
		return nil, &DisconnectedError{Msg: "server disconnected (recv)"}
	}
	n := binary.BigEndian.Uint32(hdr)
	if n == 0 {
		return nil, &DisconnectedError{Msg: "server disconnected (empty frame)"}
	}
	if n > maxFrame {
		return nil, &DisconnectedError{Msg: "server disconnected (oversize frame)"}
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(c.conn, body); err != nil {
		return nil, &DisconnectedError{Msg: "server disconnected (read body)"}
	}
	return body, nil
}

// Chunk is one streamed response frame.
type Chunk struct {
	Columns []string
	Rows    [][]string
}

// req builds {"type": typ, <fields...>}.
func req(typ string, fields ...msgpack.Pair) msgpack.Map {
	m := msgpack.Map{{Key: msgpack.Str("type"), Value: msgpack.Str(typ)}}
	return append(m, fields...)
}

func (c *Client) recvMapRaw() (msgpack.Map, error) {
	body, err := c.recvFrame()
	if err != nil {
		return nil, err
	}
	v, err := msgpack.Unmarshal(body)
	if err != nil {
		return nil, fmt.Errorf("bad response: %w", err)
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		return nil, errors.New("malformed response (not a map)")
	}
	return m, nil
}

func (c *Client) recvMap() (msgpack.Map, error) {
	m, err := c.recvMapRaw()
	if err != nil {
		return nil, err
	}
	if e, ok := msgpack.Member(m, msgpack.Str("error")); ok {
		if s, ok := e.(msgpack.Str); ok && s != "" {
			return nil, &ServerError{Msg: string(s)}
		}
	}
	return m, nil
}

func (c *Client) recvChunk() (Chunk, bool, error) {
	m, err := c.recvMap()
	if err != nil {
		return Chunk{}, false, err
	}
	ch := Chunk{}
	if cols, ok := msgpack.Member(m, msgpack.Str("columns")); ok {
		if arr, ok := cols.(msgpack.Array); ok {
			for _, col := range arr {
				ch.Columns = append(ch.Columns, ValueString(col))
			}
		}
	}
	if rows, ok := msgpack.Member(m, msgpack.Str("rows")); ok {
		if arr, ok := rows.(msgpack.Array); ok {
			for _, row := range arr {
				if ra, ok := row.(msgpack.Array); ok {
					r := make([]string, len(ra))
					for i, cell := range ra {
						r[i] = ValueString(cell)
					}
					ch.Rows = append(ch.Rows, r)
				} else if row != nil {
					ch.Rows = append(ch.Rows, []string{ValueString(row)})
				}
			}
		}
	}
	more := false
	if mv, ok := msgpack.Member(m, msgpack.Str("more")); ok {
		if b, ok := mv.(msgpack.Bool); ok {
			more = bool(b)
		}
	}
	return ch, more, nil
}

// stream sends a request and invokes onChunk for each response frame until
// more=false.
func (c *Client) stream(r msgpack.Value, onChunk func(Chunk) error) error {
	if err := c.sendFrame(msgpack.Marshal(r)); err != nil {
		return err
	}
	for {
		ch, more, err := c.recvChunk()
		if err != nil {
			return err
		}
		if onChunk != nil {
			if err := onChunk(ch); err != nil {
				return err
			}
		}
		if !more {
			return nil
		}
	}
}

func (c *Client) collect(r msgpack.Value) ([]Chunk, error) {
	var chunks []Chunk
	err := c.stream(r, func(ch Chunk) error {
		chunks = append(chunks, ch)
		return nil
	})
	return chunks, err
}

// Datalog streams a Datalog EDN query, invoking onChunk per frame.
func (c *Client) Datalog(query string, onChunk func(Chunk) error) error {
	return c.stream(req("datalog", msgpack.Pair{Key: msgpack.Str("query"), Value: msgpack.Str(query)}), onChunk)
}

// DatalogAll collects all chunks of a Datalog query.
func (c *Client) DatalogAll(query string) ([]Chunk, error) {
	return c.collect(req("datalog", msgpack.Pair{Key: msgpack.Str("query"), Value: msgpack.Str(query)}))
}

// Dump streams an admin dump command.
func (c *Client) Dump(index string, onChunk func(Chunk) error) error {
	return c.stream(req("admin", msgpack.Pair{Key: msgpack.Str("command"), Value: msgpack.Str("dump " + index)}), onChunk)
}

// KVScan streams a KV column-family scan.
func (c *Client) KVScan(cf int, onChunk func(Chunk) error) error {
	return c.stream(req("kv",
		msgpack.Pair{Key: msgpack.Str("op"), Value: msgpack.Str("scan")},
		msgpack.Pair{Key: msgpack.Str("cf"), Value: msgpack.Int(int64(cf))},
	), onChunk)
}

// Admin sends an admin command and returns its "output" string.
func (c *Client) Admin(command string) (string, error) {
	if err := c.sendFrame(msgpack.Marshal(req("admin",
		msgpack.Pair{Key: msgpack.Str("command"), Value: msgpack.Str(command)}))); err != nil {
		return "", err
	}
	m, err := c.recvMapRaw()
	if err != nil {
		return "", err
	}
	if out, ok := msgpack.Member(m, msgpack.Str("output")); ok {
		if s, ok := out.(msgpack.Str); ok {
			return string(s), nil
		}
	}
	return "", nil
}

func (c *Client) kvOp(op string, cf int, key, value *string) (msgpack.Map, error) {
	fields := []msgpack.Pair{
		{Key: msgpack.Str("op"), Value: msgpack.Str(op)},
		{Key: msgpack.Str("cf"), Value: msgpack.Int(int64(cf))},
	}
	if key != nil {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("key"), Value: msgpack.Str(*key)})
	}
	if value != nil {
		fields = append(fields, msgpack.Pair{Key: msgpack.Str("value"), Value: msgpack.Str(*value)})
	}
	if err := c.sendFrame(msgpack.Marshal(req("kv", fields...))); err != nil {
		return nil, err
	}
	body, err := c.recvFrame()
	if err != nil {
		return nil, err
	}
	v, err := msgpack.Unmarshal(body)
	if err != nil {
		return nil, fmt.Errorf("bad response: %w", err)
	}
	m, ok := v.(msgpack.Map)
	if !ok {
		return nil, errors.New("malformed response (not a map)")
	}
	if e, ok := msgpack.Member(m, msgpack.Str("error")); ok {
		if s, ok := e.(msgpack.Str); ok && s != "" {
			return nil, &ServerError{Msg: string(s)}
		}
	}
	return m, nil
}

// KVPut puts a key/value pair.
func (c *Client) KVPut(cf int, key, value string) (string, error) {
	_, err := c.kvOp("put", cf, &key, &value)
	if err != nil {
		if se, ok := err.(*ServerError); ok {
			return "error: " + se.Msg, nil
		}
		return "", err
	}
	return "ok", nil
}

// KVDelete deletes a key.
func (c *Client) KVDelete(cf int, key string) (string, error) {
	_, err := c.kvOp("delete", cf, &key, nil)
	if err != nil {
		if se, ok := err.(*ServerError); ok {
			return "error: " + se.Msg, nil
		}
		return "", err
	}
	return "ok", nil
}

// KVGet returns a value as a raw string, or "(none)".
func (c *Client) KVGet(cf int, key string) (string, error) {
	m, err := c.kvOp("get", cf, &key, nil)
	if err != nil {
		if se, ok := err.(*ServerError); ok {
			return "error: " + se.Msg, nil
		}
		return "", err
	}
	if rows, ok := msgpack.Member(m, msgpack.Str("rows")); ok {
		if arr, ok := rows.(msgpack.Array); ok && len(arr) > 0 {
			if row, ok := arr[0].(msgpack.Array); ok && len(row) > 0 {
				return ValueString(row[0]), nil
			}
		}
	}
	return "(none)", nil
}

// Tx sends EDN tx-data ops and returns the tx-report summary string.
func (c *Client) Tx(ops []edn.Value) (string, error) {
	wire := make(msgpack.Array, len(ops))
	for i, op := range ops {
		wire[i] = ednToWire(op)
	}
	if err := c.sendFrame(msgpack.Marshal(req("tx",
		msgpack.Pair{Key: msgpack.Str("txdata"), Value: wire}))); err != nil {
		return "", err
	}
	m, err := c.recvMap()
	if err != nil {
		if se, ok := err.(*ServerError); ok {
			return "error: " + se.Msg, nil
		}
		return "", err
	}
	txID := int64(0)
	if tv, ok := msgpack.Member(m, msgpack.Str("tx")); ok {
		if n, ok := tv.(msgpack.Int); ok {
			txID = int64(n)
		}
	}
	parts := []string{"tx=" + strconv.FormatInt(txID, 10)}
	if _, ok := msgpack.Member(m, msgpack.Str("tempids")); ok {
		parts = append(parts, "tempids resolved")
	}
	return "tx-report: " + joinComma(parts), nil
}

func ednToWire(v edn.Value) msgpack.Value {
	switch x := v.(type) {
	case edn.Int:
		return msgpack.Int(int64(x))
	case edn.Float:
		return msgpack.Float(float64(x))
	case edn.Str:
		return msgpack.Str(string(x))
	case edn.Bool:
		return msgpack.Bool(bool(x))
	case edn.Nil:
		return msgpack.Nil{}
	case edn.Keyword:
		return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(x)}
	case edn.Symbol:
		return msgpack.Ext{Type: msgpack.ExtSymbol, Data: []byte(x)}
	case edn.List:
		out := make(msgpack.Array, len(x))
		for i, e := range x {
			out[i] = ednToWire(e)
		}
		return out
	}
	return msgpack.Nil{}
}

func joinComma(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ", "
		}
		out += p
	}
	return out
}
