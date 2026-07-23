import std/[tables, sets, sequtils, strutils]
import datalog_ast, pattern

type
  SpecKindKind* = enum
    skVar, skBound, skBoundAttr, skBoundValue, skBoundParam

  SpecKind* = ref object
    case kind*: SpecKindKind
    of skVar: varName*: string
    of skBound: boundVal*: uint64
    of skBoundAttr: attrId*: uint32
    of skBoundValue:
      bvInt*: int64
      bvFloat*: float64
      bvStr*: string
    of skBoundParam: paramIdx*: uint32

  PlanValueKind* = enum
    pvValue, pvParam

  PlanValue* = ref object
    case kind*: PlanValueKind
    of pvValue:
      pvInt*: int64
      pvFloat*: float64
      pvStr*: string
    of pvParam: pvParamIdx*: uint32

  DepthTrace* = ref object
    varName*: string
    activeClauses*: seq[(int, string)]
    estimatedElements*: float64
    isBlind*: bool
    stepCost*: float64
    penalty*: bool

  PlanTrace* = ref object
    ordering*: seq[string]
    depths*: seq[DepthTrace]
    totalCost*: float64
    pruned*: bool
    chosen*: bool

  IterPlanData* = ref object
    indexName*: string
    idxOrder*: array[5, string]
    specs*: array[5, SpecKind]
    boundInts*: Table[string, PlanValue]
    varDepths*: seq[(int, string)]
    sameVarConstraints*: Table[int, seq[string]]
    activeDepths*: seq[int]
    globalVarOrder*: seq[string]
    trailingBindings*: seq[(string, PlanValue)]
    attrIsIndexed*: bool

  SyntheticVar* = ref object
    name*: string
    sourceVar*: string
    patternIdx*: int
    position*: string

  RangeBoundsMap* = Table[string, seq[seq[(string, PlanValue)]]]

  QueryPlanResult* = ref object
    iterPlans*: seq[IterPlanData]
    lookups*: seq[Pattern]
    joinPatterns*: seq[Pattern]
    orderedVars*: seq[string]
    eVars*: HashSet[string]
    attrVars*: HashSet[string]
    tLookupVars*: seq[string]
    varOrder*: seq[string]
    planTraces*: seq[PlanTrace]
    history*: bool
    existsMode*: bool
    findVars*: seq[FindVar]
    rangeBounds*: RangeBoundsMap
    syntheticVars*: seq[SyntheticVar]

proc `$`*(sv: SyntheticVar): string =
  sv.name & "=" & sv.sourceVar & "@p" & $sv.patternIdx & "." & sv.position

proc `$`*(t: PlanTrace): string =
  let vars = t.ordering.join(", ")
  let prefix = if t.pruned: "PRUNED " elif t.chosen: "\u2192 " else: ""
  result = prefix & "[" & vars & "] cost=" & formatFloat(t.totalCost, ffDefault, 1)
  for i, d in t.depths:
    let clauses = d.activeClauses.mapIt("p" & $it[0] & "@" & it[1]).join(", ")
    if d.isBlind:
      result.add("\n  depth " & $i & ": " & d.varName & " | blind | est=" & formatFloat(d.estimatedElements, ffDefault, 1))
    else:
      result.add("\n  depth " & $i & ": " & d.varName & " | clauses=[" & clauses & "] | est=" & formatFloat(d.estimatedElements, ffDefault, 1) & " \xd7" & $d.activeClauses.len & "cl = " & formatFloat(d.stepCost, ffDefault, 1))

proc `$`*(plan: QueryPlanResult): string =
  if plan.orderedVars.len == 0:
    result = "Plan: lookups-only (no join)"
  else:
    result = "Join order: [" & plan.orderedVars.join(", ") & "]"
  if plan.findVars.len > 0:
    result.add("\nProjections: " & plan.findVars.mapIt($it).join(", "))
  if plan.iterPlans.len > 0:
    result.add("\nIter plans:")
    for i, ip in plan.iterPlans:
      result.add("\n  p" & $i & " @ " & ip.indexName)
      for posIdx, pos in ip.idxOrder:
        let spec = ip.specs[posIdx]
        let varLabel =
          block:
            var lbl = ""
            for (d, p) in ip.varDepths:
              if p == pos:
                lbl = "  [depth " & $d & "]"
                break
            lbl
        case spec.kind
        of skVar:
          let displayName = spec.varName
          result.add("\n    " & pos & " = ?" & displayName & varLabel)
        of skBoundAttr:
          result.add("\n    " & pos & " = attr(" & $spec.attrId & ")" & varLabel)
        of skBoundValue:
          result.add("\n    " & pos & " = " & $spec.bvStr & varLabel)
        of skBound:
          if spec.boundVal != 0:
            result.add("\n    " & pos & " = #" & $spec.boundVal & varLabel)
          else:
            result.add("\n    " & pos & " = _" & varLabel)
        of skBoundParam:
          result.add("\n    " & pos & " = %" & $spec.paramIdx & varLabel)
  if plan.lookups.len > 0:
    result.add("\nLookups: " & $plan.lookups.len)
  for trace in plan.planTraces:
    let isWinner = not trace.pruned and trace.ordering == plan.orderedVars
    if isWinner:
      result.add("\n\u2605 " & $trace)
    else:
      result.add("\n" & $trace)

proc boundPositionsBefore*(ip: IterPlanData, depth: int): seq[(string, PlanValue)] =
  let cutoff = block:
    var c = ip.idxOrder.len
    for (d, p) in ip.varDepths:
      if d == depth:
        for ix, name in ip.idxOrder:
          if name == p:
            c = ix
            break
        break
    c
  for i in 0..<cutoff:
    let pos = ip.idxOrder[i]
    if pos == "added": continue
    if pos in ip.boundInts:
      result.add((pos, ip.boundInts[pos]))

proc allBoundPositions*(ip: IterPlanData): seq[(string, PlanValue)] =
  for pos in ip.idxOrder:
    if pos == "added": continue
    if pos in ip.boundInts:
      result.add((pos, ip.boundInts[pos]))
