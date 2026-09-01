import std/[tables, sets, strutils, options, algorithm]
import ast as sql_ast
import datalog_ast

type
  AliasState = ref object
    alias: string
    eVar: string
    attrs: seq[string]
    hasAttrWild: bool
    hasValWild: bool
    txRequested: bool
    txVar: string
    addedRequested: bool
    eBoundValue: Option[BoundValue]
    attrValues: Table[string, BoundValue]
    attrBoundValue: Option[BoundValue]
    valBoundValue: Option[BoundValue]
    rangeConds: Table[string, seq[seq[(string, BoundValue)]]]

proc newAliasState(alias: string): AliasState =
  AliasState(
    alias: alias,
    eVar: "?e_" & alias,
    txVar: "_t_" & alias,
    attrs: @[],
    rangeConds: initTable[string, seq[seq[(string, BoundValue)]]](),
    attrValues: initTable[string, BoundValue](),
  )

proc safeAttrName(attr: string): string =
  attr.replace(".", "_").replace(":", "_c_").replace("/", "_s_").replace("-", "_h_")

proc vVar(st: AliasState, attr: string): string =
  "?v_" & st.alias & "_" & safeAttrName(attr)

proc aVar(st: AliasState): string =
  "?a_" & st.alias

proc valVar(st: AliasState): string =
  "?vv_" & st.alias

proc addedVar(st: AliasState): string =
  "?added_" & st.alias

proc ensureAlias(aliases: var Table[string, AliasState], name: string) =
  if name notin aliases:
    aliases[name] = newAliasState(name)

proc propagateConstants(aliases: var Table[string, AliasState]) =
  var bindings: seq[(string, BoundValue)]
  for _, st in aliases:
    if st.eBoundValue.isSome:
      let bv = st.eBoundValue.get
      if not bv.isVar:
        bindings.add((st.eVar, bv))

  for (eVar, constVal) in bindings:
    for _, st in aliases.mpairs:
      for attr, val in st.attrValues.mpairs:
        if val.kind == bvVar and val.varName == eVar:
          st.attrValues[attr] = constVal
      if st.eBoundValue.isSome:
        let bv = st.eBoundValue.get
        if bv.kind == bvVar and bv.varName == eVar:
          st.eBoundValue = some(constVal)

proc eSlot(st: AliasState): DatalogSlot =
  if st.eBoundValue.isSome:
    let bv = st.eBoundValue.get
    if bv.kind == bvVar:
      result = slotVar(bv.varName)
    else:
      result = slotConst(bv)
  else:
    result = slotVar(st.eVar)

proc wildcardPattern(st: AliasState, tSlot: DatalogSlot): DatalogPattern =
  let e = eSlot(st)
  let a =
    if st.attrBoundValue.isSome:
      let bv = st.attrBoundValue.get
      if bv.kind == bvVar: slotVar(bv.varName)
      else: slotConst(bv)
    elif st.hasAttrWild: slotVar(st.aVar())
    else: slotMissing()
  let v =
    if st.valBoundValue.isSome:
      let bv = st.valBoundValue.get
      if bv.kind == bvVar: slotVar(bv.varName)
      else: slotConst(bv)
    elif st.hasValWild: slotVar(st.valVar())
    else: slotMissing()
  let added = if st.addedRequested: slotVar(st.addedVar()) else: slotMissing()
  DatalogPattern(e: e, a: a, v: v, t: tSlot, added: added)

proc attrPattern(st: AliasState, attr: string, tSlot: DatalogSlot): DatalogPattern =
  let e = eSlot(st)
  let a = slotConst(newBoundAttr(attr))
  let v =
    if attr in st.attrValues:
      let bv = st.attrValues[attr]
      if bv.kind == bvVar: slotVar(bv.varName)
      else: slotConst(bv)
    else:
      slotVar(st.vVar(attr))
  let added = if st.addedRequested: slotVar(st.addedVar()) else: slotMissing()
  DatalogPattern(e: e, a: a, v: v, t: tSlot, added: added)

proc buildWherePatterns(aliases: Table[string, AliasState], star: bool,
    hasConditions: bool): seq[DatalogPattern] =
  if star and not hasConditions:
    return @[]
  var sortedKeys: seq[string]
  for k in aliases.keys: sortedKeys.add(k)
  sortedKeys.sort()

  for aliasName in sortedKeys:
    let st = aliases[aliasName]
    let tSlot = if st.txRequested: slotVar(st.txVar) else: slotMissing()

    if not hasConditions:
      if st.attrs.len > 0:
        for attr in st.attrs:
          result.add(attrPattern(st, attr, tSlot))
      else:
        result.add(wildcardPattern(st, tSlot))
      continue

    if star:
      result.add(wildcardPattern(st, tSlot))
      for attr in st.attrs:
        result.add(attrPattern(st, attr, tSlot))
    else:
      let hasWild = st.hasAttrWild or st.hasValWild or
                    st.attrBoundValue.isSome or st.valBoundValue.isSome or
                    (st.eBoundValue.isSome and st.attrs.len == 0)
      if hasWild:
        result.add(wildcardPattern(st, tSlot))
      for attr in st.attrs:
        result.add(attrPattern(st, attr, tSlot))

