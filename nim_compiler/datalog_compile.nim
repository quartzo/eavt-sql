## datalog_compile.nim — Compile a Datalog EDN query to an executable
## program, via the same pipeline the SQL surface uses:
##   parse (query_edn) → resolveIr → computePlanStats → buildQueryPlan
##   → compileSelectScheme
## Reuses the Datalog IR end-to-end — the SQL AST is not involved.

import std/[options, tables, sets, sequtils]
import scheme, compiler
import datalog_ast, pattern, resolve, planner_ast, planner, scheme_compile
import stats
import query_edn

proc compileDatalogQuery*(text: string; cstats: stats.CompileStats;
                          findVarsOut: var seq[string]): CompileResult {.
    raises: [CatchableError], gcsafe.} =
  ## Compile a Datalog EDN query.  findVarsOut receives the :find variable
  ## names (result columns, in order).  Raises ValueError on resolution or
  ## syntax failures.
  result = CompileResult()
  let ir = parseDatalogQuery(text)
  var resolved = ir
  if not resolveIr(resolved, cstats):
    raise newException(ValueError, "attribute resolution failed")
  let planStats = computePlanStats(resolved, cstats)
  var joinPatterns: seq[Pattern]
  for p in resolved.patterns: joinPatterns.add(toPattern(p))
  var findVarNames: seq[string]
  for fv in resolved.findVars:
    case fv.kind
    of fvVar: findVarNames.add(fv.varName)
    of fvConst: findVarNames.add(fv.cName)
  let plan = buildQueryPlan(joinPatterns, findVarNames,
    resolved.rangeBounds.keys.toSeq.toHashSet, planStats)
  let rangeBounds = convertRangeBounds(resolved.rangeBounds)
  plan.history = resolved.history
  plan.existsMode = resolved.existsMode
  plan.findVars = resolved.findVars
  plan.rangeBounds = rangeBounds

  result.traces = plan.planTraces
  result.iterPlans = plan.iterPlans
  result.orderedVars = plan.orderedVars
  result.history = plan.history
  result.existsMode = plan.existsMode
  result.isSelect = true

  let (prog, _, _) = compileSelectScheme(plan)
  result.program = prog
  result.selectBody = prog
  findVarsOut = findVarNames