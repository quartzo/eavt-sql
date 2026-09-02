import std/[tables, sets, strutils, sequtils, options]
import datalog_ast, pattern, planner_ast, planner
import scheme

template list*(items: varargs[SExpr]): SExpr =
  newList(@items)

proc planValueToSexpr(pv: PlanValue): SExpr =
  case pv.kind
  of pvValue:
    if pv.pvStr != "": newStr(pv.pvStr)
    elif pv.pvFloat != 0: newFloat(pv.pvFloat)
    else: newInt(pv.pvInt)
  of pvParam: list(newKeyword("param"), newInt(pv.pvParamIdx.int64))

proc boundToSexpr(bv: BoundValue): SExpr =
  case bv.kind
  of bvInt: newInt(bv.ival)
  of bvFloat: newFloat(bv.fval)
  of bvStr, bvAttr: newStr(if bv.kind == bvStr: bv.sval else: bv.attrName)
  of bvResolvedAttr: list(newKeyword("intern-a"), newStr(bv.raName))
  of bvParam: list(newKeyword("param"), newInt(bv.paramIdx.int64))
  of bvVar: newSymbol("?" & bv.varName)
  of bvBool: newBool(bv.bval)
  else: newSymbol("_")

proc buildRangeTree(branches: seq[seq[(string, PlanValue)]]): SExpr =
  proc buildBranch(branch: seq[(string, PlanValue)]): SExpr =
    var inVals: seq[SExpr]
    var otherConds: seq[SExpr]
    for (op, pv) in branch:
      if op == "in":
        inVals.add(planValueToSexpr(pv))
      else:
        otherConds.add(list(newKeyword(op), planValueToSexpr(pv)))
    if inVals.len == 1:
      otherConds.add(list(newKeyword("="), inVals[0]))
    elif inVals.len > 1:
      var eqs: seq[SExpr] = @[newKeyword("or")]
      for v in inVals:
        eqs.add(list(newKeyword("="), v))
      otherConds.add(list(eqs))
    if otherConds.len == 1: otherConds[0]
    else: list(@[newKeyword("and")] & otherConds)

  if branches.len == 1: buildBranch(branches[0])
  else:
    var branchSexprs: seq[SExpr]
    for b in branches: branchSexprs.add(buildBranch(b))
    list(@[newKeyword("or")] & branchSexprs)

proc replaceBodyPlaceholder(expr: SExpr, replacement: SExpr): SExpr =
  if expr.kind == sSymbol and expr.symval == "__BODY__":
    return replacement
  elif expr.kind == sList:
    list(expr.items.mapIt(replaceBodyPlaceholder(it, replacement)))
  else:
    expr

proc flattenBegins*(expr: SExpr): SExpr =
  case expr.kind
  of sList:
    let items = expr.items.mapIt(flattenBegins(it))
    if items.len > 0 and items[0].kind == sKeyword and items[0].kwval == "begin":
      var acc: seq[SExpr] = @[items[0]]
      for item in items[1..^1]:
        if item.kind == sList and item.items.len > 0 and
           item.items[0].kind == sKeyword and item.items[0].kwval == "begin":
          acc.add(item.items[1..^1])
        else:
          acc.add(item)
      list(acc)
    else:
      list(items)
  else: expr

