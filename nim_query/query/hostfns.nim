## query/hostfns.nim — SchemeHostFns: 22 host functions + leapfrog + ranges.
##
## Port of spier-eavt-query/src/engine/scheme.rs (~983 lines Rust → Nim).

import std/[options, tables, strutils, sequtils, math]
import scheme
import kvstore
import keys
import types
import scanner

# ═══════════════════════════════════════════════════════════════════════════════
# LeapIterator — encapsulates leapfrog state across yield/resume
# ═══════════════════════════════════════════════════════════════════════════════

type
  LeapIterator* = ref object
    scanners*: seq[V2Scanner]
    rawOps*: seq[seq[(int32, SExpr)]]
    started*: bool

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

proc expectInt(expr: SExpr): int64 =
  case expr.kind:
  of sInt: expr.ival
  of sFloat: int64(expr.fval)
  else:
    raise newException(EvalError, "expected int, got " & $expr)

proc expectStr(expr: SExpr): string =
  case expr.kind:
  of sStr: expr.sval
  of sSymbol: expr.symval
  else:
    raise newException(EvalError, "expected string, got " & $expr)

proc isFloat(expr: SExpr): bool = expr.kind == sFloat

proc sexprNumToF64(expr: SExpr): float64 =
  case expr.kind:
  of sInt: float64(expr.ival)
  of sFloat: expr.fval
  else:
    raise newException(EvalError, "expected number, got " & $expr)

# ═══════════════════════════════════════════════════════════════════════════════
# Scanner registry (simple seq of V2Scanner refs)
# ═══════════════════════════════════════════════════════════════════════════════

type
  ScannerRegistry* = object
    scanners*: seq[V2Scanner]

proc addScanner*(reg: var ScannerRegistry; sc: V2Scanner) =
  reg.scanners.add sc

proc len*(reg: ScannerRegistry): int = reg.scanners.len

# ═══════════════════════════════════════════════════════════════════════════════
# EngineOps — abstract operations the host functions need from the engine
# ═══════════════════════════════════════════════════════════════════════════════

type
  EngineOps* = ref object of RootObj

method openCursor*(ops: EngineOps; cfId: uint32; prefix: seq[byte]): Cursor {.base, gcsafe.} =
  raise newException(EvalError, "not implemented")

method saveWithT*(ops: EngineOps; eid: int64; attr: string; val: SExpr;
                   t: int64; asOf: int64) {.base, gcsafe.} = discard

method retract*(ops: EngineOps; eid: int64; attr: string; val: SExpr;
                 t: int64; asOf: int64) {.base, gcsafe.} = discard

method lookupAttr*(ops: EngineOps; name: string): Option[uint32] {.base, gcsafe.} =
  none[uint32]()

method attrName*(ops: EngineOps; aid: uint32): string {.base, gcsafe.} = ""

method declareAttrFromSql*(ops: EngineOps; attr, typeName: string;
    many, unique: bool; t: int64) {.base, gcsafe.} = discard

method declarePartition*(ops: EngineOps; name: string; t: int64): uint64 {.base, gcsafe.} = 0

method allocateInPartition*(ops: EngineOps; partitionId: uint64): int64 {.base, gcsafe.} = 0

method allocateTx*(ops: EngineOps): int64 {.base, gcsafe.} = 0

method valueTypeFor*(ops: EngineOps; aid: uint32): Option[uint32] {.base, gcsafe.} =
  none[uint32]()

method isUniqueAttr*(ops: EngineOps; name: string): bool {.base, gcsafe.} = false

method lookupEntity*(ops: EngineOps; attrName: string; value: SExpr): Option[int64] {.base, gcsafe.} =
  none[int64]()

method lookupValue*(ops: EngineOps; eid: int64; attrName: string): Option[SExpr] {.base, gcsafe.} =
  none[SExpr]()

# ═══════════════════════════════════════════════════════════════════════════════
# Leapfrog converge
# ═══════════════════════════════════════════════════════════════════════════════

proc leapConverge*(scanners: var seq[V2Scanner]): bool =
  let maxIters = scanners.len * 2 + 1
  for iter in 0..<maxIters:
    var maxVal: Option[SExpr] = none[SExpr]()
    var allEqual = true
    var atEndIndices: seq[int] = @[]
    for i, sc in scanners:
      let v = sc.extractCurrent()
      if v.isSome:
        if maxVal.isNone:
          maxVal = v
        elif v.get != maxVal.get:
          allEqual = false
          if v.get > maxVal.get: maxVal = v
      else:
        atEndIndices.add i
        allEqual = false
    if allEqual: return true
    if maxVal.isSome:
      let mv = maxVal.get
      for i, sc in scanners:
        var needsSeek = false
        let cv = sc.extractCurrent()
        if cv.isSome and cv.get < mv: needsSeek = true
        if atEndIndices.contains(i): needsSeek = true
        if needsSeek:
          sc.seekToValue(mv)
          if sc.atEnd(): return false
    else:
      return false
  false

