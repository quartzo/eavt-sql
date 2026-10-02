// scheme_compile.go — plan -> Scheme program, mirroring
// nim_compiler/scheme_compile.nim.  The output S-expression encodes to wire
// msgpack; the gate is byte-identity with the Nim output.
package datalog

import (
	"strconv"
	"strings"

	S "eavt-go/internal/sexpr"
)

func slist(items ...S.Expr) S.Expr { return S.List(items) }

// rangeDn mirrors Nim countdown(a, 0): a, a-1, ..., 0 (empty when a < 0).
func rangeDn(a int) []int {
	var out []int
	for n := a; n >= 0; n-- {
		out = append(out, n)
	}
	return out
}

func planValueToSexpr(pv PlanValue) S.Expr {
	switch v := pv.(type) {
	case PvValue:
		switch {
		case v.Str != "":
			return S.Str(v.Str)
		case v.Float != 0.0:
			return S.Float(v.Float)
		default:
			return S.Int(v.Int)
		}
	case PvParam:
		return slist(S.Keyword("param"), S.Int(int64(v)))
	}
	return S.Void{}
}

func boundToSexpr(bv BoundValue) S.Expr {
	switch v := bv.(type) {
	case BvInt:
		return S.Int(int64(v))
	case BvFloat:
		return S.Float(float64(v))
	case BvStr:
		return S.Str(string(v))
	case BvAttr:
		return S.Str(string(v))
	case BvResolvedAttr:
		return slist(S.Keyword("intern-a"), S.Str(v.Name))
	case BvParam:
		return slist(S.Keyword("param"), S.Int(int64(v)))
	case BvVar:
		return S.Symbol("?" + string(v))
	case BvBool:
		return S.Bool(bool(v))
	case BvMissing:
		return S.Symbol("_")
	}
	return S.Void{}
}

func buildRangeTree(branches [][]PlanCond) S.Expr {
	buildBranch := func(branch []PlanCond) S.Expr {
		var inVals []S.Expr
		var otherConds []S.Expr
		for _, c := range branch {
			if c.Op == "in" {
				inVals = append(inVals, planValueToSexpr(c.V))
			} else {
				otherConds = append(otherConds, slist(S.Keyword(c.Op), planValueToSexpr(c.V)))
			}
		}
		switch len(inVals) {
		case 1:
			otherConds = append(otherConds, slist(S.Keyword("="), inVals[0]))
		default:
			if len(inVals) > 1 {
				eqs := []S.Expr{S.Keyword("or")}
				for _, v := range inVals {
					eqs = append(eqs, slist(S.Keyword("="), v))
				}
				otherConds = append(otherConds, S.List(eqs))
			}
		}
		if len(otherConds) == 1 {
			return otherConds[0]
		}
		return S.List(append([]S.Expr{S.Keyword("and")}, otherConds...))
	}
	if len(branches) == 1 {
		return buildBranch(branches[0])
	}
	items := []S.Expr{S.Keyword("or")}
	for _, b := range branches {
		items = append(items, buildBranch(b))
	}
	return S.List(items)
}

func replaceBodyPlaceholder(expr, replacement S.Expr) S.Expr {
	switch e := expr.(type) {
	case S.Symbol:
		if string(e) == "__BODY__" {
			return replacement
		}
		return e
	case S.List:
		out := make([]S.Expr, len(e))
		for i, it := range e {
			out[i] = replaceBodyPlaceholder(it, replacement)
		}
		return S.List(out)
	}
	return expr
}

func flattenBegins(expr S.Expr) S.Expr {
	l, ok := expr.(S.List)
	if !ok {
		return expr
	}
	items := make([]S.Expr, len(l))
	for i, it := range l {
		items[i] = flattenBegins(it)
	}
	if len(items) > 0 {
		if k, ok := items[0].(S.Keyword); ok && string(k) == "begin" {
			acc := []S.Expr{S.Keyword("begin")}
			for _, item := range items[1:] {
				if inner, ok := item.(S.List); ok && len(inner) > 0 {
					if k2, ok := inner[0].(S.Keyword); ok && string(k2) == "begin" {
						acc = append(acc, inner[1:]...)
						continue
					}
				}
				acc = append(acc, item)
			}
			return S.List(acc)
		}
	}
	return S.List(items)
}

