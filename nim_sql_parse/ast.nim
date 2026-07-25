import std/[json, options]

type
  LiteralKind* = enum
    litInt, litFloat, litStr, litBool, litBytes

  Literal* = ref object
    case lkind*: LiteralKind
    of litInt: ival*: int64
    of litFloat: fval*: float64
    of litStr: sval*: string
    of litBool: bval*: bool
    of litBytes: bytesval*: seq[byte]

  ValueKind* = enum
    valLiteral, valParam, valAliasRef, valEidLookup, valValLookup

  Value* = ref object
    case vkind*: ValueKind
    of valLiteral: vlit*: Literal
    of valParam: vparam*: uint32
    of valAliasRef: vref*: string
    of valEidLookup:
      eidAttr*: Value
      eidValue*: Value
    of valValLookup:
      valEntity*: Value
      valAttr*: Value

  FieldRef* = ref object
    alias*: string
    field*: string

  Projection* = ref object
    field*: Option[FieldRef]
    literal*: Option[Literal]

  ConditionRightKind* = enum
    crField, crLiteral, crParam, crIn, crOr

  ConditionRight* = ref object
    case rkind*: ConditionRightKind
    of crField: fref*: FieldRef
    of crLiteral: rlit*: Literal
    of crParam: rparam*: uint32
    of crIn: inValues*: seq[ConditionRight]
    of crOr: orBranches*: seq[seq[OrBranchItem]]

  Condition* = ref object
    left*: FieldRef
    op*: string
    right*: ConditionRight

  OrBranchItem* = ref object
    left*: FieldRef
    op*: string
    value*: ConditionRight

  UpsertEntityRefKind* = enum
    ueNew, ueExplicitEid, ueTx, ueLookup

  UpsertEntityRef* = ref object
    case erefKind*: UpsertEntityRefKind
    of ueNew, ueTx: discard
    of ueExplicitEid: eidParam*: uint32
    of ueLookup: lookupAttr*, lookupValue*: Value

  InsertValue* = ref object
    attr*: string
    value*: Value

  UpsertClause* = ref object
    alias*: Option[string]
    entityRef*: UpsertEntityRef
    values*: seq[InsertValue]

  UpsertStmt* = ref object
    clauses*: seq[UpsertClause]

  UpdateClause* = ref object
    alias*: string
    values*: seq[InsertValue]

  UpdateStmt* = ref object
    clauses*: seq[UpdateClause]
    conditions*: seq[Condition]

  DeleteStmt* = ref object
    conditions*: seq[Condition]

  AttributeStmt* = ref object
    attr*: string
    valueType*: string
    many*: bool
    unique*: bool

  PartitionStmt* = ref object
    name*: string

  SelectStmt* = ref object
    projections*: seq[Projection]
    conditions*: seq[Condition]
    existsMode*: bool
    star*: bool
    history*: bool

  SqlStmtKind* = enum
    stmtSelect, stmtDatalogSelect, stmtUpsert, stmtUpdate,
    stmtDelete, stmtAttribute, stmtPartition

  SqlStmt* = ref object
    isExplain*: bool
    case kind*: SqlStmtKind
    of stmtSelect, stmtDatalogSelect: selectStmt*: SelectStmt
    of stmtUpsert: upsertStmt*: UpsertStmt
    of stmtUpdate: updateStmt*: UpdateStmt
    of stmtDelete: deleteStmt*: DeleteStmt
    of stmtAttribute: attrStmt*: AttributeStmt
    of stmtPartition: partStmt*: PartitionStmt

proc toJson*(v: Literal): JsonNode =
  case v.lkind
  of litInt: %*{"Int": v.ival}
  of litFloat: %*{"Float": v.fval}
  of litStr: %*{"Str": v.sval}
  of litBool: %*{"Bool": v.bval}
  of litBytes: %*{"Bytes": v.bytesval}

proc toJson*(v: Value): JsonNode =
  case v.vkind
  of valLiteral: %*{"Literal": toJson(v.vlit)}
  of valParam: %*{"Param": v.vparam}
  of valAliasRef: %*{"AliasRef": v.vref}
  of valEidLookup:
    %*{"EidLookup": {"attr": toJson(v.eidAttr), "value": toJson(v.eidValue)}}
  of valValLookup:
    %*{"ValLookup": {"entity": toJson(v.valEntity), "attr": toJson(v.valAttr)}}

