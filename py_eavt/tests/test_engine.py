"""Smoke tests for the Python EAVT engine."""
import os
import tempfile

import pytest

from eavt import EavtEngine, EncodeMode, keys


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
# Pending buffer / commit
# ═══════════════════════════════════════════════════════════════════════════════


def test_pending_visible_before_commit(engine):
    """Saves accumulate in the pending buffer; all reads see them (read-your-writes)."""
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")

    assert engine.lookup_value(eid, "person.name") == "Alice"
    assert engine.lookup_entity("person.name", "Alice") == eid

    datoms = [d for d in engine.scan_datoms(0) if d.attr_name == "person.name"]
    assert len(datoms) == 1
    assert datoms[0].value == "Alice"
    assert datoms[0].retracted is False

    it = engine.open_iterator(0)
    it.seek_to_first()
    found = []
    while it.valid():
        found.append(it.key())
        it.next()
    prefix = keys.encode_eid(eid) + keys._attr_bytes(engine.lookup_attr("person.name"))
    assert sum(1 for k in found if k.startswith(prefix)) == 1


def test_commit_persists_and_clears(tmp_path):
    db_path = str(tmp_path / "test_db")

    eng1 = EavtEngine(db_path)
    eng1.bootstrap()
    eng1.declare_attr("person.name", "string")
    eid = eng1.alloc_entity()
    eng1.save(eid, "person.name", "Alice")
    eng1.commit()

    # The pending window restarted: new saves are readable again alongside old data.
    eid2 = eng1.alloc_entity()
    eng1.save(eid2, "person.name", "Bob")
    assert eng1.lookup_value(eid2, "person.name") == "Bob"
    assert eng1.lookup_value(eid, "person.name") == "Alice"
    eng1.close()

    # Committed data is durable across reopen.
    eng2 = EavtEngine(db_path)
    eng2.bootstrap()
    assert eng2.lookup_value(eid, "person.name") == "Alice"
    assert eng2.lookup_value(eid2, "person.name") == "Bob"
    eng2.close()


def test_close_commits_pending(tmp_path):
    db_path = str(tmp_path / "test_db")

    eng1 = EavtEngine(db_path)
    eng1.bootstrap()
    eng1.declare_attr("person.city", "string")
    eid = eng1.alloc_entity()
    eng1.save(eid, "person.city", "SP")
    eng1.close()

    eng2 = EavtEngine(db_path)
    eng2.bootstrap()
    assert eng2.lookup_value(eid, "person.city") == "SP"
    eng2.close()


def test_not_many_same_tx_rewrite(engine):
    """Re-saving a not-many attr in the same tx: the last value wins (idempotent)."""
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    tx = engine.allocate_tx()

    engine.save(eid, "person.name", "Bob", tx)
    engine.save(eid, "person.name", "Carol", tx)
    assert engine.lookup_value(eid, "person.name") == "Carol"

    engine.save(eid, "person.name", "Bob", tx)
    assert engine.lookup_value(eid, "person.name") == "Bob"


def test_save_same_value_is_noop(engine):
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    engine.save(eid, "person.name", "Alice")
    assert engine.lookup_value(eid, "person.name") == "Alice"


def test_not_many_retract_then_save(engine):
    """Standalone retract then save: `_merged_active_key` must walk back past
    the trailing retract to find the still-active value."""
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    engine.save(eid, "person.name", "Alice")
    engine.commit()
    engine.retract(eid, "person.name", "Alice")
    engine.save(eid, "person.name", "Bob")
    assert engine.lookup_value(eid, "person.name") == "Bob"
    engine.commit()
    assert engine.lookup_value(eid, "person.name") == "Bob"


def test_not_many_alternating_save_retract(engine):
    """Alternating save/retract leaves a run of trailing retracts that the
    backward walk must skip; the active value is the last non-retracted key."""
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    for name in ("A", "B", "C", "D", "E"):
        engine.save(eid, "person.name", name)
        engine.retract(eid, "person.name", name)
    engine.save(eid, "person.name", "Final")
    engine.commit()
    assert engine.lookup_value(eid, "person.name") == "Final"


def test_not_many_commit_per_save_rewrite(engine):
    """Rewrite across multiple commit boundaries: committed history must not
    make the active-value lookup quadratic or wrong."""
    engine.declare_attr("person.name", "string")
    eid = engine.alloc_entity()
    for i in range(50):
        engine.save(eid, "person.name", f"name-{i}")
        engine.commit()
    assert engine.lookup_value(eid, "person.name") == "name-49"


def test_pending_merge_iter_snapshot_after_commit(engine):
    """A PendingMergeIter freezes the pending buffer at open. A commit during
    the iterator's lifetime must not crash, and the frozen pending keys must
    still be emitted (the committed cursor stays live)."""
    engine.declare_attr("t.v", "long", many=True)
    engine.commit()
    engine.save(1, "t.v", 1)
    it = engine.open_iterator(0)
    assert type(it).__name__ == "PendingMergeIter"

    it.seek_to_first()
    before = [it.key() for _ in range(3)]
    while it.valid():
        it.next()

    engine.save(2, "t.v", 99)
    engine.commit()

    it.seek_to_first()
    after = []
    while it.valid():
        after.append(it.key())
        it.next()
    assert set(before) <= set(after)  # frozen pending keys survive the commit
    assert after == sorted(set(after))  # still a valid sorted, deduped stream


def test_unique_same_tx(engine):
    engine.declare_attr("person.email", "string", unique=True)
    e1 = engine.alloc_entity()
    e2 = engine.alloc_entity()
    tx = engine.allocate_tx()
    engine.save(e1, "person.email", "dup@x.com", tx)
    engine.save(e2, "person.email", "dup@x.com", tx)
    assert engine.lookup_entity("person.email", "dup@x.com") == e1


def test_exclusive_lock_prevents_second_writer(tmp_path):
    """RocksDB holds an exclusive lock: a second process can't open the same path."""
    db_path = str(tmp_path / "test_db")

    eng1 = EavtEngine(db_path)
    eng1.bootstrap()
    with pytest.raises(Exception):
        EavtEngine(db_path)
    eng1.close()

    # After close the lock is released and the path can be reopened.
    eng2 = EavtEngine(db_path)
    eng2.bootstrap()
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
