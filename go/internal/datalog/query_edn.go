// query_edn.go — Datalog EDN surface -> Datalog IR, mirroring
// nim_datalog/query_edn.nim.  Operates on edn.Value (List covers both [] and
// ()); keywords carry the name WITHOUT the leading colon.
package datalog

import (
	"strings"

	"eavt-go/internal/edn"
)

// SyntaxError is a Datalog parse/validate error.
type SyntaxError string

func (e SyntaxError) Error() string { return string(e) }

var rangeOps = map[string]bool{
	">": true, "<": true, ">=": true, "<=": true, "=": true, "!=": true,
}

func isVarSym(e edn.Value) bool {
	s, ok := e.(edn.Symbol)
	return ok && len(s) > 0 && s[0] == '?'
}

func varName(e edn.Value) string {
	s := e.(edn.Symbol)
	return string(s[1:])
}

func isBlank(e edn.Value) bool {
	s, ok := e.(edn.Symbol)
	return ok && s == "_"
}

func keywordIs(e edn.Value, name string) bool {
	k, ok := e.(edn.Keyword)
	return ok && string(k) == name
}

func symbolIs(e edn.Value, name string) bool {
	s, ok := e.(edn.Symbol)
	return ok && string(s) == name
}

func parseValue(e edn.Value, params map[string]int32) (BoundValue, error) {
	if isVarSym(e) {
		vn := varName(e)
		if idx, ok := params[vn]; ok {
			return BvParam(idx), nil
		}
		return nil, SyntaxError("datalog: unbound var ?" + vn +
			" in value position (declare it in :in)")
	}
	switch x := e.(type) {
	case edn.Str:
		return BvStr(string(x)), nil
	case edn.Int:
		return BvInt(int64(x)), nil
	case edn.Float:
		return BvFloat(float64(x)), nil
	case edn.Bool:
		return BvBool(bool(x)), nil
	case edn.Keyword:
		return BvStr(":" + string(x)), nil
	}
	return nil, SyntaxError("datalog: unsupported value")
}

func parsePattern(p edn.Value, ir *IR, params map[string]int32) error {
	items, ok := p.(edn.List)
	if !ok || len(items) != 3 {
		return SyntaxError("datalog: pattern must be a 3-element vector [e attr v]")
	}
	eSlot, aSlot, vSlot := items[0], items[1], items[2]

	var e Slot
	switch {
	case isVarSym(eSlot):
		vn := varName(eSlot)
		if idx, ok := params[vn]; ok {
			e = DsConst{V: BvParam(idx)}
		} else {
			e = DsVar(vn)
		}
	case isBlank(eSlot):
		e = DsMissing{}
	default:
		if i, ok := eSlot.(edn.Int); ok {
			e = DsConst{V: BvInt(int64(i))}
		} else {
			return SyntaxError("datalog: e slot must be a var, _ or eid")
		}
	}

	kw, ok := aSlot.(edn.Keyword)
	if !ok {
		return SyntaxError("datalog: attr slot must be a keyword like :person/name")
	}
	attr := string(kw)
	if strings.Contains(attr, ".") {
		attr = strings.ReplaceAll(attr, ".", "/")
	}
	if !strings.Contains(attr, "/") {
		return SyntaxError("datalog: attr keyword must be namespaced: :" + string(kw))
	}
	a := DsConst{V: BvAttr(attr)}

	var v Slot
	switch {
	case isVarSym(vSlot):
		vn := varName(vSlot)
		if idx, ok := params[vn]; ok {
			v = DsConst{V: BvParam(idx)}
		} else {
			v = DsVar(vn)
		}
	case isBlank(vSlot):
		v = DsMissing{}
	default:
		bv, err := parseValue(vSlot, params)
		if err != nil {
			return err
		}
		v = DsConst{V: bv}
	}

	ir.Patterns = append(ir.Patterns, Pattern{E: e, A: a, V: v, T: DsMissing{}, Added: DsMissing{}})
	return nil
}

func predKey(opExpr edn.Value) (string, error) {
	if kw, ok := opExpr.(edn.Keyword); ok {
		op := string(kw)
		if rangeOps[op] {
			return op, nil
		}
		return "", SyntaxError("datalog: unsupported predicate op :" + op +
			" (supported: > < >= <= = !=)")
	}
	return "", SyntaxError("datalog: predicate op must be a keyword like :>")
}

func isOpSym(e edn.Value) bool {
	s, ok := e.(edn.Symbol)
	return ok && rangeOps[string(s)]
}

func addRange(ir *IR, vn string, branch int, cond RangeCond) {
	branches, _ := ir.RangeLookup(vn)
	n := len(branches)
	if branch+1 > n {
		n = branch + 1
	}
	arr := make([][]RangeCond, n)
	copy(arr, branches)
	arr[branch] = append(append([]RangeCond(nil), arr[branch]...), cond)
	ir.RangeSet(vn, arr)
}

