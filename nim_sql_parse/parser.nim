import std/[strutils, options]
import lexer, ast

type
  ParseError* = object of CatchableError
    pos*: int

proc newParseError(msg: string, pos: int): ref ParseError {.gcsafe.} =
  new(result)
  result.msg = msg & " at position " & $pos
  result.pos = pos

type
  Parser = ref object
    tokens: seq[LexToken]
    pos: int

proc parseOrExpr(p: Parser): seq[Condition] {.gcsafe.}
proc parseStmt(p: Parser): SqlStmt {.gcsafe.}

func peek(p: Parser): LexToken =
  p.tokens[p.pos]

proc advance(p: Parser): LexToken {.gcsafe.} =
  result = p.tokens[p.pos]
  inc p.pos

proc expect(p: Parser, tt: TokenType): LexToken {.gcsafe.} =
  let tok = p.peek()
  if tok.tt != tt:
    raise newParseError(
      "expected " & TokenNames[ord(tt)] & " (got " &
      TokenNames[ord(tok.tt)] & " " & tok.value & ")", tok.pos)
  result = p.advance()

proc expectOneof(p: Parser, tts: openArray[TokenType]): LexToken {.gcsafe.} =
  let tok = p.peek()
  for t in tts:
    if tok.tt == t:
      return p.advance()
  var names: seq[string]
  for t in tts:
    names.add(TokenNames[ord(t)])
  raise newParseError(
    "expected " & names.join(" or ") & " (got " &
    TokenNames[ord(tok.tt)] & " " & tok.value & ")", tok.pos)

proc parseFieldRef(p: Parser): FieldRef {.gcsafe.} =
  let alias = p.expect(ttALIAS).value
  discard p.expect(ttDOT)
  var field = p.expectOneof([ttIDENT, ttALIAS]).value
  while p.peek().tt == ttDOT:
    discard p.advance()
    field.add('.')
    field.add(p.expectOneof([ttIDENT, ttALIAS]).value)
  FieldRef(alias: alias, field: field)

proc parseParam(p: Parser): uint32 {.gcsafe.} =
  let tok = p.expect(ttPARAM)
  let numStr = tok.value[1..^1]
  try:
    result = parseUInt(numStr).uint32
  except ValueError:
    raise newParseError("invalid parameter number '" & numStr & "'", tok.pos)

proc parseAttrRef(p: Parser): string {.gcsafe.} =
  let ns = p.expectOneof([ttIDENT, ttALIAS]).value
  discard p.expect(ttDOT)
  let name = p.expectOneof([ttIDENT, ttALIAS]).value
  ns & "." & name

proc parseOp(p: Parser): string {.gcsafe.} =
  case p.peek().tt
  of ttEQ:
    discard p.advance()
    "="
  of ttGT:
    discard p.advance()
    ">"
  of ttLT:
    discard p.advance()
    "<"
  of ttGTE:
    discard p.advance()
    ">="
  of ttLTE:
    discard p.advance()
    "<="
  of ttNEQ:
    discard p.advance()
    "!="
  else:
    raise newParseError("expected comparison operator", p.peek().pos)

proc parseLiteralOrParam(p: Parser): Value {.gcsafe.} =
  case p.peek().tt
  of ttPARAM: Value(vkind: valParam, vparam: p.parseParam())
  of ttSTRING:
    let tok = p.advance()
    Value(vkind: valLiteral, vlit: Literal(lkind: litStr, sval: tok.value))
  of ttINTEGER:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litInt, ival: parseInt(tok.value).int64))
    except ValueError:
      raise newParseError("invalid integer '" & tok.value & "'", tok.pos)
  of ttFLOAT:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litFloat, fval: parseFloat(tok.value)))
    except ValueError:
      raise newParseError("invalid float '" & tok.value & "'", tok.pos)
  else:
    raise newParseError("expected literal or parameter", p.peek().pos)

proc parseEidAttrArg(p: Parser): Value {.gcsafe.} =
  case p.peek().tt
  of ttSTRING:
    let tok = p.advance()
    Value(vkind: valLiteral, vlit: Literal(lkind: litStr, sval: tok.value))
  of ttPARAM: Value(vkind: valParam, vparam: p.parseParam())
  of ttIDENT:
    let attr = p.parseAttrRef()
    Value(vkind: valLiteral, vlit: Literal(lkind: litStr, sval: attr))
  else:
    raise newParseError("expected attribute name (quoted or dotted)", p.peek().pos)

