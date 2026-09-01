import std/[math, tables, sets, sequtils, algorithm, options, strutils, json]
import datalog_ast, pattern, planner_ast, ast as sql_ast

proc fromBoundValue*(bv: BoundValue): PlanValue =
  case bv.kind
  of bvInt: PlanValue(kind: pvValue, pvInt: bv.ival)
  of bvFloat: PlanValue(kind: pvValue, pvFloat: bv.fval)
  of bvStr, bvAttr: PlanValue(kind: pvValue, pvStr: if bv.kind == bvStr: bv.sval else: bv.attrName)
  of bvResolvedAttr: PlanValue(kind: pvValue, pvInt: bv.raId.int64)
  of bvParam: PlanValue(kind: pvParam, pvParamIdx: bv.paramIdx)
  of bvBool: PlanValue(kind: pvValue, pvInt: if bv.bval: 1 else: 0)
  of bvExpr: PlanValue(kind: pvExpr, exprValue: bv.exprValue)
  else: nil

proc convertRangeBounds*(bounds: Table[string, seq[seq[(string, BoundValue)]]]): RangeBoundsMap =
  for varName, branches in bounds:
    var rustBranches: seq[seq[(string, PlanValue)]]
    for branch in branches:
      var filtered: seq[(string, PlanValue)]
      for (op, bv) in branch:
        let pv = fromBoundValue(bv)
        if pv != nil:
          filtered.add((op, pv))
      rustBranches.add(filtered)
    result[varName] = rustBranches

proc isSlotBound(slot: DatalogSlot, boundVars: HashSet[string]): bool =
  case slot.kind
  of dsMissing: false
  of dsConst:
    if slot.constVal.kind == bvMissing: false
    else: true
  of dsVar: slot.varName in boundVars

proc isPrefixOk(slot: DatalogSlot, boundVars: HashSet[string]): bool =
  case slot.kind
  of dsMissing: true
  of dsConst: true
  of dsVar: slot.varName in boundVars

proc findBestIndex(pattern: Pattern, varName: string, boundVars: HashSet[string], refAttrs: HashSet[string]): tuple[name: string, prefixLen: int, gapCount: int] =
  let slotNames = ["e", "a", "v", "t", "added"]
  var targetPos = ""
  for pos in slotNames:
    let s = pattern.slot(pos)
    if s.kind == dsVar and s.varName == varName:
      targetPos = pos
      break
  if targetPos == "": return

  let attrIsRef = pattern.a.kind == dsConst and pattern.a.constVal.kind == bvResolvedAttr and pattern.a.constVal.raIsRef
  let attrIsIndexed =
    if pattern.a.kind == dsConst and pattern.a.constVal.kind == bvResolvedAttr:
      pattern.a.constVal.raIsIndexed
    else:
      true

  var best: tuple[name: string, prefixLen: int, gapCount: int]
  var bestInited = false

  for (idxName, idxOrder) in IndexOrders:
    if idxName == "VAET" and not attrIsRef: continue
    if idxName == "AVET" and not attrIsIndexed: continue

    var posInIdx = -1
    for i, p in idxOrder:
      if $p == targetPos:
        posInIdx = i
        break
    if posInIdx < 0: continue

    var valid = true
    for pi in 0..<posInIdx:
      if not isPrefixOk(pattern.slot($idxOrder[pi]), boundVars):
        valid = false
        break
    if not valid: continue

    var prefixLen = 0
    for pi in 0..<posInIdx:
      if isSlotBound(pattern.slot($idxOrder[pi]), boundVars):
        prefixLen += 1
      else:
        break

    var gapCount = 0
    for pi in 0..<posInIdx:
      if pattern.slot($idxOrder[pi]).kind == dsMissing:
        gapCount += 1

    if not bestInited or prefixLen > best.prefixLen or
       (prefixLen == best.prefixLen and gapCount < best.gapCount):
      best = ($idxName, prefixLen, gapCount)
      bestInited = true

  if bestInited: best else: return