proc extractLiteral(lit: sql_ast.Literal): BoundValue =
  case lit.lkind
  of litInt: newBoundInt(lit.ival)
  of litFloat: newBoundFloat(lit.fval)
  of litStr:
    if lit.sval.contains('.'): newBoundAttr(lit.sval)
    else: newBoundStr(lit.sval)
  of litBool:
    if lit.bval: newBoundInt(1) else: newBoundInt(0)
  of litBytes:
    newBoundStr(repr(lit.bytesval))

proc extractRight(right: sql_ast.ConditionRight): BoundValue =
  case right.rkind
  of crParam: newBoundParam(right.rparam)
  of crLiteral: extractLiteral(right.rlit)
  of crField:
    if right.fref.field == "eid":
      newBoundVar("?e_" & right.fref.alias)
    elif right.fref.field == "val":
      newBoundVar("?vv_" & right.fref.alias)
    elif right.fref.field == "attr":
      newBoundVar("?a_" & right.fref.alias)
    else:
      newBoundVar("?v_" & right.fref.alias & "_" & safeAttrName(right.fref.field))
  of crExpr: newBoundExpr(right.exprValue)
  of crIn, crOr: newBoundMissing("compound")

proc validateAttrName(field: string): string =
  ## SQL surface accepts dot notation (d1.ns.attr → field "ns.attr"); the IR
  ## carries the SLASH canonical form (tx-protocol.md §8) — normalize here so
  ## resolveIr and the storage agree on names end-to-end.  Idempotent: the
  ## same FieldRef may flow through more than once (already slash → kept).
  if field.contains('/'):
    field
  elif field.contains('.'):
    field.replace('.', '/')
  else:
    raise newException(ValueError,
      "attribute name must include namespace (e.g. 'company.name' or 'company/name'), got '" & field & "'")

proc processEq(la: string; lf: var string; right: sql_ast.ConditionRight,
    aliases: var Table[string, AliasState]) =
  case lf
  of "eid":
    case right.rkind
    of crParam:
      ensureAlias(aliases, la)
      aliases[la].eBoundValue = some(newBoundParam(right.rparam))
    of crLiteral:
      ensureAlias(aliases, la)
      aliases[la].eBoundValue = some(extractLiteral(right.rlit))
    of crField:
      let ra = right.fref.alias
      let rf = right.fref.field
      if rf == "eid":
        ensureAlias(aliases, la)
        ensureAlias(aliases, ra)
        let rightEvar = aliases[ra].eVar
        aliases[la].eVar = rightEvar
      else:
        ensureAlias(aliases, la)
        ensureAlias(aliases, ra)
        if rf notin aliases[ra].attrs:
          aliases[ra].attrs.add(rf)
        let rv = aliases[ra].vVar(rf)
        aliases[la].eBoundValue = some(newBoundVar(rv))
    of crExpr:
      ensureAlias(aliases, la)
      aliases[la].eBoundValue = some(newBoundExpr(right.exprValue))
    else: discard
  of "attr":
    ensureAlias(aliases, la)
    if right.rkind == crLiteral:
      aliases[la].attrBoundValue = some(extractLiteral(right.rlit))
    else:
      aliases[la].hasAttrWild = true
  of "val":
    ensureAlias(aliases, la)
    if right.rkind == crLiteral:
      aliases[la].valBoundValue = some(extractLiteral(right.rlit))
    else:
      aliases[la].hasValWild = true
  of "tx":
    ensureAlias(aliases, la)
    aliases[la].txRequested = true
    if right.rkind == crField:
      let ra = right.fref.alias
      let rf = right.fref.field
      ensureAlias(aliases, ra)
      if rf == "eid":
        let tv = aliases[la].txVar
        aliases[ra].eVar = tv
      elif rf == "tx":
        aliases[ra].txRequested = true
        let leftTv = aliases[la].txVar
        let rightTv = aliases[ra].txVar
        let newVar = min(leftTv, rightTv)
        aliases[la].txVar = newVar
        aliases[ra].txVar = newVar
  of "added":
    ensureAlias(aliases, la)
    aliases[la].addedRequested = true
  else:
    lf = validateAttrName(lf)
    ensureAlias(aliases, la)
    if lf notin aliases[la].attrs:
      aliases[la].attrs.add(lf)
    case right.rkind
    of crField:
      let ra = right.fref.alias
      let rf = right.fref.field
      ensureAlias(aliases, ra)
      case rf
      of "eid":
        let ev = aliases[ra].eVar
        aliases[la].attrValues[lf] = newBoundVar(ev)
      of "val":
        let vv = aliases[ra].valVar()
        aliases[la].attrValues[lf] = newBoundVar(vv)
        aliases[la].hasValWild = true
      of "attr":
        let av = aliases[ra].aVar()
        aliases[la].attrValues[lf] = newBoundVar(av)
        aliases[ra].hasAttrWild = true
      else:
        if rf notin aliases[ra].attrs:
          aliases[ra].attrs.add(rf)
        let rv = aliases[ra].vVar(rf)
        aliases[la].attrValues[lf] = newBoundVar(rv)
    of crParam:
      aliases[la].attrValues[lf] = newBoundParam(right.rparam)
    of crLiteral:
      aliases[la].attrValues[lf] = extractLiteral(right.rlit)
    of crExpr:
      aliases[la].attrValues[lf] = newBoundExpr(right.exprValue)
    else: discard

