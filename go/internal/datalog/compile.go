// compile.go — orchestration, mirroring nim_compiler/datalog_compile.nim:
// parse (query_edn) -> resolveIr -> computePlanStats -> buildQueryPlan
// -> compileSelectScheme.
package datalog

import S "eavt-go/internal/sexpr"

// CompileError is a Datalog compile failure.
type CompileError string

func (e CompileError) Error() string { return string(e) }

func compileToPlan(text string, cstats *CompileStats) (*QueryPlanResult, []string, error) {
	ir, findVars, err := ParseDatalogQuery(text)
	if err != nil {
		return nil, nil, CompileError(err.Error())
	}
	if err := ResolveIR(ir, cstats); err != nil {
		return nil, nil, CompileError("attribute resolution failed")
	}
	planStats := computePlanStats(ir, cstats)
	rangeVars := make([]string, len(ir.RangeBounds))
	for i, rb := range ir.RangeBounds {
		rangeVars[i] = rb.Var
	}
	plan, err := BuildQueryPlan(ir.Patterns, findVars, rangeVars, planStats)
	if err != nil {
		return nil, nil, CompileError(err.Error())
	}
	plan.History = ir.History
	plan.ExistsMode = ir.ExistsMode
	plan.FindVars = ir.FindVars
	plan.RangeBounds = convertRangeBounds(ir.RangeBounds)
	return plan, findVars, nil
}

// CompileDatalogQueryDebug compiles and returns the program plus planner
// debug data (find vars, ordered vars, iter plans).
func CompileDatalogQueryDebug(text string, cstats *CompileStats) (S.Expr, []string, []string, []IterPlanData, error) {
	plan, findVars, err := compileToPlan(text, cstats)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	prog := compileSelectScheme(plan)
	return prog, findVars, plan.OrderedVars, plan.IterPlans, nil
}

// CompileDatalogQuery compiles a query into a wire program + find vars.
func CompileDatalogQuery(text string, cstats *CompileStats) (S.Expr, []string, error) {
	prog, fv, _, _, err := CompileDatalogQueryDebug(text, cstats)
	return prog, fv, err
}

// CompileResult carries everything the EXPLAIN renderer needs.
type CompileResult struct {
	Program     S.Expr
	Traces      []*PlanTrace
	IterPlans   []IterPlanData
	OrderedVars []string
	History     bool
	ExistsMode  bool
	FindVars    []string
}

// CompileDatalogQueryResult compiles and returns the full result (for EXPLAIN).
func CompileDatalogQueryResult(text string, cstats *CompileStats) (*CompileResult, error) {
	plan, _, err := compileToPlan(text, cstats)
	if err != nil {
		return nil, err
	}
	prog := compileSelectScheme(plan)
	return &CompileResult{
		Program:     prog,
		Traces:      plan.PlanTraces,
		IterPlans:   plan.IterPlans,
		OrderedVars: plan.OrderedVars,
		History:     plan.History,
		ExistsMode:  plan.ExistsMode,
		FindVars: func() []string {
			out := make([]string, len(plan.FindVars))
			for i, fv := range plan.FindVars {
				switch f := fv.(type) {
				case FvVar:
					out[i] = string(f)
				case FvConst:
					out[i] = f.Name
				}
			}
			return out
		}(),
	}, nil
}
