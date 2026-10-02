// Package edn implements the EDN reader for the Datomic-style tx-data subset,
// mirroring nim_edn/edn.nim:
//
//	vectors [..], lists (..), keywords :ns/name (value WITHOUT the leading
//	colon), symbols, ?vars, strings, ints (negative tempids), floats,
//	true/false/nil, `_`.  Commas are whitespace.  Maps {..} and sets #{..}
//	are rejected.  Parsing is fail-loud with position.
package edn

import (
	"fmt"
	"strconv"
	"strings"
)

// Error is a parse error with position information.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errf(format string, a ...any) *Error { return &Error{Msg: fmt.Sprintf(format, a...)} }

// Value is one EDN node.  List covers both [] and ().
type Value interface{ ednValue() }

type (
	Int     int64
	Float   float64
	Str     string
	Bool    bool
	Nil     struct{}
	Keyword string // without the leading colon
	Symbol  string
	List    []Value
)

func (Int) ednValue()     {}
func (Float) ednValue()   {}
func (Str) ednValue()     {}
func (Bool) ednValue()    {}
func (Nil) ednValue()     {}
func (Keyword) ednValue() {}
func (Symbol) ednValue()  {}
func (List) ednValue()    {}

func isWS(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','
}

func skipWS(s string, pos int) int {
	for pos < len(s) && isWS(s[pos]) {
		pos++
	}
	return pos
}

func isDelim(c byte) bool {
	return isWS(c) || c == '(' || c == ')' || c == '[' || c == ']' ||
		c == '{' || c == '}' || c == '"'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// parseString expects pos on the opening quote.
func parseString(s string, pos int) (string, int, error) {
	var b strings.Builder
	i := pos + 1
	for {
		if i >= len(s) {
			return "", 0, errf("edn: unterminated string")
		}
		switch s[i] {
		case '"':
			return b.String(), i + 1, nil
		case '\\':
			if i+1 >= len(s) {
				return "", 0, errf("edn: unterminated escape at end of input")
			}
			switch s[i+1] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			default:
				return "", 0, errf("edn: unsupported escape \\%c at pos %d", s[i+1], i)
			}
			i += 2
		default:
			b.WriteByte(s[i])
			i++
		}
	}
}

func parseValue(s string, pos int) (Value, int, error) {
	pos = skipWS(s, pos)
	if pos >= len(s) {
		return nil, 0, errf("edn: unexpected end of input")
	}
	switch c := s[pos]; c {
	case '[':
		return parseSeq(s, pos, ']', "vector")
	case '(':
		return parseSeq(s, pos, ')', "list")
	case '{':
		return nil, 0, errf("edn: maps not supported at pos %d", pos)
	case '#':
		if pos+1 < len(s) && s[pos+1] == '{' {
			return nil, 0, errf("edn: sets not supported at pos %d", pos)
		}
		nc := byte('?')
		if pos+1 < len(s) {
			nc = s[pos+1]
		}
		return nil, 0, errf("edn: unsupported dispatch #%c at pos %d", nc, pos)
	case '"':
		str, next, err := parseString(s, pos)
		if err != nil {
			return nil, 0, err
		}
		return Str(str), next, nil
	}

	start := pos
	for pos < len(s) && !isDelim(s[pos]) {
		pos++
	}
	stop := pos
	if stop == start {
		return nil, 0, errf("edn: empty atom at pos %d", start)
	}
	atom := s[start:stop]
	switch atom {
	case "nil":
		return Nil{}, stop, nil
	case "true":
		return Bool(true), stop, nil
	case "false":
		return Bool(false), stop, nil
	case "_":
		return Symbol("_"), stop, nil
	case ":":
		return nil, 0, errf("edn: bare ':' at pos %d", start)
	}
	if atom[0] == ':' {
		return Keyword(atom[1:]), stop, nil
	}
	if isDigit(atom[0]) ||
		((atom[0] == '-' || atom[0] == '+') && len(atom) > 1 && isDigit(atom[1])) {
		if n, err := strconv.ParseInt(atom, 10, 64); err == nil {
			return Int(n), stop, nil
		}
		if f, err := strconv.ParseFloat(atom, 64); err == nil {
			return Float(f), stop, nil
		}
		return Symbol(atom), stop, nil
	}
	// Float only when plausibly numeric — keeps nan/inf as symbols.
	if strings.IndexFunc(atom, func(r rune) bool { return r >= '0' && r <= '9' }) >= 0 {
		if f, err := strconv.ParseFloat(atom, 64); err == nil {
			return Float(f), stop, nil
		}
	}
	return Symbol(atom), stop, nil
}

func parseSeq(s string, pos int, close byte, kind string) (Value, int, error) {
	var items List
	i := pos + 1
	for {
		i = skipWS(s, i)
		if i >= len(s) {
			return nil, 0, errf("edn: unterminated %s", kind)
		}
		if s[i] == close {
			return items, i + 1, nil
		}
		v, next, err := parseValue(s, i)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, v)
		i = next
	}
}

// Read parses a single value and rejects trailing content.
func Read(s string) (Value, error) {
	v, pos, err := parseValue(s, 0)
	if err != nil {
		return nil, err
	}
	pos = skipWS(s, pos)
	if pos != len(s) {
		return nil, errf("edn: trailing content at pos %d", pos)
	}
	return v, nil
}

// ReadVector parses a top-level vector and returns its elements; trailing
// content after the vector is ignored (like the Nim reader).
func ReadVector(s string) ([]Value, error) {
	pos := skipWS(s, 0)
	if pos >= len(s) || s[pos] != '[' {
		got := "<eof>"
		if pos < len(s) {
			got = string(s[pos])
		}
		return nil, errf("edn: expected tx-data vector, got: %s", got)
	}
	v, _, err := parseValue(s, pos)
	if err != nil {
		return nil, err
	}
	lst, ok := v.(List)
	if !ok {
		return nil, errf("edn: expected tx-data vector")
	}
	return []Value(lst), nil
}
