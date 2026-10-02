// planner.go — cost-based join ordering, mirroring nim_planner/planner.nim
// (+ planner_ast.nim types).  The wire output depends on bestOrdering,
// clauseIndexes, orderedVars (with skip-var insertion), iterPlans and
// syntheticVars — the search must reproduce the Nim tie-breaking and cost
// arithmetic exactly.
package datalog

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

// ── planner_ast types ────────────────────────────────────────────────────

// PlanValue is a bound value carried by the planner.
type PlanValue interface{ isPlanValue() }

type (
	PvValue struct {
		Int   int64
		Float float64
		Str   string
	}
	PvParam int32
)

func (PvValue) isPlanValue() {}
func (PvParam) isPlanValue() {}

func pvInt(i int64) PlanValue     { return PvValue{Int: i} }
func pvFloat(f float64) PlanValue { return PvValue{Float: f} }
func pvStr(s string) PlanValue    { return PvValue{Str: s} }

// SpecKind is one slot spec in an iter plan.
type SpecKind interface{ isSpecKind() }

type (
	SkVar        string
	SkBound      int64
	SkBoundAttr  int32
	SkBoundValue struct {
		Int   int64
		Float float64
		Str   string
	}
	SkBoundParam int32
)

func (SkVar) isSpecKind()        {}
func (SkBound) isSpecKind()      {}
func (SkBoundAttr) isSpecKind()  {}
func (SkBoundValue) isSpecKind() {}
func (SkBoundParam) isSpecKind() {}

// ActiveClause records a clause participating in a depth.
type ActiveClause struct {
	Ci    int
	Index string
}

// DepthTrace is one step of an ordering trace.
type DepthTrace struct {
	VarName           string
	ActiveClauses     []ActiveClause
	EstimatedElements float64
	IsBlind           bool
	StepCost          float64
	Penalty           bool
}

// PlanTrace is one explored ordering.
type PlanTrace struct {
	Ordering  []string
	Depths    []DepthTrace
	TotalCost float64
	Pruned    bool
	Chosen    bool
}

// SyntheticVar is a derived variable for a repeated occurrence.
type SyntheticVar struct {
	Name       string
	SourceVar  string
	PatternIdx int
	Position   string
}

// BoundInt is an ordered (position, value) binding.
type BoundInt struct {
	Pos string
	V   PlanValue
}

// DepthPos is a (depth, position) binding.
type DepthPos struct {
	Depth int
	Pos   string
}

// SameVarConstraint groups positions sharing one depth.
type SameVarConstraint struct {
	Depth     int
	Positions []string
}

// IterPlanData is one scanner plan.
type IterPlanData struct {
	IndexName          string
	IdxOrder           []string
	Specs              []SpecKind
	BoundInts          []BoundInt
	VarDepths          []DepthPos
	SameVarConstraints []SameVarConstraint
	ActiveDepths       []int
	GlobalVarOrder     []string
	AttrIsIndexed      bool
}

// PlanCond is a converted range condition.
type PlanCond struct {
	Op string
	V  PlanValue
}

// ConvertedRangeBound is one variable's converted branches.
type ConvertedRangeBound struct {
	Var      string
	Branches [][]PlanCond
}

// QueryPlanResult is the planner output.
type QueryPlanResult struct {
	IterPlans     []IterPlanData
	Lookups       []Pattern
	JoinPatterns  []Pattern
	OrderedVars   []string
	EVars         []string
	AttrVars      []string
	TLookupVars   []string
	VarOrder      []string
	PlanTraces    []*PlanTrace
	History       bool
	ExistsMode    bool
	FindVars      []FindVar
	RangeBounds   []ConvertedRangeBound
	SyntheticVars []SyntheticVar
}

// ── bound-value conversion ───────────────────────────────────────────────

func fromBoundValue(bv BoundValue) (PlanValue, bool) {
	switch v := bv.(type) {
	case BvInt:
		return pvInt(int64(v)), true
	case BvFloat:
		return pvFloat(float64(v)), true
	case BvStr:
		return pvStr(string(v)), true
	case BvAttr:
		return pvStr(string(v)), true
	case BvResolvedAttr:
		return pvInt(int64(v.ID)), true
	case BvParam:
		return PvParam(v), true
	case BvBool:
		if bool(v) {
			return pvInt(1), true
		}
		return pvInt(0), true
	}
	return nil, false
}