# ═══════════════════════════════════════════════════════════════════════════════
# apply_ranges
# ═══════════════════════════════════════════════════════════════════════════════

proc applyRanges*(scanners: var seq[V2Scanner]; rawOps: seq[seq[(int32, SExpr)]]): bool =
  if rawOps.len == 0: return true

  var allIntervals: seq[(Option[SExpr], Option[SExpr], int32)] = @[]
  for branch in rawOps:
    allIntervals.add opsToIntervals(branch)
  let merged = mergeIntervals(allIntervals)
  var rangeSpecs: seq[RangeSpec] = @[]
  for (lo, hi, flags) in merged:
    rangeSpecs.add RangeSpec(lo: lo, hi: hi, flags: flags)

  if rangeSpecs.len == 0: return false

  let maxIter = rangeSpecs.len + 2
  for iter in 0..<maxIter:
    var cur: SExpr
    block getCur:
      let cv = scanners[0].extractCurrent()
      if cv.isSome: cur = cv.get
      else: return false

    var anyApplied = false
    for spec in rangeSpecs:
      if spec.hi.isSome:
        let hiOpen = (spec.flags and RangeHiOpen) != 0
        let pastHi = if hiOpen: cur >= spec.hi.get else: cur > spec.hi.get
        if pastHi: continue
      if spec.lo.isSome:
        let loOpen = (spec.flags and RangeLoOpen) != 0
        let beforeLo = if loOpen: cur <= spec.lo.get else: cur < spec.lo.get
        if beforeLo:
          if cur.kind != spec.lo.get.kind: return false
          let lo = spec.lo.get
          for sc in scanners.mitems:
            sc.seekToValue(lo)
          if not leapConverge(scanners): return false
          if loOpen:
            let cv = scanners[0].extractCurrent()
            let atLo = cv.isSome and cv.get == lo
            if atLo:
              for sc in scanners.mitems:
                sc.leapNextAt()
              if not leapConverge(scanners): return false
          anyApplied = true
          break
        else:
          return true
      else:
        return true
    if not anyApplied: return false
  false

# ═══════════════════════════════════════════════════════════════════════════════
# parse_ranges
# ═══════════════════════════════════════════════════════════════════════════════

proc parseRanges(sexpr: SExpr): seq[seq[(int32, SExpr)]] =
  case sexpr.kind:
  of sList:
    var branch: seq[(int32, SExpr)] = @[]
    for item in sexpr.items:
      case item.kind:
      of sList:
        if item.items.len == 1:
          if item.items[0].kind == sSymbol and item.items[0].symval == "branch":
            if branch.len > 0:
              result.add branch
              branch = @[]
            continue
        if item.items.len >= 2 and item.items[0].kind == sInt:
          let op = int32(expectInt(item.items[0]))
          let val = item.items[1]
          branch.add (op, val)
          continue
      else: discard
    if branch.len > 0:
      result.add branch
  else: discard

# ═══════════════════════════════════════════════════════════════════════════════
# SchemeHostFns
# ═══════════════════════════════════════════════════════════════════════════════

type
  SchemeHostFns* = ref object of HostFns
    engine*: EngineOps
    params*: seq[SExpr]
    tx*: int64
    asOfTx*: Option[int64]
    scanners*: seq[V2Scanner]
    leapIters*: Table[int, LeapIterator]

proc findScanner*(h: SchemeHostFns; resource: SExpr): V2Scanner =
  case resource.kind:
  of sResource:
    let idx = resource.rid
    if idx < h.scanners.len:
      return h.scanners[idx]
  else: discard
  raise newException(EvalError, "expected scanner resource")

proc findLeapIterator*(h: SchemeHostFns; resource: SExpr): LeapIterator =
  case resource.kind:
  of sResource:
    let idx = resource.rid
    if idx in h.leapIters:
      return h.leapIters[idx]
  else: discard
  raise newException(EvalError, "expected leap-iterator resource")

proc pushScanner*(h: SchemeHostFns; sc: V2Scanner): int =
  result = h.scanners.len
  h.scanners.add sc

