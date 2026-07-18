"""Direct Scheme IR execution tests (DML host functions).

These tests exercise the Scheme evaluator against the real engine using
`Program::Scheme` (SchemeSession + SchemeHostFns), without going through
SQL parsing or the triejoin scanner. They cover the host functions:

    declare-attr, declare-partition, alloc-entity, tx-entity,
    save, retract, lookup-entity, lookup-value, param, result

`scanner-iterate` / scanner host functions are intentionally
NOT covered here — those belong to the triejoin path.
"""
from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine

U64_MAX = 0xFFFFFFFFFFFFFFFF


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── result / Void ────────────────────────────────────────────────────────────


def test_scheme_result_literal(engine):
    """(result ...) returns its args as a single row."""
    rows = engine.run_scheme('(result "company.name" "STRING")')
    assert rows == [("company.name", "STRING")]


def test_scheme_result_int_and_bool(engine):
    rows = engine.run_scheme("(result 42 #t)")
    assert rows == [(42, True)]


def test_scheme_void_returns_no_rows(engine):
    """A program returning Void produces a zero-column row, which is skipped."""
    rows = engine.run_scheme("(declare-attr \"ns.x\" \"STRING\" #f #f)")
    assert rows == []


def test_scheme_begin_returns_last_form(engine):
    """begin evaluates each form for side effects and returns the last."""
    prog = '(begin (declare-attr "ns.a" "STRING" #f #f) (result "ok" 1))'
    rows = engine.run_scheme(prog)
    assert rows == [("ok", 1)]


# ── declare-attr ─────────────────────────────────────────────────────────────


def test_scheme_declare_attr_single(engine):
    """declare-attr registers the attribute and returns Void."""
    engine.run_scheme('(declare-attr "company.name" "STRING" #f #f)')
    aid = engine._handle.lookup_attr("company.name")
    assert aid is not None
    assert engine._handle.is_unique_attr("company.name") is False
    assert engine._handle.is_many(aid) is False


def test_scheme_declare_attr_unique(engine):
    engine.run_scheme('(declare-attr "user.email" "STRING" #f #t)')
    assert engine._handle.is_unique_attr("user.email") is True


def test_scheme_declare_attr_many(engine):
    engine.run_scheme('(declare-attr "tag.x" "STRING" #t #f)')
    aid = engine._handle.lookup_attr("tag.x")
    assert engine._handle.is_many(aid) is True


def test_scheme_declare_attr_value_types(engine):
    # value_type_for returns the Debug name of the ValueType enum.
    cases = [
        ("STRING", "String"),
        ("LONG", "Long"),
        ("FLOAT", "Float"),
        ("BOOLEAN", "Boolean"),
        ("BYTES", "Bytes"),
        ("REF", "Ref"),
        ("INSTANT", "Instant"),
    ]
    for vt_in, vt_out in cases:
        engine.run_scheme(f'(declare-attr "ns.{vt_in.lower()}" "{vt_in}" #f #f)')
        aid = engine._handle.lookup_attr(f"ns.{vt_in.lower()}")
        assert aid is not None
        assert engine._handle.value_type_for(aid) == vt_out


def test_scheme_declare_attr_is_idempotent(engine):
    """Re-declaring the same attribute with the same flags is a no-op."""
    engine.run_scheme('(declare-attr "ns.x" "STRING" #f #f)')
    aid1 = engine._handle.lookup_attr("ns.x")
    engine.run_scheme('(declare-attr "ns.x" "STRING" #f #f)')
    aid2 = engine._handle.lookup_attr("ns.x")
    assert aid1 == aid2


# ── declare-partition ────────────────────────────────────────────────────────


def test_scheme_declare_partition_returns_id(engine):
    rows = engine.run_scheme('(result (declare-partition "my-part"))')
    assert len(rows) == 1
    pid = rows[0][0]
    assert isinstance(pid, int)
    assert engine._handle.partition_id_for("my-part") == pid


def test_scheme_declare_partition_idempotent(engine):
    engine.run_scheme('(declare-partition "p1")')
    rows = engine.run_scheme('(result (declare-partition "p1"))')
    pid1 = rows[0][0]
    rows = engine.run_scheme('(result (declare-partition "p1"))')
    pid2 = rows[0][0]
    assert pid1 == pid2


# ── alloc-entity / tx-entity ─────────────────────────────────────────────────


def test_scheme_alloc_entity_returns_eid(engine):
    rows = engine.run_scheme("(result (alloc-entity))")
    assert len(rows) == 1
    eid = rows[0][0]
    assert isinstance(eid, int)
    assert eid > 0


def test_scheme_alloc_entity_in_partition(engine):
    """alloc-entity accepts an optional partition argument."""
    engine.run_scheme('(declare-partition "custom")')
    pid = engine.run_scheme('(result (declare-partition "custom"))')[0][0]
    rows = engine.run_scheme(f"(result (alloc-entity {pid}))")
    eid = rows[0][0]
    assert eid > 0


