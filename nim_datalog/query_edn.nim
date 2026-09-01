## query_edn.nim — Datalog EDN surface → DatalogIR.
##
## Parses the Datomic-style query vector into the IR the planner already
## consumes, bypassing the SQL AST entirely:
##
##   [:find  ?name ?price
##    :in    $ ?email
##    :where [?e :person/name ?name]
##           [?e :person/email ?email]
##           [?e :fin/price ?price]
##           [(> ?price 5)]]
##
## Grammar (subset — docs/datalog-reference.md):
##   query    := [:find var+ (:in $ var+)? :where clause+ (:history)?]
##   clause   := pattern | predicate | (or pred+)
##   pattern  := [e-slot attr v-slot]   e: var|_ ; attr: :ns/name ; v: var|_|const
##   predicate:= [(op var value)]       op: > < >= <= = !=
##   or       := (or pred pred+)        same var in every pred
##   var      := ?name   (_ = blank)
##   value    := string|int|float|bool|:kw|?param
##
## `?x` vars in :in bind positionally to query args (param 1..N); pattern
## slots referencing them become dsConst(bvParam).  Attribute keywords
## normalize to the canonical slash form (:person/name → person/name).

import std/[tables, strutils, options, sequtils]
import edn
import scheme  # SExpr — the args passed by the caller are SExprs
import datalog_ast

type
  DatalogSyntaxError* = object of CatchableError

const RangeOps = [">", "<", ">=", "<=", "=", "!="]

proc isVar(e: SExpr): bool = e.kind == sSymbol and e.symval.startsWith("?")

proc varName(e: SExpr): string =
  ## ?name → "name" (the IR stores var names without the ? prefix)
  e.symval[1 ..^ 1]

proc isBlank(e: SExpr): bool =
  e.kind == sSymbol and e.symval == "_"

proc isKeyword(e: SExpr): bool = e.kind == sKeyword

proc parseValue(e: SExpr; params: Table[string, uint32]): BoundValue =
  ## A constant or param in a predicate/pattern value position.
  if isVar(e):
    let vn = varName(e)
    if vn in params: return newBoundParam(params[vn])
    raise newException(DatalogSyntaxError,
      "datalog: unbound var ?" & vn & " in value position (declare it in :in)")
  case e.kind
  of sStr: newBoundStr(e.sval)
  of sInt: newBoundInt(e.ival)
  of sFloat: newBoundFloat(e.fval)
  of sBool: newBoundBool(e.bval)
  of sKeyword: newBoundStr(":" & e.kwval)  # enum-style keyword value
  else:
    raise newException(DatalogSyntaxError,
      "datalog: unsupported value: " & $e)

proc parsePattern(p: SExpr; ir: var DatalogIR; params: Table[string, uint32]) =
  ## [e attr v] with vars, blanks and constants.
  if p.kind != sList or p.items.len != 3:
    raise newException(DatalogSyntaxError,
      "datalog: pattern must be a 3-element vector [e attr v], got " & $p)
  var dp = DatalogPattern(t: slotMissing(), added: slotMissing())

  # e slot: var, _ or int eid
  let eSlot = p.items[0]
  if isVar(eSlot): dp.e = slotVar(varName(eSlot))
  elif isBlank(eSlot): dp.e = slotMissing()
  elif eSlot.kind == sInt: dp.e = slotConst(newBoundInt(eSlot.ival))
  else:
    raise newException(DatalogSyntaxError,
      "datalog: e slot must be a var, _ or eid, got " & $eSlot)

  # a slot: keyword (required — no wildcard patterns in v1)
  let aSlot = p.items[1]
  if not isKeyword(aSlot):
    raise newException(DatalogSyntaxError,
      "datalog: attr slot must be a keyword like :person/name, got " & $aSlot)
  # SQL-style surface (:dl.name) normalizes to canonical slash (dl/name)
  let attr = if "." in aSlot.kwval: aSlot.kwval.replace(".", "/") else: aSlot.kwval
  if "/" notin attr:
    raise newException(DatalogSyntaxError,
      "datalog: attr keyword must be namespaced: :" & aSlot.kwval)
  dp.a = slotConst(newBoundAttr(attr))

  # v slot: var (or :in param), _ or constant
  let vSlot = p.items[2]
  if isVar(vSlot):
    let vn = varName(vSlot)
    if vn in params: dp.v = slotConst(newBoundParam(params[vn]))
    else: dp.v = slotVar(vn)
  elif isBlank(vSlot): dp.v = slotMissing()
  else: dp.v = slotConst(parseValue(vSlot, params))

  ir.patterns.add dp

proc isOpSym(e: SExpr): bool =
  e.kind == sSymbol and e.symval in RangeOps

proc predKey(opExpr: SExpr): string =
  if opExpr.kind != sKeyword:
    raise newException(DatalogSyntaxError,
      "datalog: predicate op must be a keyword like :>, got " & $opExpr)
  let op = opExpr.kwval
  if op notin RangeOps:
    raise newException(DatalogSyntaxError,
      "datalog: unsupported predicate op :" & op &
      " (supported: > < >= <= = !=)")
  op