method scannerOpen(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let idxName = expectStr(args[0])
    let history = args.len > 1 and args[1].kind == sBool and args[1].bval
    let upper = idxName.toUpperAscii()
    let baseOrder = case upper:
      of "EAVT": @["e", "a", "v"]
      of "AEVT": @["a", "e", "v"]
      of "AVET": @["a", "v", "e"]
      of "VAET": @["v", "a", "e"]
      else: @["e", "a", "v"]

    var idxOrder = baseOrder
    idxOrder.add "t"
    idxOrder.add "added"

    var scanner = newV2Scanner(idxName, idxOrder, h.asOfTx, none[uint32]())
    if history: scanner.historyMode = true

    let cfId = case upper:
      of "AEVT": 1'u32
      of "AVET": 2'u32
      of "VAET": 3'u32
      else: 0'u32

    scanner.setCursor(h.engine.openCursor(cfId, @[]))
    scanner.advanceToActiveAt()

    let rid = h.pushScanner(scanner)
    return done(SExpr(kind: sResource, rid: rid))

method scannerRead(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let sc = h.findScanner(args[0])
    let val = sc.extractCurrent()
    if val.isSome: return done(val.get)
    return done(newVoid())

method scannerPush(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let sc = h.findScanner(args[0])
    sc.saveValue(args[1])
    return done(newVoid())

method scannerPop(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let sc = h.findScanner(args[0])
    sc.popSavedValue()
    return done(newVoid())

method scannerPrefix(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let sc = h.findScanner(args[0])
    return done(SExpr(kind: sBytes, bytesval: sc.prefixCache))

  # -- Leapfrog --

method scannerLeapInit(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    var scanners: seq[V2Scanner] = @[]
    for i in 1..<args.len - 1:
      scanners.add h.findScanner(args[i])
    let rangesSexpr = args[^1]

    for sc in scanners.mitems:
      let vtOpt = sc.attrIdFromPrefixBytes()
      var vt: Option[uint32] = none[uint32]()
      if vtOpt.isSome:
        vt = h.engine.valueTypeFor(vtOpt.get)
      sc.setValueAttrType(vt)
      sc.advanceToActiveAt()
      if sc.valueAttrType.isNone:
        let aid = sc.attrIdFromKey()
        if aid.isSome:
          sc.setValueAttrType(h.engine.valueTypeFor(aid.get))

    let rawOps = parseRanges(rangesSexpr)
    let ok = if rawOps.len == 0:
      leapConverge(scanners)
    else:
      applyRanges(scanners, rawOps)
    return done(newBool(ok))

method scannerLeapNext(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    var scanners: seq[V2Scanner] = @[]
    for i in 1..<args.len - 1:
      scanners.add h.findScanner(args[i])
    let rangesSexpr = args[^1]
    if scanners.len == 0: return done(newBool(false))
    let rawOps = parseRanges(rangesSexpr)

    var minIdx = 0
    var minVal: Option[SExpr] = none[SExpr]()
    for i, sc in scanners:
      let val = sc.extractCurrent()
      if minVal.isNone:
        minVal = val; minIdx = i
      elif val.isSome and val.get < minVal.get:
        minVal = val; minIdx = i

    scanners[minIdx].leapNextAt()
    if scanners[minIdx].atEnd(): return done(newBool(false))
    if not leapConverge(scanners):
      return done(newBool(false))
    if rawOps.len > 0 and not applyRanges(scanners, rawOps):
      return done(newBool(false))
    return done(newBool(true))

  # -- LeapIterator hostfns --

method scannerIterateInit(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    # (scanner-iterate-init scanner... ranges)
    # Creates a LeapIterator resource without iterating.
    var scanners: seq[V2Scanner] = @[]
    for i in 0..<args.len - 1:
      scanners.add h.findScanner(args[i])
    let rangesSexpr = args[^1]
    if scanners.len == 0: return done(newVoid())

    for sc in scanners.mitems:
      let vtOpt = sc.attrIdFromPrefixBytes()
      var vt: Option[uint32] = none[uint32]()
      if vtOpt.isSome:
        vt = h.engine.valueTypeFor(vtOpt.get)
      sc.setValueAttrType(vt)
      sc.advanceToActiveAt()
      if sc.valueAttrType.isNone:
        let aid = sc.attrIdFromKey()
        if aid.isSome:
          sc.setValueAttrType(h.engine.valueTypeFor(aid.get))

    let rawOps = parseRanges(rangesSexpr)
    let it = LeapIterator(scanners: scanners, rawOps: rawOps, started: false)
    let idx = h.leapIters.len
    h.leapIters[idx] = it
    return done(SExpr(kind: sResource, rid: idx))

method scannerIterateNext(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    # (scanner-iterate-next iter)
    # On first call: converge + apply ranges, return first value or void.
    # On subsequent calls: advance + converge + apply ranges, return next value or void.
    let iter = h.findLeapIterator(args[0])
    if iter.scanners.len == 0: return done(newVoid())

    if not iter.started:
      # First call: converge and apply ranges.
      let ok = if iter.rawOps.len == 0:
        leapConverge(iter.scanners)
      else:
        applyRanges(iter.scanners, iter.rawOps)
      if not ok: return done(newVoid())
      iter.started = true
    else:
      # Subsequent call: advance the smallest scanner, then converge + ranges.
      var minIdx = 0
      var minVal: Option[SExpr] = none[SExpr]()
      for i, sc in iter.scanners:
        let val = sc.extractCurrent()
        if minVal.isNone:
          minVal = val; minIdx = i
        elif val.isSome and val.get < minVal.get:
          minVal = val; minIdx = i

      iter.scanners[minIdx].leapNextAt()
      if iter.scanners[minIdx].atEnd(): return done(newVoid())
      if not leapConverge(iter.scanners):
        return done(newVoid())
      if iter.rawOps.len > 0 and not applyRanges(iter.scanners, iter.rawOps):
        return done(newVoid())

    let val = iter.scanners[0].extractCurrent()
    if val.isSome: return done(val.get)
    return done(newVoid())

  # -- Attribute access --

method internA(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let name = expectStr(args[0])
    let aid = h.engine.lookupAttr(name)
    if aid.isNone:
      return done(newVoid())
    return done(SExpr(kind: sInt, ival: int64(aid.get)))

method attrName(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let aid = uint32(expectInt(args[0]))
    return done(SExpr(kind: sStr, sval: h.engine.attrName(aid)))

method param(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let idx = int(expectInt(args[0]))
    if idx < 1 or idx > h.params.len:
      raise newException(EvalError, "param index out of range: " & $idx)
    return done(h.params[idx - 1])

method resolveVal(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    return done(args[0])

  # -- DML --

method save(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let eid = expectInt(args[0])
    let attr = expectStr(args[1])
    let val = args[2]
    h.engine.saveWithT(eid, attr, val, h.tx, h.asOfTx.get(0))
    return done(newVoid())

method retract(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let eid = expectInt(args[0])
    let attr = expectStr(args[1])
    let val = args[2]
    h.engine.retract(eid, attr, val, h.tx, h.asOfTx.get(0))
    return done(newVoid())

  # -- Result --

method resultRow(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    return yieldRow(SExpr(kind: sList, items: args))

method result(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    var items = @[SExpr(kind: sSymbol, symval: "result")]
    items.add args
    return done(SExpr(kind: sList, items: items))

method allocEntity(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let partition = if args.len > 0: uint64(expectInt(args[0])) else: 4'u64
    let eid = h.engine.allocateInPartition(partition)
    return done(SExpr(kind: sInt, ival: eid))

method txEntity(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    return done(SExpr(kind: sInt, ival: int64(h.tx)))

method lookupEntity(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let attr = expectStr(args[0])
    let val = args[1]
    let isUnique = h.engine.isUniqueAttr(attr)
    if not isUnique:
      raise newException(EvalError, "lookup-entity: attribute is not UNIQUE")
    let eid = h.engine.lookupEntity(attr, val)
    if eid.isSome:
      return done(SExpr(kind: sInt, ival: int64(eid.get)))
    return done(newVoid())

method lookupValue(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let eid = expectInt(args[0])
    let attr = expectStr(args[1])
    let val = h.engine.lookupValue(eid, attr)
    if val.isSome: return done(val.get)
    return done(newVoid())

method declareAttr(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let attr = expectStr(args[0])
    let vtName = expectStr(args[1])
    let many = args.len > 2 and args[2].kind == sBool and args[2].bval
    let unique = args.len > 3 and args[3].kind == sBool and args[3].bval
    h.engine.declareAttrFromSql(attr, vtName, many, unique, h.tx)
    return done(newVoid())

method declarePartition(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let name = expectStr(args[0])
    let pid = h.engine.declarePartition(name, h.tx)
    return done(SExpr(kind: sInt, ival: int64(pid)))

  # -- Debug --

method dbgScanners(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    for i, sc in h.scanners:
      stderr.writeLine "scanner[", i, "] at_end=", sc.atEnd(),
        " key=", (if sc.pos.currentActiveKey.isSome: $sc.pos.currentActiveKey.get.len & "b" else: "none")
    return done(newVoid())

method rangesShow(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let rawOps = parseRanges(args[0])
    if rawOps.len == 0:
      return done(SExpr(kind: sStr, sval: "(-inf, +inf)"))
    var allIntervals = opsToIntervals(rawOps[0])
    for i in 1..<rawOps.len:
      let more = opsToIntervals(rawOps[i])
      allIntervals.add more
    var descriptions: seq[string] = @[]
    for (lo, hi, flags) in allIntervals:
      let loStr = if lo.isNone: "-inf" else: $lo.get
      let hiStr = if hi.isNone: "+inf" else: $hi.get
      let l = if lo.isNone or (flags and RangeLoOpen) != 0: "(" else: "["
      let r = if hi.isNone or (flags and RangeHiOpen) != 0: ")" else: "]"
      descriptions.add l & loStr & ", " & hiStr & r
    return done(SExpr(kind: sStr, sval: descriptions.join(", ")))