func convertRangeBounds(bounds []RangeBound) []ConvertedRangeBound {
	out := make([]ConvertedRangeBound, 0, len(bounds))
	for _, rb := range bounds {
		branches := make([][]PlanCond, len(rb.Branches))
		for i, branch := range rb.Branches {
			var conds []PlanCond
			for _, c := range branch {
				if pv, ok := fromBoundValue(c.V); ok {
					conds = append(conds, PlanCond{Op: c.Op, V: pv})
				}
			}
			branches[i] = conds
		}
		out = append(out, ConvertedRangeBound{Var: rb.Var, Branches: branches})
	}
	return out
}

// ── index selection ──────────────────────────────────────────────────────

func isSlotBound(slot Slot, boundVars map[string]bool) bool {
	switch s := slot.(type) {
	case DsMissing:
		return false
	case DsConst:
		if _, missing := s.V.(BvMissing); missing {
			return false
		}
		return true
	case DsVar:
		return boundVars[string(s)]
	}
	return false
}

func isPrefixOK(slot Slot, boundVars map[string]bool) bool {
	switch s := slot.(type) {
	case DsMissing:
		return true
	case DsConst:
		return true
	case DsVar:
		return boundVars[string(s)]
	}
	return false
}

func targetPosOf(p Pattern, varName string) string {
	for _, pos := range []string{"e", "a", "v", "t", "added"} {
		if v, ok := p.SlotAt(pos).(DsVar); ok && string(v) == varName {
			return pos
		}
	}
	return ""
}

func findBestIndex(p Pattern, varName string, boundVars map[string]bool, refAttrs map[string]bool) (string, int, int) {
	targetPos := targetPosOf(p, varName)
	if targetPos == "" {
		return "", 0, 0
	}
	attrIsRef := false
	if c, ok := p.A.(DsConst); ok {
		if ra, ok := c.V.(BvResolvedAttr); ok {
			attrIsRef = ra.IsRef
		}
	}
	attrIsIndexed := true
	if c, ok := p.A.(DsConst); ok {
		if ra, ok := c.V.(BvResolvedAttr); ok {
			attrIsIndexed = ra.IsIndexed
		}
	}

	bestName := ""
	bestPrefix := 0
	bestGap := 0
	bestInited := false
	for _, idx := range IndexOrders {
		if idx.Name == "VAET" && !attrIsRef {
			continue
		}
		if idx.Name == "AVET" && !attrIsIndexed {
			continue
		}
		posInIdx := indexOf(idx.Order, targetPos)
		if posInIdx < 0 {
			continue
		}
		valid := true
		for pi := 0; pi < posInIdx; pi++ {
			if !isPrefixOK(p.SlotAt(idx.Order[pi]), boundVars) {
				valid = false
				break
			}
		}
		if !valid {
			continue
		}
		prefixLen := 0
		for pi := 0; pi < posInIdx; pi++ {
			if isSlotBound(p.SlotAt(idx.Order[pi]), boundVars) {
				prefixLen++
			} else {
				break
			}
		}
		gapCount := 0
		for pi := 0; pi < posInIdx; pi++ {
			if _, ok := p.SlotAt(idx.Order[pi]).(DsMissing); ok {
				gapCount++
			}
		}
		if !bestInited || prefixLen > bestPrefix || (prefixLen == bestPrefix && gapCount < bestGap) {
			bestName = idx.Name
			bestPrefix = prefixLen
			bestGap = gapCount
			bestInited = true
		}
	}
	if !bestInited {
		return "", 0, 0
	}
	return bestName, bestPrefix, bestGap
}