proc isVarReachableInIndex(pattern: Pattern, varName: string, indexName: string, boundVars: HashSet[string]): bool =
  let slotNames = ["e", "a", "v", "t", "added"]
  var targetPos = ""
  for pos in slotNames:
    let s = pattern.slot(pos)
    if s.kind == dsVar and s.varName == varName:
      targetPos = pos
      break
  if targetPos == "": return false

  var idxEntry: seq[string]
  for (name, order) in IndexOrders:
    if name == indexName:
      idxEntry = @order
      break
  if idxEntry.len == 0: return false

  var posInIdx = -1
  for i, p in idxEntry:
    if p == targetPos:
      posInIdx = i
      break
  if posInIdx < 0: return false

  for pi in 0..<posInIdx:
    if not isSlotBound(pattern.slot(idxEntry[pi]), boundVars):
      return false
  true

proc estimateCardinality(patternIdx: int, indexName: string, varName: string, stats: PlanStats): float64 =
  let key = (patternIdx, indexName, varName)
  if key in stats.estimates: stats.estimates[key] else: Inf

type
  SearchState = ref object
    bestOrdering: seq[string]
    bestClauseIndexes: seq[Option[string]]
    bestCost: float64
    traces: seq[PlanTrace]

proc exploreOrderingDepth(
    remainingVars: seq[string],
    boundVars: HashSet[string],
    clauseIndexMap: seq[Option[string]],
    accumulatedCost: float64,
    topElements: float64,
    clauses: seq[Pattern],
    findVars: HashSet[string],
    rangeVars: HashSet[string],
    totalRecords: float64,
    stats: PlanStats,
    joinIndices: seq[int],
    refAttrs: HashSet[string],
    syntheticVars: seq[SyntheticVar],
    state: var SearchState,
    path: var seq[string],
    depthTraces: var seq[DepthTrace]
) =
  if remainingVars.len == 0:
    state.traces.add(PlanTrace(ordering: path, depths: depthTraces, totalCost: accumulatedCost, pruned: false, chosen: false))
    if accumulatedCost < state.bestCost:
      state.bestCost = accumulatedCost
      state.bestOrdering = path
      state.bestClauseIndexes = clauseIndexMap
    return

  if accumulatedCost >= state.bestCost:
    state.traces.add(PlanTrace(ordering: path, depths: depthTraces, totalCost: accumulatedCost, pruned: true, chosen: false))
    return

  proc varPriority(name: string): int =
    if name.startsWith("?e_"): 0
    elif name.startsWith("?a_"): 1
    elif name.startsWith("?v"): 2
    elif name.startsWith("_t_"): 3
    elif name.startsWith("?added_"): 4
    else: 5

  var candidates = remainingVars
  candidates.sort proc(a, b: string): int =
    let aFind = findVars.contains(a)
    let bFind = findVars.contains(b)
    result = cmp(bFind, aFind)
    if result == 0: result = cmp(varPriority(a), varPriority(b))
    if result == 0: result = cmp(a, b)

  for currentVar in candidates:
    var isSynthetic: SyntheticVar
    for s in syntheticVars:
      if s.name == currentVar:
        isSynthetic = s
        break
    if isSynthetic != nil:
      if isSynthetic.sourceVar notin boundVars:
        continue

    var activeClauses: seq[(int, string)]
    var clauseSizes: seq[float64]
    var newClauseIndexes = clauseIndexMap
    var totalGaps = 0

    for ci, clause in clauses:
      if not clause.containsVarInEav(currentVar): continue

      if clauseIndexMap[ci].isSome:
        let assignedIdx = clauseIndexMap[ci].get
        if isVarReachableInIndex(clause, currentVar, assignedIdx, boundVars):
          activeClauses.add((ci, assignedIdx))
          let sz = estimateCardinality(joinIndices[ci], assignedIdx, currentVar, stats)
          clauseSizes.add(sz)
      else:
        let best = findBestIndex(clause, currentVar, boundVars, refAttrs)
        if best.name != "":
          activeClauses.add((ci, best.name))
          newClauseIndexes[ci] = some(best.name)
          let sz = estimateCardinality(joinIndices[ci], best.name, currentVar, stats)
          clauseSizes.add(sz)
          totalGaps += best.gapCount

    let isBlind = activeClauses.len == 0
    let rangeSel = if currentVar in rangeVars: 0.1 else: 1.0
    let depth = path.len

    let (levelElements, stepCost) =
      if isSynthetic != nil:
        (topElements, depth.float64 * 0.1)
      elif isBlind:
        let el = totalRecords * rangeSel
        if path.len == 0: (el, el * el)
        else: (el, topElements * el)
      else:
        let el = clauseSizes.min * rangeSel
        var undefPenalty = 1.0
        for (ci, _) in activeClauses:
          let cl = clauses[ci]
          var undefCount = 0
          for s in [cl.e, cl.a, cl.v]:
            if s.kind == dsVar and s.varName != currentVar and s.varName notin boundVars:
              undefCount += 1
          if undefCount > 0:
            undefPenalty = max(undefPenalty, 1.0 + undefCount.float64)
        let cost = el * activeClauses.len.float64 * undefPenalty * (1.0 + totalGaps.float64)
        (el, cost)

    let adjustedCost = stepCost

    path.add(currentVar)
    depthTraces.add(DepthTrace(
      varName: currentVar, activeClauses: activeClauses,
      estimatedElements: levelElements, isBlind: isBlind, stepCost: adjustedCost, penalty: false))

    var newBound = boundVars
    newBound.incl(currentVar)
    var newRemaining: seq[string]
    for v in remainingVars:
      if v != currentVar: newRemaining.add(v)

    exploreOrderingDepth(newRemaining, newBound, newClauseIndexes,
      accumulatedCost + adjustedCost, levelElements, clauses,
      findVars, rangeVars, totalRecords, stats, joinIndices, refAttrs,
      syntheticVars, state, path, depthTraces)

    discard path.pop()
    discard depthTraces.pop()

