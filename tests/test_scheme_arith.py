"""Arithmetic, comparison, logical, and utility operation tests for Scheme IR."""

from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── Arithmetic ──────────────────────────────────────────────────────────────


def test_add_int(engine):
    assert engine.run_scheme("(result (+ 1 2))") == [(3,)]


def test_add_many(engine):
    assert engine.run_scheme("(result (+ 1 2 3 4))") == [(10,)]


def test_add_float_promotion(engine):
    assert engine.run_scheme("(result (+ 1 0.5))") == [(1.5,)]


def test_add_all_float(engine):
    assert engine.run_scheme("(result (+ 0.5 1.5))") == [(2.0,)]


def test_sub_two(engine):
    assert engine.run_scheme("(result (- 5 3))") == [(2,)]


def test_sub_negate(engine):
    assert engine.run_scheme("(result (- 7))") == [(-7,)]


def test_sub_float(engine):
    assert engine.run_scheme("(result (- 3.5 1.0))") == [(2.5,)]


def test_mul_int(engine):
    assert engine.run_scheme("(result (* 2 3))") == [(6,)]


def test_mul_float_promotion(engine):
    assert engine.run_scheme("(result (* 2 3.0))") == [(6.0,)]


def test_div_int(engine):
    assert engine.run_scheme("(result (/ 6 2))") == [(3,)]


def test_div_float_result(engine):
    assert engine.run_scheme("(result (/ 5 2))") == [(2.5,)]


def test_div_by_zero_errors(engine):
    with pytest.raises(ValueError, match="division by zero"):
        engine.run_scheme("(/ 1 0)")


def test_mod_int(engine):
    assert engine.run_scheme("(result (mod 7 3))") == [(1,)]


def test_mod_negative(engine):
    assert engine.run_scheme("(result (mod -7 3))") == [(-1,)]


def test_mod_by_zero_errors(engine):
    with pytest.raises(ValueError, match="mod: division by zero"):
        engine.run_scheme("(mod 7 0)")


# ── Comparison ───────────────────────────────────────────────────────────────


def test_lt_chain_true(engine):
    assert engine.run_scheme("(result (< 1 2 3))") == [(True,)]


def test_lt_chain_false(engine):
    assert engine.run_scheme("(result (< 1 3 2))") == [(False,)]


def test_gt_chain_true(engine):
    assert engine.run_scheme("(result (> 3 2 1))") == [(True,)]


def test_gt_chain_false(engine):
    assert engine.run_scheme("(result (> 1 2 3))") == [(False,)]


def test_le_chain(engine):
    assert engine.run_scheme("(result (<= 1 1 2 3))") == [(True,)]


def test_ge_chain(engine):
    assert engine.run_scheme("(result (>= 3 2 2 1))") == [(True,)]


def test_eq_same_type(engine):
    assert engine.run_scheme("(result (= 1 1))") == [(True,)]


def test_eq_different(engine):
    assert engine.run_scheme("(result (= 1 2))") == [(False,)]


def test_eq_int_float_semantic(engine):
    """Numeric equality: Int(1) equals Float(1.0)."""
    assert engine.run_scheme("(result (= 1 1.0))") == [(True,)]


def test_eq_chain(engine):
    assert engine.run_scheme("(result (= 3 3 3))") == [(True,)]
    assert engine.run_scheme("(result (= 3 3 4))") == [(False,)]


def test_neq(engine):
    assert engine.run_scheme("(result (!= 1 2))") == [(True,)]
    assert engine.run_scheme("(result (!= 1 1))") == [(False,)]
    assert engine.run_scheme("(result (!= 1 1.0))") == [(False,)]


def test_cmp_float_promotion(engine):
    assert engine.run_scheme("(result (< 0.5 1 2.0))") == [(True,)]


# ── Min / Max / Abs ──────────────────────────────────────────────────────────


def test_min_int(engine):
    assert engine.run_scheme("(result (min 3 1 4 2))") == [(1,)]


def test_max_int(engine):
    assert engine.run_scheme("(result (max 3 1 4 2))") == [(4,)]


def test_min_float_promotion(engine):
    assert engine.run_scheme("(result (min 1 0.5 2))") == [(0.5,)]


def test_max_single_arg(engine):
    assert engine.run_scheme("(result (max 5))") == [(5,)]


def test_abs_int(engine):
    assert engine.run_scheme("(result (abs -5))") == [(5,)]


def test_abs_float(engine):
    assert engine.run_scheme("(result (abs -3.14))") == [(3.14,)]


def test_abs_positive(engine):
    assert engine.run_scheme("(result (abs 7))") == [(7,)]


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