proc processRange(la: string; lf: var string; op: string, right: sql_ast.ConditionRight,
    aliases: var Table[string, AliasState]) =
  if lf in ["attr", "val", "tx"]: return
  ensureAlias(aliases, la)
  if lf == "eid":
    let evar = aliases[la].eVar
    let bv = extractRight(right)
    if evar notin aliases[la].rangeConds:
      aliases[la].rangeConds[evar] = @[newSeq[(string, BoundValue)]()]
    aliases[la].rangeConds[evar][^1].add((op, bv))
    return

  lf = validateAttrName(lf)
  if lf notin aliases[la].attrs:
    aliases[la].attrs.add(lf)
  let bv = extractRight(right)
  if lf notin aliases[la].rangeConds:
    aliases[la].rangeConds[lf] = @[newSeq[(string, BoundValue)]()]
  aliases[la].rangeConds[lf][^1].add((op, bv))

proc processIn(left: sql_ast.FieldRef, values: seq[sql_ast.ConditionRight],
    aliases: var Table[string, AliasState]) =
  let la = left.alias
  if left.field in ["attr", "val", "tx"]: return
  let lf = validateAttrName(left.field)
  ensureAlias(aliases, la)
  left.field = lf
  var target: string
  if lf == "eid":
    target = aliases[la].eVar
  else:
    if lf notin aliases[la].attrs:
      aliases[la].attrs.add(lf)
    target = lf

  var conds: seq[(string, BoundValue)]
  for v in values:
    conds.add(("in", extractRight(v)))
  if target notin aliases[la].rangeConds:
    aliases[la].rangeConds[target] = @[]
  aliases[la].rangeConds[target].add(conds)

proc processOr(left: sql_ast.FieldRef, branches: seq[seq[sql_ast.OrBranchItem]],
    aliases: var Table[string, AliasState]) =
  let alias = left.alias
  let field = left.field
  if field in ["attr", "val", "tx"]:
    raise newException(ValueError, "OR not supported on " & field)
  ensureAlias(aliases, alias)
  var target: string
  if field == "eid":
    target = aliases[alias].eVar
  else:
    target = validateAttrName(field)

  for branch in branches:
    for inner in branch:
      if inner.left.alias != alias or inner.left.field != field:
        raise newException(ValueError,
          "OR requires same (alias, field), got " & inner.left.alias & "." &
          inner.left.field & " vs " & alias & "." & field)
      if inner.value.rkind == crField:
        raise newException(ValueError, "OR with join conditions (= other.field) is not supported")

  if field != "eid":
    if field notin aliases[alias].attrs:
      aliases[alias].attrs.add(field)

  for branch in branches:
    var conds: seq[(string, BoundValue)]
    for inner in branch:
      case inner.value.rkind
      of crIn:
        for v in inner.value.inValues:
          conds.add(("in", extractRight(v)))
      of crField:
        raise newException(ValueError, "OR with join conditions (= other.field) is not supported")
      else:
        let bv = extractRight(inner.value)
        let op = if inner.op == "=": "in" else: inner.op
        conds.add((op, bv))
    if target notin aliases[alias].rangeConds:
      aliases[alias].rangeConds[target] = @[]
    aliases[alias].rangeConds[target].add(conds)