proc parseValueOrAlias(p: Parser): Value {.gcsafe.} =
  case p.peek().tt
  of ttALIAS:
    let aliasVal = toUpperAscii(p.advance().value)
    if p.peek().tt == ttDOT:
      raise newParseError("dotted alias not allowed in value position", p.peek().pos)
    Value(vkind: valAliasRef, vref: aliasVal)
  of ttPARAM:
    Value(vkind: valParam, vparam: p.parseParam())
  of ttSTRING:
    let tok = p.advance()
    Value(vkind: valLiteral, vlit: Literal(lkind: litStr, sval: tok.value))
  of ttINTEGER:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litInt, ival: parseInt(tok.value).int64))
    except ValueError:
      raise newParseError("invalid integer '" & tok.value & "'", tok.pos)
  of ttFLOAT:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litFloat, fval: parseFloat(tok.value)))
    except ValueError:
      raise newParseError("invalid float '" & tok.value & "'", tok.pos)
  of ttIDENT:
    let idVal = p.peek().value
    if idVal == "true":
      discard p.advance()
      Value(vkind: valLiteral, vlit: Literal(lkind: litBool, bval: true))
    elif idVal == "false":
      discard p.advance()
      Value(vkind: valLiteral, vlit: Literal(lkind: litBool, bval: false))
    elif cmpIgnoreCase(idVal, "eid") == 0:
      discard p.advance()
      discard p.expect(ttLPAREN)
      let attr = p.parseEidAttrArg()
      discard p.expect(ttCOMMA)
      let val = p.parseLiteralOrParam()
      discard p.expect(ttRPAREN)
      Value(vkind: valEidLookup, eidAttr: attr, eidValue: val)
    elif cmpIgnoreCase(idVal, "val") == 0:
      discard p.advance()
      discard p.expect(ttLPAREN)
      let entity = p.parseValueOrAlias()
      discard p.expect(ttCOMMA)
      let attr = p.parseEidAttrArg()
      discard p.expect(ttRPAREN)
      Value(vkind: valValLookup, valEntity: entity, valAttr: attr)
    else:
      raise newParseError("expected value after =", p.peek().pos)
  else:
    raise newParseError("expected value after =", p.peek().pos)

proc parseSetValue(p: Parser): InsertValue {.gcsafe.} =
  let attr = p.parseAttrRef()
  discard p.expect(ttEQ)
  let value = p.parseValueOrAlias()
  InsertValue(attr: attr, value: value)

proc parseSetValueList(p: Parser): seq[InsertValue] {.gcsafe.} =
  result = @[p.parseSetValue()]
  while p.peek().tt == ttCOMMA:
    let save = p.pos
    discard p.advance()
    if p.peek().tt in {ttAS, ttEOF}:
      p.pos = save
      break
    result.add(p.parseSetValue())

# ── Expression grammar (used by SELECT projections of expressions) ──
#   parseExpr   := parseTerm ( ('+'|'-') parseTerm )*
#   parseTerm   := parseUnary ( ('*'|'/'|MOD) parseUnary )*
#   parseUnary  := ('+'|'-') parseUnary | parsePrimary
#   parsePrimary:= literal | param | eid(...) | val(...) | '(' parseExpr ')'
# Produces a Value (valBinOp / valUnaryOp / valLiteral / valParam /
# valEidLookup / valValLookup) — the same type used for upsert values, so
# compileValue/compileExpr is the single funnel for both.

proc parseExpr*(p: Parser): Value {.gcsafe.}
proc parseExprRest*(p: Parser; left: Value): Value {.gcsafe.}
proc parseTermRest*(p: Parser; left: Value): Value {.gcsafe.}

