"""Tests for QuerySession — mirrors the 22 Scheme host functions."""
import pytest

from eavt import EavtEngine, QuerySession


@pytest.fixture
def session(tmp_path):
    eng = EavtEngine(str(tmp_path / "db"))
    eng.bootstrap()
    eng.declare_attr("person.name", "string")
    eng.declare_attr("person.age", "long")
    eng.declare_attr("person.city", "string")
    eng.declare_attr("person.email", "string", unique=True)
    eng.declare_attr("person.friend", "ref")
    eng.declare_attr("person.tags", "string", many=True)

    sess = QuerySession(eng)

    e1 = sess.alloc_entity()
    e2 = sess.alloc_entity()
    e3 = sess.alloc_entity()

    sess.save(e1, "person.name", "Alice")
    sess.save(e1, "person.age", 30)
    sess.save(e1, "person.city", "SP")
    sess.save(e1, "person.email", "alice@example.com")

    sess.save(e2, "person.name", "Bob")
    sess.save(e2, "person.age", 25)
    sess.save(e2, "person.city", "SP")
    sess.save(e2, "person.email", "bob@example.com")

    sess.save(e3, "person.name", "Carol")
    sess.save(e3, "person.age", 35)
    sess.save(e3, "person.city", "RJ")
    sess.save(e3, "person.email", "carol@example.com")

    sess.save(e1, "person.friend", e2)

    return sess, e1, e2, e3


# ═══════════════════════════════════════════════════════════════════════════════
# DML: save, retract
# ═══════════════════════════════════════════════════════════════════════════════


def test_save_and_lookup(session):
    sess, e1, e2, e3 = session
    assert sess.lookup_value(e1, "person.name") == "Alice"
    assert sess.lookup_value(e2, "person.name") == "Bob"


def test_retract(session):
    sess, e1, _, _ = session
    sess.retract(e1, "person.name", "Alice")
    assert sess.lookup_value(e1, "person.name") is None


# ═══════════════════════════════════════════════════════════════════════════════
# Entity / Tx allocation
# ═══════════════════════════════════════════════════════════════════════════════


def test_alloc_entity(session):
    sess, _, _, _ = session
    eid = sess.alloc_entity()
    assert eid > 0


def test_tx_entity(session):
    sess, _, _, _ = session
    tx = sess.tx_entity()
    assert tx > 0


# ═══════════════════════════════════════════════════════════════════════════════
# Attribute access: intern_a, attr_name
# ═══════════════════════════════════════════════════════════════════════════════


def test_intern_a(session):
    sess, _, _, _ = session
    aid = sess.intern_a("person.name")
    assert aid is not None
    assert aid > 0


def test_intern_a_unknown(session):
    sess, _, _, _ = session
    assert sess.intern_a("nonexistent.attr") is None


def test_attr_name(session):
    sess, _, _, _ = session
    aid = sess.intern_a("person.name")
    assert sess.attr_name(aid) == "person.name"


# ═══════════════════════════════════════════════════════════════════════════════
# Lookup: lookup_entity, lookup_value
# ═══════════════════════════════════════════════════════════════════════════════


def test_lookup_entity(session):
    sess, _, e2, _ = session
    found = sess.lookup_entity("person.email", "bob@example.com")
    assert found == e2


def test_lookup_entity_not_unique(session):
    sess, _, _, _ = session
    with pytest.raises(ValueError, match="not UNIQUE"):
        sess.lookup_entity("person.name", "Alice")


def test_lookup_value(session):
    sess, e1, _, _ = session
    assert sess.lookup_value(e1, "person.name") == "Alice"
    assert sess.lookup_value(e1, "person.age") == 30


# ═══════════════════════════════════════════════════════════════════════════════
# Schema: declare_attr, declare_partition
# ═══════════════════════════════════════════════════════════════════════════════


def test_declare_attr(session):
    sess, _, _, _ = session
    sess.declare_attr("company.name", "string")
    aid = sess.intern_a("company.name")
    assert aid is not None


def test_declare_partition(session):
    sess, _, _, _ = session
    pid = sess.declare_partition("myapp.data")
    assert pid >= 64
    eid = sess.alloc_entity(pid)
    assert eid > 0


# ═══════════════════════════════════════════════════════════════════════════════
# Param, resolve_val
# ═══════════════════════════════════════════════════════════════════════════════


def test_param():
    eng = EavtEngine("/tmp/test_param_unused")
    eng.bootstrap()
    sess = QuerySession(eng, params=["hello", 42, 3.14])
    assert sess.param(1) == "hello"
    assert sess.param(2) == 42
    assert sess.param(3) == 3.14
    with pytest.raises(IndexError):
        sess.param(0)
    with pytest.raises(IndexError):
        sess.param(4)
    eng.close()


def test_resolve_val(session):
    sess, _, _, _ = session
    assert sess.resolve_val(42) == 42
    assert sess.resolve_val("hello") == "hello"


# ═══════════════════════════════════════════════════════════════════════════════
# Result: result
# ═══════════════════════════════════════════════════════════════════════════════


def test_result(session):
    sess, _, _, _ = session
    r = sess.result(1, "two", 3.0)
    assert r == [1, "two", 3.0]