proc collectAliases(stmt: sql_ast.SelectStmt, aliases: var Table[string, AliasState],
    whereAliases: var HashSet[string]) =
  for cond in stmt.conditions:
    case cond.right.rkind
    of crOr:
      whereAliases.incl(cond.left.alias)
      ensureAlias(aliases, cond.left.alias)
      for branch in cond.right.orBranches:
        for inner in branch:
          if inner.value.rkind == crField:
            whereAliases.incl(inner.value.fref.alias)
            ensureAlias(aliases, inner.value.fref.alias)
    of crIn:
      whereAliases.incl(cond.left.alias)
      ensureAlias(aliases, cond.left.alias)
    of crField:
      whereAliases.incl(cond.left.alias)
      ensureAlias(aliases, cond.left.alias)
      whereAliases.incl(cond.right.fref.alias)
      ensureAlias(aliases, cond.right.fref.alias)
    else:
      whereAliases.incl(cond.left.alias)
      ensureAlias(aliases, cond.left.alias)

  if stmt.conditions.len == 0:
    for proj in stmt.projections:
      if proj.field.isSome:
        ensureAlias(aliases, proj.field.get.alias)

proc processConditions(stmt: sql_ast.SelectStmt, aliases: var Table[string, AliasState]) =
  for cond in stmt.conditions:
    case cond.right.rkind
    of crOr:
      processOr(cond.left, cond.right.orBranches, aliases)
    of crIn:
      processIn(cond.left, cond.right.inValues, aliases)
    else:
      let la = cond.left.alias
      var lf = cond.left.field
      case cond.op
      of "=": processEq(la, lf, cond.right, aliases)
      of ">", "<", ">=", "<=", "!=":
        processRange(la, lf, cond.op, cond.right, aliases)
      else: discard

proc processProjections(stmt: sql_ast.SelectStmt, aliases: var Table[string, AliasState]):
    seq[Option[(string, string)]] =
  if stmt.star:
    return @[]
  for proj in stmt.projections:
    if proj.field.isSome:
      let fr = proj.field.get
      ensureAlias(aliases, fr.alias)
      let st = aliases[fr.alias]
      case fr.field
      of "attr": st.hasAttrWild = true
      of "val": st.hasValWild = true
      of "tx": st.txRequested = true
      of "added": st.addedRequested = true
      of "eid": discard
      else:
        let fname = validateAttrName(fr.field)
        if fname notin st.attrs:
          st.attrs.add(fname)
        fr.field = fname
      result.add(some((fr.alias, fr.field)))
    else:
      result.add(none((string, string)))

proc buildFindVars(stmt: sql_ast.SelectStmt, aliases: Table[string, AliasState],
    aliasEVars: Table[string, string], projections: seq[Option[(string, string)]]): seq[FindVar] =
  if stmt.star:
    var keys: seq[string]
    for k in aliases.keys: keys.add(k)
    keys.sort()
    if keys.len > 0:
      let firstAlias = keys[0]
      let st = aliases[firstAlias]
      if st.eBoundValue.isSome:
        let bv = st.eBoundValue.get
        if not bv.isVar:
          result.add(FindVar(kind: fvConst, cName: st.eVar, cVal: bv))
        else:
          result.add(FindVar(kind: fvVar, varName: st.eVar))
      else:
        result.add(FindVar(kind: fvVar, varName: st.eVar))
      if st.attrBoundValue.isSome:
        result.add(FindVar(kind: fvConst, cName: st.aVar(), cVal: st.attrBoundValue.get))
      else:
        result.add(FindVar(kind: fvVar, varName: st.aVar()))
      if st.valBoundValue.isSome:
        let bv = st.valBoundValue.get
        if not bv.isVar:
          result.add(FindVar(kind: fvConst, cName: st.valVar(), cVal: bv))
        else:
          result.add(FindVar(kind: fvVar, varName: st.valVar()))
      else:
        result.add(FindVar(kind: fvVar, varName: st.valVar()))
    return

  for i, proj in projections:
    if proj.isSome:
      let (alias, field) = proj.get
      let st = aliases.getOrDefault(alias)
      case field
      of "eid":
        let varName = aliasEVars.getOrDefault(alias, "?e_" & alias)
        if st != nil and st.eBoundValue.isSome:
          let bv = st.eBoundValue.get
          if not bv.isVar:
            result.add(FindVar(kind: fvConst, cName: varName, cVal: bv))
          else:
            result.add(FindVar(kind: fvVar, varName: varName))
        else:
          result.add(FindVar(kind: fvVar, varName: varName))
      of "tx": result.add(FindVar(kind: fvVar, varName: "_t_" & alias))
      of "added": result.add(FindVar(kind: fvVar, varName: "?added_" & alias))
      of "attr":
        let varName = "?a_" & alias
        if st != nil and st.attrBoundValue.isSome:
          result.add(FindVar(kind: fvConst, cName: varName, cVal: st.attrBoundValue.get))
        else:
          result.add(FindVar(kind: fvVar, varName: varName))
      of "val":
        let varName = "?vv_" & alias
        if st != nil and st.valBoundValue.isSome:
          let bv = st.valBoundValue.get
          if not bv.isVar:
            result.add(FindVar(kind: fvConst, cName: varName, cVal: bv))
          else:
            result.add(FindVar(kind: fvVar, varName: varName))
        else:
          result.add(FindVar(kind: fvVar, varName: varName))
      else:
        let varName = "?v_" & alias & "_" & safeAttrName(field)
        if st != nil and field in st.attrValues:
          let bv = st.attrValues[field]
          if not bv.isVar:
            result.add(FindVar(kind: fvConst, cName: varName, cVal: bv))
          else:
            result.add(FindVar(kind: fvVar, varName: varName))
        else:
          result.add(FindVar(kind: fvVar, varName: varName))
    else:
      var bv: BoundValue
      if i < stmt.projections.len and stmt.projections[i].literal.isSome:
        let lit = stmt.projections[i].literal.get
        bv = extractLiteral(lit)
      else:
        bv = newBoundInt(1)
      result.add(FindVar(kind: fvConst, cName: "_lit_" & $i, cVal: bv))

