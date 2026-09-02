import std/[tables, sets, strutils, options, sequtils]
import datalog_ast, pattern, planner_ast, planner
import scheme, scheme_compile

type
  CompileResult* = ref object
    program*: SchemeProgram
    isSelect*: bool
    isExplain*: bool
    selectBody*: SchemeProgram
    traces*: seq[PlanTrace]
    iterPlans*: seq[IterPlanData]
    lookups*: seq[Pattern]
    orderedVars*: seq[string]
    history*: bool
    existsMode*: bool

proc compileSelect*(datalogIr: DatalogIR): CompileResult =
  result = CompileResult()

  var findVarNames: seq[string]
  for fv in datalogIr.findVars:
    case fv.kind
    of fvVar: findVarNames.add(fv.varName)
    of fvConst: findVarNames.add(fv.cName)

  let plan = buildQueryPlan(
    datalogIr.patterns.mapIt(toPattern(it)),
    findVarNames,
    datalogIr.rangeBounds.keys.toSeq.toHashSet,
    PlanStats(totalEavt: 10_000_000.0),
  )
  let rangeBounds = convertRangeBounds(datalogIr.rangeBounds)
  plan.history = datalogIr.history
  plan.existsMode = datalogIr.existsMode
  plan.findVars = datalogIr.findVars
  plan.rangeBounds = rangeBounds
  result.history = plan.history
  result.existsMode = plan.existsMode
  result.traces = plan.planTraces
  result.iterPlans = plan.iterPlans
  result.lookups = plan.lookups
  result.orderedVars = plan.orderedVars

  let (prog, _, _) = compileSelectScheme(plan)
  result.program = prog

