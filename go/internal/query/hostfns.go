// hostfns.go — SchemeHostFns: the host functions bridging the Scheme VM to
// the scanners + engine.  Port of nim_query/query/hostfns.nim (query path).
package query

import (
	"fmt"

	"eavt-go/internal/cursor"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

// EngineOps is the engine surface the host functions and the tx interpreter
// need (read + write).
type EngineOps interface {
	// OpenCursor opens a scan cursor over a CF; history disables the
	// hydrated (active-only) fast path so older versions stay visible.
	OpenCursor(cfID uint32, prefix []byte, history bool) cursor.Cursor
	LookupAttr(name string) (uint32, bool)
	AttrName(aid uint32) string
	ValueTypeFor(aid uint32) (uint32, bool)
	IsUniqueAttr(name string) bool
	LookupEntity(attrName string, value sexpr.Expr) (int64, bool)
	LookupValue(eid int64, attrName string) (sexpr.Expr, bool)

	// Write path (exec mode + tx interpreter).
	Symtab() *scheme.SymTab
	AllocateTxDeferred() int64
	AllocateTx() int64
	AllocateInPartition(pid uint64) int64
	IsUniqueByID(aid uint32) bool
	BatchLookupAvet(keys [][]byte) []int64
	HasDatomW(eid int64, attrID uint32, v scheme.TxWSlot) bool
	SaveBatchEdn(txops []scheme.TxWOp, t int64)
	RetractBatch(txops []scheme.TxWOp, t int64)
	DeclareAttrFromSQL(attr, typeName string, many, unique bool, t int64) error
	SaveWithT(eid int64, attr string, val sexpr.Expr, t, asOf int64) error
	SaveManyWithT(attr string, pairs []Pair, t, asOf int64) error
	Retract(eid int64, attr string, val sexpr.Expr, t, asOf int64) error
	DeclarePartition(name string, t int64) uint64
}

// Pair is an (eid, value) save pair for save-many.
type Pair struct {
	Eid int64
	Val sexpr.Expr
}

// LeapIterator carries leapfrog state across yield/resume.
type LeapIterator struct {
	Scanners []*V2Scanner
	Specs    []ByteRangeSpec
	Started  bool
}

// SchemeHostFns implements scheme.HostFns.
type SchemeHostFns struct {
	Engine    EngineOps
	Params    []sexpr.Expr
	Tx        int64
	AsOfTx    int64
	HasAsOfTx bool
	Scanners  []*V2Scanner
	LeapIters map[int]*LeapIterator
}

// NewSchemeHostFns creates a host-fn environment.
func NewSchemeHostFns(engine EngineOps, params []sexpr.Expr, tx int64, asOfTx int64, hasAsOfTx bool) *SchemeHostFns {
	return &SchemeHostFns{
		Engine: engine, Params: params, Tx: tx,
		AsOfTx: asOfTx, HasAsOfTx: hasAsOfTx,
		LeapIters: map[int]*LeapIterator{},
	}
}

func expectInt(e sexpr.Expr) (int64, error) {
	switch v := e.(type) {
	case sexpr.Int:
		return int64(v), nil
	case sexpr.Float:
		return int64(float64(v)), nil
	}
	return 0, scheme.EvalError("expected int, got " + scheme.String(e))
}

func expectStr(e sexpr.Expr) (string, error) {
	switch v := e.(type) {
	case sexpr.Str:
		return string(v), nil
	case sexpr.Symbol:
		return string(v), nil
	}
	return "", scheme.EvalError("expected string, got " + scheme.String(e))
}

func (h *SchemeHostFns) findScanner(resource sexpr.Expr) (*V2Scanner, error) {
	if r, ok := resource.(sexpr.Resource); ok {
		idx := int(r)
		if idx >= 0 && idx < len(h.Scanners) {
			return h.Scanners[idx], nil
		}
	}
	return nil, scheme.EvalError("expected scanner resource")
}

func (h *SchemeHostFns) findLeapIterator(resource sexpr.Expr) (*LeapIterator, error) {
	if r, ok := resource.(sexpr.Resource); ok {
		if it, ok := h.LeapIters[int(r)]; ok {
			return it, nil
		}
	}
	return nil, scheme.EvalError("expected leap-iterator resource")
}

func (h *SchemeHostFns) pushScanner(sc *V2Scanner) int {
	idx := len(h.Scanners)
	h.Scanners = append(h.Scanners, sc)
	return idx
}

// Call dispatches a host function by name.
func (h *SchemeHostFns) Call(name string, args []sexpr.Expr) (scheme.EvalStep, error) {
	switch name {
	case "scanner-open":
		return h.scannerOpen(args)
	case "scanner-read":
		sc, err := h.findScanner(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if v, ok := sc.ExtractCurrent(); ok {
			return scheme.Done(v), nil
		}
		return scheme.Done(sexpr.Void{}), nil
	case "scanner-push":
		sc, err := h.findScanner(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		sc.SaveValue(args[1])
		return scheme.Done(sexpr.Void{}), nil
	case "scanner-pop":
		sc, err := h.findScanner(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		sc.PopSavedValue()
		return scheme.Done(sexpr.Void{}), nil
	case "scanner-prefix":
		sc, err := h.findScanner(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Bytes(append([]byte(nil), sc.prefixCache...))), nil
	case "scanner-leap-init":
		return h.scannerLeapInit(args)
	case "scanner-leap-next":
		return h.scannerLeapNext(args)
	case "scanner-iterate-init":
		return h.scannerIterateInit(args)
	case "scanner-iterate-next":
		return h.scannerIterateNext(args)
	case "intern-a":
		n, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		aid, ok := h.Engine.LookupAttr(n)
		if !ok {
			return scheme.EvalStep{}, scheme.EvalError("intern-a: unknown attribute: " + n)
		}
		return scheme.Done(sexpr.Int(int64(aid))), nil
	case "attr-name":
		n, err := expectInt(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Str(h.Engine.AttrName(uint32(n)))), nil
	case "param":
		idx, err := expectInt(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if idx < 1 || int(idx) > len(h.Params) {
			return scheme.EvalStep{}, scheme.EvalError(fmt.Sprintf("param index out of range: %d", idx))
		}
		return scheme.Done(h.Params[idx-1]), nil
	case "resolve-val":
		return scheme.Done(args[0]), nil
	case "result-row":
		return scheme.YieldRow(sexpr.List(append([]sexpr.Expr(nil), args...))), nil
	case "result":
		items := append([]sexpr.Expr{sexpr.Symbol("result")}, args...)
		return scheme.Done(sexpr.List(items)), nil
	case "lookup-value":
		eid, err := expectInt(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		attr, err := expectStr(args[1])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if v, ok := h.Engine.LookupValue(eid, attr); ok {
			return scheme.Done(v), nil
		}
		return scheme.Done(sexpr.Void{}), nil
	case "lookup-entity":
		attr, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if !h.Engine.IsUniqueAttr(attr) {
			return scheme.EvalStep{}, scheme.EvalError("lookup-entity: attribute is not UNIQUE")
		}
		if eid, ok := h.Engine.LookupEntity(attr, args[1]); ok {
			return scheme.Done(sexpr.Int(eid)), nil
		}
		return scheme.Done(sexpr.Void{}), nil
	case "save":
		eid, err := expectInt(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		attr, err := expectStr(args[1])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if err := h.Engine.SaveWithT(eid, attr, args[2], h.Tx, h.AsOfTx); err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Void{}), nil
	case "save-many":
		if len(args) < 3 || len(args)%2 == 0 {
			return scheme.EvalStep{}, scheme.EvalError("save-many expects an attribute name followed by eid/value pairs")
		}
		attr, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		var pairs []Pair
		for i := 1; i < len(args); i += 2 {
			eid, err := expectInt(args[i])
			if err != nil {
				return scheme.EvalStep{}, err
			}
			pairs = append(pairs, Pair{Eid: eid, Val: args[i+1]})
		}
		if err := h.Engine.SaveManyWithT(attr, pairs, h.Tx, h.AsOfTx); err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Void{}), nil
	case "retract":
		eid, err := expectInt(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		attr, err := expectStr(args[1])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if err := h.Engine.Retract(eid, attr, args[2], h.Tx, h.AsOfTx); err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Void{}), nil
	case "get-or-create-entity":
		attr, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		if !h.Engine.IsUniqueAttr(attr) {
			return scheme.EvalStep{}, scheme.EvalError("get-or-create-entity: attribute is not UNIQUE")
		}
		if found, ok := h.Engine.LookupEntity(attr, args[1]); ok {
			return scheme.Done(sexpr.Int(found)), nil
		}
		partition := uint64(4)
		if len(args) > 2 {
			n, err := expectInt(args[2])
			if err != nil {
				return scheme.EvalStep{}, err
			}
			partition = uint64(n)
		}
		eid := h.Engine.AllocateInPartition(partition)
		if err := h.Engine.SaveWithT(eid, attr, args[1], h.Tx, h.AsOfTx); err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Int(eid)), nil
	case "declare-attr":
		attr, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		vtName, err := expectStr(args[1])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		many := len(args) > 2 && args[2] == sexpr.Bool(true)
		unique := len(args) > 3 && args[3] == sexpr.Bool(true)
		if err := h.Engine.DeclareAttrFromSQL(attr, vtName, many, unique, h.Tx); err != nil {
			return scheme.EvalStep{}, err
		}
		return scheme.Done(sexpr.Void{}), nil
	case "declare-partition":
		name, err := expectStr(args[0])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		pid := h.Engine.DeclarePartition(name, h.Tx)
		return scheme.Done(sexpr.Int(int64(pid))), nil
	case "alloc-entity":
		partition := uint64(4)
		if len(args) > 0 {
			n, err := expectInt(args[0])
			if err != nil {
				return scheme.EvalStep{}, err
			}
			partition = uint64(n)
		}
		return scheme.Done(sexpr.Int(h.Engine.AllocateInPartition(partition))), nil
	case "tx-entity":
		return scheme.Done(sexpr.Int(h.Tx)), nil
	case "dbg-scanners":
		for i, sc := range h.Scanners {
			fmt.Printf("scanner[%d] at_end=%v\n", i, sc.AtEnd())
		}
		return scheme.Done(sexpr.Void{}), nil
	case "ranges-show":
		specs := parseRanges(args[0])
		if len(specs) == 0 {
			return scheme.Done(sexpr.Str("(-inf, +inf)")), nil
		}
		return scheme.Done(sexpr.Str(fmt.Sprintf("%d specs", len(specs)))), nil
	}
	return scheme.EvalStep{}, scheme.EvalError("unknown host function: " + name)
}

func (h *SchemeHostFns) scannerOpen(args []sexpr.Expr) (scheme.EvalStep, error) {
	idxName, err := expectStr(args[0])
	if err != nil {
		return scheme.EvalStep{}, err
	}
	history := len(args) > 1 && args[1] == sexpr.Bool(true)
	upper := toUpper(idxName)
	var baseOrder []string
	switch upper {
	case "EAVT":
		baseOrder = []string{"e", "a", "v"}
	case "AEVT":
		baseOrder = []string{"a", "e", "v"}
	case "AVET":
		baseOrder = []string{"a", "v", "e"}
	case "VAET":
		baseOrder = []string{"v", "a", "e"}
	default:
		baseOrder = []string{"e", "a", "v"}
	}
	idxOrder := append(append([]string{}, baseOrder...), "t", "added")

	sc := NewV2Scanner(idxName, idxOrder, h.AsOfTx, h.HasAsOfTx)
	if history {
		sc.HistoryMode = true
	}
	var cfID uint32
	switch upper {
	case "AEVT":
		cfID = 1
	case "AVET":
		cfID = 2
	case "VAET":
		cfID = 3
	}
	sc.SetCursor(h.Engine.OpenCursor(cfID, nil, history || h.HasAsOfTx))
	sc.AdvanceToActiveAt()
	rid := h.pushScanner(sc)
	return scheme.Done(sexpr.Resource(rid)), nil
}

func (h *SchemeHostFns) scannerIterateInit(args []sexpr.Expr) (scheme.EvalStep, error) {
	if len(args) == 0 {
		return scheme.Done(sexpr.Void{}), nil
	}
	var scanners []*V2Scanner
	for i := 0; i < len(args)-1; i++ {
		sc, err := h.findScanner(args[i])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		scanners = append(scanners, sc)
	}
	rangesSexpr := args[len(args)-1]
	if len(scanners) == 0 {
		return scheme.Done(sexpr.Void{}), nil
	}
	for _, sc := range scanners {
		vtOpt, ok := sc.AttrIDFromPrefixBytes()
		var vt uint32
		hasVt := false
		if ok {
			vt, hasVt = h.Engine.ValueTypeFor(vtOpt)
		}
		sc.SetValueAttrType(vt, hasVt)
		sc.AdvanceToActiveAtPreserving()
		if !sc.hasValueAttr {
			if aid, ok := sc.AttrIDFromKey(); ok {
				if v, ok := h.Engine.ValueTypeFor(aid); ok {
					sc.SetValueAttrType(v, true)
				}
			}
		}
	}
	specs := parseRanges(rangesSexpr)
	it := &LeapIterator{Scanners: scanners, Specs: specs}
	idx := len(h.LeapIters)
	h.LeapIters[idx] = it
	return scheme.Done(sexpr.Resource(idx)), nil
}

func (h *SchemeHostFns) scannerIterateNext(args []sexpr.Expr) (scheme.EvalStep, error) {
	iter, err := h.findLeapIterator(args[0])
	if err != nil {
		return scheme.EvalStep{}, err
	}
	if len(iter.Scanners) == 0 {
		return scheme.Done(sexpr.Void{}), nil
	}
	if !iter.Started {
		if !convergeWithRanges(iter.Scanners, iter.Specs) {
			return scheme.Done(sexpr.Void{}), nil
		}
		iter.Started = true
	} else {
		minIdx := 0
		var minVal sexpr.Expr
		hasMin := false
		for i, sc := range iter.Scanners {
			v, ok := sc.ExtractCurrent()
			if !hasMin {
				minVal, hasMin = v, ok
				minIdx = i
			} else if ok && (!hasMin || scheme.CmpValue(v, minVal) < 0) {
				minVal, hasMin = v, true
				minIdx = i
			}
		}
		iter.Scanners[minIdx].LeapNextAt()
		if iter.Scanners[minIdx].AtEnd() {
			return scheme.Done(sexpr.Void{}), nil
		}
		if !convergeWithRanges(iter.Scanners, iter.Specs) {
			return scheme.Done(sexpr.Void{}), nil
		}
	}
	if v, ok := iter.Scanners[0].ExtractCurrent(); ok {
		return scheme.Done(v), nil
	}
	return scheme.Done(sexpr.Void{}), nil
}

func (h *SchemeHostFns) scannerLeapInit(args []sexpr.Expr) (scheme.EvalStep, error) {
	if len(args) < 2 {
		return scheme.Done(sexpr.Bool(false)), nil
	}
	var scanners []*V2Scanner
	for i := 1; i < len(args)-1; i++ {
		sc, err := h.findScanner(args[i])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		scanners = append(scanners, sc)
	}
	specs := parseRanges(args[len(args)-1])
	return scheme.Done(sexpr.Bool(convergeWithRanges(scanners, specs))), nil
}

func (h *SchemeHostFns) scannerLeapNext(args []sexpr.Expr) (scheme.EvalStep, error) {
	if len(args) < 2 {
		return scheme.Done(sexpr.Bool(false)), nil
	}
	var scanners []*V2Scanner
	for i := 1; i < len(args)-1; i++ {
		sc, err := h.findScanner(args[i])
		if err != nil {
			return scheme.EvalStep{}, err
		}
		scanners = append(scanners, sc)
	}
	if len(scanners) == 0 {
		return scheme.Done(sexpr.Bool(false)), nil
	}
	specs := parseRanges(args[len(args)-1])
	minIdx := 0
	var minVal sexpr.Expr
	hasMin := false
	for i, sc := range scanners {
		v, ok := sc.ExtractCurrent()
		if !hasMin {
			minVal, hasMin, minIdx = v, ok, i
		} else if ok && scheme.CmpValue(v, minVal) < 0 {
			minVal, minIdx = v, i
		}
	}
	scanners[minIdx].LeapNextAt()
	if scanners[minIdx].AtEnd() {
		return scheme.Done(sexpr.Bool(false)), nil
	}
	return scheme.Done(sexpr.Bool(convergeWithRanges(scanners, specs))), nil
}

// ── leapfrog convergence ─────────────────────────────────────────────────

func leapConverge(scanners []*V2Scanner) bool {
	maxIters := len(scanners)*2 + 1
	for iter := 0; iter < maxIters; iter++ {
		var maxVal sexpr.Expr
		hasMax := false
		allEqual := true
		var atEnd []int
		for i, sc := range scanners {
			v, ok := sc.ExtractCurrent()
			if ok {
				if !hasMax {
					maxVal, hasMax = v, true
				} else if scheme.CmpValue(v, maxVal) != 0 {
					allEqual = false
					if scheme.CmpValue(v, maxVal) > 0 {
						maxVal = v
					}
				}
			} else {
				atEnd = append(atEnd, i)
				allEqual = false
			}
		}
		if allEqual {
			return true
		}
		if hasMax {
			for i, sc := range scanners {
				needsSeek := false
				cv, ok := sc.ExtractCurrent()
				if ok && scheme.CmpValue(cv, maxVal) < 0 {
					needsSeek = true
				}
				for _, ai := range atEnd {
					if ai == i {
						needsSeek = true
					}
				}
				if needsSeek {
					sc.SeekToValue(maxVal)
					if sc.AtEnd() {
						return false
					}
				}
			}
		} else {
			return false
		}
	}
	return false
}

// ParseRanges parses the list of [lo, hi, flags] triples emitted by ranges-create.
func parseRanges(e sexpr.Expr) []ByteRangeSpec {
	var out []ByteRangeSpec
	l, ok := e.(sexpr.List)
	if !ok {
		return out
	}
	for _, item := range l {
		il, ok := item.(sexpr.List)
		if !ok || len(il) != 3 {
			continue
		}
		flagsRaw, ok := il[2].(sexpr.Int)
		if !ok {
			continue
		}
		var spec ByteRangeSpec
		spec.Flags = int32(int64(flagsRaw))
		if b, ok := il[0].(sexpr.Bytes); ok {
			spec.Lo = append([]byte(nil), b...)
			spec.HasLo = true
		}
		if b, ok := il[1].(sexpr.Bytes); ok {
			spec.Hi = append([]byte(nil), b...)
			spec.HasHi = true
		}
		out = append(out, spec)
	}
	return out
}

func valueInSpecsBytes(cur []byte, specs []ByteRangeSpec) bool {
	if len(specs) == 0 {
		return true
	}
	if len(specs) == 1 && specs[0].Flags == -1 {
		return false
	}
	for _, spec := range specs {
		if spec.Flags == -1 {
			return false
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
		return true
	}
	return false
}

// ApplyRanges is a pure predicate: does the current value satisfy specs?
func applyRanges(scanners []*V2Scanner, specs []ByteRangeSpec) bool {
	if len(specs) == 0 {
		return true
	}
	if len(specs) == 1 && specs[0].Flags == -1 {
		return false
	}
	if len(scanners) == 0 {
		return false
	}
	cur, ok := scanners[0].CurrentValueBytes()
	if !ok {
		return false
	}
	return valueInSpecsBytes(cur, specs)
}

func convergeWithRanges(scanners []*V2Scanner, specs []ByteRangeSpec) bool {
	if !leapConverge(scanners) {
		return false
	}
	if len(specs) == 0 {
		return true
	}
	if len(specs) == 1 && specs[0].Flags == -1 {
		return false
	}
	maxIter := len(specs) + 30
	for iter := 0; iter < maxIter; iter++ {
		res, propose, hasPropose := scanners[0].ValidateOrProposeNextElementBytes(specs)
		switch res {
		case VrValid:
			return true
		case VrAtEnd:
			return false
		case VrPropose:
			if hasPropose {
				scanners[0].SeekToBytes(propose)
				if scanners[0].AtEnd() {
					return false
				}
				loOpenProposed := false
				for _, spec := range specs {
					if spec.HasLo && cmpBytes(spec.Lo, propose) == 0 && spec.Flags&RangeLoOpen != 0 {
						loOpenProposed = true
						break
					}
				}
				if loOpenProposed {
					if cur2, ok := scanners[0].CurrentValueBytes(); ok && cmpBytes(cur2, propose) == 0 {
						scanners[0].LeapNextAt()
						if scanners[0].AtEnd() {
							return false
						}
					}
				}
				if !leapConverge(scanners) {
					return false
				}
			} else {
				minIdx := 0
				var minVal []byte
				hasMin := false
				for i, sc := range scanners {
					v, ok := sc.CurrentValueBytes()
					if ok {
						if !hasMin || cmpBytes(v, minVal) < 0 {
							minVal, hasMin = v, true
							minIdx = i
						}
					} else {
						minIdx = i
						break
					}
				}
				scanners[minIdx].LeapNextAt()
				if scanners[minIdx].AtEnd() {
					return false
				}
				if !leapConverge(scanners) {
					return false
				}
			}
		}
	}
	return false
}