proc expandStar(stmt: var sql_ast.SelectStmt) =
  if not stmt.star: return
  let alias = if stmt.conditions.len > 0: toLowerAscii(stmt.conditions[0].left.alias) else: "d1"
  if stmt.history:
    stmt.projections = @[
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "eid")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "attr")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "val")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "tx")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "added")), literal: none(sql_ast.Literal)),
    ]
  else:
    stmt.projections = @[
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "eid")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "attr")), literal: none(sql_ast.Literal)),
      sql_ast.Projection(field: some(sql_ast.FieldRef(alias: alias, field: "val")), literal: none(sql_ast.Literal)),
    ]
  stmt.star = false

proc buildDatalogIr*(stmt: sql_ast.SqlStmt): DatalogIR =
  if stmt.kind notin {stmtSelect, stmtDatalogSelect}:
    raise newException(ValueError, "Datalog IR only supports SELECT")
  var sel = stmt.selectStmt
  sel.expandStar()

  var aliases = initTable[string, AliasState]()
  var whereAliases = initHashSet[string]()
  collectAliases(sel, aliases, whereAliases)
  let hasConditions = sel.conditions.len > 0
  if hasConditions:
    processConditions(sel, aliases)

  for _, st in aliases:
    if st.eBoundValue.isSome and st.eBoundValue.get.kind == bvMissing:
      raise newException(ValueError, "missing parameter: " & st.eBoundValue.get.missingName)
    if st.attrBoundValue.isSome and st.attrBoundValue.get.kind == bvMissing:
      raise newException(ValueError, "missing parameter: " & st.attrBoundValue.get.missingName)
    if st.valBoundValue.isSome and st.valBoundValue.get.kind == bvMissing:
      raise newException(ValueError, "missing parameter: " & st.valBoundValue.get.missingName)
    for _, bv in st.attrValues:
      if bv.kind == bvMissing:
        raise newException(ValueError, "missing parameter: " & bv.missingName)

  propagateConstants(aliases)
  let projections = processProjections(sel, aliases)

  var aliasEVars = initTable[string, string]()
  for _, st in aliases:
    if st.alias notin aliasEVars:
      aliasEVars[st.alias] = st.eVar

  let findVars = buildFindVars(sel, aliases, aliasEVars, projections)

  if hasConditions and not sel.star:
    for proj in projections:
      if proj.isSome:
        let (alias, _) = proj.get
        if alias notin whereAliases:
          raise newException(ValueError,
            "alias " & alias & " in SELECT but not in WHERE")

  let patterns = buildWherePatterns(aliases, sel.star, hasConditions)

  var rangeBounds = initTable[string, seq[seq[(string, BoundValue)]]]()
  for _, st in aliases:
    for attr, branches in st.rangeConds:
      let varName = if attr == st.eVar: st.eVar else: st.vVar(attr)
      rangeBounds[varName] = branches

  DatalogIR(
    patterns: patterns,
    findVars: findVars,
    rangeBounds: rangeBounds,
    star: sel.star,
    existsMode: sel.existsMode,
    hasConditions: hasConditions,
    history: sel.history,
  )