def test_scheme_alloc_entity_distinct(engine):
    rows = engine.run_scheme(
        "(result (alloc-entity) (alloc-entity) (alloc-entity))"
    )
    assert len(rows) == 1
    a, b, c = rows[0]
    assert a != b != c != a


def test_scheme_tx_entity(engine):
    """tx-entity returns the current transaction id."""
    rows = engine.run_scheme("(result (tx-entity))")
    assert len(rows) == 1
    tx = rows[0][0]
    assert isinstance(tx, int)
    assert tx > 0


# ── save + lookup-value ──────────────────────────────────────────────────────


def test_scheme_save_and_lookup_value(engine):
    prog = """
    (begin
      (declare-attr "user.name" "STRING" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "user.name" "Alice")
        (result eid (lookup-value eid "user.name"))))
    """
    rows = engine.run_scheme(prog)
    assert len(rows) == 1
    eid, name = rows[0]
    assert name == "Alice"
    assert eid > 0


def test_scheme_lookup_value_missing_returns_void(engine):
    """lookup-value on an entity without that attr returns Void (encoded as 0)."""
    prog = """
    (begin
      (declare-attr "user.name" "STRING" #f #f)
      (let* ((eid (alloc-entity)))
        (result (lookup-value eid "user.name"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(0,)]  # Void → Value::Timestamp(0) → 0


def test_scheme_save_long_value(engine):
    prog = """
    (begin
      (declare-attr "counter.n" "LONG" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "counter.n" 12345)
        (result (lookup-value eid "counter.n"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(12345,)]


def test_scheme_save_bool_value(engine):
    prog = """
    (begin
      (declare-attr "flag.on" "BOOLEAN" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "flag.on" #t)
        (result (lookup-value eid "flag.on"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(True,)]


def test_scheme_save_float_value(engine):
    prog = """
    (begin
      (declare-attr "sensor.temp" "FLOAT" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "sensor.temp" 3.14)
        (result (lookup-value eid "sensor.temp"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(pytest.approx(3.14),)]


def test_scheme_save_many_values(engine):
    """A :many attribute can hold multiple values."""
    prog = """
    (begin
      (declare-attr "tag.x" "STRING" #t #f)
      (let* ((eid (alloc-entity)))
        (save eid "tag.x" "a")
        (save eid "tag.x" "b")
        (save eid "tag.x" "c")
        (result eid)))
    """
    rows = engine.run_scheme(prog)
    eid = rows[0][0]
    # Verify via SQL that all three values are present.
    vals = {r[0] for r in engine.sql("SELECT d1.tag.x WHERE d1.eid = %1", eid)}
    assert vals == {"a", "b", "c"}


def test_scheme_save_overwrites_single(engine):
    """A :one attribute is overwritten by a new save."""
    prog = """
    (begin
      (declare-attr "user.name" "STRING" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "user.name" "Alice")
        (save eid "user.name" "Bob")
        (result (lookup-value eid "user.name"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [("Bob",)]


# ── retract ──────────────────────────────────────────────────────────────────


def test_scheme_retract_value(engine):
    prog = """
    (begin
      (declare-attr "tag.x" "STRING" #t #f)
      (let* ((eid (alloc-entity)))
        (save eid "tag.x" "v1")
        (retract eid "tag.x" "v1")
        (result (lookup-value eid "tag.x"))))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(0,)]  # Void after retract


def test_scheme_retract_one_of_many(engine):
    prog = """
    (begin
      (declare-attr "tag.x" "STRING" #t #f)
      (let* ((eid (alloc-entity)))
        (save eid "tag.x" "a")
        (save eid "tag.x" "b")
        (retract eid "tag.x" "a")
        (result eid)))
    """
    rows = engine.run_scheme(prog)
    eid = rows[0][0]
    vals = {r[0] for r in engine.sql("SELECT d1.tag.x WHERE d1.eid = %1", eid)}
    assert vals == {"b"}


# ── lookup-entity (requires UNIQUE) ──────────────────────────────────────────


def test_scheme_lookup_entity_finds_eid(engine):
    prog = """
    (begin
      (declare-attr "user.email" "STRING" #f #t)
      (let* ((eid (alloc-entity)))
        (save eid "user.email" "a@x.com")
        (result eid (lookup-entity "user.email" "a@x.com"))))
    """
    rows = engine.run_scheme(prog)
    eid, found = rows[0]
    assert found == eid


def test_scheme_lookup_entity_missing_returns_void(engine):
    prog = """
    (begin
      (declare-attr "user.email" "STRING" #f #t)
      (result (lookup-entity "user.email" "missing@x.com")))
    """
    rows = engine.run_scheme(prog)
    assert rows == [(0,)]  # Void


def test_scheme_lookup_entity_non_unique_errors(engine):
    """lookup-entity on a non-unique attribute raises an error."""
    engine.run_scheme('(declare-attr "tag.x" "STRING" #f #f)')
    with pytest.raises(ValueError, match="UNIQUE"):
        engine.run_scheme('(lookup-entity "tag.x" "anything")')


# ── param ────────────────────────────────────────────────────────────────────


def test_scheme_param_single(engine):
    rows = engine.run_scheme("(result (param 1))", "hello")
    assert rows == [("hello",)]


def test_scheme_param_multiple(engine):
    rows = engine.run_scheme("(result (param 1) (param 2) (param 3))", "a", 42, True)
    assert rows == [("a", 42, True)]


def test_scheme_param_used_in_save(engine):
    prog = """
    (begin
      (declare-attr "user.name" "STRING" #f #f)
      (let* ((eid (alloc-entity)))
        (save eid "user.name" (param 1))
        (result eid (lookup-value eid "user.name"))))
    """
    rows = engine.run_scheme(prog, "Carol")
    eid, name = rows[0]
    assert name == "Carol"


def test_scheme_param_out_of_range_errors(engine):
    with pytest.raises(ValueError, match="out of range"):
        engine.run_scheme("(result (param 1))")


def test_scheme_param_zero_is_out_of_range(engine):
    """param indices are 1-based; 0 is always out of range."""
    with pytest.raises(ValueError, match="out of range"):
        engine.run_scheme("(result (param 0))", "unused")


# ── pure Scheme constructs (no host fns) ─────────────────────────────────────


def test_scheme_let_star_binding(engine):
    rows = engine.run_scheme("(let* ((x 42)) (result x))")
    assert rows == [(42,)]


def test_scheme_nested_let(engine):
    """begin returns its last form; intermediate results are discarded."""
    rows = engine.run_scheme(
        "(let* ((x 10)) (let* ((y 20)) (begin (result x) (result y))))"
    )
    assert rows == [(20,)]


def test_scheme_when_true_returns_value(engine):
    rows = engine.run_scheme("(when #t (result 1))")
    assert rows == [(1,)]


def test_scheme_when_false_returns_void(engine):
    rows = engine.run_scheme("(when #f (result 1))")
    assert rows == []


def test_scheme_if_else(engine):
    rows = engine.run_scheme('(if #t (result "yes") (result "no"))')
    assert rows == [("yes",)]
    rows = engine.run_scheme('(if #f (result "yes") (result "no"))')
    assert rows == [("no",)]


def test_scheme_lambda_application(engine):
    rows = engine.run_scheme(
        "((lambda (n) (result n)) 42)"
    )
    assert rows == [(42,)]


def test_scheme_lambda_captures_env(engine):
    rows = engine.run_scheme(
        "(let* ((x 7)) ((lambda () (result x))))"
    )
    assert rows == [(7,)]


def test_scheme_begin_multiple_results(engine):
    """begin returns only the last form's value (no yield in DML sessions)."""
    rows = engine.run_scheme("(begin (result 1) (result 2) (result 3))")
    assert rows == [(3,)]


# ── combined scenarios ───────────────────────────────────────────────────────


def test_scheme_alloc_save_lookup_roundtrip(engine):
    """Full round-trip: alloc → save → lookup-value → result."""
    prog = """
    (begin
      (declare-attr "company.name" "STRING" #f #t)
      (declare-attr "company.hq" "STRING" #f #f)
      (let* ((c1 (alloc-entity))
             (c2 (alloc-entity)))
        (save c1 "company.name" "ACME")
        (save c1 "company.hq" "NYC")
        (save c2 "company.name" "Globex")
        (save c2 "company.hq" "SF")
        (result c1
               (lookup-value c1 "company.name")
               (lookup-value c1 "company.hq")
               c2
               (lookup-value c2 "company.name")
               (lookup-value c2 "company.hq")
               (lookup-entity "company.name" "Globex"))))
    """
    rows = engine.run_scheme(prog)
    assert len(rows) == 1
    c1, name1, hq1, c2, name2, hq2, globex_eid = rows[0]
    assert name1 == "ACME"
    assert hq1 == "NYC"
    assert name2 == "Globex"
    assert hq2 == "SF"
    assert globex_eid == c2


def test_scheme_multiple_statements_persist(engine):
    """State from one run_scheme call persists to the next."""
    engine.run_scheme('(declare-attr "user.name" "STRING" #f #f)')
    eid = engine.run_scheme(
        '(begin (let* ((e (alloc-entity))) (save e "user.name" "Zed") (result e)))'
    )[0][0]
    rows = engine.run_scheme(f'(result (lookup-value {eid} "user.name"))')
    assert rows == [("Zed",)]


def test_scheme_save_to_undeclared_attr_errors(engine):
    with pytest.raises(ValueError):
        engine.run_scheme(
            '(let* ((e (alloc-entity))) (save e "no.such.attr" "x"))'
        )


def test_scheme_parse_error_propagates(engine):
    with pytest.raises(ValueError, match="parse error"):
        engine.run_scheme("(result 'unterminated")


def test_scheme_unknown_host_fn_errors(engine):
    with pytest.raises(ValueError, match="unbound"):
        engine.run_scheme("(no-such-fn 1 2)")


def test_scheme_result_no_args_returns_void(engine):
    """(result) with no args produces a list too short to be a result row."""
    rows = engine.run_scheme("(result)")
    assert rows == []