proc parseExprPrimary(p: Parser): Value {.gcsafe.} =
  case p.peek().tt
  of ttINTEGER:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litInt, ival: parseInt(tok.value).int64))
    except ValueError:
      raise newParseError("invalid integer '" & tok.value & "'", tok.pos)
  of ttFLOAT:
    let tok = p.advance()
    try:
      Value(vkind: valLiteral,
        vlit: Literal(lkind: litFloat, fval: parseFloat(tok.value)))
    except ValueError:
      raise newParseError("invalid float '" & tok.value & "'", tok.pos)
  of ttSTRING:
    let tok = p.advance()
    Value(vkind: valLiteral, vlit: Literal(lkind: litStr, sval: tok.value))
  of ttPARAM:
    Value(vkind: valParam, vparam: p.parseParam())
  of ttLPAREN:
    discard p.advance()
    let inner = p.parseExpr()
    discard p.expect(ttRPAREN)
    inner
  of ttIDENT:
    let idVal = p.peek().value
    if idVal == "true":
      discard p.advance()
      Value(vkind: valLiteral, vlit: Literal(lkind: litBool, bval: true))
    elif idVal == "false":
      discard p.advance()
      Value(vkind: valLiteral, vlit: Literal(lkind: litBool, bval: false))
    elif cmpIgnoreCase(idVal, "eid") == 0:
      discard p.advance()
      discard p.expect(ttLPAREN)
      let attr = p.parseEidAttrArg()
      discard p.expect(ttCOMMA)
      let val = p.parseLiteralOrParam()
      discard p.expect(ttRPAREN)
      Value(vkind: valEidLookup, eidAttr: attr, eidValue: val)
    elif cmpIgnoreCase(idVal, "val") == 0:
      discard p.advance()
      discard p.expect(ttLPAREN)
      let entity = p.parseValueOrAlias()
      discard p.expect(ttCOMMA)
      let attr = p.parseEidAttrArg()
      discard p.expect(ttRPAREN)
      Value(vkind: valValLookup, valEntity: entity, valAttr: attr)
    else:
      raise newParseError("unexpected identifier '" & idVal & "' in expression", p.peek().pos)
  else:
    raise newParseError("expected primary expression", p.peek().pos)

proc parseUnary(p: Parser): Value {.gcsafe.} =
  case p.peek().tt
  of ttMINUS:
    discard p.advance()
    Value(vkind: valUnaryOp, unOp: "-", unOperand: p.parseUnary())
  of ttPLUS:
    discard p.advance()
    p.parseUnary()  # unary plus is a no-op
  else:
    p.parseExprPrimary()

proc parseTerm(p: Parser): Value {.gcsafe.} =
  result = p.parseUnary()
  result = p.parseTermRest(result)

proc parseTermRest*(p: Parser; left: Value): Value {.gcsafe.} =
  result = left
  while p.peek().tt in {ttSTAR, ttSLASH, ttMOD}:
    let opTok = p.advance()
    let op = case opTok.tt
      of ttSTAR: "*"
      of ttSLASH: "/"
      of ttMOD: "mod"
      else: "?"
    let rhs = p.parseUnary()
    result = Value(vkind: valBinOp, binOp: op, binLeft: result, binRight: rhs)

proc parseExpr*(p: Parser): Value {.gcsafe.} =
  result = p.parseTerm()
  result = p.parseExprRest(result)

proc parseExprRest*(p: Parser; left: Value): Value {.gcsafe.} =
  result = left
  while p.peek().tt in {ttPLUS, ttMINUS}:
    let opTok = p.advance()
    let op = if opTok.tt == ttPLUS: "+" else: "-"
    let rhs = p.parseTerm()
    result = Value(vkind: valBinOp, binOp: op, binLeft: result, binRight: rhs)

proc parseProjection(p: Parser): Projection {.gcsafe.} =
  case p.peek().tt
  of ttALIAS:
    let fr = p.parseFieldRef()
    Projection(field: some(fr), literal: none(Literal), expr: none(Value))
  of ttINTEGER, ttFLOAT, ttSTRING:
    # Could be an isolated literal OR the start of an arithmetic expression
    # (e.g. 20+20). Parse the primary, then if an operator follows, keep
    # parsing as a full expression.
    let primary = p.parseExprPrimary()
    if p.peek().tt in {ttPLUS, ttMINUS, ttSTAR, ttSLASH, ttMOD}:
      let rest = p.parseExprRest(p.parseTermRest(primary))
      Projection(field: none(FieldRef), literal: none(Literal), expr: some(rest))
    else:
      # isolated literal: unwrap the Value back into a Literal for AST compat
      case primary.vkind
      of valLiteral: Projection(field: none(FieldRef), literal: some(primary.vlit), expr: none(Value))
      else: Projection(field: none(FieldRef), literal: none(Literal), expr: some(primary))
  of ttPLUS, ttMINUS, ttLPAREN, ttPARAM, ttIDENT:
    # Expression: arithmetic / eid() / val() / param / parenthesised.
    let e = p.parseExpr()
    Projection(field: none(FieldRef), literal: none(Literal), expr: some(e))
  else:
    raise newParseError("expected field reference, literal or expression in SELECT", p.peek().pos)

