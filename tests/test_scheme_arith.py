"""Select-path (yield-mode) tests for Scheme IR.
Arithmetic, comparison, and logical operations are now tested in Nim (query/tests.nim)."""

from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── Select path (yield-mode) ─────────────────────────────────────────────────


def test_arith_in_select_path(engine):
    """Arithmetic should work in yield-mode too."""
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
