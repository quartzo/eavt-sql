## test_edn_tx.nim — Unit tests for the EDN tx interpreter (docs/tx-protocol.md).

import std/[unittest, options, strutils, tables]
import scheme, hostfns, engine, edn_tx, kvstore, edn, resolver, keys, eavt

proc parseTx(src: string): seq[SExpr] =
  ## tx-data written as EDN text — the readability front door for tests.
  readEdnVector(src)

proc newMemoryKVStore(): KVStore =
  newTempFileKVStore()

suite "edn_tx: basic add":
  test "single add with concrete eid":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("user/name", ":db.type/string", false, false, 1)

    let rep = transactEdn(q, readEdnVector(
      "[[:db/add 101 :user/name \"Alice\"]]"))
    check rep.tx > 0
    check rep.tempids.len == 0
    let val = q.lookupValue(101, "user/name")
    check val.isSome and val.get.sval == "Alice"

  test "tx datoms share one t and txInstant exists":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("user/name", ":db.type/string", false, false, 1)
    let rep = transactEdn(q, readEdnVector(
      "[[:db/add 1 :user/name \"x\"] [:db/add 2 :user/name \"y\"]]"))
    # the tx entity carries :db/txInstant
    check q.lookupValue(rep.tx, "db/txInstant").isSome

suite "edn_tx: tempids":
  test "tempid allocates and chains":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    q.declareAttrFromSql("person/employer", ":db.type/ref", false, false, 1)
    q.declareAttrFromSql("company/name", ":db.type/string", false, false, 1)

    let rep = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/name \"alice\"]" &
      " [:db/add -1 :person/employer -2]" &
      " [:db/add -2 :company/name \"Acme\"]]"))
    check rep.tempids.len == 2
    let alice = rep.tempids[-1]
    let acme = rep.tempids[-2]
    check alice > 0 and acme > 0 and alice != acme
    check q.lookupValue(alice, "person/employer").get.ival == acme

  test "tempid upsert on unique attr reuses entity":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/email", ":db.type/string", false, true, 1)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)

    let rep1 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"] [:db/add -1 :person/name \"Old\"]]"))
    check rep1.tempids[-1] > 0

    # upsert in a later tx
    let rep2 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"] [:db/add -1 :person/name \"New\"]]"))
    check rep2.tempids[-1] == rep1.tempids[-1]
    check q.lookupValue(rep2.tempids[-1], "person/name").get.sval == "New"

  test "idempotent re-assert keeps unique lookup intact across 3 txs":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/email", ":db.type/string", false, true, 1)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)

    let rep1 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"] [:db/add -1 :person/name \"Old\"]]"))
    let rep2 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"] [:db/add -1 :person/name \"New\"]]"))
    check rep2.tempids[-1] == rep1.tempids[-1]
    # third tx: re-assert the SAME value — must be a no-op, not retract+reassert
    # (a retract marker at the same t as the re-assert shadows the datom)
    let rep3 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"]]"))
    check rep3.tempids[-1] == rep1.tempids[-1]
    check q.lookupValue(rep1.tempids[-1], "person/email").get.sval == "a@b.c"

  test "cardinality-many re-add of an existing value is a no-op":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("post/tag", ":db.type/string", true, false, 1)

    let rep1 = transactEdn(q, readEdnVector(
      "[[:db/add 101 :post/tag \"db\"] [:db/add 101 :post/tag \"nim\"] [:db/add 101 :post/tag \"db\"]]"))
    # value "db" asserted once despite appearing twice in the same tx
    let eid = 101'i64
    let hasDb = q.hasDatom(eid, "post/tag", newStr("db"))
    check hasDb

    # later tx re-adding both values — no duplicate datoms
    discard transactEdn(q, readEdnVector(
      "[[:db/add 101 :post/tag \"db\"] [:db/add 101 :post/tag \"nim\"]]"))
    var prefix = keys.encodeEid(eid)
    let aidOpt = resolver.lookupAttr(q.eavt.resolver, "post/tag")
    let aid = aidOpt.get
    prefix.add byte(aid shr 24); prefix.add byte((aid shr 16) and 0xFF)
    prefix.add byte((aid shr 8) and 0xFF); prefix.add byte(aid and 0xFF)
    let active = q.eavt.scanPrefixActive(0, prefix)
    check active.len == 2  # exactly "db" and "nim" — no duplicates

  test "tempid in v slot before its op resolves (order independence)":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("a/ref", ":db.type/ref", false, false, 1)
    q.declareAttrFromSql("b/name", ":db.type/string", false, false, 1)

    let rep = transactEdn(q, readEdnVector(
      "[[:db/add -1 :a/ref -2] [:db/add -2 :b/name \"target\"]]"))
    check q.lookupValue(rep.tempids[-1], "a/ref").get.ival == rep.tempids[-2]