proc parseProjectionList(p: Parser): seq[Projection] {.gcsafe.} =
  result = @[p.parseProjection()]
  while p.peek().tt == ttCOMMA:
    discard p.advance()
    result.add(p.parseProjection())

proc parseConditionValue(p: Parser): ConditionRight {.gcsafe.} =
  case p.peek().tt
  of ttPARAM: ConditionRight(rkind: crParam, rparam: p.parseParam())
  of ttINTEGER:
    let tok = p.advance()
    try:
      ConditionRight(rkind: crLiteral,
        rlit: Literal(lkind: litInt, ival: parseInt(tok.value).int64))
    except ValueError:
      raise newParseError("invalid integer '" & tok.value & "'", tok.pos)
  of ttSTRING:
    let tok = p.advance()
    ConditionRight(rkind: crLiteral,
      rlit: Literal(lkind: litStr, sval: tok.value))
  else:
    raise newParseError("expected value in IN list", p.peek().pos)

proc parseCondition(p: Parser): Condition {.gcsafe.} =
  let left = p.parseFieldRef()

  if p.peek().tt == ttIN:
    discard p.advance()
    discard p.expect(ttLPAREN)
    var vals = @[p.parseConditionValue()]
    while p.peek().tt == ttCOMMA:
      discard p.advance()
      vals.add(p.parseConditionValue())
    discard p.expect(ttRPAREN)
    return Condition(left: left, op: "in", right: ConditionRight(rkind: crIn, inValues: vals))

  let op = p.parseOp()
  let tok = p.peek()

  let right = case tok.tt
  of ttALIAS:
    let save = p.pos
    let aliasVal = p.advance().value
    if p.peek().tt == ttDOT:
      p.pos = save
      ConditionRight(rkind: crField, fref: p.parseFieldRef())
    else:
      ConditionRight(rkind: crField,
        fref: FieldRef(alias: aliasVal, field: "eid"))
  of ttPARAM:
    ConditionRight(rkind: crParam, rparam: p.parseParam())
  of ttINTEGER:
    let tok2 = p.advance()
    try:
      ConditionRight(rkind: crLiteral,
        rlit: Literal(lkind: litInt, ival: parseInt(tok2.value).int64))
    except ValueError:
      raise newParseError("invalid integer '" & tok2.value & "'", tok2.pos)
  of ttFLOAT:
    let tok2 = p.advance()
    try:
      ConditionRight(rkind: crLiteral,
        rlit: Literal(lkind: litFloat, fval: parseFloat(tok2.value)))
    except ValueError:
      raise newParseError("invalid float '" & tok2.value & "'", tok2.pos)
  of ttSTRING:
    let tok2 = p.advance()
    ConditionRight(rkind: crLiteral,
      rlit: Literal(lkind: litStr, sval: tok2.value))
  of ttIDENT:
    if tok.value == "true":
      discard p.advance()
      ConditionRight(rkind: crLiteral, rlit: Literal(lkind: litBool, bval: true))
    elif tok.value == "false":
      discard p.advance()
      ConditionRight(rkind: crLiteral, rlit: Literal(lkind: litBool, bval: false))
    else:
      raise newParseError("expected value in condition", tok.pos)
  of ttLPAREN:
    discard p.advance()
    if p.peek().tt == ttSELECT:
      discard p.expect(ttRPAREN)
      ConditionRight(rkind: crIn, inValues: @[])
    else:
      var vals = @[p.parseConditionValue()]
      while p.peek().tt == ttCOMMA:
        discard p.advance()
        vals.add(p.parseConditionValue())
      discard p.expect(ttRPAREN)
      ConditionRight(rkind: crIn, inValues: vals)
  else:
    raise newParseError("expected value in condition", tok.pos)

  Condition(left: left, op: op, right: right)

proc parsePrimary(p: Parser): seq[Condition] {.gcsafe.} =
  if p.peek().tt == ttLPAREN:
    discard p.advance()
    result = p.parseOrExpr()
    discard p.expect(ttRPAREN)
  else:
    result = @[p.parseCondition()]

