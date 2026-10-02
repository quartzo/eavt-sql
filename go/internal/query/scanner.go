// scanner.go — V2Scanner with leapfrog triejoin over the merged cursor.
// Port of nim_query/query/scanner.nim.
package query

import (
	"eavt-go/internal/cursor"
	"eavt-go/internal/sexpr"
)

// Storage value-type constants (resolver_consts).
const (
	DbTypeString  uint32 = 20
	DbTypeRef     uint32 = 21
	DbTypeLong    uint32 = 22
	DbTypeKeyword uint32 = 23
	DbTypeBoolean uint32 = 24
	DbTypeInstant uint32 = 25
	DbTypeBytes   uint32 = 26
	DbTypeFloat   uint32 = 27
	DbTypeBlob    uint32 = 28
)

// KeyVsPrefix classifies a key against the scanner prefix.
type KeyVsPrefix int

const (
	KvpNoPrefix KeyVsPrefix = iota
	KvpBefore
	KvpMatch
	KvpAfter
)

// PositionStack tracks pushed fixed values for one scanner position.
type PositionStack struct {
	Cursor           cursor.Cursor
	IdxOrder         []string
	stack            []sexpr.Expr
	currentActiveKey []byte
	hasActiveKey     bool
	AtEnd            bool
}

// NewPositionStack creates an empty position stack.
func NewPositionStack(cur cursor.Cursor, idxOrder []string) *PositionStack {
	return &PositionStack{Cursor: cur, IdxOrder: idxOrder, AtEnd: true}
}

func (ps *PositionStack) pushFixed(val sexpr.Expr) { ps.stack = append(ps.stack, val) }

func (ps *PositionStack) popFixed() (sexpr.Expr, bool) {
	if len(ps.stack) == 0 {
		return nil, false
	}
	v := ps.stack[len(ps.stack)-1]
	ps.stack = ps.stack[:len(ps.stack)-1]
	return v, true
}

func (ps *PositionStack) currentPosition() int { return len(ps.stack) }

func (ps *PositionStack) posName() string {
	ci := ps.currentPosition()
	if ci < len(ps.IdxOrder) {
		return ps.IdxOrder[ci]
	}
	return "t"
}

// V2Scanner is the triejoin scanner.
type V2Scanner struct {
	Pos       *PositionStack
	IndexName string

	asOfTx       int64
	hasAsOfTx    bool
	valueAttr    uint32
	hasValueAttr bool

	HistoryMode bool
	prefixCache []byte
	tInPrefix   bool
}

// NewV2Scanner creates a scanner for an index.
func NewV2Scanner(indexName string, idxOrder []string, asOfTx int64, hasAsOfTx bool) *V2Scanner {
	return &V2Scanner{
		Pos:       NewPositionStack(cursor.Invalid(), idxOrder),
		IndexName: toUpper(indexName),
		asOfTx:    asOfTx,
		hasAsOfTx: hasAsOfTx,
	}
}

func toUpper(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 'a' - 'A'
		}
	}
	return string(b)
}

// SetCursor attaches a cursor and clears the end flag.
func (sc *V2Scanner) SetCursor(c cursor.Cursor) {
	sc.Pos.Cursor = c
	sc.Pos.AtEnd = false
}

// AtEnd reports whether the scanner is exhausted.
func (sc *V2Scanner) AtEnd() bool { return sc.Pos.AtEnd }

// SaveValue pushes a fixed value and recomputes the prefix.
func (sc *V2Scanner) SaveValue(val sexpr.Expr) {
	sc.Pos.pushFixed(val)
	sc.recomputePrefix()
}

// PopSavedValue pops a fixed value and recomputes the prefix.
func (sc *V2Scanner) PopSavedValue() {
	sc.Pos.popFixed()
	sc.recomputePrefix()
}

// SetValueAttrType sets the value attribute type and recomputes the prefix.
func (sc *V2Scanner) SetValueAttrType(vt uint32, has bool) {
	sc.valueAttr = vt
	sc.hasValueAttr = has
	sc.recomputePrefix()
}

