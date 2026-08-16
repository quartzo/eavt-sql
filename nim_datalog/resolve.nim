import std/[tables, sets]
import datalog_ast, pattern, stats

proc resolveIr*(ir: var DatalogIR, s: CompileStats): bool =
  for pattern in ir.patterns.mitems:
    if pattern.a.kind == dsConst:
      let name = case pattern.a.constVal.kind
        of bvAttr: pattern.a.constVal.attrName
        of bvStr: pattern.a.constVal.sval
        else: ""
      if name != "":
        let id = s.attrIds.getOrDefault(name, 0)
        if id == 0: return false
        let isRef = s.refAttrs.contains(name)
        let isIndexed = s.indexedAttrs.contains(name)
        pattern.a = slotConst(newBoundResolvedAttr(id, name, isRef, isIndexed))

  for branches in ir.rangeBounds.mvalues:
    for branch in branches.mitems:
      for pair in branch.mitems:
        let name = case pair[1].kind
          of bvAttr: pair[1].attrName
          of bvStr: pair[1].sval
          else: ""
        if name != "":
          let id = s.attrIds.getOrDefault(name, 0)
          if id == 0: continue
          let isRef = s.refAttrs.contains(name)
          let isIndexed = s.indexedAttrs.contains(name)
          pair[1] = newBoundResolvedAttr(id, name, isRef, isIndexed)

  true

proc computePlanStats*(ir: DatalogIR, s: CompileStats): PlanStats =
  let totalEavt = max(s.indexEstimates.getOrDefault("EAVT:", 1.0), 1.0)
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

        # Build cache key: "AVET:100:200:"
        var key = indexName & ":"
        for bv in boundVals:
          if bv != 0:
            key.add($bv & ":")
        let est = max(s.indexEstimates.getOrDefault(key, totalEavt), 1.0)
        estimates[(patIdx, $indexName, varName)] = est

  PlanStats(totalEavt: totalEavt, estimates: estimates)