proc parseAndGroup(p: Parser): seq[Condition] {.gcsafe.} =
  result = p.parsePrimary()
  while p.peek().tt == ttAND:
    discard p.advance()
    result.add(p.parsePrimary())

proc parseOrExpr(p: Parser): seq[Condition] {.gcsafe.} =
  let firstAnd = p.parseAndGroup()
  if p.peek().tt != ttOR:
    return firstAnd

  var branches: seq[seq[OrBranchItem]] = @[]
  let left = firstAnd[0].left
  var branch1: seq[OrBranchItem]
  for c in firstAnd:
    branch1.add(OrBranchItem(left: c.left, op: c.op, value: c.right))
  branches.add(branch1)

  while p.peek().tt == ttOR:
    discard p.advance()
    let group = p.parseAndGroup()
    var branch: seq[OrBranchItem]
    for c in group:
      branch.add(OrBranchItem(left: c.left, op: c.op, value: c.right))
    branches.add(branch)

  result = @[Condition(left: left, op: "or",
    right: ConditionRight(rkind: crOr, orBranches: branches))]

proc parseConditionList(p: Parser): seq[Condition] {.gcsafe.} =
  p.parseOrExpr()

proc parseUpsertAlias(p: Parser): tuple[alias: Option[string], eref: UpsertEntityRef] {.gcsafe.} =
  if p.peek().tt != ttAS:
    return (none(string), UpsertEntityRef(erefKind: ueNew))

  discard p.advance()
  let aliasTok = p.advance()
  if aliasTok.tt notin {ttALIAS, ttIDENT}:
    raise newParseError("expected alias after AS", aliasTok.pos)
  let aliasName = toUpperAscii(aliasTok.value)

  if aliasName == "TX":
    return (some(aliasName), UpsertEntityRef(erefKind: ueTx))

  if p.peek().tt == ttEQ:
    discard p.advance()
    let tok = p.peek()
    if tok.tt == ttIDENT and cmpIgnoreCase(tok.value, "eid") == 0:
      discard p.advance()
      discard p.expect(ttLPAREN)
      let attr = p.parseEidAttrArg()
      discard p.expect(ttCOMMA)
      let value = p.parseLiteralOrParam()
      discard p.expect(ttRPAREN)
      return (some(aliasName), UpsertEntityRef(erefKind: ueLookup,
        lookupAttr: attr, lookupValue: value))
    let paramIdx = p.parseParam()
    return (some(aliasName), UpsertEntityRef(erefKind: ueExplicitEid, eidParam: paramIdx))

  (some(aliasName), UpsertEntityRef(erefKind: ueNew))

proc parseUpsert(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttUPSERT)
  var clauses: seq[UpsertClause]

  while true:
    let (alias, entityRef) = p.parseUpsertAlias()
    var values: seq[InsertValue]
    if p.peek().tt == ttSET:
      discard p.advance()
      values = p.parseSetValueList()
    clauses.add(UpsertClause(alias: alias, entityRef: entityRef, values: values))
    if p.peek().tt != ttCOMMA:
      break
    discard p.advance()

  discard p.expect(ttEOF)
  SqlStmt(kind: stmtUpsert, upsertStmt: UpsertStmt(clauses: clauses))

proc parseUpdateClause(p: Parser): tuple[alias: string, values: seq[InsertValue]] {.gcsafe.} =
  let alias = if p.peek().tt == ttAS:
    discard p.advance()
    let tok = p.advance()
    if tok.tt notin {ttALIAS, ttIDENT}:
      raise newParseError("expected alias after AS", tok.pos)
    toUpperAscii(tok.value)
  else:
    "D1"

  discard p.expect(ttSET)
  let values = p.parseSetValueList()
  (alias, values)

proc parseUpdateStmt(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttUPDATE)

  var clauses: seq[UpdateClause]
  let (firstAlias, firstValues) = p.parseUpdateClause()
  clauses.add(UpdateClause(alias: firstAlias, values: firstValues))

  while p.peek().tt == ttCOMMA:
    let save = p.pos
    discard p.advance()
    if p.peek().tt == ttAS:
      let (alias, values) = p.parseUpdateClause()
      clauses.add(UpdateClause(alias: alias, values: values))
    else:
      p.pos = save
      break

  discard p.expect(ttWHERE)
  let conditions = p.parseConditionList()
  discard p.expect(ttEOF)
  SqlStmt(kind: stmtUpdate, updateStmt: UpdateStmt(clauses: clauses, conditions: conditions))

