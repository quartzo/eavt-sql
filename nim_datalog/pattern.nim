import std/strutils
import datalog_ast

const
  IndexOrders* = [
    ("EAVT", ["e", "a", "v", "t", "added"]),
    ("AEVT", ["a", "e", "v", "t", "added"]),
    ("AVET", ["a", "v", "e", "t", "added"]),
    ("VAET", ["v", "a", "e", "t", "added"]),
  ]

proc indexOrder*(index: string): seq[string] =
  let upper = toUpperAscii(index)
  for (name, order) in IndexOrders:
    if name == upper:
      return @order
  @["e", "a", "v"]

type
  Pattern* = ref object
    e*: DatalogSlot
    a*: DatalogSlot
    v*: DatalogSlot
    t*: DatalogSlot
    added*: DatalogSlot

proc slot*(p: Pattern, pos: string): DatalogSlot =
  case pos
  of "e": p.e
  of "a": p.a
  of "v": p.v
  of "t": p.t
  of "added": p.added
  else: p.t

proc isLookup*(p: Pattern): bool =
  (p.e.kind == dsConst and not p.e.constVal.isMissing) and
  (p.a.kind == dsConst and not p.a.constVal.isMissing) and
  (p.v.kind == dsConst and not p.v.constVal.isMissing)

proc containsVarInEav*(p: Pattern, varName: string): bool =
  (p.e.kind == dsVar and p.e.varName == varName) or
  (p.a.kind == dsVar and p.a.varName == varName) or
  (p.v.kind == dsVar and p.v.varName == varName) or
  (p.t.kind == dsVar and p.t.varName == varName) or
  (p.added.kind == dsVar and p.added.varName == varName)

proc toPattern*(dp: DatalogPattern): Pattern =
  Pattern(e: dp.e, a: dp.a, v: dp.v, t: dp.t, added: dp.added)

proc toDatalogPattern*(p: Pattern): DatalogPattern =
  DatalogPattern(e: p.e, a: p.a, v: p.v, t: p.t, added: p.added)