func (sc *V2Scanner) recomputePrefix() {
	var buf []byte
	tInPrefix := false
	fixed := sc.Pos.stack
	for pi, pn := range sc.Pos.IdxOrder {
		if pi >= len(fixed) {
			break
		}
		v := fixed[pi]
		switch pn {
		case "a":
			v32 := uint32(int64(v.(sexpr.Int)))
			buf = append(buf, byte(v32>>24), byte(v32>>16), byte(v32>>8), byte(v32))
		case "e":
			buf = append(buf, encodeEid(int64(v.(sexpr.Int)))...)
		case "v":
			if sc.hasValueAttr && sc.valueAttr == DbTypeBlob {
				buf = append(buf, encodeVariableUnordered([]byte(v.(sexpr.Bytes)))...)
			} else if s, ok := v.(sexpr.Str); ok {
				buf = append(buf, encodeVariable(string(s))...)
			} else if b, ok := v.(sexpr.Bytes); ok {
				buf = append(buf, encodeVariableUnordered(b)...)
			} else {
				buf = append(buf, encodeFixed(v)...)
			}
		case "t":
			sf := encodeSuffix(int64(v.(sexpr.Int)), false)
			buf = append(buf, byte(sf>>56), byte(sf>>48), byte(sf>>40), byte(sf>>32),
				byte(sf>>24), byte(sf>>16), byte(sf>>8), byte(sf))
			tInPrefix = true
		default:
			buf = append(buf, encodeBoundValue(v)...)
		}
	}
	sc.prefixCache = buf
	sc.tInPrefix = tInPrefix
}

// ClassifyKey compares a key against the current prefix.
func (sc *V2Scanner) ClassifyKey(key []byte) KeyVsPrefix {
	bp := sc.prefixCache
	if len(bp) == 0 {
		return KvpNoPrefix
	}
	n := len(bp)
	if len(key) < n {
		n = len(key)
	}
	ord := 0
	if sc.tInPrefix {
		last := n - 1
		if last < 0 {
			return KvpBefore
		}
		for i := 0; i < last; i++ {
			if key[i] < bp[i] {
				ord = -1
				break
			}
			if key[i] > bp[i] {
				ord = 1
				break
			}
		}
		if ord == 0 {
			k := key[last] & 0xFE
			p := bp[last] & 0xFE
			switch {
			case k < p:
				ord = -1
			case k > p:
				ord = 1
			}
		}
	} else {
		for i := 0; i < n; i++ {
			if key[i] < bp[i] {
				ord = -1
				break
			}
			if key[i] > bp[i] {
				ord = 1
				break
			}
		}
	}
	if ord < 0 {
		return KvpBefore
	}
	if ord > 0 {
		return KvpAfter
	}
	if len(key) < len(bp) {
		return KvpBefore
	}
	return KvpMatch
}

func findVEnd(key []byte, start int, isUnordered bool) int {
	if isUnordered {
		if start+4 > len(key) {
			return len(key)
		}
		length := int(beUint32(key, start))
		return start + 4 + length
	}
	pos := start
	for pos+9 <= len(key) {
		if key[pos+8] == 0xff {
			pos += 9
		} else {
			return pos + 9
		}
	}
	return len(key)
}

func (sc *V2Scanner) isUnorderedAttr() bool {
	return sc.hasValueAttr && sc.valueAttr == DbTypeBlob
}

func (sc *V2Scanner) isVariableValue(keyLen int) bool {
	if sc.hasValueAttr && (sc.valueAttr == DbTypeString || sc.valueAttr == DbTypeBytes || sc.valueAttr == DbTypeBlob) {
		return true
	}
	return keyLen != 28
}

// ValueStart returns the start offset of the value segment in a key.
func (sc *V2Scanner) ValueStart(key []byte) int {
	ci := sc.Pos.currentPosition()
	pn := sc.Pos.posName()
	if ci >= len(sc.Pos.IdxOrder) || pn == "t" || pn == "added" {
		return len(key) - 8
	}
	switch sc.IndexName {
	case "EAVT":
		switch ci {
		case 0:
			return 0
		case 1:
			return 8
		default:
			return 12
		}
	case "AEVT":
		switch ci {
		case 0:
			return 0
		case 1:
			return 4
		default:
			return 12
		}
	case "AVET":
		switch ci {
		case 0:
			return 0
		case 1:
			return 4
		default:
			vs := 4
			if sc.isVariableValue(len(key)) {
				return findVEnd(key, vs, sc.isUnorderedAttr())
			}
			return vs + 8
		}
	case "VAET":
		switch ci {
		case 0:
			return 0
		case 1:
			return 8
		default:
			return 12
		}
	}
	return 12
}

// ValueEnd returns the end offset of the value segment in a key.
func (sc *V2Scanner) ValueEnd(key []byte) int {
	ci := sc.Pos.currentPosition()
	if ci >= len(sc.Pos.IdxOrder) {
		return len(key)
	}
	pn := sc.Pos.posName()
	vs := sc.ValueStart(key)
	switch pn {
	case "e":
		return vs + 8
	case "a":
		return vs + 4
	case "v":
		if sc.isVariableValue(len(key)) {
			return findVEnd(key, vs, sc.isUnorderedAttr())
		}
		return vs + 8
	}
	return len(key)
}