func isVarReachableInIndex(p Pattern, varName, indexName string, boundVars map[string]bool) bool {
	targetPos := targetPosOf(p, varName)
	if targetPos == "" {
		return false
	}
	idxEntry := IndexEntry(indexName)
	posInIdx := indexOf(idxEntry, targetPos)
	if posInIdx < 0 {
		return false
	}
	for pi := 0; pi < posInIdx; pi++ {
		if !isSlotBound(p.SlotAt(idxEntry[pi]), boundVars) {
			return false
		}
	}
	return true
}

// ── the ordering search ──────────────────────────────────────────────────

type searchState struct {
	bestOrdering      []string
	bestClauseIndexes []string
	bestCost          float64
	traces            []*PlanTrace
}

type searchEnv struct {
	clauses       []Pattern
	findSet       map[string]bool
	rangeVars     map[string]bool
	totalRecords  float64
	stats         *planStats
	joinIndices   []int
	refAttrs      map[string]bool
	syntheticVars []SyntheticVar
	synthByName   map[string]SyntheticVar
}

func varPriority(name string) int {
	switch {
	case strings.HasPrefix(name, "?e_"):
		return 0
	case strings.HasPrefix(name, "?a_"):
		return 1
	case strings.HasPrefix(name, "?v"):
		return 2
	case strings.HasPrefix(name, "_t_"):
		return 3
	case strings.HasPrefix(name, "?added_"):
		return 4
	}
	return 5
}