proc toJson*(v: FieldRef): JsonNode =
  %*{"alias": v.alias, "field": v.field}

proc toJson*(v: Projection): JsonNode =
  result = newJObject()
  if v.field.isSome:
    result["field"] = toJson(v.field.get)
  else:
    result["field"] = newJNull()
  if v.literal.isSome:
    result["literal"] = toJson(v.literal.get)
  else:
    result["literal"] = newJNull()

proc toJson*(v: ConditionRight): JsonNode =
  case v.rkind
  of crField: %*{"Field": toJson(v.fref)}
  of crLiteral: %*{"Literal": toJson(v.rlit)}
  of crParam: %*{"Param": v.rparam}
  of crIn:
    var arr = newJArray()
    for iv in v.inValues:
      arr.add(toJson(iv))
    %*{"In": arr}
  of crOr:
    var arr = newJArray()
    for branch in v.orBranches:
      var items = newJArray()
      for item in branch:
        items.add(%*{"left": toJson(item.left), "op": item.op, "value": toJson(item.value)})
      arr.add(items)
    %*{"Or": arr}

proc toJson*(v: Condition): JsonNode =
  %*{"left": toJson(v.left), "op": v.op, "right": toJson(v.right)}

proc toJson*(v: OrBranchItem): JsonNode =
  %*{"left": toJson(v.left), "op": v.op, "value": toJson(v.value)}

proc toJson*(v: UpsertEntityRef): JsonNode =
  case v.erefKind
  of ueNew: %"New"
  of ueTx: %"Tx"
  of ueExplicitEid: %*{"ExplicitEid": v.eidParam}
  of ueLookup:
    %*{"Lookup": {"attr": toJson(v.lookupAttr), "value": toJson(v.lookupValue)}}

proc toJson*(v: InsertValue): JsonNode =
  %*{"attr": v.attr, "value": toJson(v.value)}

proc toJson*(v: UpsertClause): JsonNode =
  result = newJObject()
  if v.alias.isSome:
    result["alias"] = %v.alias.get
  else:
    result["alias"] = newJNull()
  result["entity_ref"] = toJson(v.entityRef)
  var vals = newJArray()
  for iv in v.values:
    vals.add(toJson(iv))
  result["values"] = vals

proc toJson*(v: UpsertStmt): JsonNode =
  var arr = newJArray()
  for c in v.clauses:
    arr.add(toJson(c))
  %*{"clauses": arr}

proc toJson*(v: UpdateClause): JsonNode =
  var vals = newJArray()
  for iv in v.values:
    vals.add(toJson(iv))
  %*{"alias": v.alias, "values": vals}

proc toJson*(v: UpdateStmt): JsonNode =
  var clausesArr = newJArray()
  for c in v.clauses:
    clausesArr.add(toJson(c))
  var condsArr = newJArray()
  for c in v.conditions:
    condsArr.add(toJson(c))
  %*{"clauses": clausesArr, "conditions": condsArr}

proc toJson*(v: DeleteStmt): JsonNode =
  var arr = newJArray()
  for c in v.conditions:
    arr.add(toJson(c))
  %*{"conditions": arr}

proc toJson*(v: AttributeStmt): JsonNode =
  %*{"attr": v.attr, "value_type": v.valueType, "many": v.many, "unique": v.unique}

proc toJson*(v: PartitionStmt): JsonNode =
  %*{"name": v.name}

proc toJson*(v: SelectStmt): JsonNode =
  var projArr = newJArray()
  for p in v.projections:
    projArr.add(toJson(p))
  var condArr = newJArray()
  for c in v.conditions:
    condArr.add(toJson(c))
  %*{"projections": projArr, "conditions": condArr,
     "exists_mode": v.existsMode, "star": v.star, "history": v.history}

proc toJson*(v: SqlStmt): JsonNode =
  case v.kind
  of stmtSelect: %*{"Select": toJson(v.selectStmt)}
  of stmtDatalogSelect: %*{"DatalogSelect": toJson(v.selectStmt)}
  of stmtUpsert: %*{"Upsert": toJson(v.upsertStmt)}
  of stmtUpdate: %*{"Update": toJson(v.updateStmt)}
  of stmtDelete: %*{"Delete": toJson(v.deleteStmt)}
  of stmtAttribute: %*{"Attribute": toJson(v.attrStmt)}
  of stmtPartition: %*{"Partition": toJson(v.partStmt)}
