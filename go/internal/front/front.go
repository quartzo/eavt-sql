// Package front implements the two-layer query front: it owns the
// client socket, compiles Datalog EDN locally (byte-identical to the Nim
// compiler) and drives the back's internal executor socket.  tx/admin/kv/
// scheme are forwarded verbatim; responses stream through untouched.
package front

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"eavt-go/internal/datalog"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/sexpr"
)

const maxFrame = 100_000_000

// Config configures the front.
type Config struct {
	BackPath string
	TTL      time.Duration
}

// Server is a query front.
type Server struct {
	cfg Config

	mu      sync.Mutex
	stats   *datalog.CompileStats
	statsAt time.Time
}

// New returns a front server.
func New(cfg Config) *Server {
	if cfg.TTL <= 0 {
		cfg.TTL = 30 * time.Second
	}
	return &Server{cfg: cfg}
}

// ── frame I/O ────────────────────────────────────────────────────────────

func readFrame(conn net.Conn) ([]byte, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr)
	if n == 0 || n > maxFrame {
		return nil, fmt.Errorf("bad frame length")
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(conn, body); err != nil {
		return nil, err
	}
	return body, nil
}

func writeFrame(conn net.Conn, body []byte) error {
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

func errorFrame(msg string) []byte {
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("error"), Value: msgpack.Str(msg)},
		{Key: msgpack.Str("more"), Value: msgpack.Bool(false)},
	})
}

func writeError(conn net.Conn, msg string) {
	_ = writeFrame(conn, errorFrame(msg))
}

// ── back connection ──────────────────────────────────────────────────────

func (s *Server) withBack(fn func(conn net.Conn) error) error {
	conn, err := net.Dial("unix", s.cfg.BackPath)
	if err != nil {
		return err
	}
	defer conn.Close()
	return fn(conn)
}

func (s *Server) requestOne(req msgpack.Value) (msgpack.Value, error) {
	var resp msgpack.Value
	err := s.withBack(func(conn net.Conn) error {
		if err := writeFrame(conn, msgpack.Marshal(req)); err != nil {
			return err
		}
		body, err := readFrame(conn)
		if err != nil {
			return err
		}
		resp, err = msgpack.Unmarshal(body)
		return err
	})
	return resp, err
}

// ── CompileStats cache ───────────────────────────────────────────────────

func (s *Server) fetchStats() (*datalog.CompileStats, error) {
	resp, err := s.requestOne(msgpack.Map{{Key: msgpack.Str("type"), Value: msgpack.Str("schema")}})
	if err != nil {
		return nil, err
	}
	m, ok := resp.(msgpack.Map)
	if !ok {
		return nil, fmt.Errorf("bad schema response")
	}
	nested, ok := msgpack.Member(m, msgpack.Str("schema"))
	if !ok {
		return nil, fmt.Errorf("schema response missing stats")
	}
	return datalog.DecodeCompileStats(nested), nil
}

func (s *Server) getStats() (*datalog.CompileStats, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.stats != nil && now.Sub(s.statsAt) < s.cfg.TTL {
		return s.stats, nil
	}
	st, err := s.fetchStats()
	if err != nil {
		return nil, err
	}
	s.stats = st
	s.statsAt = now
	return st, nil
}

func (s *Server) setStats(st *datalog.CompileStats) {
	s.mu.Lock()
	s.stats = st
	s.statsAt = time.Now()
	s.mu.Unlock()
}

func (s *Server) invalidateStats() {
	s.mu.Lock()
	s.stats = nil
	s.mu.Unlock()
}

func (s *Server) compileQuery(query string) ([]byte, []string, error) {
	attempt := func() ([]byte, []string, error) {
		stats, err := s.getStats()
		if err != nil {
			return nil, nil, err
		}
		prog, findVars, err := datalog.CompileDatalogQuery(query, stats)
		if err != nil {
			return nil, nil, err
		}
		return sexpr.ToWire(prog), findVars, nil
	}
	wire, cols, err := attempt()
	if err != nil && strings.Contains(err.Error(), "attribute resolution failed") {
		s.invalidateStats()
		return attempt()
	}
	return wire, cols, err
}