func parsePredicate(p edn.Value, ir *IR, params map[string]int32, branch int) error {
	items, _ := p.(edn.List)
	if len(items) >= 2 {
		head := items[0]
		if symbolIs(head, "in") || keywordIs(head, "in") {
			varExpr := items[1]
			if !isVarSym(varExpr) {
				return SyntaxError("datalog: IN var must be ?var")
			}
			vn := varName(varExpr)
			for _, item := range items[2:] {
				bv, err := parseValue(item, params)
				if err != nil {
					return err
				}
				addRange(ir, vn, branch, RangeCond{Op: "in", V: bv})
			}
			return nil
		}
	}
	if len(items) == 3 {
		var op string
		if isOpSym(items[0]) {
			op = string(items[0].(edn.Symbol))
		} else {
			var err error
			op, err = predKey(items[0])
			if err != nil {
				return err
			}
		}
		if !isVarSym(items[1]) {
			return SyntaxError("datalog: predicate var must be ?var")
		}
		vn := varName(items[1])
		bv, err := parseValue(items[2], params)
		if err != nil {
			return err
		}
		addRange(ir, vn, branch, RangeCond{Op: op, V: bv})
		return nil
	}
	return SyntaxError("datalog: predicate must be [(op var value)]")
}

func parseWhereElement(p0 edn.Value, ir *IR, params map[string]int32, branch int) error {
	p := p0
	if outer, ok := p0.(edn.List); ok && len(outer) == 1 {
		if inner, ok := outer[0].(edn.List); ok && len(inner) > 0 {
			head := inner[0]
			innerIsRoute := isOpSym(head) || symbolIs(head, "or") || symbolIs(head, "in") ||
				keywordIs(head, "or") || keywordIs(head, "in") ||
				(func() bool { k, ok := head.(edn.Keyword); return ok && rangeOps[string(k)] })()
			if innerIsRoute {
				p = edn.List(inner)
			}
		}
	}

	if items, ok := p.(edn.List); ok && len(items) > 0 {
		head := items[0]
		headIsOr := symbolIs(head, "or") || keywordIs(head, "or")
		if headIsOr {
			for i, item := range items[1:] {
				if err := parseWhereElement(item, ir, params, i); err != nil {
					return err
				}
			}
			return nil
		}
		isPred := isOpSym(head) || symbolIs(head, "in") || keywordIs(head, "in") ||
			(func() bool { k, ok := head.(edn.Keyword); return ok && rangeOps[string(k)] })()
		if isPred {
			return parsePredicate(p, ir, params, branch)
		}
	}
	return parsePattern(p, ir, params)
}

type section int

const (
	secNone section = iota
	secFind
	secIn
	secWhere
)

// ParseDatalogQuery parses a Datalog EDN query into an IR and the :find names.
func ParseDatalogQuery(src string) (*IR, []string, error) {
	top, err := edn.Read(src)
	if err != nil {
		return nil, nil, SyntaxError("datalog: EDN parse error: " + err.Error())
	}
	items, ok := top.(edn.List)
	if !ok {
		return nil, nil, SyntaxError("datalog: query must start with [:find ...]")
	}
	if len(items) == 0 || !keywordIs(items[0], "find") {
		return nil, nil, SyntaxError("datalog: query must start with [:find ...]")
	}

	ir := NewIR()
	params := map[string]int32{}
	var paramIdx int32
	sec := secFind

	for i, el := range items {
		if i == 0 {
			continue
		}
		if kw, ok := el.(edn.Keyword); ok {
			switch string(kw) {
			case "find":
				sec = secFind
			case "in":
				sec = secIn
			case "where":
				sec = secWhere
			case "history":
				ir.History = true
				sec = secNone
			default:
				return nil, nil, SyntaxError("datalog: unknown query section :" + string(kw))
			}
			continue
		}
		switch sec {
		case secFind:
			if !isVarSym(el) {
				return nil, nil, SyntaxError("datalog: :find takes vars like ?name")
			}
			ir.FindVars = append(ir.FindVars, FvVar(varName(el)))
		case secIn:
			if symbolIs(el, "$") {
				continue
			}
			if !isVarSym(el) {
				return nil, nil, SyntaxError("datalog: :in takes $ and vars like ?x")
			}
			paramIdx++
			params[varName(el)] = paramIdx
		case secWhere:
			if err := parseWhereElement(el, ir, params, 0); err != nil {
				return nil, nil, err
			}
		case secNone:
			return nil, nil, SyntaxError("datalog: unexpected element outside a section")
		}
	}

	if len(ir.FindVars) == 0 {
		return nil, nil, SyntaxError("datalog: :find is required")
	}
	if len(ir.Patterns) == 0 {
		return nil, nil, SyntaxError("datalog: :where with at least one pattern is required")
	}
	for _, rb := range ir.RangeBounds {
		bound := false
		for _, p := range ir.Patterns {
			if v, ok := p.V.(DsVar); ok && string(v) == rb.Var {
				bound = true
				break
			}
		}
		if !bound {
			return nil, nil, SyntaxError("datalog: predicate var ?" + rb.Var +
				" is not bound by any pattern value slot")
		}
	}
	findVars := make([]string, len(ir.FindVars))
	for i, fv := range ir.FindVars {
		switch f := fv.(type) {
		case FvVar:
			findVars[i] = string(f)
		case FvConst:
			findVars[i] = f.Name
		}
	}
	return ir, findVars, nil
}
