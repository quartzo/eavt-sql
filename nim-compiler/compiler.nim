import std/[tables, sets, strutils, options, sequtils]
import ast as sql_ast
import datalog_ast, pattern, planner_ast, planner
import scheme, scheme_compile

type
  CompileResult* = ref object
    program*: SchemeProgram
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

proc compileUpsert*(stmt: sql_ast.UpsertStmt): CompileResult =
  result = CompileResult()
  result.program = compileUpsertScheme(stmt)

proc compileAttribute*(stmt: sql_ast.AttributeStmt): CompileResult =
  result = CompileResult()
  result.program = compileAttributeScheme(stmt)

proc compilePartition*(stmt: sql_ast.PartitionStmt): CompileResult =
  result = CompileResult()
  result.program = compilePartitionScheme(stmt)

proc compileDeleteDirect*(entityVal: int64, pairs: seq[(string, int64)]): CompileResult =
  result = CompileResult()
  result.program = compileDeleteDirectScheme(entityVal, pairs)

proc fakeSelectFromUpdate(stmt: sql_ast.UpdateStmt): sql_ast.SelectStmt =
  let firstAlias = if stmt.clauses.len > 0: toLowerAscii(stmt.clauses[0].alias) else: "d1"
  sql_ast.SelectStmt(
    projections: @[sql_ast.Projection(
      field: some(sql_ast.FieldRef(alias: firstAlias, field: "eid")),
      literal: none(sql_ast.Literal),
    )],
    conditions: stmt.conditions,
  )

proc fakeSelectFromDelete(stmt: sql_ast.DeleteStmt): sql_ast.SelectStmt =
  let firstAlias = if stmt.conditions.len > 0: toLowerAscii(stmt.conditions[0].left.alias) else: "d1"
  sql_ast.SelectStmt(
    projections: @[sql_ast.Projection(
      field: some(sql_ast.FieldRef(alias: firstAlias, field: "eid")),
      literal: none(sql_ast.Literal),
    )],
    conditions: stmt.conditions,
  )