// ── request handling ─────────────────────────────────────────────────────

func memberStr(m msgpack.Map, key string) string {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if s, ok := v.(msgpack.Str); ok {
			return string(s)
		}
	}
	return ""
}

func memberArray(m msgpack.Map, key string) []msgpack.Value {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if a, ok := v.(msgpack.Array); ok {
			return a
		}
	}
	return nil
}

func memberBool(m msgpack.Map, key string) bool {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		if b, ok := v.(msgpack.Bool); ok {
			return bool(b)
		}
	}
	return false
}

func frameMore(resp msgpack.Value) bool {
	if m, ok := resp.(msgpack.Map); ok {
		return memberBool(m, "more")
	}
	return false
}

// Serve handles one client connection until it closes.
func (s *Server) Serve(conn net.Conn) {
	defer conn.Close()
	for {
		raw, err := readFrame(conn)
		if err != nil {
			return
		}
		v, err := msgpack.Unmarshal(raw)
		if err != nil {
			writeError(conn, "parse error: request must be an object")
			continue
		}
		m, ok := v.(msgpack.Map)
		if !ok {
			writeError(conn, "parse error: request must be an object")
			continue
		}
		typ := memberStr(m, "type")
		switch typ {
		case "datalog":
			s.handleDatalog(conn, raw, m)
		case "schema":
			s.handleSchema(conn)
		case "tx", "admin", "kv", "scheme":
			s.forward(conn, raw)
		default:
			if _, ok := msgpack.Member(m, msgpack.Str("type")); !ok {
				writeError(conn, "parse error: request must be an object with a type")
			} else {
				writeError(conn, "unknown request type: "+typ)
			}
		}
	}
}

func (s *Server) handleDatalog(conn net.Conn, raw []byte, m msgpack.Map) {
	query := memberStr(m, "query")
	if query == "" {
		writeError(conn, "datalog request missing query field")
		return
	}
	if strings.Contains(query, ":db/add") || strings.Contains(query, ":db/retract") {
		s.forward(conn, raw)
		return
	}
	if memberBool(m, "explain") {
		s.forward(conn, raw)
		return
	}
	progWire, columns, err := s.compileQuery(query)
	if err != nil {
		writeError(conn, err.Error())
		return
	}
	params := memberArray(m, "params")
	s.forward(conn, buildSchemeLocal(progWire, params, columns))
}

func buildSchemeLocal(progWire []byte, params []msgpack.Value, columns []string) []byte {
	cols := make(msgpack.Array, len(columns))
	for i, c := range columns {
		cols[i] = msgpack.Str(c)
	}
	if params == nil {
		params = []msgpack.Value{}
	}
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("scheme-local")},
		{Key: msgpack.Str("program"), Value: msgpack.Raw(progWire)},
		{Key: msgpack.Str("params"), Value: msgpack.Array(params)},
		{Key: msgpack.Str("mode"), Value: msgpack.Str("query")},
		{Key: msgpack.Str("columns"), Value: cols},
	})
}

func (s *Server) handleSchema(conn net.Conn) {
	resp, err := s.requestOne(msgpack.Map{{Key: msgpack.Str("type"), Value: msgpack.Str("schema")}})
	if err != nil {
		writeError(conn, err.Error())
		return
	}
	if m, ok := resp.(msgpack.Map); ok {
		if nested, ok := msgpack.Member(m, msgpack.Str("schema")); ok {
			s.setStats(datalog.DecodeCompileStats(nested))
		}
	}
	_ = writeFrame(conn, msgpack.Marshal(resp))
}

// forward sends a request frame to the back and relays the response frames.
func (s *Server) forward(conn net.Conn, req []byte) {
	err := s.withBack(func(back net.Conn) error {
		if err := writeFrame(back, req); err != nil {
			return err
		}
		for {
			frame, err := readFrame(back)
			if err != nil {
				return err
			}
			if err := writeFrame(conn, frame); err != nil {
				return err
			}
			resp, err := msgpack.Unmarshal(frame)
			if err != nil {
				return err
			}
			if !frameMore(resp) {
				return nil
			}
		}
	})
	if err != nil {
		writeError(conn, err.Error())
	}
}
