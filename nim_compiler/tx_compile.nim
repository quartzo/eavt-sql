## tx_compile.nim — Compile SQL write statements to EDN tx-data
## (docs/tx-protocol.md).  EDN twins of scheme_compile's write compilers:
## the query server sends the transactor a `tx` request instead of a
## Scheme program.  Params are substituted at compile time — the tx
## protocol has no (param N) (§5.4).
##
## Ops are plain SExpr vectors: [kw("db/add"), e, kw("attr"), value].
## Values are concrete SExprs (params resolved by the caller).

import std/[strutils, options]
import ast as sql_ast
import scheme

# ── Value translation (SQL AST → concrete SExpr; params resolved) ──────────

proc literalToVal*(l: sql_ast.Literal): SExpr =
  case l.lkind
  of sql_ast.litInt: newInt(l.ival)
  of sql_ast.litFloat: newFloat(l.fval)
  of sql_ast.litStr: newStr(l.sval)
  of sql_ast.litBool: newBool(l.bval)
  of sql_ast.litBytes: newBytes(l.bytesval)

proc valueToVal*(v: sql_ast.Value; params: seq[SExpr]): SExpr =
  ## Substitute %N params at compile time (§5.4): the tx protocol carries
  ## values inline.  Non-literal/non-param values are not supported in tx
  ## (the SQL surface routes alias refs and expressions to the VM path).
  case v.vkind
  of sql_ast.valLiteral: literalToVal(v.vlit)
  of sql_ast.valParam:
    let idx = int(v.vparam)
    if idx < 1 or idx > params.len:
      raise newException(ValueError,
        "tx: param %" & $idx & " out of range (" & $params.len & " supplied)")
    params[idx - 1]
  else:
    raise newException(ValueError,
      "tx: unsupported value kind in write statement: " & $v.vkind)

# ── Ops ──────────────────────────────────────────────────────────────────────

template txAdd*(e: SExpr; attr: string; v: SExpr): SExpr =
  newList(@[newKeyword("db/add"), e, newKeyword(attr), v])

template txRetract*(e: SExpr; attr: string; v: SExpr): SExpr =
  newList(@[newKeyword("db/retract"), e, newKeyword(attr), v])

# ── Statement compilers (twins of scheme_compile's write paths) ─────────────

proc compileUpsertTx*(stmt: sql_ast.UpsertStmt; params: seq[SExpr];
                      tempidBase: int64 = -1): seq[SExpr] =
  ## UPSERT → tx-data.  One tempid per clause:
  ##   ueNew / ueTx       → fresh tempid (allocates / current-tx metadata)
  ##   ueExplicitEid      → concrete eid (param resolved by caller)
  ##   ueLookup           → tempid anchored on the unique attr: the first
  ##                        :db/add carries (lookupAttr, lookupValue), so
  ##                        the interpreter's upsert resolution reuses the
  ##                        existing entity (get-or-create; Datomic
  ##                        :db.unique/identity semantics).  The tx-report
  ##                        tempids map then carries the eid for the client.
  var tid = tempidBase
  for clause in stmt.clauses:
    let eSlot: SExpr = case clause.entityRef.erefKind
      of sql_ast.ueNew: newInt(tid)
      of sql_ast.ueTx: newKeyword("db/current-tx")
      of sql_ast.ueExplicitEid: valueToVal(
          sql_ast.Value(vkind: sql_ast.valParam, vparam: clause.entityRef.eidParam),
          params)
      of sql_ast.ueLookup:
        result.add txAdd(newInt(tid),
          case clause.entityRef.lookupAttr.vkind
          of sql_ast.valLiteral: clause.entityRef.lookupAttr.vlit.sval
          else: raise newException(ValueError,
            "tx: lookup ref attr must be a string literal"),
          valueToVal(clause.entityRef.lookupValue, params))
        newInt(tid)
    for iv in clause.values:
      result.add txAdd(eSlot, iv.attr, valueToVal(iv.value, params))
    if clause.entityRef.erefKind == sql_ast.ueNew or
       clause.entityRef.erefKind == sql_ast.ueLookup:
      dec tid
  # NB: allocation order — tempids are assigned per clause in emission order;
  # the interpreter resolves them all in step 3 (§5.1).

proc compileAttributeTx*(stmt: sql_ast.AttributeStmt): seq[SExpr] =
  ## ATTRIBUTE → schema-as-data group on a fixed schema eid.  The eid is a
  ## plain positive int (schema entities are engine-managed, §4).  The
  ## transactor's declareAttrFromSql allocates the real aid; the tx-data
  ## eid literal just groups the datoms.  The SQL path sends one ATTRIBUTE
  ## per tx, so a fixed marker eid can never collide with another group.
  var ops: seq[SExpr] = @[
    txAdd(newInt(0), "db/ident", newKeyword(stmt.attr)),
    txAdd(newInt(0), "db/valueType", newKeyword("db.type/" & stmt.valueType)),
    txAdd(newInt(0), "db/cardinality",
          newKeyword(if stmt.many: "db.cardinality/many"
                     else: "db.cardinality/one")),
  ]
  if stmt.unique:
    ops.add txAdd(newInt(0), "db/unique", newKeyword("db.unique/identity"))
  ops