type boundVal struct {
	Pos  string
	Expr S.Expr
}

func lookupBoundVal(l []boundVal, pos string) (S.Expr, bool) {
	for _, b := range l {
		if b.Pos == pos {
			return b.Expr, true
		}
	}
	return nil, false
}

func buildTriejoinScheme(plan *QueryPlanResult, _ []string, leafBody S.Expr) S.Expr {
	orderedVars := plan.OrderedVars
	numDepths := len(orderedVars)
	varNamesList := copySlice(orderedVars)
	for _, tn := range plan.TLookupVars {
		if !contains(varNamesList, tn) {
			varNamesList = append(varNamesList, tn)
		}
	}
	_ = varNamesList

	var scannerBindings []S.Expr
	for ipIdx, ip := range plan.IterPlans {
		scannerName := "?s" + strconv.Itoa(ipIdx)
		openArgs := []S.Expr{S.Keyword("scanner-open"), S.Str(strings.ToUpper(ip.IndexName))}
		if plan.History {
			openArgs = append(openArgs, S.Bool(true))
		}
		scannerBindings = append(scannerBindings, slist(S.Symbol(scannerName), S.List(openArgs)))
	}

	depthRanges := map[int]S.Expr{}
	for _, rb := range plan.RangeBounds {
		if found := indexOf(orderedVars, rb.Var); found >= 0 {
			depthRanges[found] = buildRangeTree(rb.Branches)
		}
	}

	bindVals := make([][]boundVal, len(plan.IterPlans))
	for i, ip := range plan.IterPlans {
		for _, bi := range ip.BoundInts {
			var valExpr S.Expr
			if pv, ok := bi.V.(PvValue); ok && pv.Str != "" && bi.Pos == "a" {
				valExpr = slist(S.Keyword("intern-a"), S.Str(pv.Str))
			} else {
				valExpr = planValueToSexpr(bi.V)
			}
			bindVals[i] = append(bindVals[i], boundVal{Pos: bi.Pos, Expr: valExpr})
		}
	}

	boundEmitted := make([]map[string]bool, len(plan.IterPlans))
	for i := range boundEmitted {
		boundEmitted[i] = map[string]bool{}
	}
	scanPos := make([]int, len(plan.IterPlans))
	var ops []S.Expr

	for depth := 0; depth < numDepths; depth++ {
		varName := orderedVars[depth]
		var scanners []S.Expr
		for ipIdx, ip := range plan.IterPlans {
			if _, ok := depthPos(ip.VarDepths, depth); ok {
				scanners = append(scanners, S.Symbol("?s"+strconv.Itoa(ipIdx)))
			}
		}
		if len(scanners) == 0 {
			continue
		}
		for ipIdx, ip := range plan.IterPlans {
			varPos, ok := depthPos(ip.VarDepths, depth)
			if !ok {
				continue
			}
			for _, bp := range boundPositionsBefore(ip, depth) {
				posName := bp.Pos
				if boundEmitted[ipIdx][posName] {
					continue
				}
				valExpr, ok := lookupBoundVal(bindVals[ipIdx], posName)
				if !ok {
					continue
				}
				boundEmitted[ipIdx][posName] = true
				scanPos[ipIdx]++
				scannerSym := S.Symbol("?s" + strconv.Itoa(ipIdx))
				ops = append(ops, slist(
					S.Keyword("begin"),
					slist(S.Keyword("scanner-push"), scannerSym, valExpr),
					S.Symbol("__BODY__"),
					slist(S.Keyword("scanner-pop"), scannerSym),
				))
			}
			targetIdx := indexOf(ip.IdxOrder, varPos)
			for scanPos[ipIdx] < targetIdx {
				gapSlot := ip.IdxOrder[scanPos[ipIdx]]
				isHandled := false
				for _, dp := range ip.VarDepths {
					if dp.Depth <= depth && dp.Pos == gapSlot {
						isHandled = true
						break
					}
				}
				if boundEmitted[ipIdx][gapSlot] || isHandled {
					scanPos[ipIdx]++
					continue
				}
				gapVar := "?skip_" + gapSlot + "_" + strings.ToLower(ip.IndexName)
				scanPos[ipIdx]++
				scannerSym := S.Symbol("?s" + strconv.Itoa(ipIdx))
				iterVar := S.Symbol("?it_" + gapVar)
				gapBody := slist(
					S.Keyword("begin"),
					slist(S.Keyword("scanner-push"), scannerSym, S.Symbol(gapVar)),
					S.Symbol("__BODY__"),
					slist(S.Keyword("scanner-pop"), scannerSym),
				)
				gapWhile := slist(
					S.Keyword("while"),
					slist(S.Keyword("set!"), S.Symbol(gapVar),
						slist(S.Keyword("scanner-iterate-next"), iterVar)),
					gapBody,
				)
				gapExpr := slist(
					S.Keyword("begin"),
					slist(S.Keyword("set!"), iterVar,
						slist(S.Keyword("scanner-iterate-init"), scannerSym, S.List{})),
					gapWhile,
				)
				ops = append(ops, gapExpr)
			}
		}

		rangesTree, ok := depthRanges[depth]
		if !ok {
			rangesTree = S.List{}
		}
		rangesIsEmpty := false
		if l, ok := rangesTree.(S.List); ok && len(l) == 0 {
			rangesIsEmpty = true
		}
		var rangesExpr S.Expr = S.List{}
		isSynthetic := false
		for _, synth := range plan.SyntheticVars {
			if synth.Name == varName {
				rangesExpr = slist(S.Keyword("ranges-create"),
					slist(S.Keyword("="), S.Symbol(synth.SourceVar)))
				isSynthetic = true
			}
		}
		if !isSynthetic && !rangesIsEmpty {
			rangesExpr = slist(S.Keyword("ranges-create"), rangesTree)
		}

		initArgs := append([]S.Expr{}, scanners...)
		initArgs = append(initArgs, rangesExpr)
		iterVar := S.Symbol("?it_" + varName)
		innerItems := []S.Expr{S.Keyword("begin")}
		if depth < numDepths-1 {
			for _, s := range scanners {
				innerItems = append(innerItems, slist(S.Keyword("scanner-push"), s, S.Symbol(varName)))
			}
			for ipIdx, ip := range plan.IterPlans {
				for _, dp := range ip.VarDepths {
					if dp.Depth == depth {
						boundEmitted[ipIdx][dp.Pos] = true
					}
				}
			}
		}
		innerItems = append(innerItems, S.Symbol("__BODY__"))
		if depth < numDepths-1 {
			for _, s := range scanners {
				innerItems = append(innerItems, slist(S.Keyword("scanner-pop"), s))
			}
		}
		mainWhile := slist(
			S.Keyword("while"),
			slist(S.Keyword("set!"), S.Symbol(varName),
				slist(S.Keyword("scanner-iterate-next"), iterVar)),
			S.List(innerItems),
		)
		mainArgs := append([]S.Expr{S.Keyword("scanner-iterate-init")}, initArgs...)
		mainExpr := slist(
			S.Keyword("begin"),
			slist(S.Keyword("set!"), iterVar, S.List(mainArgs)),
			mainWhile,
		)
		ops = append(ops, mainExpr)
	}

	// trailing bindings
	rangeTrees := map[string]S.Expr{}
	for _, rb := range plan.RangeBounds {
		rangeTrees[rb.Var] = buildRangeTree(rb.Branches)
	}
	for ipIdx, ip := range plan.IterPlans {
		var trailing []boundVal
		for _, bp := range allBoundPositions(ip) {
			if boundEmitted[ipIdx][bp.Pos] {
				continue
			}
			if valExpr, ok := lookupBoundVal(bindVals[ipIdx], bp.Pos); ok {
				trailing = append(trailing, boundVal{Pos: bp.Pos, Expr: valExpr})
			}
		}
		if len(trailing) == 0 {
			continue
		}
		posToVar := map[string]S.Expr{}
		for _, dp := range ip.VarDepths {
			if dp.Depth < len(orderedVars) {
				posToVar[dp.Pos] = S.Symbol(orderedVars[dp.Depth])
			}
		}
		var prePushes []string
		for _, pos := range ip.IdxOrder {
			isTrailing := false
			for _, t := range trailing {
				if t.Pos == pos {
					isTrailing = true
					break
				}
			}
			if !isTrailing && !boundEmitted[ipIdx][pos] {
				if _, ok := posToVar[pos]; ok {
					prePushes = append(prePushes, pos)
				}
			}
		}
		lastIdx := len(trailing) - 1
		for i, t := range trailing {
			posName := t.Pos
			valExpr := t.Expr
			boundEmitted[ipIdx][posName] = true
			scannerSym := S.Symbol("?s" + strconv.Itoa(ipIdx))
			if i == lastIdx {
				var lastRanges S.Expr = slist(S.Keyword("="), valExpr)
				for posIdx, pos := range ip.IdxOrder {
					if pos == posName || posIdx >= len(ip.IdxOrder) {
						continue
					}
					if spec, ok := ip.Specs[posIdx].(SkVar); ok {
						varName := string(spec)
						if rt, ok := rangeTrees[varName]; ok &&
							!boundEmitted[ipIdx][pos] {
							if _, hasVar := posToVar[pos]; !hasVar {
								lastRanges = rt
								boundEmitted[ipIdx][pos] = true
							}
						}
					}
				}
				trailVar := "_" + posName + "_trail"
				trailIterVar := S.Symbol("?it_" + trailVar)
				trailRanges := slist(S.Keyword("ranges-create"), lastRanges)
				trailBody := slist(
					S.Keyword("begin"),
					slist(S.Keyword("scanner-push"), scannerSym, S.Symbol(trailVar)),
					S.Symbol("__BODY__"),
					slist(S.Keyword("scanner-pop"), scannerSym),
				)
				trailWhile := slist(
					S.Keyword("while"),
					slist(S.Keyword("set!"), S.Symbol(trailVar),
						slist(S.Keyword("scanner-iterate-next"), trailIterVar)),
					trailBody,
				)
				trailItems := []S.Expr{S.Keyword("begin")}
				for _, p := range prePushes {
					trailItems = append(trailItems, slist(S.Keyword("scanner-push"), scannerSym, posToVar[p]))
				}
				trailItems = append(trailItems, slist(S.Keyword("set!"), trailIterVar,
					slist(S.Keyword("scanner-iterate-init"), scannerSym, trailRanges)))
				trailItems = append(trailItems, trailWhile)
				for range rangeDn(len(prePushes) - 1) {
					trailItems = append(trailItems, slist(S.Keyword("scanner-pop"), scannerSym))
				}
				ops = append(ops, S.List(trailItems))
			} else {
				pushItems := []S.Expr{S.Keyword("begin")}
				for _, p := range prePushes {
					pushItems = append(pushItems, slist(S.Keyword("scanner-push"), scannerSym, posToVar[p]))
				}
				pushItems = append(pushItems, slist(S.Keyword("scanner-push"), scannerSym, valExpr))
				pushItems = append(pushItems, S.Symbol("__BODY__"))
				pushItems = append(pushItems, slist(S.Keyword("scanner-pop"), scannerSym))
				for range rangeDn(len(prePushes) - 1) {
					pushItems = append(pushItems, slist(S.Keyword("scanner-pop"), scannerSym))
				}
				ops = append(ops, S.List(pushItems))
			}
		}
	}

	// non-iterated range vars
	var iteratedVars []string
	for _, ip := range plan.IterPlans {
		for _, dp := range ip.VarDepths {
			if dp.Depth < len(orderedVars) {
				v := orderedVars[dp.Depth]
				if !contains(iteratedVars, v) {
					iteratedVars = append([]string{v}, iteratedVars...)
				}
			}
		}
	}
	for ipIdx, ip := range plan.IterPlans {
		posToVar := map[string]S.Expr{}
		for _, dp := range ip.VarDepths {
			if dp.Depth < len(orderedVars) {
				posToVar[dp.Pos] = S.Symbol(orderedVars[dp.Depth])
			}
		}
		emittedPos := map[string]bool{}
		for _, bv := range bindVals[ipIdx] {
			emittedPos[bv.Pos] = true
		}
		for posIdx, pos := range ip.IdxOrder {
			specVar, ok := ip.Specs[posIdx].(SkVar)
			if !ok {
				continue
			}
			vs := string(specVar)
			rt, hasRange := rangeTrees[vs]
			if !hasRange || contains(iteratedVars, vs) {
				continue
			}
			if _, hasVar := posToVar[pos]; hasVar {
				continue
			}
			if emittedPos[pos] {
				continue
			}
			emittedPos[pos] = true
			scannerSym := S.Symbol("?s" + strconv.Itoa(ipIdx))
			varSym := S.Symbol(vs)
			iterVar := S.Symbol("?it_" + vs)
			rangesExpr := slist(S.Keyword("ranges-create"), rt)
			var prePushes []string
			for checkIdx, checkPos := range ip.IdxOrder {
				if checkIdx < posIdx && !emittedPos[checkPos] {
					if _, ok := posToVar[checkPos]; ok {
						prePushes = append(prePushes, checkPos)
					}
				}
			}
			innerBody := slist(
				S.Keyword("begin"),
				slist(S.Keyword("scanner-push"), scannerSym, varSym),
				S.Symbol("__BODY__"),
				slist(S.Keyword("scanner-pop"), scannerSym),
			)
			innerWhile := slist(
				S.Keyword("while"),
				slist(S.Keyword("set!"), varSym,
					slist(S.Keyword("scanner-iterate-next"), iterVar)),
				innerBody,
			)
			items := []S.Expr{S.Keyword("begin")}
			for _, p := range prePushes {
				items = append(items, slist(S.Keyword("scanner-push"), scannerSym, posToVar[p]))
			}
			items = append(items, slist(S.Keyword("set!"), iterVar,
				slist(S.Keyword("scanner-iterate-init"), scannerSym, rangesExpr)))
			items = append(items, innerWhile)
			for range rangeDn(len(prePushes) - 1) {
				items = append(items, slist(S.Keyword("scanner-pop"), scannerSym))
			}
			ops = append(ops, S.List(items))
		}
	}

	// wrap __BODY__ placeholders
	body := leafBody
	for _, i := range rangeDn(len(ops) - 1) {
		body = replaceBodyPlaceholder(ops[i], body)
	}

	// lookup probes
	for _, pattern := range plan.Lookups {
		if !IsLookup(pattern) {
			continue
		}
		tParam := "_t"
		if n, ok := pattern.T.(DsVar); ok {
			tParam = string(n)
		}
		eConst, eOK := pattern.E.(DsConst)
		aConst, aOK := pattern.A.(DsConst)
		vConst, vOK := pattern.V.(DsConst)
		if !eOK || !aOK || !vOK {
			continue
		}
		probeSVar := "?s_probe"
		probeIterVar := S.Symbol("?it_probe")
		body = slist(
			S.Keyword("begin"),
			slist(S.Keyword("set!"), S.Symbol(probeSVar),
				slist(S.Keyword("scanner-open"), S.Str("EAVT"))),
			slist(S.Keyword("set!"), probeIterVar,
				slist(S.Keyword("scanner-iterate-init"), S.Symbol(probeSVar), S.List{})),
			slist(
				S.Keyword("begin"),
				slist(S.Keyword("scanner-push"), S.Symbol(probeSVar), boundToSexpr(eConst.V)),
				slist(S.Keyword("scanner-push"), S.Symbol(probeSVar), boundToSexpr(aConst.V)),
				slist(S.Keyword("scanner-push"), S.Symbol(probeSVar), boundToSexpr(vConst.V)),
				slist(
					S.Keyword("while"),
					slist(S.Keyword("set!"), S.Symbol(tParam),
						slist(S.Keyword("scanner-iterate-next"), probeIterVar)),
					slist(
						S.Keyword("begin"),
						slist(S.Keyword("scanner-push"), S.Symbol(probeSVar), S.Symbol(tParam)),
						body,
						slist(S.Keyword("scanner-pop"), S.Symbol(probeSVar)),
					),
				),
				slist(S.Keyword("scanner-pop"), S.Symbol(probeSVar)),
				slist(S.Keyword("scanner-pop"), S.Symbol(probeSVar)),
				slist(S.Keyword("scanner-pop"), S.Symbol(probeSVar)),
			),
		)
	}

	// scanner bindings prefix
	fullBody := body
	if len(scannerBindings) > 0 {
		stmts := []S.Expr{S.Keyword("begin")}
		for _, b := range scannerBindings {
			if bl, ok := b.(S.List); ok && len(bl) == 2 {
				if openArgs, ok := bl[1].(S.List); ok {
					stmts = append(stmts, slist(S.Keyword("set!"), bl[0], openArgs))
				}
			}
		}
		stmts = append(stmts, body)
		fullBody = S.List(stmts)
	}
	return flattenBegins(fullBody)
}