proc buildIterPlan(
    pattern: Pattern, patternIdx: int, idxName: string,
    boundInts: Table[string, PlanValue], globalVarOrder: seq[string],
    syntheticVars: seq[SyntheticVar]): IterPlanData =

  var idxEntry: seq[string]
  for (name, order) in IndexOrders:
    if name == idxName:
      idxEntry = @order
      break

  var idxOrder: array[5, string]
  for i in 0..<5: idxOrder[i] = idxEntry[i]

  proc synthNameFor(pos: string): string =
    for s in syntheticVars:
      if s.patternIdx == patternIdx and s.position == pos:
        return s.name
    return ""

  let slots = [pattern.e, pattern.a, pattern.v, pattern.t, pattern.added]
  var specs: array[5, SpecKind]
  for i, s in slots:
    specs[i] = case s.kind
      of dsMissing: SpecKind(kind: skBound, boundVal: 0)
      of dsVar: SpecKind(kind: skVar, varName: s.varName)
      of dsConst:
        case s.constVal.kind
        of bvInt: SpecKind(kind: skBoundValue, bvInt: s.constVal.ival)
        of bvFloat: SpecKind(kind: skBoundValue, bvFloat: s.constVal.fval)
        of bvStr: SpecKind(kind: skBoundValue, bvStr: s.constVal.sval)
        of bvAttr: SpecKind(kind: skBoundValue, bvStr: s.constVal.attrName)
        of bvResolvedAttr: SpecKind(kind: skBoundAttr, attrId: s.constVal.raId)
        of bvParam: SpecKind(kind: skBoundParam, paramIdx: s.constVal.paramIdx)
        of bvVar: SpecKind(kind: skVar, varName: s.constVal.varName)
        of bvExpr: SpecKind(kind: skBoundExpr, bvExprRepr: $toJson(s.constVal.exprValue))
        else: SpecKind(kind: skBound, boundVal: 0)

  var varDepths: seq[(int, string)]
  var sameVarConstraints = initTable[int, seq[string]]()
  var activeDepthsSet = initHashSet[int]()
  var seenRealVar = false

  for pos in idxEntry:
    let specIdx = case pos
      of "e": 0
      of "a": 1
      of "v": 2
      of "t": 3
      of "added": 4
      else: continue
    let slot = pattern.slot(pos)
    case slot.kind
    of dsVar:
      seenRealVar = true
      let syntheticName = synthNameFor(pos)
      let effectiveName = if syntheticName != "": syntheticName else: slot.varName
      # Find depth from globalVarOrder
      var foundDepth = -1
      for di, v in globalVarOrder:
        if v == effectiveName:
          foundDepth = di
          break
      if foundDepth >= 0:
        if foundDepth notin activeDepthsSet:
          varDepths.add((foundDepth, pos))
          activeDepthsSet.incl(foundDepth)
          if effectiveName != slot.varName:
            specs[specIdx] = SpecKind(kind: skVar, varName: effectiveName)
        else:
          if foundDepth notin sameVarConstraints:
            sameVarConstraints[foundDepth] = @[]
          sameVarConstraints[foundDepth].add(pos)
    of dsMissing:
      if not seenRealVar:
        let synthName = "?skip_" & pos & "_" & idxEntry[0].toLowerAscii()
        var foundDepth = -1
        for di, v in globalVarOrder:
          if v == synthName:
            foundDepth = di
            break
        if foundDepth >= 0 and foundDepth notin activeDepthsSet:
          varDepths.add((foundDepth, pos))
          activeDepthsSet.incl(foundDepth)
          specs[specIdx] = SpecKind(kind: skVar, varName: synthName)
    else: discard

  var activeDepths: seq[int]
  for d in activeDepthsSet: activeDepths.add(d)
  activeDepths.sort()
  varDepths.sort proc(a, b: (int, string)): int = cmp(a[0], b[0])

  # Filter varDepths: remove unreachable entries
  var filteredDepths: seq[(int, string)]
  for (depth, pos) in varDepths:
    let slot = pattern.slot(pos)
    if slot.kind != dsVar:
      filteredDepths.add((depth, pos))
      continue
    var resolved = initHashSet[string]()
    for i in 0..<depth:
      resolved.incl(globalVarOrder[i])
    var idxEntry2: seq[string]
    for (name, order) in IndexOrders:
      if name == idxName:
        idxEntry2 = @order
        break
    if idxEntry2.len == 0: continue
    var posInIdx = -1
    for i, p in idxEntry2:
      if p == pos:
        posInIdx = i
        break
    if posInIdx < 0: continue
    var ok = true
    for pi in 0..<posInIdx:
      if not isPrefixOk(pattern.slot(idxEntry2[pi]), resolved):
        ok = false
        break
    if ok:
      filteredDepths.add((depth, pos))
  varDepths = filteredDepths

  activeDepths.setLen(0)
  for (d, _) in varDepths:
    if activeDepths.len == 0 or d != activeDepths[^1]:
      activeDepths.add(d)

  let attrIsIndexed =
    if pattern.a.kind == dsConst and pattern.a.constVal.kind == bvResolvedAttr:
      pattern.a.constVal.raIsIndexed
    else: true

  IterPlanData(
    indexName: idxName,
    idxOrder: idxOrder,
    specs: specs,
    boundInts: boundInts,
    varDepths: varDepths,
    sameVarConstraints: sameVarConstraints,
    activeDepths: activeDepths,
    globalVarOrder: globalVarOrder,
    trailingBindings: @[],
    attrIsIndexed: attrIsIndexed,
  )