# ═══════════════════════════════════════════════════════════════════════════════
# Scanner ops: scanner_open, scanner_read, scanner_push, scanner_pop, scanner_prefix
# ═══════════════════════════════════════════════════════════════════════════════


def test_scanner_open(session):
    sess, _, _, _ = session
    h = sess.scanner_open("EAVT")
    assert h >= 0


def test_scanner_read(session):
    sess, _, _, _ = session
    h = sess.scanner_open("EAVT")
    val = sess.scanner_read(h)
    assert val is not None
    assert isinstance(val, int)  # entity ID


def test_scanner_push_pop(session):
    sess, _, _, _ = session
    h = sess.scanner_open("AEVT")
    aid = sess.intern_a("person.name")
    sess.scanner_push(h, aid)
    assert len(sess.scanner_prefix(h)) > 0
    sess.scanner_pop(h)


def test_scanner_prefix(session):
    sess, _, _, _ = session
    h = sess.scanner_open("EAVT")
    # No prefix initially
    prefix = sess.scanner_prefix(h)
    assert isinstance(prefix, bytes)


# ═══════════════════════════════════════════════════════════════════════════════
# Leapfrog: scanner_iterate_init, scanner_iterate_next
# ═══════════════════════════════════════════════════════════════════════════════


def test_scanner_iterate_two_scanners(session):
    """Two AEVT scanners converge on entity IDs that have both attrs."""
    sess, e1, e2, e3 = session

    sc_name = sess.scanner_open("AEVT")
    sess.scanner_push(sc_name, sess.intern_a("person.name"))

    sc_age = sess.scanner_open("AEVT")
    sess.scanner_push(sc_age, sess.intern_a("person.age"))

    it = sess.scanner_iterate_init(sc_name, sc_age)

    entities = set()
    while True:
        eid = sess.scanner_iterate_next(it)
        if eid is None:
            break
        entities.add(eid)

    assert e1 in entities
    assert e2 in entities
    assert e3 in entities


def test_scanner_iterate_with_range(session):
    """Two AEVT scanners with range filter on value."""
    sess, e1, e2, e3 = session

    sc_name = sess.scanner_open("AEVT")
    sess.scanner_push(sc_name, sess.intern_a("person.name"))

    sc_age = sess.scanner_open("AEVT")
    sess.scanner_push(sc_age, sess.intern_a("person.age"))

    from eavt.types import RANGE_OP_GT
    sess.scanner_set_ranges(sc_age, [[(RANGE_OP_GT, 28)]])
    it = sess.scanner_iterate_init(sc_name, sc_age)

    entities = set()
    while True:
        eid = sess.scanner_iterate_next(it)
        if eid is None:
            break
        entities.add(eid)

    assert e1 in entities
    assert e3 in entities


def test_scanner_iterate_exhausted(session):
    """Iterate returns None when exhausted."""
    sess, _, _, _ = session

    sc = sess.scanner_open("AEVT")
    sess.scanner_push(sc, sess.intern_a("person.name"))

    # Single scanner converge → always true
    it = sess.scanner_iterate_init(sc)

    count = 0
    while True:
        val = sess.scanner_iterate_next(it)
        if val is None:
            break
        count += 1
        if count > 100:
            break

    assert count >= 3  # at least Alice, Bob, Carol


# ═══════════════════════════════════════════════════════════════════════════════
# Full query example: SELECT name WHERE age > 28 AND city = 'SP'
# ═══════════════════════════════════════════════════════════════════════════════


def test_full_query(session):
    """Full query: SELECT name WHERE age > 28 AND city = 'SP'.

    Canonical triejoin shape — cursors are reused across levels:
      - sc_age: value-position scan (ranges > 28), then descend (push age)
        and re-iterate-init at [aid][age] to enumerate every entity.
      - sc_city: opened ONCE, reused per entity via pop/push + iterate-init
        (iterate-init re-seeks to the new prefix, so eid order doesn't matter).
    No manual filtering.
    """
    sess, e1, e2, e3 = session

    aid_age = sess.intern_a("person.age")
    aid_city = sess.intern_a("person.city")

    sc_age = sess.scanner_open("AVET")
    sess.scanner_push(sc_age, aid_age)
    sess.scanner_set_ranges(sc_age, sess.ranges_create([">", 28]))

    sc_city = sess.scanner_open("EAVT")

    it_age = sess.scanner_iterate_init(sc_age)
    rows = []
    while (age := sess.scanner_iterate_next(it_age)) is not None:
        sess.scanner_push(sc_age, age)
        it_e = sess.scanner_iterate_init(sc_age)
        while (eid := sess.scanner_iterate_next(it_e)) is not None:
            sess.scanner_pop(sc_city)
            sess.scanner_pop(sc_city)
            sess.scanner_pop(sc_city)
            sess.scanner_push(sc_city, eid)
            sess.scanner_push(sc_city, aid_city)
            sess.scanner_push(sc_city, "SP")
            it_c = sess.scanner_iterate_init(sc_city)
            if sess.scanner_iterate_next(it_c) is not None:
                name = sess.lookup_value(eid, "person.name")
                rows.append((eid, name, age, "SP"))
        sess.scanner_pop(sc_age)

    assert len(rows) == 1
    assert rows[0][1] == "Alice"


