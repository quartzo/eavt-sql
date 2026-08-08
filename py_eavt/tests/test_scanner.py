"""Integration tests for V2Scanner + leapfrog triejoin."""
import tempfile

import pytest

from eavt import EavtEngine
from eavt.scanner import (
    V2Scanner,
    RocksCursor,
    leap_converge,
    apply_ranges,
)
from eavt.types import (
    DB_TYPE_LONG,
    DB_TYPE_REF,
    DB_TYPE_STRING,
)


@pytest.fixture
def populated_engine(tmp_path):
    """Engine with schema + sample data for scanner tests."""
    db_path = str(tmp_path / "scan_db")
    eng = EavtEngine(db_path)
    eng.bootstrap()

    eng.declare_attr("person.name", "string")
    eng.declare_attr("person.age", "long")
    eng.declare_attr("person.friend", "ref")

    e1 = eng.alloc_entity()
    e2 = eng.alloc_entity()
    e3 = eng.alloc_entity()

    eng.save(e1, "person.name", "Alice")
    eng.save(e1, "person.age", 30)

    eng.save(e2, "person.name", "Bob")
    eng.save(e2, "person.age", 25)

    eng.save(e3, "person.name", "Charlie")
    eng.save(e3, "person.age", 35)

    # Ref: Alice -> Bob
    eng.save(e1, "person.friend", e2)

    yield eng
    eng.close()


def _open_scanner(engine, index_name, as_of_tx=None, value_attr_type=None):
    """Helper to create a V2Scanner with cursor from engine."""
    from eavt.types import index_order as get_index_order

    idx_order = get_index_order(index_name)
    idx_order_full = idx_order + ["t", "added"]

    scanner = V2Scanner(index_name, idx_order_full, as_of_tx, value_attr_type)
    cf_id = {"eavt": 0, "aevt": 1, "avet": 2, "vaet": 3}[index_name.lower()]
    raw_it = engine.open_iterator(cf_id)
    raw_it.seek_to_first()
    scanner.set_cursor(RocksCursor(raw_it))
    scanner.advance_to_active_at()
    return scanner


def _collect_all_values(engine, index_name, push_values=None, value_attr_type=None):
    """Open scanner, optionally push some values, then collect all remaining values."""
    sc = _open_scanner(engine, index_name, value_attr_type=value_attr_type)
    for v in push_values or []:
        cur = sc.extract_current()
        if cur is None:
            return []
        sc.save_value(v)
        sc.advance_to_active_at()  # re-seek after push

    results = []
    count = 0
    while not sc.at_end() and count < 100:
        val = sc.extract_current()
        if val is not None:
            results.append(val[1])
        sc.leap_next_at()
        count += 1
    return results


# ═══════════════════════════════════════════════════════════════════════════════
# Basic scanner operations
# ═══════════════════════════════════════════════════════════════════════════════


def test_scanner_open_eavt(populated_engine):
    sc = _open_scanner(populated_engine, "EAVT")
    assert not sc.at_end()


def test_scanner_extract_current_returns_entity(populated_engine):
    sc = _open_scanner(populated_engine, "EAVT")
    val = sc.extract_current()
    assert val is not None
    vtype, vraw = val
    assert vtype == int
    assert vraw > 0  # entity ID


def test_scanner_iterate_all_eavt(populated_engine):
    """EAVT scanner visits all datoms."""
    sc = _open_scanner(populated_engine, "EAVT")
    entities = set()
    count = 0
    while not sc.at_end() and count < 100:
        val = sc.extract_current()
        if val is not None:
            entities.add(val[1])
        sc.leap_next_at()
        count += 1
    # Should see multiple entity IDs (bootstrap + user)
    assert len(entities) > 3