proc buildTriejoinScheme*(plan: QueryPlanResult, findVars: seq[string],
    leafBody: SExpr): tuple[prog: SchemeProgram, vars: seq[string], depthVarPairs: seq[(int, int)]] =
  let orderedVars = plan.orderedVars
  let numDepths = orderedVars.len

  var varNamesList = orderedVars
  for tn in plan.tLookupVars:
    if tn notin varNamesList: varNamesList.add(tn)
  for ip in plan.iterPlans:
    for (name, _) in ip.trailingBindings:
      if name notin varNamesList: varNamesList.add(name)

  var varIdMap = initTable[string, int]()
  for i, n in varNamesList:
    varIdMap[n] = i

  var depthVarPairs: seq[(int, int)]
  for d, name in orderedVars:
    depthVarPairs.add((d, varIdMap[name]))

  var scannerBindings: seq[SExpr]
  for ipIdx, ip in plan.iterPlans:
    let scannerName = "?s" & $ipIdx
    var openArgs = @[newKeyword("scanner-open"), newStr(toUpperAscii(ip.indexName))]
    if plan.history: openArgs.add(newBool(true))
    scannerBindings.add(list(newSymbol(scannerName), list(openArgs)))

  var depthRanges = initTable[int, SExpr]()
  for varName, branches in pairs(plan.rangeBounds):
    var found = -1
    for i, v in orderedVars:
      if v == varName: found = i; break
    if found >= 0:
      depthRanges[found] = buildRangeTree(branches)

  var bindVals: seq[Table[string, SExpr]]
  for ip in plan.iterPlans:
    var bv = initTable[string, SExpr]()
    for (posName, pv) in pairs(ip.boundInts):
      let valExpr = if pv.kind == pvValue and pv.pvStr != "" and posName == "a":
        list(newKeyword("intern-a"), newStr(pv.pvStr))
      else:
        planValueToSexpr(pv)
      bv[posName] = valExpr
    bindVals.add(bv)

  var ops: seq[SExpr]
  var boundEmitted: seq[HashSet[string]]
  var scanPos: seq[int]
  for _ in plan.iterPlans:
    boundEmitted.add(initHashSet[string]())
    scanPos.add(0)

  for depth in 0..<numDepths:
    let varName = orderedVars[depth]

    var scanners: seq[SExpr]
    for ipIdx, ip in plan.iterPlans:
      var found = false
      for (d, _) in ip.varDepths:
        if d == depth: found = true; break
      if found: scanners.add(newSymbol("?s" & $ipIdx))
    if scanners.len == 0: continue

    for ipIdx, ip in plan.iterPlans:
      var found = false
      for (d, _) in ip.varDepths:
        if d == depth: found = true; break
      if not found: continue

      var varPos = ""
      for (d, p) in ip.varDepths:
        if d == depth: varPos = p; break

      for (posName, _) in ip.boundPositionsBefore(depth):
        if posName in boundEmitted[ipIdx]: continue
        if posName in bindVals[ipIdx]:
          boundEmitted[ipIdx].incl(posName)
          scanPos[ipIdx] += 1
          let scannerSym = newSymbol("?s" & $ipIdx)
          ops.add(list(
            newKeyword("begin"),
            list(newKeyword("scanner-push"), scannerSym, bindVals[ipIdx][posName]),
            newSymbol("__BODY__"),
            list(newKeyword("scanner-pop"), scannerSym),
          ))

      var targetIdx = ip.idxOrder.len
      for i, s in ip.idxOrder:
        if s == varPos: targetIdx = i; break
      while scanPos[ipIdx] < targetIdx:
        let gapSlot = ip.idxOrder[scanPos[ipIdx]]
        var isHandled = false
        for (d, s) in ip.varDepths:
          if d <= depth and s == gapSlot: isHandled = true; break
        if gapSlot in boundEmitted[ipIdx] or isHandled:
          scanPos[ipIdx] += 1
          continue
        let gapVar = "?skip_" & gapSlot & "_" & toLowerAscii(ip.indexName)
        scanPos[ipIdx] += 1
        let scannerSym = newSymbol("?s" & $ipIdx)
        let gapIterVar = newSymbol("?it_" & gapVar)
        let gapBody = list(
          newKeyword("begin"),
          list(newKeyword("scanner-push"), scannerSym, newSymbol(gapVar)),
          newSymbol("__BODY__"),
          list(newKeyword("scanner-pop"), scannerSym))
        let gapWhile = list(
          newKeyword("while"),
          list(newKeyword("set!"), newSymbol(gapVar),
            list(newKeyword("scanner-iterate-next"), gapIterVar)),
          gapBody)
        let gapExpr = list(
          newKeyword("begin"),
          list(newKeyword("set!"), gapIterVar,
            list(newKeyword("scanner-iterate-init"), scannerSym, list())),
          gapWhile)
        ops.add(gapExpr)

    let rangesTree = if depthRanges.hasKey(depth): depthRanges[depth] else: list()
    let rangesIsEmpty = rangesTree.kind == sList and rangesTree.items.len == 0

    var rangesExpr: SExpr = list()
    var isSynthetic = false
    for synth in plan.syntheticVars:
      if synth.name == varName:
        rangesExpr = list(newKeyword("ranges-create"), list(newKeyword("="), newSymbol(synth.sourceVar)))
        isSynthetic = true
        break
    if not isSynthetic and not rangesIsEmpty:
      rangesExpr = list(newKeyword("ranges-create"), rangesTree)

    var initArgs: seq[SExpr] = @[]
    for s in scanners: initArgs.add(s)
    initArgs.add(rangesExpr)

    let iterVar = newSymbol("?it_" & varName)

    var innerItems = @[newKeyword("begin")]
    if depth < numDepths - 1:
      for s in scanners:
        innerItems.add(list(newKeyword("scanner-push"), s, newSymbol(varName)))
      for ipIdx, ip in plan.iterPlans:
        for (d, p) in ip.varDepths:
          if d == depth: boundEmitted[ipIdx].incl(p); break
    innerItems.add(newSymbol("__BODY__"))
    if depth < numDepths - 1:
      for s in scanners:
        innerItems.add(list(newKeyword("scanner-pop"), s))

    let mainWhile = list(
      newKeyword("while"),
      list(newKeyword("set!"), newSymbol(varName),
        list(newKeyword("scanner-iterate-next"), iterVar)),
      list(innerItems))
    let mainExpr = list(
      newKeyword("begin"),
      list(newKeyword("set!"), iterVar,
        list(@[newKeyword("scanner-iterate-init")] & initArgs)),
      mainWhile)
    ops.add(mainExpr)

  var rangeTrees: Table[string, SExpr]
  for varName, branches in pairs(plan.rangeBounds):
    rangeTrees[varName] = buildRangeTree(branches)

  for ipIdx, ip in plan.iterPlans:
    var trailing: seq[(string, SExpr)]
    for (posName, _) in ip.allBoundPositions():
      if posName in boundEmitted[ipIdx]: continue
      if posName in bindVals[ipIdx]:
        trailing.add((posName, bindVals[ipIdx][posName]))

    if trailing.len == 0: continue

    var posToVar: Table[string, SExpr]
    for (d, p) in ip.varDepths:
      if d < orderedVars.len:
        posToVar[p] = newSymbol(orderedVars[d])

    var prePushes: seq[string] = @[]
    for pos in ip.idxOrder:
      block checkPos:
        for (posName, _) in trailing:
          if pos == posName: break checkPos
        if pos in boundEmitted[ipIdx]: continue
        if pos in posToVar: prePushes.add(pos)

    let lastIdx = trailing.len - 1
    for i, (posName, valExpr) in trailing:
      boundEmitted[ipIdx].incl(posName)
      let scannerSym = newSymbol("?s" & $ipIdx)
      if i == lastIdx:
        var lastRanges = list(newKeyword("="), valExpr)
        for posIdx, pos in ip.idxOrder:
          if pos == posName or posIdx >= ip.idxOrder.len: continue
          let spec = ip.specs[posIdx]
          if spec.kind == skVar and spec.varName in rangeTrees and
             pos notin boundEmitted[ipIdx] and pos notin posToVar:
            lastRanges = rangeTrees[spec.varName]
            boundEmitted[ipIdx].incl(pos)
            break
        let trailVar = "_" & posName & "_trail"
        let trailIterVar = newSymbol("?it_" & trailVar)
        let trailRanges = list(newKeyword("ranges-create"), lastRanges)
        let trailBody = list(
          newKeyword("begin"),
          list(newKeyword("scanner-push"), scannerSym, newSymbol(trailVar)),
          newSymbol("__BODY__"),
          list(newKeyword("scanner-pop"), scannerSym))
        let trailWhile = list(
          newKeyword("while"),
          list(newKeyword("set!"), newSymbol(trailVar),
            list(newKeyword("scanner-iterate-next"), trailIterVar)),
          trailBody)
        var trailItems = @[newKeyword("begin")]
        for p in prePushes:
          trailItems.add(list(newKeyword("scanner-push"), scannerSym, posToVar[p]))
        trailItems.add(list(
          newKeyword("set!"), trailIterVar,
          list(newKeyword("scanner-iterate-init"), scannerSym, trailRanges)))
        trailItems.add(trailWhile)
        for p in countdown(prePushes.len - 1, 0):
          trailItems.add(list(newKeyword("scanner-pop"), scannerSym))
        ops.add(list(trailItems))
      else:
        var pushItems = @[newKeyword("begin")]
        for p in prePushes:
          pushItems.add(list(newKeyword("scanner-push"), scannerSym, posToVar[p]))
        pushItems.add(list(newKeyword("scanner-push"), scannerSym, valExpr))
        pushItems.add(newSymbol("__BODY__"))
        pushItems.add(list(newKeyword("scanner-pop"), scannerSym))
        for p in countdown(prePushes.len - 1, 0):
          pushItems.add(list(newKeyword("scanner-pop"), scannerSym))
        ops.add(list(pushItems))

  var iteratedVars: HashSet[string]
  for ip in plan.iterPlans:
    for (d, p) in ip.varDepths:
      if d < orderedVars.len:
        iteratedVars.incl(orderedVars[d])

  for ipIdx, ip in plan.iterPlans:
    var posToVar: Table[string, SExpr]
    for (d, p) in ip.varDepths:
      if d < orderedVars.len:
        posToVar[p] = newSymbol(orderedVars[d])

    var emittedPos: HashSet[string]
    for posName in bindVals[ipIdx].keys: emittedPos.incl(posName)

    for posIdx, pos in ip.idxOrder:
      let spec = ip.specs[posIdx]
      if spec.kind != skVar: continue
      if spec.varName notin rangeTrees: continue
      if spec.varName in iteratedVars: continue
      if pos in posToVar: continue
      if pos in emittedPos: continue
      emittedPos.incl(pos)

      let scannerSym = newSymbol("?s" & $ipIdx)
      let varSym = newSymbol(spec.varName)
      let iterVar = newSymbol("?it_" & spec.varName)
      let rangesExpr = list(newKeyword("ranges-create"), rangeTrees[spec.varName])

      var prePushes: seq[string] = @[]
      for checkIdx, checkPos in ip.idxOrder:
        if checkIdx >= posIdx: break
        if checkPos in emittedPos: continue
        if checkPos in posToVar: prePushes.add(checkPos)

      let innerBody = list(
        newKeyword("begin"),
        list(newKeyword("scanner-push"), scannerSym, varSym),
        newSymbol("__BODY__"),
        list(newKeyword("scanner-pop"), scannerSym))
      let innerWhile = list(
        newKeyword("while"),
        list(newKeyword("set!"), varSym,
          list(newKeyword("scanner-iterate-next"), iterVar)),
        innerBody)
      var items = @[newKeyword("begin")]
      for p in prePushes:
        items.add(list(newKeyword("scanner-push"), scannerSym, posToVar[p]))
      items.add(list(
        newKeyword("set!"), iterVar,
        list(newKeyword("scanner-iterate-init"), scannerSym, rangesExpr)))
      items.add(innerWhile)
      for p in countdown(prePushes.len - 1, 0):
        items.add(list(newKeyword("scanner-pop"), scannerSym))
      ops.add(list(items))

  var body = leafBody
  for i in countdown(ops.len-1, 0):
    body = replaceBodyPlaceholder(ops[i], body)

  for pattern in plan.lookups:
    if not pattern.isLookup(): continue
    let tParam = if pattern.t.kind == dsVar: pattern.t.varName else: "_t"
    let eVal = if pattern.e.kind == dsConst: boundToSexpr(pattern.e.constVal) else: continue
    let aVal = if pattern.a.kind == dsConst: boundToSexpr(pattern.a.constVal) else: continue
    let vVal = if pattern.v.kind == dsConst: boundToSexpr(pattern.v.constVal) else: continue
    let probeSVar = "?s_probe"
    let probeIterVar = newSymbol("?it_probe")
    body = list(
      newKeyword("begin"),
      list(newKeyword("set!"), newSymbol(probeSVar),
        list(newKeyword("scanner-open"), newStr("EAVT"))),
      list(newKeyword("set!"), probeIterVar,
        list(newKeyword("scanner-iterate-init"), newSymbol(probeSVar), list())),
      list(
        newKeyword("begin"),
        list(newKeyword("scanner-push"), newSymbol(probeSVar), eVal),
        list(newKeyword("scanner-push"), newSymbol(probeSVar), aVal),
        list(newKeyword("scanner-push"), newSymbol(probeSVar), vVal),
        list(
          newKeyword("while"),
          list(newKeyword("set!"), newSymbol(tParam),
            list(newKeyword("scanner-iterate-next"), probeIterVar)),
          list(
            newKeyword("begin"),
            list(newKeyword("scanner-push"), newSymbol(probeSVar), newSymbol(tParam)),
            body,
            list(newKeyword("scanner-pop"), newSymbol(probeSVar)),
          ),
        ),
        list(newKeyword("scanner-pop"), newSymbol(probeSVar)),
        list(newKeyword("scanner-pop"), newSymbol(probeSVar)),
        list(newKeyword("scanner-pop"), newSymbol(probeSVar)),
      ),
    )

  var fullBody = body
  if scannerBindings.len > 0:
    var stmts: seq[SExpr] = @[newKeyword("begin")]
    for b in scannerBindings:
      if b.kind == sList and b.items.len >= 2:
        stmts.add(list(newKeyword("set!"), b.items[0], b.items[1]))
    stmts.add(body)
    fullBody = list(stmts)

  let flatBody = flattenBegins(fullBody)
  (SchemeProgram(body: flatBody), varNamesList, depthVarPairs)

