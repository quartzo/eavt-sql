import pytest
from eavt_sql.engine import EAVTEngine


@pytest.fixture
def db(tmp_path):
    return str(tmp_path / "test")


def test_partition_creates_and_returns_id(db):
    e = EAVTEngine(db)
    rows = list(e.sql("PARTITION cnpj"))
    assert len(rows) == 1
    assert rows[0][0] == 64
    e.close()


def test_partition_idempotent(db):
    e = EAVTEngine(db)
    r1 = list(e.sql("PARTITION cnpj"))
    r2 = list(e.sql("PARTITION cnpj"))
    assert r1[0][0] == r2[0][0]
    e.close()


def test_multiple_partitions_sequential_ids(db):
    e = EAVTEngine(db)
    p1 = list(e.sql("PARTITION alpha"))
    p2 = list(e.sql("PARTITION beta"))
    assert p1[0][0] == 64
    assert p2[0][0] == 65
    e.close()


def test_insert_default_uses_user_partition(db):
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(e.sql("UPSERT SET company.name = 'ACME'"))
    eid = rows[0][0]
    assert eid >> 44 == 4
    e.close()


def test_partition_persists_across_reopen(db):
    e = EAVTEngine(db)
    list(e.sql("PARTITION cnpj"))
    e.close()

    e2 = EAVTEngine(db)
    p = e2.partition_id_for("cnpj")
    assert p == 64
    e2.close()


def test_schema_entities_no_collision_after_reopen(db):
    e = EAVTEngine(db)
    list(e.sql("PARTITION cnpj"))
    e.close()

    e2 = EAVTEngine(db)
    list(e2.sql("ATTRIBUTE cliente.nome STRING ONE"))
    rows = list(e2.sql("UPSERT SET cliente.nome = 'Test'"))
    attr_eid = rows[0][0]
    assert attr_eid >> 44 == 4
    e2.close()