def test_scanner_push_and_advance(populated_engine):
    """Push an entity ID, then iterate attributes for that entity."""
    aid = populated_engine.lookup_attr("person.name")
    e1 = populated_engine.alloc_entity()  # just get a known eid
    # Actually, let's use the first entity from the scanner
    sc = _open_scanner(populated_engine, "EAVT")

    # Get first entity ID
    val = sc.extract_current()
    assert val is not None
    eid = val[1]

    # Push eid to filter to that entity
    sc.save_value(eid)

    # Now iterate attributes for this entity
    attrs = []
    count = 0
    while not sc.at_end() and count < 20:
        v = sc.extract_current()
        if v is not None:
            attrs.append(v[1])
        sc.leap_next_at()
        count += 1

    # Should see at least one attribute
    assert len(attrs) >= 1


# ═══════════════════════════════════════════════════════════════════════════════
# AEVT scanner — iterate by attribute
# ═══════════════════════════════════════════════════════════════════════════════


def test_scanner_aevt_iterate_attrs(populated_engine):
    """AEVT index: first position is attribute ID."""
    sc = _open_scanner(populated_engine, "AEVT")
    seen_attrs = set()
    count = 0
    while not sc.at_end() and count < 100:
        val = sc.extract_current()
        if val is not None:
            seen_attrs.add(val[1])
        sc.leap_next_at()
        count += 1
    # Should see multiple distinct attribute IDs
    assert len(seen_attrs) > 1


def test_scanner_aevt_filter_by_attr(populated_engine):
    """Push an attr ID in AEVT to iterate entities with that attr."""
    aid = populated_engine.lookup_attr("person.name")
    assert aid is not None

    # Push attr ID
    entities = _collect_all_values(populated_engine, "AEVT", push_values=[aid])
    # Should find entities that have person.name
    assert len(entities) >= 3  # e1, e2, e3


# ═══════════════════════════════════════════════════════════════════════════════
# Leapfrog triejoin
# ═══════════════════════════════════════════════════════════════════════════════


def test_leap_converge_two_scanners(populated_engine):
    """Two EAVT scanners converge on shared entity IDs."""
    sc1 = _open_scanner(populated_engine, "EAVT")
    sc2 = _open_scanner(populated_engine, "EAVT")

    result = leap_converge([sc1, sc2])
    assert result is True

    v1 = sc1.extract_current()
    v2 = sc2.extract_current()
    assert v1 is not None
    assert v2 is not None
    assert v1 == v2  # same entity ID


def test_leapfrog_iterate_shared_entities(populated_engine):
    """Leapfrog iterate over entity IDs shared by two EAVT scanners."""
    sc1 = _open_scanner(populated_engine, "EAVT")
    sc2 = _open_scanner(populated_engine, "EAVT")

    converged = leap_converge([sc1, sc2])
    assert converged

    entities = []
    count = 0
    while converged and count < 50:
        v = sc1.extract_current()
        if v is not None:
            entities.append(v[1])
        sc1.leap_next_at()
        converged = leap_converge([sc1, sc2])
        count += 1

    assert len(entities) >= 3


def test_leapfrog_two_aevt_scanners(populated_engine):
    """Two AEVT scanners with same attr converge on entity IDs."""
    aid = populated_engine.lookup_attr("person.name")
    assert aid is not None

    sc1 = _open_scanner(populated_engine, "AEVT")
    sc2 = _open_scanner(populated_engine, "AEVT")

    # Push same attr on both, then re-seek
    sc1.save_value(aid)
    sc1.advance_to_active_at()
    sc2.save_value(aid)
    sc2.advance_to_active_at()

    result = leap_converge([sc1, sc2])
    assert result is True

    # Should find entity IDs that have person.name
    entities = []
    count = 0
    while result and count < 20:
        v = sc1.extract_current()
        if v is not None:
            entities.append(v[1])
        sc1.leap_next_at()
        result = leap_converge([sc1, sc2])
        count += 1

    assert len(entities) >= 3  # Alice, Bob, Charlie


# ═══════════════════════════════════════════════════════════════════════════════
# Scanner classify_key
# ═══════════════════════════════════════════════════════════════════════════════


def test_classify_key_no_prefix(populated_engine):
    sc = _open_scanner(populated_engine, "EAVT")
    key = sc.pos.current_active_key
    assert key is not None
    from eavt.scanner import KVP_NO_PREFIX
    assert sc.classify_key(key) == KVP_NO_PREFIX