def test_city_direct_push(session):
    """Direct-push existence probe: push e + a + v, iterate-init, one next.

    A non-None next means the (eid, attr, value) datom exists (extract at
    position 't' returns the tx id). Pushes must happen BEFORE iterate-init
    (both engines advance eagerly at init, hostfns.nim:376).
    """
    sess, e1, _, e3 = session

    def city_exists(eid):
        sc = sess.scanner_open("EAVT")
        sess.scanner_push(sc, eid)
        sess.scanner_push(sc, sess.intern_a("person.city"))
        sess.scanner_push(sc, "SP")
        it = sess.scanner_iterate_init(sc)
        return sess.scanner_iterate_next(it) is not None

    assert city_exists(e1) is True
    assert city_exists(e3) is False


def test_second_iterate_repositions(session):
    """A consumed scanner is reusable: iterate-init re-seeks to the prefix.

    Deliberately diverges from the Nim test "second iterate call empty"
    (test_query.nim:1965), which asserts the second iterate emits nothing.
    Cursor reuse across loops is basic triejoin; the same prefix re-emits.
    """
    sess, e1, _, _ = session

    s = sess.scanner_open("EAVT")
    sess.scanner_push(s, e1)
    sess.scanner_push(s, sess.intern_a("person.name"))

    first = sess.scanner_iterate_init(s)
    got1 = []
    while (v := sess.scanner_iterate_next(first)) is not None:
        got1.append(v)

    second = sess.scanner_iterate_init(s)
    got2 = []
    while (v := sess.scanner_iterate_next(second)) is not None:
        got2.append(v)

    assert got1 == ["Alice"]
    assert got2 == ["Alice"]


def test_nested_entity_scan_duplicate_age(session):
    """Descending via push + iterate-init enumerates ALL entities per value.

    Two entities share age 30; the nested re-seek at [aid][age] yields both.
    """
    sess, e1, e2, _ = session

    sess.save(e2, "person.age", 30)

    sc_age = sess.scanner_open("AVET")
    sess.scanner_push(sc_age, sess.intern_a("person.age"))
    sess.scanner_set_ranges(sc_age, sess.ranges_create(["=", 30]))
    it_age = sess.scanner_iterate_init(sc_age)

    eids = []
    while (age := sess.scanner_iterate_next(it_age)) is not None:
        sess.scanner_push(sc_age, age)
        it_e = sess.scanner_iterate_init(sc_age)
        while (eid := sess.scanner_iterate_next(it_e)) is not None:
            eids.append(eid)
        sess.scanner_pop(sc_age)

    assert set(eids) == {e1, e2}


def test_nested_scan_last_index_value_no_infinite_loop(tmp_path):
    """Outer value loop must not re-emit when the inner descent ran past the
    end of the whole AVET index (the matching value is the last key).

    Regression: scanner_pop used to reset the cursor's fell_past_end flag, so
    the outer advance re-seeked to the prefix and re-announced the same value
    forever. Falling past the physical end is level-independent — no shallower
    re-seek can find data beyond it.
    """
    eng = EavtEngine(str(tmp_path / "db"))
    eng.bootstrap()
    eng.declare_attr("person.age", "long")  # last aid → its keys sort last in AVET
    sess = QuerySession(eng)
    for _ in range(2):
        e = sess.alloc_entity()
        sess.save(e, "person.age", 30)

    sc_age = sess.scanner_open("AVET")
    sess.scanner_push(sc_age, sess.intern_a("person.age"))
    sess.scanner_set_ranges(sc_age, sess.ranges_create([">", 28]))

    it_age = sess.scanner_iterate_init(sc_age)
    values = []
    count = 0
    while (age := sess.scanner_iterate_next(it_age)) is not None:
        count += 1
        assert count <= 10  # would blow past this before the fix
        sess.scanner_push(sc_age, age)
        it_e = sess.scanner_iterate_init(sc_age)
        eids = []
        while (eid := sess.scanner_iterate_next(it_e)) is not None:
            eids.append(eid)
        sess.scanner_pop(sc_age)
        values.append((age, eids))

    assert count == 1
    assert values[0][0] == 30
    assert len(values[0][1]) == 2


# ═══════════════════════════════════════════════════════════════════════════════
# Debug: dbg_scanners, ranges_show
# ═══════════════════════════════════════════════════════════════════════════════


def test_dbg_scanners(session, capsys):
    sess, _, _, _ = session
    sess.scanner_open("EAVT")
    sess.dbg_scanners()
    captured = capsys.readouterr()
    assert "scanner[0]" in captured.err


def test_ranges_show(session):
    sess, _, _, _ = session
    from eavt.types import RANGE_OP_GT, RANGE_OP_LTE
    # parse_ranges expects flat list: [op, val] items in one branch
    ranges = [[RANGE_OP_GT, 10], [RANGE_OP_LTE, 50]]
    desc = sess.ranges_show(ranges)
    assert "10" in desc
    assert "50" in desc