proc parseDelete(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttDELETE)
  discard p.expect(ttWHERE)
  let conditions = p.parseConditionList()
  discard p.expect(ttEOF)
  SqlStmt(kind: stmtDelete, deleteStmt: DeleteStmt(conditions: conditions))

proc parseAttribute(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttATTRIBUTE)
  let attr = p.parseAttrRef()

  const typeNames = [
    "STRING", "LONG", "REF", "BOOLEAN", "INSTANT", "BYTES", "BLOB", "KEYWORD", "FLOAT"
  ]

  let upper = toUpperAscii(p.peek().value)
  if (p.peek().tt in {ttIDENT, ttREF, ttBYTES}) and (upper in typeNames):
    discard p.advance()
  else:
    raise newParseError("expected type name", p.peek().pos)

  let many = if p.peek().tt == ttMANY:
    discard p.advance()
    true
  elif p.peek().tt == ttONE:
    discard p.advance()
    false
  else:
    false

  let unique = p.peek().tt == ttUNIQUE and (discard p.advance(); true)

  discard p.expect(ttEOF)
  SqlStmt(kind: stmtAttribute,
    attrStmt: AttributeStmt(attr: attr, valueType: upper, many: many, unique: unique))

proc parsePartitionStmt(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttPARTITION)
  let name = p.expect(ttIDENT).value
  discard p.expect(ttEOF)
  SqlStmt(kind: stmtPartition, partStmt: PartitionStmt(name: name))

proc parseSelect(p: Parser): SqlStmt {.gcsafe.} =
  discard p.expect(ttSELECT)

  let history = if p.peek().tt == ttHISTORY:
    discard p.advance()
    true
  else:
    false

  if p.peek().tt == ttSTAR:
    discard p.advance()
    var conditions: seq[Condition]
    if p.peek().tt == ttWHERE:
      discard p.advance()
      conditions = p.parseConditionList()
    discard p.expect(ttEOF)
    SqlStmt(kind: stmtSelect,
      selectStmt: SelectStmt(projections: @[], conditions: conditions,
        existsMode: false, star: true, history: history))
  else:
    let projections = p.parseProjectionList()
    var conditions: seq[Condition]
    if p.peek().tt == ttWHERE:
      discard p.advance()
      conditions = p.parseConditionList()
    discard p.expect(ttEOF)

    var allLit: bool = true
    for proj in projections:
      if not (proj.field.isNone and proj.literal.isSome):
        allLit = false
        break
    let existsMode = not history and allLit

    SqlStmt(kind: stmtSelect,
      selectStmt: SelectStmt(projections: projections, conditions: conditions,
        existsMode: existsMode, star: false, history: history))

proc parseStmt(p: Parser): SqlStmt {.gcsafe.} =
  case p.peek().tt
  of ttSELECT: return p.parseSelect()
  of ttUPSERT: return p.parseUpsert()
  of ttUPDATE: return p.parseUpdateStmt()
  of ttDELETE: return p.parseDelete()
  of ttATTRIBUTE: return p.parseAttribute()
  of ttPARTITION: return p.parsePartitionStmt()
  of ttEXPLAIN:
    discard p.advance()
    var stmt = p.parseStmt()
    stmt.isExplain = true
    return stmt
  of ttDATALOG:
    discard p.expect(ttDATALOG)
    let inner = p.parseStmt()
    if inner.kind == stmtSelect:
      return SqlStmt(kind: stmtDatalogSelect, selectStmt: inner.selectStmt)
    else:
      raise newParseError("expected SELECT after DATALOG", p.peek().pos)
  else:
    raise newParseError(
      "expected SELECT, UPSERT, UPDATE, DELETE, ATTRIBUTE, PARTITION, or EXPLAIN (got " &
      TokenNames[ord(p.peek().tt)] & ")", p.peek().pos)

proc parse*(source: string): SqlStmt {.gcsafe.} =
  let tokens = tokenize(source)
  var parser = Parser(tokens: tokens, pos: 0)
  parser.parseStmt()