func depthPos(vd []DepthPos, depth int) (string, bool) {
	for _, dp := range vd {
		if dp.Depth == depth {
			return dp.Pos, true
		}
	}
	return "", false
}

func buildProjection(plan *QueryPlanResult, totalProjLen int, constantIndices []intPV) S.Expr {
	var projArgs []S.Expr
	fvIdx := 0
	findVars := make([]string, len(plan.FindVars))
	for i, fv := range plan.FindVars {
		switch f := fv.(type) {
		case FvVar:
			findVars[i] = string(f)
		case FvConst:
			findVars[i] = f.Name
		}
	}
	for i := 0; i < totalProjLen; i++ {
		var pv PlanValue
		found := false
		for _, ci := range constantIndices {
			if ci.Index == i {
				pv = ci.V
				found = true
				break
			}
		}
		if found {
			projArgs = append(projArgs, planValueToSexpr(pv))
			fvIdx++
			continue
		}
		if fvIdx >= len(findVars) {
			projArgs = append(projArgs, S.Void{})
			continue
		}
		varName := findVars[fvIdx]
		fvIdx++
		bnd := S.Symbol(varName)
		if contains(plan.AttrVars, varName) {
			projArgs = append(projArgs, slist(S.Keyword("attr-name"), bnd))
		} else {
			projArgs = append(projArgs, slist(S.Keyword("resolve-val"), bnd))
		}
	}
	return S.List(append([]S.Expr{S.Keyword("result-row")}, projArgs...))
}

type intPV struct {
	Index int
	V     PlanValue
}

func compileSelectScheme(plan *QueryPlanResult) S.Expr {
	var findVars []string
	var constantIndices []intPV
	for i, fv := range plan.FindVars {
		switch f := fv.(type) {
		case FvVar:
			findVars = append(findVars, string(f))
		case FvConst:
			findVars = append(findVars, f.Name)
			if pv, ok := fromBoundValue(f.V); ok {
				constantIndices = append(constantIndices, intPV{Index: i, V: pv})
			}
		}
	}
	var leafBody S.Expr
	if plan.ExistsMode && len(constantIndices) == 0 {
		leafBody = slist(S.Keyword("result-row"), S.Int(1))
	} else {
		leafBody = buildProjection(plan, len(plan.FindVars), constantIndices)
	}
	return buildTriejoinScheme(plan, findVars, leafBody)
}
