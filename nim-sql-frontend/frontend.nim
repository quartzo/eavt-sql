import std/[options, tables, sequtils, sets, strutils]
import ast, translate, datalog_ast, pattern, resolve, stats, planner, planner_ast, scheme_compile
import scheme

type
  CompileResult* = ref object
    program*: SchemeProgram
    isSelect*: bool
    selectBody*: SchemeProgram
    traces*: seq[PlanTrace]
    orderedVars*: seq[string]

proc fakeSelectFromUpdate(stmt: UpdateStmt): SelectStmt
proc fakeSelectFromDelete(stmt: DeleteStmt): SelectStmt
proc isDeleteDirect(stmt: DeleteStmt): bool

proc compileSql*(stmt: SqlStmt, cstats: CompileStats): CompileResult =
  result = CompileResult()

  case stmt.kind
  of stmtSelect, stmtDatalogSelect:
    let ir = buildDatalogIr(stmt)
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
    result.orderedVars = plan.orderedVars
    result.isSelect = true

    let (prog, _, _) = compileSelectScheme(plan)
    result.program = prog
    result.selectBody = prog

  of stmtUpsert:
    result.program = compileUpsertScheme(stmt.upsertStmt)

  of stmtAttribute:
    result.program = compileAttributeScheme(stmt.attrStmt)

  of stmtPartition:
    result.program = compilePartitionScheme(stmt.partStmt)

  of stmtUpdate:
    let fakeSelect = fakeSelectFromUpdate(stmt.updateStmt)
    let ir = buildDatalogIr(SqlStmt(kind: stmtSelect, selectStmt: fakeSelect))
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
    plan.findVars = resolved.findVars
    plan.rangeBounds = convertRangeBounds(resolved.rangeBounds)
    result.traces = plan.planTraces
    result.orderedVars = plan.orderedVars
    result.isSelect = true

    let (prog, _, _) = compileUpdateScheme(plan, findVarNames, stmt.updateStmt)
    result.program = prog

  of stmtDelete:
    if isDeleteDirect(stmt.deleteStmt):
      result.program = compileDeleteDirectScheme(0, @[])
    else:
      let fakeSelect = fakeSelectFromDelete(stmt.deleteStmt)
      let ir = buildDatalogIr(SqlStmt(kind: stmtSelect, selectStmt: fakeSelect))
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
      plan.findVars = resolved.findVars
      plan.rangeBounds = convertRangeBounds(resolved.rangeBounds)
      result.traces = plan.planTraces
      result.orderedVars = plan.orderedVars
      result.isSelect = true

      let firstAlias = if stmt.deleteStmt.conditions.len > 0:
        stmt.deleteStmt.conditions[0].left.alias
      else: "d1"
      let targetEvar = "_e_" & toLowerAscii(firstAlias)
      let (prog, _, _) = compileDeleteScheme(plan, findVarNames, targetEvar, stmt.deleteStmt)
      result.program = prog

proc isDeleteDirect(stmt: DeleteStmt): bool =
  for cond in stmt.conditions:
    if cond.left.field == "eid":
      return true
  false

proc fakeSelectFromUpdate(stmt: UpdateStmt): SelectStmt =
  let firstAlias = if stmt.clauses.len > 0: toLowerAscii(stmt.clauses[0].alias) else: "d1"
  SelectStmt(
    projections: @[Projection(
      field: some(FieldRef(alias: firstAlias, field: "eid")),
      literal: none(Literal),
    )],
    conditions: stmt.conditions,
  )

proc fakeSelectFromDelete(stmt: DeleteStmt): SelectStmt =
  let firstAlias = if stmt.conditions.len > 0: toLowerAscii(stmt.conditions[0].left.alias) else: "d1"
  SelectStmt(
    projections: @[Projection(
      field: some(FieldRef(alias: firstAlias, field: "eid")),
      literal: none(Literal),
    )],
    conditions: stmt.conditions,
  )