suite "edn_tx: lookup refs":
  test "lookup ref resolves in-tx":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/email", ":db.type/string", false, true, 1)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)

    let rep1 = transactEdn(q, readEdnVector(
      "[[:db/add -1 :person/email \"a@b.c\"] [:db/add -1 :person/name \"A\"]]"))
    let eid = rep1.tempids[-1]

    let rep2 = transactEdn(q, readEdnVector(
      "[[:db/add [:person/email \"a@b.c\"] :person/name \"A2\"]]"))
    check rep2.tempids.len == 0
    check q.lookupValue(eid, "person/name").get.sval == "A2"

  test "lookup ref miss is an error and aborts the tx":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/email", ":db.type/string", false, true, 1)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)

    expect(TxError):
      discard transactEdn(q, readEdnVector(
        "[[:db/add [:person/email \"missing\"] :person/name \"X\"]]"))
    # nothing applied
    check q.lookupEntity("person/name", newStr("X")).isNone

  test "lookup ref on non-unique attr is an error":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("person/name", ":db.type/string", false, false, 1)
    expect(TxError):
      discard transactEdn(q, readEdnVector(
        "[[:db/add [:person/name \"x\"] :person/name \"y\"]]"))

suite "edn_tx: :db/current-tx":
  test "tx metadata attaches to the tx entity":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("audit/user", ":db.type/string", false, false, 1)
    q.declareAttrFromSql("user/name", ":db.type/string", false, false, 1)

    let rep = transactEdn(q, readEdnVector(
      "[[:db/add 101 :user/name \"x\"]" &
      " [:db/add :db/current-tx :audit/user \"fabio\"]]"))
    check q.lookupValue(rep.tx, "audit/user").get.sval == "fabio"

  test "retract on :db/current-tx is an error":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("audit/user", ":db.type/string", false, false, 1)
    expect(TxError):
      discard transactEdn(q, readEdnVector(
        "[[:db/retract :db/current-tx :audit/user \"x\"]]"))

suite "edn_tx: schema as data":
  test "attribute declared and used in the same tx":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    let rep = transactEdn(q, readEdnVector(
      "[[:db/add 1 :db/ident :person/name]" &
      " [:db/add 1 :db/valueType :db.type/string]" &
      " [:db/add 1 :db/cardinality :db.cardinality/one]" &
      " [:db/add -1 :person/name \"works\"]]"))
    check rep.tempids[-1] > 0
    check q.lookupValue(rep.tempids[-1], "person/name").get.sval == "works"
    check q.isUniqueAttr("person/name") == false

  test "schema unique identity makes same-tx upsert work":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)

    discard transactEdn(q, readEdnVector(
      "[[:db/add 1 :db/ident :person/email]" &
      " [:db/add 1 :db/valueType :db.type/string]" &
      " [:db/add 1 :db/unique :db.unique/identity]]"))
    check q.isUniqueAttr("person/email")

  test "unknown value type keyword errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    expect(TxError):
      discard transactEdn(q, readEdnVector(
        "[[:db/add 1 :db/ident :x/y] [:db/add 1 :db/valueType :db.type/nonsense]]"))

suite "edn_tx: retract and errors":
  test "retract removes the datom":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("user/name", ":db.type/string", false, false, 1)
    discard transactEdn(q, readEdnVector("[[:db/add 101 :user/name \"gone\"]]"))
    check q.lookupValue(101, "user/name").isSome

    discard transactEdn(q, readEdnVector("[[:db/retract 101 :user/name \"gone\"]]"))
    check q.lookupValue(101, "user/name").isNone

  test "retract with keyword value errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    q.declareAttrFromSql("user/name", ":db.type/string", false, false, 1)
    expect(TxError):
      discard transactEdn(q, readEdnVector("[[:db/retract 101 :user/name :kw]]"))

  test "unknown op keyword errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    expect(TxError):
      discard transactEdn(q, readEdnVector("[[:db/fn 1 2 3]]"))

  test "empty txdata errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    expect(TxError):
      discard transactEdn(q, readEdnVector("[]"))

  test "malformed op errors":
    let kv = newMemoryKVStore()
    defer: kv.close()
    let q = newQueryStore(kv)
    expect(TxError):
      discard transactEdn(q, readEdnVector("[[:db/add 1]]"))
    expect(TxError):
      discard transactEdn(q, readEdnVector("[[1 2 3 4]]"))