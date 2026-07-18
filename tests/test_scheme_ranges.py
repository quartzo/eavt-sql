"""Tests for `ranges-create` and `ranges-show` Scheme helpers.

`ranges-create` is a special form that turns a range tree like
    (and (> 10) (< 20))
into the flat serialized SExpr used internally by `scheme-leap-init` /
`scheme-leap-next` (the triejoin range filter).

`ranges-show` is a host function that takes the flat SExpr produced by
`ranges-create` and renders it as a human-readable interval string using
the standard mathematical bracket convention:

    (  = open (exclusive) lower bound
    [  = closed (inclusive) lower bound
    )  = open (exclusive) upper bound
    ]  = closed (inclusive) upper bound

Multiple disjoint branches are separated by ", ".
Infinite bounds are always rendered with parens.
"""
from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


def _show(engine, scheme_text):
    """Run a `(result (ranges-show ...))` program and return the string."""
    rows = engine.run_scheme(scheme_text)
    assert len(rows) == 1, f"expected 1 row, got {rows}"
    assert len(rows[0]) == 1, f"expected 1 col, got {rows[0]}"
    return rows[0][0]


# ── Basic open/closed combinations ───────────────────────────────────────────


def test_gt_lt_open_both(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (> 10) (< 20)))))')
    assert s == "(10, 20)"


def test_gte_lte_closed_both(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (>= 10) (<= 20)))))')
    assert s == "[10, 20]"


def test_gt_lte_mixed(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (> 10) (<= 20)))))')
    assert s == "(10, 20]"


def test_gte_lt_mixed(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (>= 10) (< 20)))))')
    assert s == "[10, 20)"


# ── Single conditions ────────────────────────────────────────────────────────


def test_eq_single(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (= 5))))')
    assert s == "[5, 5]"


def test_gt_only(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (> 10))))')
    assert s == "(10, +inf)"


def test_gte_only(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (>= 10))))')
    assert s == "[10, +inf)"


def test_lt_only(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (< 10))))')
    assert s == "(-inf, 10)"


def test_lte_only(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (<= 10))))')
    assert s == "(-inf, 10]"


# ── NEQ and OR ───────────────────────────────────────────────────────────────


def test_neq_splits_interval(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (!= 5))))')
    assert s == "(-inf, 5), (5, +inf)"


def test_neq_inside_range_splits(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (> 10) (< 20) (!= 15)))))')
    assert s == "(10, 15), (15, 20)"


def test_or_disjoint(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (or (= 1) (= 2)))))')
    assert s == "[1, 1], [2, 2]"


def test_or_with_ranges(engine):
    s = _show(engine,
              '(result (ranges-show (ranges-create (or (and (>= 1) (<= 5)) (and (>= 10) (<= 20))))))')
    assert s == "[1, 5], [10, 20]"


# ── Empty / unbounded ────────────────────────────────────────────────────────


def test_empty_constraints(engine):
    """No constraints → full range, infinite bounds always open."""
    s = _show(engine, '(result (ranges-show (ranges-create (and))))')
    assert s == "(-inf, +inf)"


# ── Binding via let* ─────────────────────────────────────────────────────────


def test_bind_with_let_star(engine):
    """User can store the flat ranges in a variable for later inspection."""
    s = _show(engine,
              '(let* ((r0 (ranges-create (and (> 10) (< 20))))) '
              '  (result (ranges-show r0)))')
    assert s == "(10, 20)"


def test_bind_reuse(engine):
    """The bound value is reusable."""
    prog = (
        '(let* ((r0 (ranges-create (or (= 1) (= 2))))) '
        '  (result (ranges-show r0)))'
    )
    s = _show(engine, prog)
    assert s == "[1, 1], [2, 2]"


# ── Param support (DML path) ─────────────────────────────────────────────────


def test_with_params(engine):
    rows = engine.run_scheme(
        '(result (ranges-show (ranges-create (and (> (param 1)) (< (param 2))))))',
        10, 20,
    )
    assert rows == [("(10, 20)",)]


# ── Yield path (SelectSchemeSession) ─────────────────────────────────────────


def test_yield_path_basic(engine):
    """ranges-create / ranges-show must also work via the yield path
    (SelectSchemeSession), since both run_scheme and run_scheme_select
    share the same SchemeHostFns."""
    rows = engine.run_scheme_select(
        '(result-row (ranges-show (ranges-create (and (> 10) (< 20)))))'
    )
    assert rows == [("(10, 20)",)]


def test_yield_path_bind(engine):
    rows = engine.run_scheme_select(
        '(let* ((r0 (ranges-create (and (>= 1) (<= 5))))) '
        '  (result-row (ranges-show r0)))'
    )
    assert rows == [("[1, 5]",)]


# ── Float values ─────────────────────────────────────────────────────────────


def test_float_bounds(engine):
    s = _show(engine, '(result (ranges-show (ranges-create (and (> 1.5) (< 2.5)))))')
    assert s == "(1.5, 2.5)"


# ── Arity errors ─────────────────────────────────────────────────────────────


def test_ranges_create_arity_error(engine):
    with pytest.raises(ValueError, match="ranges-create"):
        engine.run_scheme('(ranges-create)')


def test_ranges_show_arity_error(engine):
    with pytest.raises(ValueError):
        engine.run_scheme('(result (ranges-show))')