proc parsePredicate(p: SExpr; ir: var DatalogIR;
                    params: Table[string, uint32]; branch: int) =
  ## [(op ?var value)] — adds a range condition on the var.
  if p.kind != sList or p.items.len != 3:
    raise newException(DatalogSyntaxError,
      "datalog: predicate must be [(op var value)], got " & $p)
  let op = if isOpSym(p.items[0]): p.items[0].symval else: predKey(p.items[0])
  if not isVar(p.items[1]):
    raise newException(DatalogSyntaxError,
      "datalog: predicate var must be ?var, got " & $p.items[1])
  let vn = varName(p.items[1])
  let bv = parseValue(p.items[2], params)
  if vn notin ir.rangeBounds: ir.rangeBounds[vn] = @[]
  while ir.rangeBounds[vn].len <= branch:
    ir.rangeBounds[vn].add(@[])
  ir.rangeBounds[vn][branch].add((op, bv))

proc parseWhereElement(p0: SExpr; ir: var DatalogIR;
                       params: Table[string, uint32]; branch: int = 0) =
  ## Route one :where element.  The EDN reader nests predicate vectors:
  ## [(> ?v 5)] arrives as [[> ?v 5]] with the op as a symbol atom (not a
  ## keyword).  Unwrap one level, then route: or-form → branches, predicate
  ## → range, else → pattern.
  var p = p0
  if p.kind == sList and p.items.len == 1 and p.items[0].kind == sList:
    let inner = p.items[0]
    let innerIsRoute = inner.items.len > 0 and (
      isOpSym(inner.items[0]) or
      (inner.items[0].kind == sSymbol and inner.items[0].symval == "or") or
      (inner.items[0].kind == sKeyword and
       (inner.items[0].kwval == "or" or inner.items[0].kwval in RangeOps)))
    if innerIsRoute:
      p = inner
  let headIsOr = p.kind == sList and p.items.len > 0 and (
    (p.items[0].kind == sSymbol and p.items[0].symval == "or") or
    (p.items[0].kind == sKeyword and p.items[0].kwval == "or"))
  if headIsOr:
    for i in 1 ..< p.items.len:
      parseWhereElement(p.items[i], ir, params, i - 1)  # each or-item is a branch
  elif p.kind == sList and p.items.len > 0 and
       (isOpSym(p.items[0]) or (isKeyword(p.items[0]) and p.items[0].kwval in RangeOps)):
    parsePredicate(p, ir, params, branch)
  else:
    parsePattern(p, ir, params)

proc parseDatalogQuery*(src: string): DatalogIR {.raises: [DatalogSyntaxError, ValueError], gcsafe.} =
  ## Parse a Datalog EDN query vector into the IR.
  ## Raises DatalogSyntaxError on malformed input.
  var top: SExpr
  try:
    top = readEdn(src)
  except EdnError as e:
    raise newException(DatalogSyntaxError, "datalog: EDN parse error: " & e.msg)
  if top.kind != sList or top.items.len == 0 or
     not isKeyword(top.items[0]) or top.items[0].kwval != "find":
    raise newException(DatalogSyntaxError,
      "datalog: query must start with [:find ...]")

  result = DatalogIR(rangeBounds: initTable[string, seq[seq[(string, BoundValue)]]]())

  var params = initTable[string, uint32]()
  var paramIdx: uint32 = 0

  type Section = enum secNone, secFind, secIn, secWhere
  var section: Section = secFind  # the header check guarantees items[0] = :find

  var i = 1
  while i < top.items.len:
    let el = top.items[i]
    if isKeyword(el):
      case el.kwval
      of "find": section = secFind
      of "in": section = secIn
      of "where": section = secWhere
      of "history":
        result.history = true
        section = secNone
      else:
        raise newException(DatalogSyntaxError,
          "datalog: unknown query section :" & el.kwval)
    else:
      case section
      of secFind:
        if not isVar(el):
          raise newException(DatalogSyntaxError,
            "datalog: :find takes vars like ?name, got " & $el)
        result.findVars.add FindVar(kind: fvVar, varName: varName(el))
      of secIn:
        if el.kind == sSymbol and el.symval == "$":  # the db input — ignore
          discard
        elif isVar(el):
          inc paramIdx
          params[varName(el)] = paramIdx
        else:
          raise newException(DatalogSyntaxError,
            "datalog: :in takes $ and vars like ?x, got " & $el)
      of secWhere:
        parseWhereElement(el, result, params, 0)
      of secNone:
        raise newException(DatalogSyntaxError,
          "datalog: unexpected element outside a section: " & $el)
    inc i

  if result.findVars.len == 0:
    raise newException(DatalogSyntaxError, "datalog: :find is required")
  if result.patterns.len == 0:
    raise newException(DatalogSyntaxError, "datalog: :where with at least one pattern is required")

  # Every range-predicate var must be bound by some pattern's value slot —
  # an unbound predicate var would silently filter nothing.
  block checkBound:
    for varName, branches in pairs(result.rangeBounds):
      var bound = false
      for p in result.patterns:
        if p.v.kind == dsVar and p.v.varName == varName:
          bound = true; break
      if not bound:
        raise newException(DatalogSyntaxError,
          "datalog: predicate var ?" & varName &
          " is not bound by any pattern value slot")