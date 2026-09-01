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
    specs*: seq[ByteRangeSpec]
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

method saveManyWithT*(ops: EngineOps; attr: string;
                      pairs: seq[(int64, SExpr)]; t: int64; asOf: int64) {.
    base, gcsafe.} = discard

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

method hasDatom*(ops: EngineOps; eid: int64; attr: string; val: SExpr): bool {.
    base, gcsafe.} = false

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
# apply_ranges — pure predicate, no seeking
# ═══════════════════════════════════════════════════════════════════════════════

proc bytesCmp(a, b: seq[byte]): int =
  let n = min(a.len, b.len)
  for i in 0..<n:
    if a[i] < b[i]: return -1
    elif a[i] > b[i]: return 1
  if a.len < b.len: -1 elif a.len > b.len: 1 else: 0

proc valueInSpecsBytes*(cur: seq[byte]; specs: seq[ByteRangeSpec]): bool =
  if specs.len == 0: return true
  if specs.len == 1 and specs[0].flags == -1: return false
  for spec in specs:
    if spec.flags == -1: return false
    if spec.hi.isSome:
      let hiOpen = (spec.flags and RangeHiOpen) != 0
      let cmpHi = bytesCmp(cur, spec.hi.get)
      let pastHi = if hiOpen: cmpHi >= 0 else: cmpHi > 0
      if pastHi: continue
    if spec.lo.isSome:
      let loOpen = (spec.flags and RangeLoOpen) != 0
      let cmpLo = bytesCmp(cur, spec.lo.get)
      let beforeLo = if loOpen: cmpLo <= 0 else: cmpLo < 0
      if beforeLo: continue
    return true
  false

proc applyRanges*(scanners: var seq[V2Scanner]; specs: seq[ByteRangeSpec]): bool =
  if specs.len == 0: return true
  if specs.len == 1 and specs[0].flags == -1: return false
  let curOpt = scanners[0].currentValueBytes()
  if curOpt.isNone: return false
  valueInSpecsBytes(curOpt.get, specs)

# ═══════════════════════════════════════════════════════════════════════════════
# parse_ranges — now parses list of [lo, hi, flags] triples (lo/hi as bytes)
# ═══════════════════════════════════════════════════════════════════════════════

proc parseRanges*(sexpr: SExpr): seq[ByteRangeSpec] =
  case sexpr.kind:
  of sList:
    for item in sexpr.items:
      if item.kind == sList and item.items.len == 3:
        let loRaw = item.items[0]
        let hiRaw = item.items[1]
        let flagsRaw = item.items[2]
        if flagsRaw.kind != sInt: continue
        let flags = int32(flagsRaw.ival)
        let lo = if loRaw.kind == sVoid: none[seq[byte]]()
                 elif loRaw.kind == sBytes: some(loRaw.bytesval)
                 else: none[seq[byte]]()
        let hi = if hiRaw.kind == sVoid: none[seq[byte]]()
                 elif hiRaw.kind == sBytes: some(hiRaw.bytesval)
                 else: none[seq[byte]]()
        result.add ByteRangeSpec(lo: lo, hi: hi, flags: flags)
      elif item.kind == sList and item.items.len == 0:
        discard
  else: discard

proc convergeWithRanges*(scanners: var seq[V2Scanner]; specs: seq[ByteRangeSpec]): bool =
  if not leapConverge(scanners): return false
  if specs.len == 0: return true
  if specs.len == 1 and specs[0].flags == -1: return false
  let maxIter = specs.len + 30
  for _ in 0..<maxIter:
    let (res, propose) = scanners[0].validateOrProposeNextElementBytes(specs)
    case res:
    of vrValid:
      return true
    of vrAtEnd:
      return false
    of vrPropose:
      if propose.isSome:
        scanners[0].seekToBytes(propose.get)
        if scanners[0].atEnd(): return false
        let loOpenProposed = block:
          var isOpen = false
          for spec in specs:
            if spec.lo.isSome and bytesCmp(spec.lo.get, propose.get) == 0 and (spec.flags and RangeLoOpen) != 0:
              isOpen = true; break
          isOpen
        if loOpenProposed:
          let cur2 = scanners[0].currentValueBytes()
          if cur2.isSome and bytesCmp(cur2.get, propose.get) == 0:
            scanners[0].leapNextAt()
            if scanners[0].atEnd(): return false
        if not leapConverge(scanners): return false
      else:
        var minIdx = 0
        var minVal: Option[seq[byte]] = none[seq[byte]]()
        for i, sc in scanners:
          let v = sc.currentValueBytes()
          if v.isSome:
            if minVal.isNone or bytesCmp(v.get, minVal.get) < 0:
              minVal = v; minIdx = i
          else:
            minIdx = i; break
        scanners[minIdx].leapNextAt()
        if scanners[minIdx].atEnd(): return false
        if not leapConverge(scanners): return false
  false

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
      sc.advanceToActiveAtPreserving()
      if sc.valueAttrType.isNone:
        let aid = sc.attrIdFromKey()
        if aid.isSome:
          sc.setValueAttrType(h.engine.valueTypeFor(aid.get))

    let specs = parseRanges(rangesSexpr)
    let ok = convergeWithRanges(scanners, specs)
    return done(newBool(ok))

