// Package datalog ports the Nim Datalog query pipeline: EDN reader → IR →
// resolve → cost-based planner → Scheme compiler.  It mirrors the OCaml port
// (itself byte-identical to the Nim compiler over 25 golden vectors).
package datalog

import "strings"

// ── IR ───────────────────────────────────────────────────────────────────

// BoundValue is a resolved or literal value in a slot.
type BoundValue interface{ isBoundValue() }

type (
	BvInt          int64
	BvFloat        float64
	BvStr          string
	BvAttr         string
	BvResolvedAttr struct {
		ID               int32
		Name             string
		IsRef, IsIndexed bool
	}
	BvVar     string
	BvMissing string
	BvParam   int32
	BvBool    bool
)

func (BvInt) isBoundValue()          {}
func (BvFloat) isBoundValue()        {}
func (BvStr) isBoundValue()          {}
func (BvAttr) isBoundValue()         {}
func (BvResolvedAttr) isBoundValue() {}
func (BvVar) isBoundValue()          {}
func (BvMissing) isBoundValue()      {}
func (BvParam) isBoundValue()        {}
func (BvBool) isBoundValue()         {}

// Slot is one pattern position.
type Slot interface{ isSlot() }

type (
	DsVar     string
	DsConst   struct{ V BoundValue }
	DsMissing struct{}
)

func (DsVar) isSlot()     {}
func (DsConst) isSlot()   {}
func (DsMissing) isSlot() {}

// Pattern is an [e a v t added] tuple.
type Pattern struct{ E, A, V, T, Added Slot }

// SlotAt returns the slot at the named position ("e".."added").
func (p Pattern) SlotAt(pos string) Slot {
	switch pos {
	case "e":
		return p.E
	case "a":
		return p.A
	case "v":
		return p.V
	case "t":
		return p.T
	case "added":
		return p.Added
	}
	return p.T
}

// FindVar is one :find projection element.
type FindVar interface{ isFindVar() }

type (
	FvVar   string
	FvConst struct {
		Name string
		V    BoundValue
	}
)

func (FvVar) isFindVar()   {}
func (FvConst) isFindVar() {}

// RangeCond is one predicate (op, value).
type RangeCond struct {
	Op string
	V  BoundValue
}

// RangeBound is the disjunction-of-branches for one var.
type RangeBound struct {
	Var      string
	Branches [][]RangeCond
}

// IR is the parsed Datalog query.
type IR struct {
	Patterns      []Pattern
	FindVars      []FindVar
	RangeBounds   []RangeBound
	Star          bool
	ExistsMode    bool
	HasConditions bool
	History       bool
}

// NewIR returns an empty IR.
func NewIR() *IR { return &IR{} }

// RangeLookup finds the branches for a variable.
func (ir *IR) RangeLookup(name string) ([][]RangeCond, bool) {
	for _, rb := range ir.RangeBounds {
		if rb.Var == name {
			return rb.Branches, true
		}
	}
	return nil, false
}

// RangeSet replaces the branches for a variable (appending when new).
func (ir *IR) RangeSet(name string, v [][]RangeCond) {
	for i := range ir.RangeBounds {
		if ir.RangeBounds[i].Var == name {
			ir.RangeBounds[i].Branches = v
			return
		}
	}
	ir.RangeBounds = append(ir.RangeBounds, RangeBound{Var: name, Branches: v})
}

// ── pattern helpers ──────────────────────────────────────────────────────

// IndexDef is a named index order.
type IndexDef struct {
	Name  string
	Order []string
}

// IndexOrders are the four planner index orders.
var IndexOrders = []IndexDef{
	{"EAVT", []string{"e", "a", "v", "t", "added"}},
	{"AEVT", []string{"a", "e", "v", "t", "added"}},
	{"AVET", []string{"a", "v", "e", "t", "added"}},
	{"VAET", []string{"v", "a", "e", "t", "added"}},
}

// IndexEntry returns the order for an index name (default EAV).
func IndexEntry(name string) []string {
	switch strings.ToUpper(name) {
	case "EAVT":
		return IndexOrders[0].Order
	case "AEVT":
		return IndexOrders[1].Order
	case "AVET":
		return IndexOrders[2].Order
	case "VAET":
		return IndexOrders[3].Order
	}
	return []string{"e", "a", "v"}
}

// IsLookup reports whether a pattern is fully bound (e, a and v const,
// with no missing bindings).
func IsLookup(p Pattern) bool {
	for _, s := range []Slot{p.E, p.A, p.V} {
		c, ok := s.(DsConst)
		if !ok {
			return false
		}
		if _, missing := c.V.(BvMissing); missing {
			return false
		}
	}
	return true
}

// ContainsVarInEAV reports whether varName appears in the e/a/v/t/added slots.
func ContainsVarInEAV(p Pattern, varName string) bool {
	for _, s := range []Slot{p.E, p.A, p.V, p.T, p.Added} {
		if v, ok := s.(DsVar); ok && string(v) == varName {
			return true
		}
	}
	return false
}
