"""Logical and utility operation tests for Scheme IR.
Arithmetic and comparison operations are now tested in Nim (query/tests.nim)."""

from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── and / or / not (special forms, short-circuit) ────────────────────────────


def test_and_all_truthy(engine):
    assert engine.run_scheme("(result (and #t #t #t))") == [(True,)]


def test_and_returns_last_truthy(engine):
    assert engine.run_scheme("(result (and 1 2 3))") == [(3,)]


def test_and_short_circuit(engine):
    assert engine.run_scheme("(result (and #f 1))") == [(False,)]


def test_and_empty_returns_true(engine):
    assert engine.run_scheme("(result (and))") == [(True,)]


def test_or_first_truthy(engine):
    assert engine.run_scheme("(result (or #f #f 5))") == [(5,)]


def test_or_all_falsy(engine):
    assert engine.run_scheme("(result (or #f #f))") == [(False,)]


def test_or_short_circuit(engine):
    assert engine.run_scheme("(result (or #t 1))") == [(True,)]


def test_or_empty_returns_false(engine):
    assert engine.run_scheme("(result (or))") == [(False,)]


def test_not_true(engine):
    assert engine.run_scheme("(result (not #t))") == [(False,)]


def test_not_false(engine):
    assert engine.run_scheme("(result (not #f))") == [(True,)]


def test_not_truthy(engine):
    """not treats non-bool truthy values same as in is_truthy."""
    assert engine.run_scheme("(result (not 1))") == [(False,)]
    assert engine.run_scheme("(result (not 0))") == [(False,)]


# ── and/or short-circuit with side effects ───────────────────────────────────


def test_and_short_circuit_no_side_effect(engine):
    """and short-circuits — second arg not evaluated."""
    rows = engine.run_scheme("(result (and #f (begin (print \"skipped\") #t)))")
    assert rows == [(False,)]


def test_or_short_circuit_no_side_effect(engine):
    """or short-circuits — second arg not evaluated."""
    rows = engine.run_scheme("(result (or #t (begin (print \"skipped\") #f)))")
    assert rows == [(True,)]


# ── Combinado: arith + logic ─────────────────────────────────────────────────


def test_and_with_arith(engine):
    assert engine.run_scheme("(result (and (< 1 2) (> 3 1)))") == [(True,)]


def test_if_with_cmp(engine):
    assert engine.run_scheme('(if (= (+ 1 1) 2) (result "yes") (result "no"))') == [("yes",)]


def test_when_with_cmp(engine):
    assert engine.run_scheme('(when (> 5 3) (result "bigger"))') == [("bigger",)]


# ── Select path (yield-mode) ─────────────────────────────────────────────────


def test_arith_in_select_path(engine):
    """and/or short-circuit should work in yield-mode too."""
    rows = engine.run_scheme_select("(begin (print (+ 1 2)) (result-row 3))")
    assert rows == [(3,)]


def test_and_in_select_path(engine):
    """and short-circuits in yield-mode."""
    rows = engine.run_scheme_select("(begin (print (and #t 42)) (result-row 1))")
    assert rows == [(1,)]


def test_or_in_select_path(engine):
    """or short-circuits in yield-mode."""
    rows = engine.run_scheme_select("(begin (print (or #f 7)) (result-row 2))")
    assert rows == [(2,)]


def test_not_in_select_path(engine):
    """not works in yield-mode."""
    rows = engine.run_scheme_select("(begin (print (not #t)) (result-row 3))")
    assert rows == [(3,)]
