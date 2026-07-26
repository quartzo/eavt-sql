import std/[unittest, tables, sets, sequtils]
import datalog_ast, pattern, planner, planner_ast, resolve, stats

proc makeFixedStats(): CompileStats =
  result = CompileStats()
  result.attrIds = {
    "user.name": 100'u32,
    "user.age": 101'u32,
    "company.ceo": 200'u32,
  }.toTable
  result.refAttrs = ["company.ceo"].toHashSet
  result.indexEstimates = {
    "EAVT:": 10_000_000.0,
    "AEVT:100:": 100.0,
    "AEVT:101:": 100.0,
    "AEVT:200:": 100.0,
    "AVET:100:": 10_000.0,
    "AVET:101:": 10_000.0,
    "AVET:200:": 10_000.0,
  }.toTable
  result.partitionIds = initTable[string, uint64]()

proc resolveAndPlan(ir: DatalogIR): QueryPlanResult =
  let stats = makeFixedStats()
  var resolved = ir
  if not resolveIr(resolved, stats):
    raise newException(ValueError, "resolveIr failed")
  let planStats = computePlanStats(resolved, stats)
  var joinPatterns: seq[Pattern]
  for p in resolved.patterns:
    joinPatterns.add(toPattern(p))
  let findVarNames = resolved.findVars.mapIt(
    case it.kind
    of fvVar: it.varName
    of fvConst: it.cName
  )
  let rangeVarSet = toHashSet(toSeq(resolved.rangeBounds.keys))
  buildQueryPlan(joinPatterns, findVarNames, rangeVarSet, planStats)

suite "planner: lookups":
  test "lookup-only plan":
    let ir = DatalogIR(
      patterns: @[DatalogPattern(
        e: slotConst(newBoundInt(7)),
        a: slotConst(newBoundAttr("user.name")),
        v: slotConst(newBoundStr("Alice")),
        t: slotMissing(),
        added: slotMissing(),
      )],
      findVars: @[FindVar(kind: fvVar, varName: "x")],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let plan = resolveAndPlan(ir)
    check plan.iterPlans.len == 0
    check plan.lookups.len == 1
    check plan.orderedVars.len == 0
    check plan.lookups[0].a.kind == dsConst
    check plan.lookups[0].a.constVal.kind == bvResolvedAttr
    check plan.lookups[0].a.constVal.raName == "user.name"

suite "planner: join ordering":
  test "join prefers AEVT when attribute is bound":
    let ir = DatalogIR(
      patterns: @[
        DatalogPattern(
          e: slotVar("e"), a: slotConst(newBoundAttr("user.name")),
          v: slotVar("name"), t: slotMissing(), added: slotMissing(),
        ),
        DatalogPattern(
          e: slotVar("e"), a: slotConst(newBoundAttr("user.age")),
          v: slotVar("age"), t: slotMissing(), added: slotMissing(),
        ),
      ],
      findVars: @[
        FindVar(kind: fvVar, varName: "e"),
        FindVar(kind: fvVar, varName: "name"),
        FindVar(kind: fvVar, varName: "age"),
      ],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let plan = resolveAndPlan(ir)
    check plan.orderedVars[0] == "e"
    check plan.iterPlans.len == 2
    for ip in plan.iterPlans:
      check ip.indexName == "AEVT"

  test "ref attr is resolved":
    let ir = DatalogIR(
      patterns: @[DatalogPattern(
        e: slotVar("e"), a: slotConst(newBoundAttr("company.ceo")),
        v: slotVar("ceo"), t: slotMissing(), added: slotMissing(),
      )],
      findVars: @[
        FindVar(kind: fvVar, varName: "e"),
        FindVar(kind: fvVar, varName: "ceo"),
      ],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let plan = resolveAndPlan(ir)
    check plan.lookups.len == 0
    check plan.iterPlans.len == 1
    check plan.joinPatterns[0].a.kind == dsConst
    check plan.joinPatterns[0].a.constVal.kind == bvResolvedAttr
    check plan.joinPatterns[0].a.constVal.raIsRef
    check plan.iterPlans[0].indexName == "AEVT"

suite "planner: error cases":
  test "3-position same-var rejection":
    let ir = DatalogIR(
      patterns: @[DatalogPattern(
        e: slotVar("x"), a: slotConst(newBoundAttr("user.name")),
        v: slotVar("x"), t: slotVar("x"), added: slotMissing(),
      )],
      findVars: @[FindVar(kind: fvVar, varName: "x")],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let stats = makeFixedStats()
    var resolved = ir
    check resolveIr(resolved, stats)
    let planStats = computePlanStats(resolved, stats)
    var joinPatterns: seq[Pattern]
    for p in resolved.patterns: joinPatterns.add(toPattern(p))
    let findVarNames = resolved.findVars.mapIt(
      case it.kind
      of fvVar: it.varName
      of fvConst: it.cName
    )
    expect CatchableError:
      discard buildQueryPlan(joinPatterns, findVarNames, initHashSet[string](), planStats)

  test "unknown attribute in resolve":
    let ir = DatalogIR(
      patterns: @[DatalogPattern(
        e: slotVar("e"), a: slotConst(newBoundAttr("unknown.attr")),
        v: slotVar("v"), t: slotMissing(), added: slotMissing(),
      )],
      findVars: @[FindVar(kind: fvVar, varName: "e")],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let stats = makeFixedStats()
    var resolved = ir
    check not resolveIr(resolved, stats)

suite "planner: single pattern":
  test "single pattern uses AEVT":
    let ir = DatalogIR(
      patterns: @[DatalogPattern(
        e: slotVar("e"), a: slotConst(newBoundAttr("user.name")),
        v: slotVar("name"), t: slotMissing(), added: slotMissing(),
      )],
      findVars: @[FindVar(kind: fvVar, varName: "e"), FindVar(kind: fvVar, varName: "name")],
      rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]](),
      history: false,
    )
    let plan = resolveAndPlan(ir)
    check plan.iterPlans.len == 1
    check plan.iterPlans[0].indexName == "AEVT"
    check plan.orderedVars.len >= 1
