import std/[tables, sequtils, strutils, json]
import ast as sql_ast

type
  BoundValueKind* = enum
    bvInt, bvFloat, bvStr, bvAttr, bvResolvedAttr, bvVar, bvMissing, bvParam, bvBool, bvExpr

  BoundValue* = ref object
    case kind*: BoundValueKind
    of bvInt: ival*: int64
    of bvFloat: fval*: float64
    of bvStr: sval*: string
    of bvAttr: attrName*: string
    of bvResolvedAttr:
      raId*: uint32
      raName*: string
      raIsRef*: bool
      raIsIndexed*: bool
    of bvVar: varName*: string
    of bvMissing: missingName*: string
    of bvParam: paramIdx*: uint32
    of bvBool: bval*: bool
    of bvExpr: exprValue*: sql_ast.Value

  DatalogSlotKind* = enum
    dsVar, dsConst, dsMissing

  DatalogSlot* = ref object
    case kind*: DatalogSlotKind
    of dsVar: varName*: string
    of dsConst: constVal*: BoundValue
    of dsMissing: discard

  FindVarKind* = enum
    fvVar, fvConst

  FindVar* = ref object
    case kind*: FindVarKind
    of fvVar: varName*: string
    of fvConst:
      cName*: string
      cVal*: BoundValue

  DatalogPattern* = ref object
    e*: DatalogSlot
    a*: DatalogSlot
    v*: DatalogSlot
    t*: DatalogSlot
    added*: DatalogSlot

  DatalogIR* = ref object
    patterns*: seq[DatalogPattern]
    findVars*: seq[FindVar]
    rangeBounds*: Table[string, seq[seq[(string, BoundValue)]]]
    star*: bool
    existsMode*: bool
    hasConditions*: bool
    history*: bool

  PlanStats* = ref object
    totalEavt*: float64
    estimates*: Table[(int, string, string), float64]

  DatalogNumIR* = ref object
    ir*: DatalogIR
    stats*: PlanStats

proc newBoundInt*(n: int64): BoundValue =
  BoundValue(kind: bvInt, ival: n)

proc newBoundFloat*(f: float64): BoundValue =
  BoundValue(kind: bvFloat, fval: f)

proc newBoundStr*(s: string): BoundValue =
  BoundValue(kind: bvStr, sval: s)

proc newBoundAttr*(name: string): BoundValue =
  BoundValue(kind: bvAttr, attrName: name)

proc newBoundResolvedAttr*(id: uint32, name: string, isRef: bool, isIndexed: bool): BoundValue =
  BoundValue(kind: bvResolvedAttr, raId: id, raName: name, raIsRef: isRef, raIsIndexed: isIndexed)

proc newBoundVar*(name: string): BoundValue =
  BoundValue(kind: bvVar, varName: name)

proc newBoundMissing*(name: string = ""): BoundValue =
  BoundValue(kind: bvMissing, missingName: name)

proc newBoundParam*(idx: uint32): BoundValue =
  BoundValue(kind: bvParam, paramIdx: idx)

proc newBoundBool*(b: bool): BoundValue =
  BoundValue(kind: bvBool, bval: b)

proc newBoundExpr*(v: sql_ast.Value): BoundValue =
  BoundValue(kind: bvExpr, exprValue: v)

proc slotVar*(n: string): DatalogSlot =
  DatalogSlot(kind: dsVar, varName: n)

proc slotConst*(bv: BoundValue): DatalogSlot =
  DatalogSlot(kind: dsConst, constVal: bv)

proc slotMissing*(): DatalogSlot =
  DatalogSlot(kind: dsMissing)

proc isVar*(s: DatalogSlot): bool =
  s.kind == dsVar

proc isConst*(s: DatalogSlot): bool =
  s.kind == dsConst

proc isMissing*(s: DatalogSlot): bool =
  s.kind == dsMissing

proc isInt*(bv: BoundValue): bool =
  bv.kind == bvInt

proc isVar*(bv: BoundValue): bool =
  bv.kind == bvVar

proc isMissing*(bv: BoundValue): bool =
  bv.kind == bvMissing

proc `==`*(a, b: BoundValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of bvInt: a.ival == b.ival
  of bvFloat: a.fval == b.fval
  of bvStr: a.sval == b.sval
  of bvAttr: a.attrName == b.attrName
  of bvResolvedAttr: a.raId == b.raId
  of bvVar: a.varName == b.varName
  of bvMissing: a.missingName == b.missingName
  of bvParam: a.paramIdx == b.paramIdx
  of bvBool: a.bval == b.bval
  of bvExpr: false  # expression comparison not supported

proc `$`*(bv: BoundValue): string =
  case bv.kind
  of bvInt: $bv.ival
  of bvFloat: $bv.fval
  of bvStr: "\"" & bv.sval & "\""
  of bvAttr: "Attr(" & bv.attrName & ")"
  of bvResolvedAttr: "Attr(" & bv.raName & ", id=" & $bv.raId &
    ", ref=" & $bv.raIsRef & ", idx=" & $bv.raIsIndexed & ")"
  of bvVar: "?" & bv.varName
  of bvMissing: "_"
  of bvParam: "%" & $bv.paramIdx
  of bvBool: $bv.bval
  of bvExpr: "Expr(" & $toJson(bv.exprValue) & ")"

proc `$`*(s: DatalogSlot): string =
  case s.kind
  of dsVar: "?" & s.varName
  of dsConst: $s.constVal
  of dsMissing: "_"

proc `$`*(fv: FindVar): string =
  case fv.kind
  of fvVar: "?" & fv.varName
  of fvConst: fv.cName & "=" & $fv.cVal

proc `$`*(p: DatalogPattern): string =
  "[" & $p.e & ", " & $p.a & ", " & $p.v & ", " & $p.t & ", " & $p.added & "]"

proc `$`*(ir: DatalogIR): string =
  let fvs = ir.findVars.mapIt($it).join(", ")
  result = "Find: " & fvs & "\n"
  for i, pat in ir.patterns:
    result.add("  p" & $i & ": " & $pat & "\n")
  var hasRanges = false
  for varName, branches in pairs(ir.rangeBounds):
    hasRanges = true
    break
  if hasRanges:
    result.add("  Range:\n")
    for varName, branches in pairs(ir.rangeBounds):
      for branch in branches:
        let conds = branch.mapIt(it[0] & " " & $it[1]).join(" AND ")
        result.add("    " & varName & " " & conds & "\n")