method scannerLeapNext(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    var scanners: seq[V2Scanner] = @[]
    for i in 1..<args.len - 1:
      scanners.add h.findScanner(args[i])
    let rangesSexpr = args[^1]
    if scanners.len == 0: return done(newBool(false))
    let specs = parseRanges(rangesSexpr)

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
    if not convergeWithRanges(scanners, specs):
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
      sc.advanceToActiveAtPreserving()
      if sc.valueAttrType.isNone:
        let aid = sc.attrIdFromKey()
        if aid.isSome:
          sc.setValueAttrType(h.engine.valueTypeFor(aid.get))

    let specs = parseRanges(rangesSexpr)
    let it = LeapIterator(scanners: scanners, specs: specs, started: false)
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
      let ok = convergeWithRanges(iter.scanners, iter.specs)
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
      if not convergeWithRanges(iter.scanners, iter.specs):
        return done(newVoid())

    let val = iter.scanners[0].extractCurrent()
    if val.isSome: return done(val.get)
    return done(newVoid())

  # -- Attribute access --

method internA(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    let name = expectStr(args[0])
    let aid = h.engine.lookupAttr(name)
    if aid.isNone:
      raise newException(EvalError, "intern-a: unknown attribute: " & name)
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

method saveMany(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    ## (save-many "attr" eid1 val1 eid2 val2 ...) — batched save grouped by
    ## attribute: metadata resolved once, ONE vm form instead of N. Flat
    ## layout because nested data lists are not evaluable program position.
    if args.len < 3 or (args.len and 1) == 0:
      raise newException(EvalError,
        "save-many expects an attribute name followed by eid/value pairs")
    let attr = expectStr(args[0])
    var pairs = newSeqOfCap[(int64, SExpr)]((args.len - 1) div 2)
    var i = 1
    while i < args.len:
      pairs.add((expectInt(args[i]), args[i + 1]))
      inc i, 2
    h.engine.saveManyWithT(attr, pairs, h.tx, h.asOfTx.get(0))
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

method getOrCreateEntity(h: SchemeHostFns; args: seq[SExpr]): EvalStep {.gcsafe.} =
    ## Get-or-create by unique attribute: returns the eid of the entity holding
    ## `value` for `attr`; if none exists, allocates in `partition` and saves.
    let attr = expectStr(args[0])
    let val = args[1]
    if not h.engine.isUniqueAttr(attr):
      raise newException(EvalError,
        "get-or-create-entity: attribute is not UNIQUE")
    let found = h.engine.lookupEntity(attr, val)
    if found.isSome:
      return done(SExpr(kind: sInt, ival: int64(found.get)))
    let partition = if args.len > 2: uint64(expectInt(args[2])) else: 4'u64
    let eid = h.engine.allocateInPartition(partition)
    h.engine.saveWithT(eid, attr, val, h.tx, h.asOfTx.get(0))
    return done(SExpr(kind: sInt, ival: eid))

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
    let specs = parseRanges(args[0])
    if specs.len == 0:
      return done(SExpr(kind: sStr, sval: "(-inf, +inf)"))
    if specs.len == 1 and specs[0].flags == -1:
      return done(SExpr(kind: sStr, sval: "∅ (empty)"))
    var descriptions: seq[string] = @[]
    for spec in specs:
      let loStr = if spec.lo.isNone: "-inf" else: $spec.lo.get
      let hiStr = if spec.hi.isNone: "+inf" else: $spec.hi.get
      let l = if spec.lo.isNone or (spec.flags and RangeLoOpen) != 0: "(" else: "["
      let r = if spec.hi.isNone or (spec.flags and RangeHiOpen) != 0: ")" else: "]"
      descriptions.add l & loStr & ", " & hiStr & r
    return done(SExpr(kind: sStr, sval: descriptions.join(", ")))

