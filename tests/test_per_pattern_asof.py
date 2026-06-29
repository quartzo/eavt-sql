from eavt_sql.engine import EAVTEngine


def _tx_ent(t: int) -> int:
    return (3 << 44) | t


def _extract_t(tx_eid: int) -> int:
    return tx_eid & ((1 << 44) - 1)


def test_as_of_hides_future_transaction():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'first'"))
    tx1 = list(e.sql("SELECT d1.tx WHERE d1.company.name = 'first'"))[0][0]
    t1 = _extract_t(tx1)

    list(e.sql("UPSERT SET company.name = 'second'"))
    tx2 = list(e.sql("SELECT d1.tx WHERE d1.company.name = 'second'"))[0][0]
    t2 = _extract_t(tx2)

    assert t1 < t2

    all_rows = list(e.sql("SELECT d1.company.name"))
    assert set(r[0] for r in all_rows) == {"first", "second"}

    filtered = list(e.sql("SELECT d1.company.name", as_of=tx1))
    assert set(r[0] for r in filtered) == {"first"}
    e.close()


def test_as_of_with_cardinality_one_overwrite():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'old'"))
    eid = list(e.sql("SELECT d1.eid WHERE d1.company.name = 'old'"))[0][0]
    tx1 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]
    t1 = _extract_t(tx1)

    list(e.sql("UPSERT AS D1 = %1 SET company.name = 'new'", eid))
    tx2 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]
    t2 = _extract_t(tx2)
    assert t1 < t2

    current = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert current[0][0] == "new"

    old = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", eid, as_of=tx1))
    assert old[0][0] == "old"
    e.close()


def test_as_of_with_retraction():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'visible'"))
    eid = list(e.sql("SELECT d1.eid WHERE d1.company.name = 'visible'"))[0][0]
    tx_insert = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]

    list(e.sql(f"DELETE WHERE d1.eid = {eid} AND d1.company.name = 'visible'"))

    current = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert current == []

    as_insert = list(e.sql(
        "SELECT d1.company.name WHERE d1.eid = %1", eid, as_of=tx_insert
    ))
    assert as_insert[0][0] == "visible"
    e.close()


def test_as_of_three_transactions():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("ATTRIBUTE company.tags STRING MANY"))

    r1 = list(e.sql("UPSERT SET company.name = 'alpha', company.tags = 't1'"))
    eid1 = r1[0][0]
    tx1 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid1))[0][0]

    r2 = list(e.sql("UPSERT SET company.name = 'beta', company.tags = 't2'"))
    eid2 = r2[0][0]
    tx2 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid2))[0][0]

    r3 = list(e.sql("UPSERT SET company.name = 'gamma'"))
    eid3 = r3[0][0]
    tx3 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid3))[0][0]

    at_tx1 = set(r[0] for r in list(e.sql("SELECT d1.company.name", as_of=tx1)))
    assert at_tx1 == {"alpha"}

    at_tx2 = set(r[0] for r in list(e.sql("SELECT d1.company.name", as_of=tx2)))
    assert at_tx2 == {"alpha", "beta"}

    at_tx3 = set(r[0] for r in list(e.sql("SELECT d1.company.name", as_of=tx3)))
    assert at_tx3 == {"alpha", "beta", "gamma"}
    e.close()


def test_as_of_integer_t_value():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'first'"))
    list(e.sql("UPSERT SET company.name = 'second'"))

    tx1 = list(e.sql("SELECT d1.tx WHERE d1.company.name = 'first'"))[0][0]
    t1 = _extract_t(tx1)

    filtered = list(e.sql("SELECT d1.company.name", as_of=t1))
    assert set(r[0] for r in filtered) == {"first"}
    e.close()


def test_tx_join_filters_correctly():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'ACME'"))
    eid = list(e.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]
    tx_eid = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]

    rows = list(e.sql(
        "SELECT d1.company.name WHERE d1.tx = d2.eid AND d2.eid = %1",
        tx_eid,
    ))
    assert len(rows) == 1
    assert rows[0][0] == "ACME"
    e.close()


def test_per_pattern_as_of_with_join():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("ATTRIBUTE company.tag STRING MANY"))

    list(e.sql("UPSERT SET company.name = 'ACME', company.tag = 'a'"))
    eid = list(e.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]
    tx1 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]

    list(e.sql("UPSERT AS D1 = %1 SET company.tag = 'b'", eid))
    tx2 = list(e.sql("SELECT d1.tx WHERE d1.eid = %1 AND d1.company.tag = 'b'", eid))[0][0]

    all_tags = set(r[0] for r in list(e.sql("SELECT d1.company.tag WHERE d1.eid = %1", eid)))
    assert all_tags == {"a", "b"}

    tags_at_tx1 = set(r[0] for r in list(e.sql(
        "SELECT d1.company.tag WHERE d1.eid = %1", eid, as_of=tx1
    )))
    assert tags_at_tx1 == {"a"}
    e.close()
