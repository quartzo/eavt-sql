"""Direct Scheme IR execution tests.

Schema/save/retract/lookup/param tests are now covered in Nim (query/tests.nim).
Kept: Scheme evaluator constructs (let*, when, if, begin, result),
partition tests, alloc-entity/tx-entity, combined scenarios, and error paths."""

from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine

U64_MAX = 0xFFFFFFFFFFFFFFFF


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── result / Void / begin (Scheme evaluator) ──────────────────────────────────


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