func candidateCmp(a, b string, findSet map[string]bool) int {
	ba, bb := 0, 0
	if findSet[a] {
		ba = 1
	}
	if findSet[b] {
		bb = 1
	}
	if c := bb - ba; c != 0 {
		return c
	}
	if pa, pb := varPriority(a), varPriority(b); pa != pb {
		return pa - pb
	}
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func exploreOrderingDepth(env *searchEnv, remaining []string, bound []string,
	clauseIndexMap []string, accumulated, topElements float64,
	state *searchState, path []string, depthTraces []DepthTrace) {

	boundSet := make(map[string]bool, len(bound))
	for _, v := range bound {
		boundSet[v] = true
	}

	if len(remaining) == 0 {
		state.traces = append(state.traces, &PlanTrace{
			Ordering: copySlice(path), Depths: copyDepthTraces(depthTraces),
			TotalCost: accumulated, Pruned: false, Chosen: false,
		})
		if accumulated < state.bestCost {
			state.bestCost = accumulated
			state.bestOrdering = copySlice(path)
			state.bestClauseIndexes = copySlice(clauseIndexMap)
		}
		return
	}
	if accumulated >= state.bestCost {
		state.traces = append(state.traces, &PlanTrace{
			Ordering: copySlice(path), Depths: copyDepthTraces(depthTraces),
			TotalCost: accumulated, Pruned: true, Chosen: false,
		})
		return
	}

	candidates := copySlice(remaining)
	sort.SliceStable(candidates, func(i, j int) bool {
		return candidateCmp(candidates[i], candidates[j], env.findSet) < 0
	})

	for _, currentVar := range candidates {
		if synth, ok := env.synthByName[currentVar]; ok && !boundSet[synth.SourceVar] {
			continue
		}
		var activeClauses []ActiveClause
		var clauseSizes []float64
		newClauseIndexes := copySlice(clauseIndexMap)
		totalGaps := 0
		for ci, clause := range env.clauses {
			if !ContainsVarInEAV(clause, currentVar) {
				continue
			}
			if assigned := clauseIndexMap[ci]; assigned != "" {
				if isVarReachableInIndex(clause, currentVar, assigned, boundSet) {
					activeClauses = append(activeClauses, ActiveClause{Ci: ci, Index: assigned})
					clauseSizes = append(clauseSizes, env.stats.estimate(env.joinIndices[ci], assigned, currentVar))
				}
			} else {
				bestName, _, bestGap := findBestIndex(clause, currentVar, boundSet, env.refAttrs)
				if bestName != "" {
					activeClauses = append(activeClauses, ActiveClause{Ci: ci, Index: bestName})
					newClauseIndexes[ci] = bestName
					clauseSizes = append(clauseSizes, env.stats.estimate(env.joinIndices[ci], bestName, currentVar))
					totalGaps += bestGap
				}
			}
		}
		isBlind := len(activeClauses) == 0
		rangeSel := 1.0
		if env.rangeVars[currentVar] {
			rangeSel = 0.1
		}
		depth := len(path)

		var levelElements, stepCost float64
		if _, isSynth := env.synthByName[currentVar]; isSynth {
			levelElements = topElements
			stepCost = float64(depth) * 0.1
		} else if isBlind {
			el := env.totalRecords * rangeSel
			levelElements = el
			if depth == 0 {
				stepCost = el * el
			} else {
				stepCost = topElements * el
			}
		} else {
			el := math.Inf(1)
			for _, s := range clauseSizes {
				if s < el {
					el = s
				}
			}
			el *= rangeSel
			undefPenalty := 1.0
			for _, ac := range activeClauses {
				cl := env.clauses[ac.Ci]
				undefCount := 0
				for _, s := range []Slot{cl.E, cl.A, cl.V} {
					if v, ok := s.(DsVar); ok && string(v) != currentVar && !boundSet[string(v)] {
						undefCount++
					}
				}
				if undefCount > 0 {
					p := 1.0 + float64(undefCount)
					if p > undefPenalty {
						undefPenalty = p
					}
				}
			}
			levelElements = el
			stepCost = el * float64(len(activeClauses)) * undefPenalty * (1.0 + float64(totalGaps))
		}

		newPath := append(copySlice(path), currentVar)
		newDepths := append(copyDepthTraces(depthTraces), DepthTrace{
			VarName: currentVar, ActiveClauses: activeClauses,
			EstimatedElements: levelElements, IsBlind: isBlind, StepCost: stepCost,
		})
		newBound := append(copySlice(bound), currentVar)
		var newRemaining []string
		for _, v := range remaining {
			if v != currentVar {
				newRemaining = append(newRemaining, v)
			}
		}
		exploreOrderingDepth(env, newRemaining, newBound, newClauseIndexes,
			accumulated+stepCost, levelElements, state, newPath, newDepths)
	}
}

// ── iter plans ───────────────────────────────────────────────────────────

func firstn(n int, l []string) []string {
	var out []string
	for i := 0; i < len(l) && i < n; i++ {
		out = append(out, l[i])
	}
	return out
}

func boundPositionsBefore(ip IterPlanData, depth int) []BoundInt {
	cutoff := len(ip.IdxOrder)
	for _, dp := range ip.VarDepths {
		if dp.Depth == depth {
			if idx := indexOf(ip.IdxOrder, dp.Pos); idx >= 0 {
				cutoff = idx
			} else {
				cutoff = len(ip.IdxOrder)
			}
			break
		}
	}
	var out []BoundInt
	for i := 0; i < cutoff && i < len(ip.IdxOrder); i++ {
		pos := ip.IdxOrder[i]
		if pos == "added" {
			continue
		}
		if pv, ok := assocBoundInt(ip.BoundInts, pos); ok {
			out = append(out, BoundInt{Pos: pos, V: pv})
		}
	}
	return out
}

func allBoundPositions(ip IterPlanData) []BoundInt {
	var out []BoundInt
	for _, pos := range ip.IdxOrder {
		if pos == "added" {
			continue
		}
		if pv, ok := assocBoundInt(ip.BoundInts, pos); ok {
			out = append(out, BoundInt{Pos: pos, V: pv})
		}
	}
	return out
}

func assocBoundInt(l []BoundInt, pos string) (PlanValue, bool) {
	for _, b := range l {
		if b.Pos == pos {
			return b.V, true
		}
	}
	return nil, false
}

// ── buildQueryPlan ───────────────────────────────────────────────────────

func buildIterPlan(p Pattern, patternIdx int, idxName string, boundInts []BoundInt,
	globalVarOrder []string, syntheticVars []SyntheticVar) IterPlanData {

	idxEntry := IndexEntry(idxName)
	idxOrder := copySlice(idxEntry)

	synthNameFor := func(pos string) string {
		for _, s := range syntheticVars {
			if s.PatternIdx == patternIdx && s.Position == pos {
				return s.Name
			}
		}
		return ""
	}

	slots := []Slot{p.E, p.A, p.V, p.T, p.Added}
	specs := make([]SpecKind, 5)
	for i, s := range slots {
		switch v := s.(type) {
		case DsMissing:
			specs[i] = SkBound(0)
		case DsVar:
			specs[i] = SkVar(string(v))
		case DsConst:
			switch bv := v.V.(type) {
			case BvInt:
				specs[i] = SkBoundValue{Int: int64(bv)}
			case BvFloat:
				specs[i] = SkBoundValue{Float: float64(bv)}
			case BvStr:
				specs[i] = SkBoundValue{Str: string(bv)}
			case BvAttr:
				specs[i] = SkBoundValue{Str: string(bv)}
			case BvResolvedAttr:
				specs[i] = SkBoundAttr(bv.ID)
			case BvParam:
				specs[i] = SkBoundParam(bv)
			case BvVar:
				specs[i] = SkVar(string(bv))
			default:
				specs[i] = SkBound(0)
			}
		}
	}

	var varDepths []DepthPos
	var sameVarConstraints []SameVarConstraint
	activeDepthsSet := map[int]bool{}
	seenRealVar := false

	for _, pos := range idxEntry {
		specIdx := indexOf([]string{"e", "a", "v", "t", "added"}, pos)
		if specIdx < 0 {
			continue
		}
		switch sl := p.SlotAt(pos).(type) {
		case DsVar:
			varName := string(sl)
			seenRealVar = true
			syntheticName := synthNameFor(pos)
			effectiveName := varName
			if syntheticName != "" {
				effectiveName = syntheticName
			}
			foundDepth := indexOf(globalVarOrder, effectiveName)
			if foundDepth >= 0 {
				if !activeDepthsSet[foundDepth] {
					varDepths = append(varDepths, DepthPos{Depth: foundDepth, Pos: pos})
					activeDepthsSet[foundDepth] = true
					if effectiveName != varName {
						specs[specIdx] = SkVar(effectiveName)
					}
				} else {
					sameVarConstraints = setSameVarConstraint(sameVarConstraints, foundDepth, pos)
				}
			}
		case DsMissing:
			if !seenRealVar {
				synthName := "?skip_" + pos + "_" + strings.ToLower(idxEntry[0])
				foundDepth := indexOf(globalVarOrder, synthName)
				if foundDepth >= 0 && !activeDepthsSet[foundDepth] {
					varDepths = append(varDepths, DepthPos{Depth: foundDepth, Pos: pos})
					activeDepthsSet[foundDepth] = true
					specs[specIdx] = SkVar(synthName)
				}
			}
		}
	}

	varDepthsSorted := copyDepthPos(varDepths)
	sort.SliceStable(varDepthsSorted, func(i, j int) bool {
		return varDepthsSorted[i].Depth < varDepthsSorted[j].Depth
	})

	var filtered []DepthPos
	for _, dp := range varDepthsSorted {
		sl := p.SlotAt(dp.Pos)
		if _, ok := sl.(DsVar); !ok {
			filtered = append(filtered, dp)
			continue
		}
		resolved := firstn(dp.Depth, globalVarOrder)
		resolvedSet := make(map[string]bool, len(resolved))
		for _, v := range resolved {
			resolvedSet[v] = true
		}
		idxEntry2 := IndexEntry(idxName)
		posInIdx := indexOf(idxEntry2, dp.Pos)
		if posInIdx < 0 {
			continue
		}
		ok := true
		for pi := 0; pi < posInIdx; pi++ {
			if !isPrefixOK(p.SlotAt(idxEntry2[pi]), resolvedSet) {
				ok = false
				break
			}
		}
		if ok {
			filtered = append(filtered, dp)
		}
	}

	var activeDepths []int
	for _, dp := range filtered {
		if len(activeDepths) > 0 && activeDepths[len(activeDepths)-1] == dp.Depth {
			continue
		}
		activeDepths = append(activeDepths, dp.Depth)
	}

	attrIsIndexed := true
	if c, ok := p.A.(DsConst); ok {
		if ra, ok := c.V.(BvResolvedAttr); ok {
			attrIsIndexed = ra.IsIndexed
		}
	}

	// same_var_constraints was built by prepending replacements; reverse it.
	rev := make([]SameVarConstraint, 0, len(sameVarConstraints))
	for i := len(sameVarConstraints) - 1; i >= 0; i-- {
		rev = append(rev, sameVarConstraints[i])
	}

	return IterPlanData{
		IndexName:          idxName,
		IdxOrder:           idxOrder,
		Specs:              specs,
		BoundInts:          boundInts,
		VarDepths:          filtered,
		SameVarConstraints: rev,
		ActiveDepths:       activeDepths,
		GlobalVarOrder:     globalVarOrder,
		AttrIsIndexed:      attrIsIndexed,
	}
}

// setSameVarConstraint mirrors OCaml's (depth, positions) :: remove_assoc depth.
func setSameVarConstraint(l []SameVarConstraint, depth int, pos string) []SameVarConstraint {
	var existing []string
	var rest []SameVarConstraint
	for _, c := range l {
		if c.Depth == depth && existing == nil {
			existing = append([]string(nil), c.Positions...)
			continue
		}
		rest = append(rest, c)
	}
	existing = append(existing, pos)
	return append([]SameVarConstraint{{Depth: depth, Positions: existing}}, rest...)
}

// listInsert inserts item before index i (append when i >= len).
func listInsert(l []string, i int, item string) []string {
	out := make([]string, 0, len(l)+1)
	inserted := false
	for n, x := range l {
		if n == i {
			out = append(out, item)
			inserted = true
		}
		out = append(out, x)
	}
	if !inserted {
		out = append(out, item)
	}
	return out
}

// BuildQueryPlan runs the cost-based ordering search and produces iter plans.
func BuildQueryPlan(wherePatterns []Pattern, findVars []string,
	rangeVars []string, stats *planStats) (*QueryPlanResult, error) {

	var lookups []Pattern
	var joinPatterns []Pattern
	var joinIndices []int
	for i, p := range wherePatterns {
		if IsLookup(p) {
			lookups = append(lookups, p)
		} else {
			joinPatterns = append(joinPatterns, p)
			joinIndices = append(joinIndices, i)
		}
	}

	if len(joinPatterns) == 0 {
		var tLookupVars []string
		for _, p := range lookups {
			if n, ok := p.T.(DsVar); ok && !contains(tLookupVars, string(n)) {
				tLookupVars = append(tLookupVars, string(n))
			}
		}
		return &QueryPlanResult{
			Lookups: lookups, JoinPatterns: joinPatterns, TLookupVars: tLookupVars,
			VarOrder: []string{}, EVars: []string{}, AttrVars: []string{},
		}, nil
	}

	seen := map[string]bool{}
	var varOrder []string
	var allVars []string
	var syntheticVars []SyntheticVar

	for patIdx, p := range joinPatterns {
		seenInPattern := map[string]bool{}
		occurrences := map[string][]string{}
		for _, pn := range []struct {
			Name string
			Slot Slot
		}{{"e", p.E}, {"a", p.A}, {"v", p.V}, {"t", p.T}, {"added", p.Added}} {
			v, ok := pn.Slot.(DsVar)
			if !ok {
				continue
			}
			name := string(v)
			occ := occurrences[name]
			occurrences[name] = append(occ, pn.Name)
			if len(occ)+1 > 2 {
				return nil, SyntaxError("variable '" + name +
					"' appears in more than 2 positions in pattern " +
					strconv.Itoa(patIdx) +
					"; only 2 occurrences (same-var confirmation) are supported")
			}
			if !seen[name] {
				seen[name] = true
				varOrder = append(varOrder, name)
				allVars = append(allVars, name)
				seenInPattern[name] = true
			} else if !seenInPattern[name] {
				seenInPattern[name] = true
			} else {
				synthName := name + "@p" + strconv.Itoa(patIdx) + "." + pn.Name
				allVars = append(allVars, synthName)
				syntheticVars = append(syntheticVars, SyntheticVar{
					Name: synthName, SourceVar: name, PatternIdx: patIdx, Position: pn.Name,
				})
			}
		}
	}

	var eVars, attrVars []string
	for _, p := range joinPatterns {
		if n, ok := p.E.(DsVar); ok {
			eVars = append(eVars, string(n))
		}
		if n, ok := p.A.(DsVar); ok {
			attrVars = append(attrVars, string(n))
		}
	}
	eVars = sortedUnique(eVars)
	attrVars = sortedUnique(attrVars)

	findSetMap := map[string]bool{}
	for _, v := range findVars {
		findSetMap[v] = true
	}
	var refAttrs []string
	for _, p := range joinPatterns {
		if c, ok := p.A.(DsConst); ok {
			if ra, ok := c.V.(BvResolvedAttr); ok && ra.IsRef {
				refAttrs = append(refAttrs, ra.Name)
			}
		}
	}
	refAttrs = sortedUnique(refAttrs)
	refSet := map[string]bool{}
	for _, v := range refAttrs {
		refSet[v] = true
	}
	rangeSet := map[string]bool{}
	for _, v := range rangeVars {
		rangeSet[v] = true
	}
	synthByName := map[string]SyntheticVar{}
	for _, s := range syntheticVars {
		synthByName[s.Name] = s
	}

	env := &searchEnv{
		clauses: joinPatterns, findSet: findSetMap, rangeVars: rangeSet,
		totalRecords: stats.TotalEAVT, stats: stats, joinIndices: joinIndices,
		refAttrs: refSet, syntheticVars: syntheticVars, synthByName: synthByName,
	}
	clauseIndexMap := make([]string, len(joinPatterns))
	state := &searchState{bestCost: math.Inf(1)}
	exploreOrderingDepth(env, allVars, nil, clauseIndexMap, 0.0, 1.0, state, nil, nil)

	bestOrderingOrig := state.bestOrdering
	orderedVars := bestOrderingOrig
	if len(orderedVars) == 0 {
		orderedVars = allVars
	}
	clauseIndexes := clauseIndexMap
	if len(state.bestClauseIndexes) > 0 {
		clauseIndexes = state.bestClauseIndexes
	}

	// validation-only patterns
	for patIdx, p := range joinPatterns {
		if clauseIndexes[patIdx] != "" {
			continue
		}
		hasVar := false
		for _, s := range []Slot{p.E, p.A, p.V, p.T, p.Added} {
			if _, ok := s.(DsVar); ok {
				hasVar = true
				break
			}
		}
		if !hasVar && !IsLookup(p) {
			bestIdx := ""
			bestScore := 0
			for _, idx := range IndexOrders {
				score := 0
				for _, pos := range idx.Order {
					if _, ok := p.SlotAt(pos).(DsConst); ok {
						score++
					} else {
						break
					}
				}
				if score > bestScore {
					bestScore = score
					bestIdx = idx.Name
				}
			}
			if bestScore > 0 {
				clauseIndexes[patIdx] = bestIdx
			}
		}
	}

	// pre-compute skip vars for missing gaps
	for patIdx, p := range joinPatterns {
		idxName := clauseIndexes[patIdx]
		if idxName == "" {
			continue
		}
		idxEntry := IndexEntry(idxName)
		firstVarPos := -1
		for i, pos := range idxEntry {
			if _, ok := p.SlotAt(pos).(DsVar); ok {
				firstVarPos = i
				break
			}
		}
		if firstVarPos < 0 {
			continue
		}
		targetVar := string(p.SlotAt(idxEntry[firstVarPos]).(DsVar))
		for posIdx := 0; posIdx < firstVarPos; posIdx++ {
			pos := idxEntry[posIdx]
			if _, ok := p.SlotAt(pos).(DsMissing); !ok {
				continue
			}
			synthName := "?skip_" + pos + "_" + strings.ToLower(idxName)
			if contains(orderedVars, synthName) {
				continue
			}
			found := false
			for vi := 0; vi < len(orderedVars); vi++ {
				if orderedVars[vi] == targetVar {
					orderedVars = listInsert(orderedVars, vi, synthName)
					found = true
					break
				}
			}
			if !found {
				orderedVars = append(orderedVars, synthName)
			}
		}
	}

	var iterPlans []IterPlanData
	for patIdx, p := range joinPatterns {
		idxName := clauseIndexes[patIdx]
		if idxName == "" {
			continue
		}
		var boundInts []BoundInt
		if c, ok := p.E.(DsConst); ok {
			switch v := c.V.(type) {
			case BvInt:
				boundInts = append(boundInts, BoundInt{"e", pvInt(int64(v))})
			case BvStr:
				boundInts = append(boundInts, BoundInt{"e", pvStr(string(v))})
			case BvAttr:
				boundInts = append(boundInts, BoundInt{"e", pvStr(string(v))})
			case BvParam:
				boundInts = append(boundInts, BoundInt{"e", PvParam(v)})
			}
		}
		if c, ok := p.A.(DsConst); ok {
			switch v := c.V.(type) {
			case BvResolvedAttr:
				boundInts = append(boundInts, BoundInt{"a", pvStr(v.Name)})
			case BvStr:
				boundInts = append(boundInts, BoundInt{"a", pvStr(string(v))})
			case BvAttr:
				boundInts = append(boundInts, BoundInt{"a", pvStr(string(v))})
			case BvParam:
				boundInts = append(boundInts, BoundInt{"a", PvParam(v)})
			}
		}
		if c, ok := p.V.(DsConst); ok {
			switch v := c.V.(type) {
			case BvInt:
				boundInts = append(boundInts, BoundInt{"v", pvInt(int64(v))})
			case BvFloat:
				boundInts = append(boundInts, BoundInt{"v", pvFloat(float64(v))})
			case BvStr:
				boundInts = append(boundInts, BoundInt{"v", pvStr(string(v))})
			case BvAttr:
				boundInts = append(boundInts, BoundInt{"v", pvStr(string(v))})
			case BvParam:
				boundInts = append(boundInts, BoundInt{"v", PvParam(v)})
			}
		}
		iterPlans = append(iterPlans, buildIterPlan(p, patIdx, idxName, boundInts, orderedVars, syntheticVars))
	}

	var tLookupVars []string
	for _, p := range lookups {
		if n, ok := p.T.(DsVar); ok && !contains(tLookupVars, string(n)) {
			tLookupVars = append(tLookupVars, string(n))
		}
	}

	var planTraces []*PlanTrace
	for _, trace := range state.traces {
		if trace.Pruned {
			planTraces = append(planTraces, trace)
			continue
		}
		if slicesEqual(bestOrderingOrig, trace.Ordering) {
			trace.Chosen = true
			oldDepths := map[string]DepthTrace{}
			for _, d := range trace.Depths {
				oldDepths[d.VarName] = d
			}
			newDepths := make([]DepthTrace, 0, len(orderedVars))
			for _, vn := range orderedVars {
				if d, ok := oldDepths[vn]; ok {
					newDepths = append(newDepths, d)
				} else {
					newDepths = append(newDepths, DepthTrace{VarName: vn})
				}
			}
			trace.Depths = newDepths
			trace.Ordering = copySlice(orderedVars)
		}
		planTraces = append(planTraces, trace)
	}

	return &QueryPlanResult{
		IterPlans: iterPlans, Lookups: lookups, JoinPatterns: joinPatterns,
		OrderedVars: orderedVars, EVars: eVars, AttrVars: attrVars,
		TLookupVars: tLookupVars, VarOrder: varOrder, PlanTraces: planTraces,
		SyntheticVars: syntheticVars,
	}, nil
}

// ── small helpers ────────────────────────────────────────────────────────

func copySlice(s []string) []string {
	if s == nil {
		return nil
	}
	out := make([]string, len(s))
	copy(out, s)
	return out
}

func copyDepthTraces(s []DepthTrace) []DepthTrace {
	if s == nil {
		return nil
	}
	out := make([]DepthTrace, len(s))
	copy(out, s)
	return out
}

func copyDepthPos(s []DepthPos) []DepthPos {
	if s == nil {
		return nil
	}
	out := make([]DepthPos, len(s))
	copy(out, s)
	return out
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func sortedUnique(l []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, x := range l {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}

func slicesEqual(a, b []string) bool {
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
