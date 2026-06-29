import pytest
from eavt_sql.engine import EAVTEngine


def _make_tx_ent(t: int) -> int:
    return (3 << 44) | t


def test_insert_into_tx_basic():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        " AS TX SET tx.user = 'alice'"
    ))

    rows = list(e.sql("SELECT d1.eid WHERE d1.tx.user = 'alice'"))
    assert len(rows) == 1
    tx_eid = rows[0][0]
    assert tx_eid == _make_tx_ent(1002)


def test_insert_into_tx_returns_tx_entity():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))

    rows = list(e.sql("UPSERT AS TX SET tx.user = 'bob'"))
    assert len(rows) == 1
    assert rows[0][0] == _make_tx_ent(1001)


def test_insert_into_tx_multiple_attrs():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))
    list(e.sql("ATTRIBUTE tx.comment STRING ONE"))

    list(e.sql("UPSERT AS TX SET tx.user = 'carol', tx.comment = 'initial import'"))

    user_rows = list(e.sql("SELECT d1.tx.user WHERE d1.eid = %1", _make_tx_ent(1002)))
    assert user_rows[0][0] == "carol"

    comment_rows = list(e.sql("SELECT d1.tx.comment WHERE d1.eid = %1", _make_tx_ent(1002)))
    assert comment_rows[0][0] == "initial import"


def test_insert_into_tx_with_data():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    rows = list(e.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        " AS TX SET tx.user = 'dave'"
    ))
    company_eid = rows[0][0]

    company = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert company[0][0] == "ACME"

    tx_rows = list(e.sql("SELECT d1.tx.user WHERE d1.tx.user = 'dave'"))
    assert tx_rows[0][0] == "dave"


def test_insert_into_tx_separate_transaction():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))

    rows_a = list(e.sql("UPSERT AS TX SET tx.user = 'alice'"))
    rows_b = list(e.sql("UPSERT AS TX SET tx.user = 'bob'"))

    assert rows_a[0][0] != rows_b[0][0]
    assert rows_a[0][0] == _make_tx_ent(1001)
    assert rows_b[0][0] == _make_tx_ent(1002)


def test_insert_into_tx_shared_transaction():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE tx.user STRING ONE"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    rows = list(e.sql(
        "UPSERT AS D1 SET company.name = 'Foo',"
        " AS TX SET tx.user = 'eve'"
    ))
    company_eid = rows[0][0]

    tx_eids = list(e.sql("SELECT d1.tx WHERE d1.eid = %1", company_eid))
    tx_eid = tx_eids[0][0]

    tx_rows = list(e.sql("SELECT d1.tx.user WHERE d1.eid = %1", tx_eid))
    assert tx_rows[0][0] == "eve"

    tx_user_tx = list(e.sql("SELECT d1.tx WHERE d1.eid = %1 AND d1.tx.user = 'eve'", tx_eid))
    assert tx_user_tx[0][0] == tx_eid


def test_t_persists_across_reopen(tmp_path):
    e = EAVTEngine(str(tmp_path / "test.db"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("UPSERT SET company.name = 'first'"))
    list(e.sql("UPSERT SET company.name = 'second'"))
    e.close()

    e2 = EAVTEngine(str(tmp_path / "test.db"))
    rows = list(e2.sql("UPSERT SET company.name = 'third'"))
    tx_eids = list(e2.sql("SELECT d1.tx WHERE d1.eid = %1", rows[0][0]))
    tx_eid = tx_eids[0][0]
    t = tx_eid & ((1 << 44) - 1)
    assert t >= 1003
    e2.close()


def test_as_of_t(tmp_path):
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))

    list(e.sql("UPSERT SET company.name = 'before'"))
    rows = list(e.sql("UPSERT SET company.name = 'after'"))
    after_eid = rows[0][0]

    all_rows = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", after_eid))
    assert all_rows[0][0] == "after"

    tx_eids = list(e.sql("SELECT d1.tx WHERE d1.company.name = 'before'"))
    as_of_tx = tx_eids[0][0]

    filtered = list(e.sql(
        "SELECT d1.company.name WHERE d1.eid = %1",
        after_eid,
        as_of=as_of_tx,
    ))
    assert len(filtered) == 0