proc buildProjection(plan: QueryPlanResult, totalProjLen: int, constantIndices: Table[int, PlanValue]): SExpr =
  var projArgs: seq[SExpr]
  var fvIdx = 0
  let findVars = plan.findVars.mapIt(
    case it.kind
    of fvVar: it.varName
    of fvConst: it.cName
  )

  for i in 0..<totalProjLen:
    if i in constantIndices:
      projArgs.add(planValueToSexpr(constantIndices[i]))
      fvIdx += 1
      continue
    if fvIdx >= findVars.len:
      projArgs.add(newVoid())
      continue
    let varName = findVars[fvIdx]
    fvIdx += 1
    let bnd = newSymbol(varName)
    if varName in plan.attrVars:
      projArgs.add(list(newKeyword("attr-name"), bnd))
    else:
      projArgs.add(list(newKeyword("resolve-val"), bnd))

  list(@[newKeyword("result-row")] & projArgs)

proc compileSelectScheme*(plan: QueryPlanResult): tuple[prog: SchemeProgram, vars: seq[string], depthVarPairs: seq[(int, int)]] =
  var findVars: seq[string]
  var constantIndices = initTable[int, PlanValue]()
  for i, fv in plan.findVars:
    case fv.kind
    of fvVar: findVars.add(fv.varName)
    of fvConst:
      findVars.add(fv.cName)
      let pv = fromBoundValue(fv.cVal)
      if pv != nil: constantIndices[i] = pv

  let leafBody = if plan.existsMode and constantIndices.len == 0:
    list(newKeyword("result-row"), newInt(1))
  else:
    buildProjection(plan, plan.findVars.len, constantIndices)

  buildTriejoinScheme(plan, findVars, leafBody)
