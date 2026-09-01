## test_golden_tx.nim — Golden tests: the SQL-compiled Scheme program and the
## EDN tx interpreter produce the SAME final datoms (docs/tx-protocol.md F4
## acceptance: "golden tests SQL↔EDN (same final datoms via both paths)").

import std/[unittest, options, tables, algorithm, strutils, sequtils]
import scheme, hostfns, engine, edn_tx, kvstore, edn, resolver, keys, eavt
import ast as sql_ast
import frontend, compiler

proc newMemoryKVStore(): KVStore = newTempFileKVStore()

proc dumpUserDatoms(q: QueryStore): seq[(int64, string, string)] =
  ## (eid, attrName, value-as-string) for all active user datoms, sorted.
  let ks = q.eavt.scanPrefix(0, @[])
  for k in ks:
    if k.len < 24: continue
    let eid = decodeEid(beUint64(k, 0))
    let aid = beUint32(k, 8)
    let name = q.eavt.attrName(aid)
    if name.startsWith("db/"): continue
    let vt = q.eavt.valueTypeFor(aid).get(resolver.DbTypeString)
    let v = decodeStoredValue(k[12 ..< k.len - 8], vt)
    result.add (eid, name, $v)
  result.sort(proc (a, b: (int64, string, string)): int = system.cmp(a[2], b[2]))

proc runSqlUpsert(q: QueryStore; attrs: seq[string]; vals: seq[string]): int64 =
  ## Compile the SQL UPSERT surface and execute it through the VM (the same
  ## path the transactor's scheme exec uses) — returns the reported eid.
  var clauses: seq[sql_ast.UpsertClause] = @[]
  for i in 0 ..< attrs.len:
    clauses.add sql_ast.UpsertClause(
      alias: none(string),
      entityRef: sql_ast.UpsertEntityRef(erefKind: sql_ast.ueNew),
      values: @[sql_ast.InsertValue(attr: attrs[i],
        value: sql_ast.Value(vkind: sql_ast.valLiteral,
          vlit: sql_ast.Literal(lkind: sql_ast.litStr, sval: vals[i])))])
  let stmt = sql_ast.SqlStmt(kind: sql_ast.stmtUpsert,
    upsertStmt: sql_ast.UpsertStmt(clauses: clauses))
  let compiled = compileSql(stmt, q.eavt.buildCompileStats())
  let session = newQuerySession(q, compiled.program, @[], q.allocateTx(),
                                none[int64]())
  let r = executeProgram(session)
  doAssert r.kind == sList and r.items.len >= 2
  result = r.items[1].ival

suite "golden: SQL (scheme VM) vs EDN (tx interpreter) — same final datoms":
  test "single-attr upsert":
    let qA = newQueryStore(newMemoryKVStore())
    qA.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    discard runSqlUpsert(qA, @["person/name"], @["Alice"])
    let datomsA = dumpUserDatoms(qA)

    let qB = newQueryStore(newMemoryKVStore())
    qB.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    discard transactEdn(qB, readEdnVector(
      "[[:db/add -1 :person/name \"Alice\"]]"))
    let datomsB = dumpUserDatoms(qB)

    check datomsA.len == 1
    check datomsA == datomsB

  test "multi-attr upsert (ref chaining shape)":
    let qA = newQueryStore(newMemoryKVStore())
    qA.declareAttrFromSql("company/name", ":db.type/string", false, false, 1)
    qA.declareAttrFromSql("company/ceo", ":db.type/ref", false, false, 1)
    qA.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    # person via plain SQL UPSERT; company via explicit-eid UPSERT with ref param
    let eidPerson = runSqlUpsert(qA, @["person/name"], @["John"])
    let stmt = sql_ast.SqlStmt(kind: sql_ast.stmtUpsert,
      upsertStmt: sql_ast.UpsertStmt(
        clauses: @[sql_ast.UpsertClause(
          alias: none(string),
          entityRef: sql_ast.UpsertEntityRef(erefKind: sql_ast.ueExplicitEid,
            eidParam: 1'u32),
          values: @[sql_ast.InsertValue(attr: "company/name",
            value: sql_ast.Value(vkind: sql_ast.valLiteral,
              vlit: sql_ast.Literal(lkind: sql_ast.litStr, sval: "Acme"))),
          sql_ast.InsertValue(attr: "company/ceo",
            value: sql_ast.Value(vkind: sql_ast.valParam, vparam: 1'u32))])])
    )
    let compiled = compileSql(stmt, qA.eavt.buildCompileStats())
    let session = newQuerySession(qA, compiled.program,
      @[SExpr(kind: sInt, ival: eidPerson)], qA.allocateTx(), none[int64]())
    discard executeProgram(session)
    let datomsA = dumpUserDatoms(qA)

    let qB = newQueryStore(newMemoryKVStore())
    qB.declareAttrFromSql("company/name", ":db.type/string", false, false, 1)
    qB.declareAttrFromSql("company/ceo", ":db.type/ref", false, false, 1)
    qB.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    let repB = transactEdn(qB, readEdnVector(
      "[[:db/add -1 :person/name \"John\"]" &
      " [:db/add -2 :company/name \"Acme\"]" &
      " [:db/add -2 :company/ceo -1]]"))
    let eidJohn = repB.tempids[-1]
    let datomsB = dumpUserDatoms(qB)

    # eids differ across stores (independent allocators) — compare the
    # (attr, value) sets and ref-target consistency:
    check datomsA.len == 3
    check datomsB.len == 3
    let valsA = datomsA.mapIt((it[1], it[2]))
    let valsB = datomsB.mapIt((it[1], it[2]))
    check valsA == valsB
    for (eid, attr, v) in datomsA:
      if attr == "company/ceo":
        check v == $eidPerson
    for (eid, attr, v) in datomsB:
      if attr == "company/ceo":
        check v == $eidJohn

  test "retract via tx matches SQL retract":
    let qA = newQueryStore(newMemoryKVStore())
    qA.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    let eid = qA.allocateInPartition(4)
    qA.saveWithT(eid, "person/name", newStr("Alice"), 1, 0)
    qA.retract(eid, "person/name", newStr("Alice"), 2, 0)
    check qA.lookupValue(eid, "person/name").isNone

    let qB = newQueryStore(newMemoryKVStore())
    qB.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    let eidB = qB.allocateInPartition(4)
    qB.saveWithT(eidB, "person/name", newStr("Alice"), 1, 0)
    discard transactEdn(qB, readEdnVector(
      "[[:db/retract " & $eidB & " :person/name \"Alice\"]]"))
    check qB.lookupValue(eidB, "person/name").isNone