func extractSuffix(key []byte) uint64 { return beUint64(key, len(key)-8) }

// ExtractCurrent reads the value at the current position.
func (sc *V2Scanner) ExtractCurrent() (sexpr.Expr, bool) {
	if !sc.Pos.hasActiveKey {
		return nil, false
	}
	k := sc.Pos.currentActiveKey
	if c := sc.ClassifyKey(k); c != KvpMatch && c != KvpNoPrefix {
		return nil, false
	}
	pn := sc.Pos.posName()
	ci := sc.Pos.currentPosition()

	if ci >= len(sc.Pos.IdxOrder) || pn == "t" || pn == "added" {
		t, retracted := decodeSuffix(extractSuffix(k))
		if pn == "added" {
			return sexpr.Bool(!retracted), true
		}
		return sexpr.Int(t), true
	}

	vs := sc.ValueStart(k)
	ve := sc.ValueEnd(k)
	switch pn {
	case "a":
		return sexpr.Int(int64(beUint32(k, vs))), true
	case "e":
		return sexpr.Int(decodeEid(beUint64(k, vs))), true
	case "v":
		if sc.isVariableValue(len(k)) {
			data := k[vs:ve]
			if sc.hasValueAttr && sc.valueAttr == DbTypeString {
				return sexpr.Str(decodeVariableStr(data, 0)), true
			} else if sc.hasValueAttr && sc.valueAttr == DbTypeBytes {
				return sexpr.Bytes(append([]byte(nil), data...)), true
			} else if sc.hasValueAttr && sc.valueAttr == DbTypeBlob {
				return sexpr.Bytes(append([]byte(nil), data...)), true
			}
			return sexpr.Str(decodeVariableStr(data, 0)), true
		}
		raw := beUint64(k, vs)
		switch {
		case sc.hasValueAttr && sc.valueAttr == DbTypeFloat:
			return sexpr.Float(decodeFloat64(raw)), true
		case sc.hasValueAttr && sc.valueAttr == DbTypeBoolean:
			return sexpr.Bool(raw != 0), true
		case sc.hasValueAttr && (sc.valueAttr == DbTypeInstant || sc.valueAttr == DbTypeRef):
			return sexpr.Int(decodeInt64(raw)), true
		case sc.hasValueAttr && sc.valueAttr == DbTypeLong:
			return sexpr.Int(decodeInt64(raw)), true
		default:
			return sexpr.Int(int64(raw)), true
		}
	}
	return nil, false
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// AdvanceToActiveAt positions the cursor on the newest active key for the prefix.
func (sc *V2Scanner) AdvanceToActiveAt() {
	pn := sc.Pos.posName()
	if pn == "added" {
		sc.Pos.AtEnd = !sc.Pos.hasActiveKey
		return
	}
	if sc.HistoryMode && pn == "t" {
		for sc.Pos.Cursor.Valid() {
			key, ok := sc.Pos.Cursor.CurrentKey()
			if !ok || len(key) < 8 {
				sc.Pos.Cursor.Step()
				continue
			}
			c := sc.ClassifyKey(key)
			if c == KvpBefore || c == KvpAfter {
				sc.Pos.AtEnd = true
				return
			}
			t, _ := decodeSuffix(extractSuffix(key))
			if sc.hasAsOfTx && t > sc.asOfTx {
				sc.Pos.Cursor.Step()
				continue
			}
			sc.Pos.currentActiveKey = key
			sc.Pos.hasActiveKey = true
			sc.Pos.AtEnd = false
			return
		}
		sc.Pos.hasActiveKey = false
		sc.Pos.AtEnd = true
		return
	}

	for sc.Pos.Cursor.Valid() {
		key, ok := sc.Pos.Cursor.CurrentKey()
		if !ok || len(key) < 8 {
			sc.Pos.Cursor.Step()
			continue
		}
		firstKey := key
		switch sc.ClassifyKey(firstKey) {
		case KvpNoPrefix, KvpMatch:
		case KvpBefore:
			sc.Pos.Cursor.Seek(sc.prefixCache)
			continue
		case KvpAfter:
			sc.Pos.hasActiveKey = false
			sc.Pos.AtEnd = true
			return
		}

		var bestKey []byte
		hasBest := false
		bestT := int64(0)
		bestRetracted := false
		groupEnd := len(firstKey) - 8
		curGroup := firstKey[:groupEnd]

		for sc.Pos.Cursor.Valid() {
			k, ok := sc.Pos.Cursor.CurrentKey()
			if !ok || len(k) < 8 {
				sc.Pos.Cursor.Step()
				continue
			}
			ge := len(k) - 8
			if !bytesEqual(k[:ge], curGroup) {
				if hasBest {
					break
				}
				curGroup = k[:ge]
			}
			t, retracted := decodeSuffix(extractSuffix(k))
			if sc.hasAsOfTx && t > sc.asOfTx {
				sc.Pos.Cursor.Step()
				continue
			}
			if t >= bestT {
				bestKey = k
				hasBest = true
				bestT = t
				bestRetracted = retracted
			}
			sc.Pos.Cursor.Step()
		}

		if hasBest && !bestRetracted {
			sc.Pos.currentActiveKey = bestKey
			sc.Pos.hasActiveKey = true
			sc.Pos.AtEnd = false
			return
		}
	}
	sc.Pos.hasActiveKey = false
	sc.Pos.AtEnd = true
}

// AdvanceToActiveAtPreserving reuses a matching saved key.
func (sc *V2Scanner) AdvanceToActiveAtPreserving() {
	if sc.Pos.hasActiveKey && sc.ClassifyKey(sc.Pos.currentActiveKey) == KvpMatch {
		sc.Pos.AtEnd = false
		return
	}
	sc.AdvanceToActiveAt()
}

func (sc *V2Scanner) seekPastValueAt() {
	pn := sc.Pos.posName()
	if !sc.Pos.hasActiveKey {
		sc.Pos.Cursor.Invalidate()
		return
	}
	k := sc.Pos.currentActiveKey
	vs := sc.ValueStart(k)
	target := append([]byte(nil), k[:vs]...)

	if pn == "t" {
		suffix := extractSuffix(k)
		if suffix == 0 {
			sc.Pos.Cursor.Invalidate()
			return
		}
		nextVal := suffix + 1
		for i := 7; i >= 0; i-- {
			target = append(target, byte(nextVal>>(uint(i)*8)))
		}
		sc.Pos.Cursor.Seek(target)
		return
	}

	ve := sc.ValueEnd(k)
	raw := k[vs:ve]
	switch {
	case pn == "a":
		cur := beUint32(k, vs)
		if cur == ^uint32(0) {
			sc.Pos.Cursor.Invalidate()
			return
		}
		nextVal := cur + 1
		target = append(target, byte(nextVal>>24), byte(nextVal>>16), byte(nextVal>>8), byte(nextVal))
		sc.Pos.Cursor.Seek(target)
	case sc.isVariableValue(len(k)):
		inc := append([]byte(nil), raw...)
		carry := true
		i := len(inc) - 1
		for carry && i >= 0 {
			if inc[i] < 0xff {
				inc[i]++
				carry = false
			} else {
				inc[i] = 0
				i--
			}
		}
		if carry {
			sc.Pos.Cursor.Invalidate()
			return
		}
		target = append(target, inc...)
		sc.Pos.Cursor.Seek(target)
	default:
		cur := beUint64(k, vs)
		if cur == ^uint64(0) {
			sc.Pos.Cursor.Invalidate()
			return
		}
		nextVal := cur + 1
		for i := 7; i >= 0; i-- {
			target = append(target, byte(nextVal>>(uint(i)*8)))
		}
		sc.Pos.Cursor.Seek(target)
	}
}

// LeapNextAt advances past the current value.
func (sc *V2Scanner) LeapNextAt() {
	if sc.Pos.posName() == "added" {
		sc.Pos.AtEnd = true
		return
	}
	if sc.Pos.hasActiveKey {
		sc.seekPastValueAt()
	}
	sc.AdvanceToActiveAt()
}

// SeekToValue seeks to the first key >= prefix + encoded(value).
func (sc *V2Scanner) SeekToValue(value sexpr.Expr) {
	pn := sc.Pos.posName()
	target := append([]byte(nil), sc.prefixCache...)
	switch pn {
	case "e":
		target = append(target, encodeEid(int64(value.(sexpr.Int)))...)
	case "a":
		v32 := uint32(int64(value.(sexpr.Int)))
		target = append(target, byte(v32>>24), byte(v32>>16), byte(v32>>8), byte(v32))
	case "v":
		if sc.isUnorderedAttr() {
			target = append(target, encodeVariableUnordered([]byte(value.(sexpr.Bytes)))...)
		} else if s, ok := value.(sexpr.Str); ok {
			target = append(target, encodeVariable(string(s))...)
		} else if b, ok := value.(sexpr.Bytes); ok {
			target = append(target, encodeVariableUnordered(b)...)
		} else {
			target = append(target, encodeFixed(value)...)
		}
	}
	target = append(target, make([]byte, 8)...)
	sc.Pos.Cursor.Seek(target)
	sc.AdvanceToActiveAt()
}

// CurrentValueBytes returns the value segment of the current key.
func (sc *V2Scanner) CurrentValueBytes() ([]byte, bool) {
	if !sc.Pos.hasActiveKey {
		return nil, false
	}
	k := sc.Pos.currentActiveKey
	if c := sc.ClassifyKey(k); c != KvpMatch && c != KvpNoPrefix {
		return nil, false
	}
	vs := sc.ValueStart(k)
	ve := sc.ValueEnd(k)
	if vs < 0 || ve > len(k) || vs >= ve {
		return nil, false
	}
	return k[vs:ve], true
}

// SeekToBytes seeks to prefix + valueBytes + suffix.
func (sc *V2Scanner) SeekToBytes(valueBytes []byte) {
	target := append([]byte(nil), sc.prefixCache...)
	target = append(target, valueBytes...)
	target = append(target, make([]byte, 8)...)
	sc.Pos.Cursor.Seek(target)
	sc.AdvanceToActiveAt()
}

// ValidateOrProposeNextElementBytes validates the current value against specs.
func (sc *V2Scanner) ValidateOrProposeNextElementBytes(specs []ByteRangeSpec) (ValidateResult, []byte, bool) {
	cur, ok := sc.CurrentValueBytes()
	if !ok {
		return VrAtEnd, nil, false
	}
	if len(specs) == 0 {
		return VrValid, nil, false
	}
	if len(specs) == 1 && specs[0].Flags == -1 {
		return VrAtEnd, nil, false
	}
	for _, spec := range specs {
		if spec.Flags == -1 {
			continue
		}
		if spec.HasHi {
			hiOpen := spec.Flags&RangeHiOpen != 0
			cmpHi := cmpBytes(cur, spec.Hi)
			pastHi := cmpHi > 0
			if hiOpen {
				pastHi = cmpHi >= 0
			}
			if pastHi {
				continue
			}
		}
		if spec.HasLo {
			loOpen := spec.Flags&RangeLoOpen != 0
			cmpLo := cmpBytes(cur, spec.Lo)
			beforeLo := cmpLo < 0
			if loOpen {
				beforeLo = cmpLo <= 0
			}
			if beforeLo {
				continue
			}
		}
		return VrValid, nil, false
	}
	for _, spec := range specs {
		if spec.Flags == -1 || !spec.HasLo {
			continue
		}
		loOpen := spec.Flags&RangeLoOpen != 0
		cmpLo := cmpBytes(cur, spec.Lo)
		beforeLo := cmpLo < 0
		if loOpen {
			beforeLo = cmpLo <= 0
		}
		if beforeLo {
			return VrPropose, spec.Lo, true
		}
	}
	pastAll := true
	for _, spec := range specs {
		if !spec.HasHi {
			pastAll = false
			break
		}
		hiOpen := spec.Flags&RangeHiOpen != 0
		cmpHi := cmpBytes(cur, spec.Hi)
		pastHi := cmpHi > 0
		if hiOpen {
			pastHi = cmpHi >= 0
		}
		if !pastHi {
			pastAll = false
			break
		}
	}
	if pastAll {
		return VrAtEnd, nil, false
	}
	return VrPropose, nil, false
}

// AttrIDFromPrefixBytes returns the attr id embedded in the prefix.
func (sc *V2Scanner) AttrIDFromPrefixBytes() (uint32, bool) {
	var off int
	switch sc.IndexName {
	case "EAVT", "VAET":
		off = 8
	case "AEVT", "AVET":
		off = 0
	default:
		return 0, false
	}
	if len(sc.prefixCache) >= off+4 {
		return beUint32(sc.prefixCache, off), true
	}
	return 0, false
}

// AttrIDFromKey returns the attr id embedded in the current key.
func (sc *V2Scanner) AttrIDFromKey() (uint32, bool) {
	if !sc.Pos.hasActiveKey {
		return 0, false
	}
	k := sc.Pos.currentActiveKey
	off := 8
	switch sc.IndexName {
	case "EAVT", "VAET":
		off = 8
	case "AEVT", "AVET":
		off = 0
	}
	if len(k) >= off+4 {
		return beUint32(k, off), true
	}
	return 0, false
}

// ValidateResult is the outcome of a range validation.
type ValidateResult int

const (
	VrValid ValidateResult = iota
	VrPropose
	VrAtEnd
)

func cmpBytes(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	}
	return 0
}