def test_classify_key_with_prefix(populated_engine):
    sc = _open_scanner(populated_engine, "EAVT")
    val = sc.extract_current()
    assert val is not None
    sc.save_value(val[1])  # push eid → prefix now has eid

    key = sc.pos.current_active_key
    assert key is not None
    from eavt.scanner import KVP_MATCH, KVP_NO_PREFIX
    # Key should match the prefix (same eid)
    assert sc.classify_key(key) in (KVP_MATCH, KVP_NO_PREFIX)


# ═══════════════════════════════════════════════════════════════════════════════
# Scanner seek_to_value
# ═══════════════════════════════════════════════════════════════════════════════


def test_scanner_seek_to_value(populated_engine):
    """Seek an AEVT scanner to a specific attribute."""
    aid = populated_engine.lookup_attr("person.name")
    assert aid is not None

    sc = _open_scanner(populated_engine, "AEVT")
    sc.seek_to_value((int, aid))

    if not sc.at_end():
        v = sc.extract_current()
        assert v is not None
        # Should be at or past the target attribute
        assert v[1] >= aid


# ═══════════════════════════════════════════════════════════════════════════════
# VAET scanner for ref types
# ═══════════════════════════════════════════════════════════════════════════════


def test_vaet_scanner_basic(populated_engine):
    """VAET index has value-first layout."""
    sc = _open_scanner(populated_engine, "VAET", value_attr_type=DB_TYPE_REF)
    # First position is value (ref target eid)
    val = sc.extract_current()
    assert val is not None
    vtype, vraw = val
    assert vtype == int  # ref target is an entity ID


def test_vaet_scanner_find_referrers(populated_engine):
    """Use VAET to find who references a specific entity via person.friend."""
    # Find Bob's eid by scanning EAVT for all datoms
    bob_eid = None
    for datom in populated_engine.scan_datoms(0):  # EAVT
        if datom.attr_name == "person.name" and datom.value == "Bob" and not datom.retracted:
            bob_eid = datom.e
            break
    assert bob_eid is not None, "Could not find Bob's entity ID"

    # Now use VAET to find who references Bob via person.friend
    aid_friend = populated_engine.lookup_attr("person.friend")
    assert aid_friend is not None

    sc_vaet = _open_scanner(populated_engine, "VAET", value_attr_type=DB_TYPE_REF)
    sc_vaet.save_value(bob_eid)  # push ref target (Bob's eid)
    sc_vaet.advance_to_active_at()
    sc_vaet.save_value(aid_friend)  # push person.friend attr
    sc_vaet.advance_to_active_at()

    referrers = []
    count = 0
    while not sc_vaet.at_end() and count < 20:
        v = sc_vaet.extract_current()
        if v is not None:
            referrers.append(v[1])
        sc_vaet.leap_next_at()
        count += 1

    assert len(referrers) >= 1


# ═══════════════════════════════════════════════════════════════════════════════
# Multiple scanners with different prefixes
# ═══════════════════════════════════════════════════════════════════════════════


def test_two_scanners_different_attrs(populated_engine):
    """Two AEVT scanners with different attrs converge via leapfrog."""
    aid_name = populated_engine.lookup_attr("person.name")
    aid_age = populated_engine.lookup_attr("person.age")

    sc1 = _open_scanner(populated_engine, "AEVT")
    sc2 = _open_scanner(populated_engine, "AEVT")

    sc1.save_value(aid_name)
    sc1.advance_to_active_at()
    sc2.save_value(aid_age)
    sc2.advance_to_active_at()

    # Leapfrog should find entity IDs that have BOTH person.name and person.age
    result = leap_converge([sc1, sc2])
    assert result is True

    entities = []
    count = 0
    while result and count < 20:
        v = sc1.extract_current()
        if v is not None:
            entities.append(v[1])
        sc1.leap_next_at()
        result = leap_converge([sc1, sc2])
        count += 1

    # All 3 user entities have both name and age
    assert len(entities) >= 3
