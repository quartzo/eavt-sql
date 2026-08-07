"""Smoke tests for the Python EAVT engine."""
import os
import tempfile

import pytest

from eavt import EavtEngine, EncodeMode


@pytest.fixture
def engine(tmp_path):
    db_path = str(tmp_path / "test_db")
    eng = EavtEngine(db_path)
    eng.bootstrap()
    yield eng
    eng.close()


# ═══════════════════════════════════════════════════════════════════════════════
# Bootstrap
# ═══════════════════════════════════════════════════════════════════════════════


def test_bootstrap_creates_system_attrs(engine):
    # db.ident should be attribute 1
    assert engine.lookup_attr("db.ident") == 1
    assert engine.lookup_attr("db.valueType") == 3
    assert engine.lookup_attr("db.txInstant") == 9


def test_bootstrap_idempotent(tmp_path):
    db_path = str(tmp_path / "test_db")
    eng1 = EavtEngine(db_path)
    eng1.bootstrap()
    eng1.close()

    eng2 = EavtEngine(db_path)
    eng2.bootstrap()
    # Should not crash, should load existing schema
    assert eng2.lookup_attr("db.ident") == 1
    eng2.close()


# ═══════════════════════════════════════════════════════════════════════════════
# Schema declaration
# ═══════════════════════════════════════════════════════════════════════════════


def test_declare_attr(engine):
    aid, is_new = engine.declare_attr("person.name", "string")
    assert is_new is True
    assert aid > 0

    # Second call should be idempotent
    aid2, is_new2 = engine.declare_attr("person.name", "string")
    assert is_new2 is False
    assert aid2 == aid


def test_declare_attr_many(engine):
    aid, _ = engine.declare_attr("person.tags", "string", many=True)
    assert engine.is_many(aid) is True


def test_declare_attr_unique(engine):
    aid, _ = engine.declare_attr("person.email", "string", unique=True)
    assert engine.is_unique(aid) is True


# ═══════════════════════════════════════════════════════════════════════════════
# Save / Lookup
# ═══════════════════════════════════════════════════════════════════════════════


def test_save_and_lookup(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    assert engine.lookup_value(eid, "person.name") == "Alice"


def test_save_overwrites_not_many(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    engine.save(eid, "person.name", "Bob")
    assert engine.lookup_value(eid, "person.name") == "Bob"


def test_save_long(engine):
    engine.declare_attr("person.age", "long")
    eid = engine.alloc_entity()
    engine.save(eid, "person.age", 42)
    assert engine.lookup_value(eid, "person.age") == 42


def test_save_float(engine):
    engine.declare_attr("person.score", "float")
    eid = engine.alloc_entity()
    engine.save(eid, "person.score", 3.14)
    val = engine.lookup_value(eid, "person.score")
    assert abs(val - 3.14) < 0.001


def test_save_boolean(engine):
    engine.declare_attr("person.active", "boolean")
    eid = engine.alloc_entity()
    engine.save(eid, "person.active", True)
    assert engine.lookup_value(eid, "person.active") is True


def test_save_ref(engine):
    engine.declare_attr("person.friend", "ref")
    eid1 = engine.alloc_entity()
    eid2 = engine.alloc_entity()
    engine.save(eid1, "person.friend", eid2)
    assert engine.lookup_value(eid1, "person.friend") == eid2


# ═══════════════════════════════════════════════════════════════════════════════
# Retract
# ═══════════════════════════════════════════════════════════════════════════════


def test_retract(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    assert engine.lookup_value(eid, "person.name") == "Alice"

    engine.retract(eid, "person.name", "Alice")
    assert engine.lookup_value(eid, "person.name") is None


# ═══════════════════════════════════════════════════════════════════════════════
# Unique lookup
# ═══════════════════════════════════════════════════════════════════════════════


def test_lookup_entity_unique(engine):
    engine.declare_attr("person.email", "string", unique=True)
    eid = engine.alloc_entity()
    engine.save(eid, "person.email", "alice@example.com")
    found = engine.lookup_entity("person.email", "alice@example.com")
    assert found == eid


def test_lookup_entity_not_found(engine):
    engine.declare_attr("person.email", "string", unique=True)
    assert engine.lookup_entity("person.email", "nobody@example.com") is None


# ═══════════════════════════════════════════════════════════════════════════════
# Scan datoms
# ═══════════════════════════════════════════════════════════════════════════════


def test_scan_datoms_eavt(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")

    datoms = list(engine.scan_datoms(0))  # EAVT
    user_datoms = [d for d in datoms if d.attr_name == "person.name"]
    assert len(user_datoms) == 1
    assert user_datoms[0].e == eid
    assert user_datoms[0].value == "Alice"
    assert user_datoms[0].retracted is False


def test_scan_datoms_after_retract(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    engine.retract(eid, "person.name", "Alice")

    datoms = list(engine.scan_datoms(0))
    name_datoms = [d for d in datoms if d.attr_name == "person.name"]
    # Both save and retract entries exist
    assert len(name_datoms) == 2
    active = [d for d in name_datoms if not d.retracted]
    retracted = [d for d in name_datoms if d.retracted]
    assert len(active) == 1
    assert len(retracted) == 1


# ═══════════════════════════════════════════════════════════════════════════════
# Persistence
# ═══════════════════════════════════════════════════════════════════════════════


def test_persistence(tmp_path):
    db_path = str(tmp_path / "test_db")

    eng1 = EavtEngine(db_path)
    eng1.bootstrap()
    eng1.declare_attr("person.name", "string")
    eid = eng1.alloc_entity()
    eng1.save(eid, "person.name", "Alice")
    eng1.close()

    eng2 = EavtEngine(db_path)
    eng2.bootstrap()
    assert eng2.lookup_value(eid, "person.name") == "Alice"
    eng2.close()


# ═══════════════════════════════════════════════════════════════════════════════
# Partition management
# ═══════════════════════════════════════════════════════════════════════════════


def test_declare_partition(engine):
    pid = engine.declare_partition("myapp.users")
    assert pid >= 64  # FIRST_CUSTOM_PARTITION

    eid = engine.alloc_entity(pid)
    from eavt.resolver import partition_of
    assert partition_of(eid) == pid


def test_multiple_entities(engine):
    engine.declare_attr("person.name", "string")
    eids = []
    for name in ["Alice", "Bob", "Charlie"]:
        eid = engine.alloc_entity()
        engine.save(eid, "person.name", name)
        eids.append(eid)

    for eid, name in zip(eids, ["Alice", "Bob", "Charlie"]):
        assert engine.lookup_value(eid, "person.name") == name