proc buildQueryPlan*(
    wherePatterns: seq[Pattern],
    findVars: seq[string],
    rangeVars: HashSet[string],
    stats: PlanStats,
): QueryPlanResult =

  let lookups = wherePatterns.filterIt(it.isLookup())
  var joinIndices: seq[int]
  for i, p in wherePatterns:
    if not p.isLookup(): joinIndices.add(i)
  let joinPatterns = wherePatterns.filterIt(not it.isLookup())

  if joinPatterns.len == 0:
    var tLookupVars: seq[string]
    for p in lookups:
      if p.t.kind == dsVar and p.t.varName notin tLookupVars:
        tLookupVars.add(p.t.varName)
    return QueryPlanResult(
      iterPlans: @[], lookups: lookups, joinPatterns: joinPatterns,
      orderedVars: @[], eVars: initHashSet[string](),
      attrVars: initHashSet[string](), tLookupVars: tLookupVars,
      varOrder: @[], planTraces: @[], rangeBounds: initTable[string, seq[seq[(string, PlanValue)]]](),
      syntheticVars: @[],
    )

  var seen = initHashSet[string]()
  var varOrder: seq[string]
  var allVars: seq[string]
  var syntheticVars: seq[SyntheticVar]
  for patIdx, pattern in joinPatterns:
    var seenInPattern = initHashSet[string]()
    var occurrencesInPattern = initTable[string, seq[string]]()
    for (posName, slot) in [("e", pattern.e), ("a", pattern.a), ("v", pattern.v), ("t", pattern.t), ("added", pattern.added)]:
      if slot.kind == dsVar:
        let name = slot.varName
        if name notin occurrencesInPattern:
          occurrencesInPattern[name] = @[]
        occurrencesInPattern[name].add(posName)
        if occurrencesInPattern[name].len > 2:
          raise newException(ValueError,
            "variable '" & name & "' appears in " & $occurrencesInPattern[name].len &
            " positions (" & occurrencesInPattern[name].join(", ") &
            ") in pattern " & $patIdx &
            "; only 2 occurrences (same-var confirmation) are supported")
        if name notin seen:
          seen.incl(name)
          varOrder.add(name)
          allVars.add(name)
          seenInPattern.incl(name)
        elif name notin seenInPattern:
          seenInPattern.incl(name)
        else:
          let synthName = name & "@p" & $patIdx & "." & posName
          allVars.add(synthName)
          syntheticVars.add(SyntheticVar(
            name: synthName, sourceVar: name,
            patternIdx: patIdx, position: posName))

  var eVars = initHashSet[string]()
  var attrVars = initHashSet[string]()
  for p in joinPatterns:
    if p.e.kind == dsVar: eVars.incl(p.e.varName)
    if p.a.kind == dsVar: attrVars.incl(p.a.varName)

  let findSet = toHashSet(findVars)
  let totalRecords = stats.totalEavt

  var refAttrs = initHashSet[string]()
  for p in joinPatterns:
    if p.a.kind == dsConst and p.a.constVal.kind == bvResolvedAttr and p.a.constVal.raIsRef:
      refAttrs.incl(p.a.constVal.raName)

  var clauseIndexMap: seq[Option[string]] = newSeq[Option[string]](joinPatterns.len)

  var state = SearchState(
    bestCost: Inf,
    traces: @[],
  )
  var path: seq[string]
  var depthTraces: seq[DepthTrace]

  exploreOrderingDepth(allVars, initHashSet[string](), clauseIndexMap, 0.0, 1.0,
    joinPatterns, findSet, rangeVars, totalRecords, stats, joinIndices, refAttrs,
    syntheticVars, state, path, depthTraces)

  var bestOrderingOrig = state.bestOrdering
  var orderedVars = if state.bestOrdering.len > 0: state.bestOrdering else: allVars
  var clauseIndexes = if state.bestClauseIndexes.len > 0: state.bestClauseIndexes else: clauseIndexMap

  # Validation-only patterns
  for patIdx, pattern in joinPatterns:
    if clauseIndexes[patIdx].isSome: continue
    let hasVar = pattern.e.kind == dsVar or pattern.a.kind == dsVar or
                 pattern.v.kind == dsVar or pattern.t.kind == dsVar or
                 pattern.added.kind == dsVar
    if hasVar or pattern.isLookup(): continue
    var bestIdx: string
    var bestScore = 0
    for (idxName, idxOrder) in IndexOrders:
      var score = 0
      for pos in idxOrder:
        if pattern.slot($pos).kind == dsConst: score += 1
        else: break
      if score > bestScore:
        bestScore = score
        bestIdx = $idxName
    if bestScore > 0:
      clauseIndexes[patIdx] = some(bestIdx)

  # Pre-compute skip vars for Missing gaps
  for patIdx, pattern in joinPatterns:
    let idxName = if clauseIndexes[patIdx].isSome: clauseIndexes[patIdx].get else: continue
    var idxEntry: seq[string]
    for (name, order) in IndexOrders:
      if name == idxName: idxEntry = @order; break

    var firstVarPos = -1
    for i, pos in idxEntry:
      if pattern.slot(pos).kind == dsVar:
        firstVarPos = i
        break
    if firstVarPos < 0: continue
    let targetVar = if pattern.slot(idxEntry[firstVarPos]).kind == dsVar:
      pattern.slot(idxEntry[firstVarPos]).varName else: continue
    for posIdx in 0..<firstVarPos:
      let pos = idxEntry[posIdx]
      if pattern.slot(pos).kind == dsMissing:
        let synthName = "?skip_" & pos & "_" & idxName.toLowerAscii()
        if synthName notin orderedVars:
          var found = false
          for vi, v in orderedVars:
            if v == targetVar:
              orderedVars.insert(synthName, vi)
              found = true
              break
          if not found: orderedVars.add(synthName)

  var iterPlans: seq[IterPlanData]
  for patIdx, pattern in joinPatterns:
    let idxName = if clauseIndexes[patIdx].isSome: clauseIndexes[patIdx].get else: continue

    var boundInts = initTable[string, PlanValue]()
    if pattern.e.kind == dsConst:
      case pattern.e.constVal.kind
      of bvInt: boundInts["e"] = PlanValue(kind: pvValue, pvInt: pattern.e.constVal.ival)
      of bvStr, bvAttr: boundInts["e"] = PlanValue(kind: pvValue, pvStr: if pattern.e.constVal.kind == bvStr: pattern.e.constVal.sval else: pattern.e.constVal.attrName)
      of bvParam: boundInts["e"] = PlanValue(kind: pvParam, pvParamIdx: pattern.e.constVal.paramIdx)
      of bvExpr: boundInts["e"] = PlanValue(kind: pvExpr, exprValue: pattern.e.constVal.exprValue)
      else: discard
    if pattern.a.kind == dsConst:
      case pattern.a.constVal.kind
      of bvResolvedAttr: boundInts["a"] = PlanValue(kind: pvValue, pvStr: pattern.a.constVal.raName)
      of bvStr, bvAttr: boundInts["a"] = PlanValue(kind: pvValue, pvStr: if pattern.a.constVal.kind == bvStr: pattern.a.constVal.sval else: pattern.a.constVal.attrName)
      of bvParam: boundInts["a"] = PlanValue(kind: pvParam, pvParamIdx: pattern.a.constVal.paramIdx)
      of bvExpr: boundInts["a"] = PlanValue(kind: pvExpr, exprValue: pattern.a.constVal.exprValue)
      else: discard
    if pattern.v.kind == dsConst:
      case pattern.v.constVal.kind
      of bvInt: boundInts["v"] = PlanValue(kind: pvValue, pvInt: pattern.v.constVal.ival)
      of bvFloat: boundInts["v"] = PlanValue(kind: pvValue, pvFloat: pattern.v.constVal.fval)
      of bvStr, bvAttr: boundInts["v"] = PlanValue(kind: pvValue, pvStr: if pattern.v.constVal.kind == bvStr: pattern.v.constVal.sval else: pattern.v.constVal.attrName)
      of bvParam: boundInts["v"] = PlanValue(kind: pvParam, pvParamIdx: pattern.v.constVal.paramIdx)
      of bvExpr: boundInts["v"] = PlanValue(kind: pvExpr, exprValue: pattern.v.constVal.exprValue)
      else: discard

    iterPlans.add(buildIterPlan(pattern, patIdx, idxName, boundInts, orderedVars, syntheticVars))

  var tLookupVars: seq[string]
  for p in lookups:
    if p.t.kind == dsVar and p.t.varName notin tLookupVars:
      tLookupVars.add(p.t.varName)

  var planTraces = state.traces
  for trace in planTraces.mitems:
    if trace.pruned: continue
    if bestOrderingOrig == trace.ordering:
      trace.chosen = true
      var oldDepths = initTable[string, DepthTrace]()
      for d in trace.depths:
        oldDepths[d.varName] = d
      trace.depths.setLen(0)
      for varName in orderedVars:
        if varName in oldDepths:
          trace.depths.add(oldDepths[varName])
        else:
          trace.depths.add(DepthTrace(
            varName: varName, activeClauses: @[],
            estimatedElements: 0.0, isBlind: false, stepCost: 0.0, penalty: false))
      trace.ordering = orderedVars

  QueryPlanResult(
    iterPlans: iterPlans, lookups: lookups, joinPatterns: joinPatterns,
    orderedVars: orderedVars, eVars: eVars, attrVars: attrVars,
    tLookupVars: tLookupVars, varOrder: varOrder, planTraces: planTraces,
    rangeBounds: initTable[string, seq[seq[(string, PlanValue)]]](),
    syntheticVars: syntheticVars,
  )
