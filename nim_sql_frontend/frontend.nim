import std/[options, tables, sequtils, sets, strutils]
import ast, translate, datalog_ast, pattern, resolve, stats, planner, planner_ast, scheme_compile
import scheme

type
  CompileResult* = ref object
    program*: SchemeProgram
    isSelect*: bool
    isExplain*: bool
    selectBody*: SchemeProgram
    traces*: seq[PlanTrace]
    iterPlans*: seq[IterPlanData]
    orderedVars*: seq[string]
    history*: bool
    existsMode*: bool


proc isDeleteDirect(stmt: DeleteStmt): bool =
  for cond in stmt.conditions:
    if cond.left.field == "eid":
      return true
  false

proc fakeSelectFromUpdate*(stmt: UpdateStmt): SelectStmt =
  let firstAlias = if stmt.clauses.len > 0: toLowerAscii(stmt.clauses[0].alias) else: "d1"
  SelectStmt(
    projections: @[Projection(
      field: some(FieldRef(alias: firstAlias, field: "eid")),
      literal: none(Literal),
    )],
    conditions: stmt.conditions,
  )

proc fakeSelectFromDelete*(stmt: DeleteStmt): SelectStmt =
  let firstAlias = if stmt.conditions.len > 0: toLowerAscii(stmt.conditions[0].left.alias) else: "d1"
  SelectStmt(
    projections: @[Projection(
      field: some(FieldRef(alias: firstAlias, field: "eid")),
      literal: none(Literal),
    )],
    conditions: stmt.conditions,
  )

proc compileSql*(stmt: SqlStmt, cstats: CompileStats): CompileResult =
  result = CompileResult()
  result.isExplain = stmt.isExplain

  case stmt.kind
  of stmtSelect, stmtDatalogSelect:
    # Pure-expression projection (no field refs, no WHERE): a SELECT whose
    # projection list is only literals/expressions produces a stream of one
    # row directly — no scanner, no triejoin. This is the degenerate
    # 0-scanner case of the general compileSelect algorithm: projections go
    # through compileValue (the single expression funnel), and there are no
    # patterns to join, so no scanner is emitted.
    if stmt.kind == stmtSelect and stmt.selectStmt.conditions.len == 0 and
       not stmt.selectStmt.star and not stmt.selectStmt.existsMode and
       not stmt.selectStmt.history:
      var allExpr = true
      for proj in stmt.selectStmt.projections:
        if proj.field.isSome: allExpr = false; break
      if allExpr:
          var projArgs: seq[SExpr] = @[]
          for proj in stmt.selectStmt.projections:
            if proj.expr.isSome:
              projArgs.add(compileValue(proj.expr.get))
            elif proj.literal.isSome:
              projArgs.add(compileLiteral(proj.literal.get))
            else:
              projArgs.add(newVoid())
          let prog = SchemeProgram(body: list(@[newSymbol("result-row")] & projArgs))
          result.isSelect = true
          result.program = prog
          result.selectBody = prog
          return result
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
    result.iterPlans = plan.iterPlans
    result.orderedVars = plan.orderedVars
    result.history = plan.history
    result.existsMode = plan.existsMode
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
    result.iterPlans = plan.iterPlans
    result.orderedVars = plan.orderedVars
    result.history = plan.history
    result.existsMode = plan.existsMode
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
      result.iterPlans = plan.iterPlans
      result.orderedVars = plan.orderedVars
      result.history = plan.history
      result.existsMode = plan.existsMode
      result.isSelect = true

      let firstAlias = if stmt.deleteStmt.conditions.len > 0:
        stmt.deleteStmt.conditions[0].left.alias
      else: "d1"
      let targetEvar = "_e_" & toLowerAscii(firstAlias)
      let (prog, _, _) = compileDeleteScheme(plan, findVarNames, targetEvar, stmt.deleteStmt)
      result.program = prog

