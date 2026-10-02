// explain.go — EXPLAIN renderer, port of nim_compiler/explain.nim (+ the
// PlanTrace stringification from nim_planner/planner_ast.nim).
package datalog

import (
	"strconv"
	"strings"

	"eavt-go/internal/numfmt"
	"eavt-go/internal/scheme"
)

func oneDecimal(f float64) string { return strconv.FormatFloat(f, 'f', 1, 64) }

// String renders a PlanTrace like nim_planner's `$`.
func (t *PlanTrace) String() string {
	prefix := ""
	switch {
	case t.Pruned:
		prefix = "PRUNED "
	case t.Chosen:
		prefix = "\u2192 "
	}
	var b strings.Builder
	b.WriteString(prefix + "[" + strings.Join(t.Ordering, ", ") + "] cost=" + oneDecimal(t.TotalCost))
	for i, d := range t.Depths {
		if d.IsBlind {
			b.WriteString("\n  depth " + strconv.Itoa(i) + ": " + d.VarName +
				" | blind | est=" + oneDecimal(d.EstimatedElements))
			continue
		}
		parts := make([]string, len(d.ActiveClauses))
		for j, ac := range d.ActiveClauses {
			parts[j] = "p" + strconv.Itoa(ac.Ci) + "@" + ac.Index
		}
		b.WriteString("\n  depth " + strconv.Itoa(i) + ": " + d.VarName +
			" | clauses=[" + strings.Join(parts, ", ") + "] | est=" +
			oneDecimal(d.EstimatedElements) + " \u00d7" +
			strconv.Itoa(len(d.ActiveClauses)) + "cl = " + oneDecimal(d.StepCost))
	}
	return b.String()
}

// RenderExplain ports nim_compiler/explain.nim renderExplain.
func RenderExplain(c *CompileResult) string {
	var b strings.Builder
	if len(c.IterPlans) > 0 {
		b.WriteString("Plan:\n")
		histTag := ""
		if c.History {
			histTag = " (history)"
		}
		existsTag := ""
		if c.ExistsMode {
			existsTag = " (exists)"
		}
		b.WriteString("  Join order: [" + strings.Join(c.OrderedVars, ", ") + "]" + histTag + existsTag + "\n")
		for i, ip := range c.IterPlans {
			b.WriteString("  p" + strconv.Itoa(i) + " @ " + ip.IndexName + "\n")
			for posIdx, pos := range ip.IdxOrder {
				varLabel := ""
				for _, dp := range ip.VarDepths {
					if dp.Pos == pos {
						varLabel = " [depth " + strconv.Itoa(dp.Depth) + "]"
						break
					}
				}
				switch spec := ip.Specs[posIdx].(type) {
				case SkVar:
					b.WriteString("    " + pos + " = " + string(spec) + varLabel + "\n")
				case SkBound:
					if int64(spec) != 0 {
						b.WriteString("    " + pos + " = #" + strconv.FormatInt(int64(spec), 10) + varLabel + "\n")
					} else {
						b.WriteString("    " + pos + " = _" + varLabel + "\n")
					}
				case SkBoundAttr:
					b.WriteString("    " + pos + " = attr(id=" + strconv.Itoa(int(spec)) + ")" + varLabel + "\n")
				case SkBoundValue:
					switch {
					case spec.Str != "":
						b.WriteString("    " + pos + " = \"" + spec.Str + "\"" + varLabel + "\n")
					case spec.Float != 0:
						b.WriteString("    " + pos + " = " + numfmt.FloatString(spec.Float) + varLabel + "\n")
					default:
						b.WriteString("    " + pos + " = " + strconv.FormatInt(spec.Int, 10) + varLabel + "\n")
					}
				case SkBoundParam:
					b.WriteString("    " + pos + " = %" + strconv.Itoa(int(spec)) + varLabel + "\n")
				}
			}
		}
		b.WriteString("\n")
	}
	for _, t := range c.Traces {
		b.WriteString(t.String() + "\n")
	}
	b.WriteString("\n" + scheme.WriteSchemePretty(scheme.Program{Body: c.Program}))
	return b.String()
}
