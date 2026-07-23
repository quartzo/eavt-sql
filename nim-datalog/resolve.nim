import std/tables
import datalog_ast, pattern, stats

proc resolveIr*(ir: var DatalogIR, s: CompileStats): bool =
  for pattern in ir.patterns.mitems:
    if pattern.a.kind == dsConst:
      let name = case pattern.a.constVal.kind
        of bvAttr: pattern.a.constVal.attrName
        of bvStr: pattern.a.constVal.sval
        else: ""
      if name != "":
        let id = s.lookupAttr(name)
        if id == 0: return false
        let isRef = s.isRefAttr(name)
        let isIndexed = s.isIndexedAttr(name)
        pattern.a = slotConst(newBoundResolvedAttr(id, name, isRef, isIndexed))

  for branches in ir.rangeBounds.mvalues:
    for branch in branches.mitems:
      for pair in branch.mitems:
        let name = case pair[1].kind
          of bvAttr: pair[1].attrName
          of bvStr: pair[1].sval
          else: ""
        if name != "":
          let id = s.lookupAttr(name)
          if id == 0: continue
          let isRef = s.isRefAttr(name)
          let isIndexed = s.isIndexedAttr(name)
          pair[1] = newBoundResolvedAttr(id, name, isRef, isIndexed)

  true

proc computePlanStats*(ir: DatalogIR, s: CompileStats): PlanStats =
  let totalEavt = max(s.estimateIndexSize("EAVT", []), 1.0)
  var estimates = initTable[(int, string, string), float64]()

  for patIdx, pattern in ir.patterns:
    let p = toPattern(pattern)
    for (indexName, indexOrder) in IndexOrders:
      for pos in indexOrder:
        let slot = p.slot(pos)
        if slot.kind != dsVar: continue
        let varName = slot.varName

        let posInIdx = indexOrder.find($pos)
        var boundVals: seq[uint64]
        for bi in 0..<posInIdx:
          let beforeSlot = p.slot($indexOrder[bi])
          if beforeSlot.kind == dsConst:
            case beforeSlot.constVal.kind
            of bvInt: boundVals.add(cast[uint64](beforeSlot.constVal.ival))
            of bvResolvedAttr: boundVals.add(cast[uint64](beforeSlot.constVal.raId))
            else: boundVals.add(0)
          else:
            boundVals.add(0)

        let est = max(s.estimateIndexSize(indexName, boundVals), 1.0)
        estimates[(patIdx, $indexName, varName)] = est

  PlanStats(totalEavt: totalEavt, estimates: estimates)
