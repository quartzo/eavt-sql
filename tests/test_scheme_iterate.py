"""Scheme scanner-iterate tests.

Tests the `scanner-iterate` special form — single-scanner iteration
without lambda/closure. Binds the param directly in the current
Environment and reuses the `DepthRunBody` frame handler for the loop.

Syntax:
    (scanner-iterate scanner-expr (param) body...)

All tests use `run_scheme_select` (yield path / SelectSchemeSession)
because `scanner-iterate` requires yield-mode evaluation.
"""
from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


def _setup_tag_data(e: EAVTEngine) -> tuple[int, int]:
    """Declare tag.x as STRING MANY, create entity with values a/b/c."""
    e.run_scheme('(declare-attr "tag.x" "STRING" #t #f)')
    eid = e.run_scheme(
        '(let* ((eid (alloc-entity))) '
        '(save eid "tag.x" "a") '
        '(save eid "tag.x" "b") '
        '(save eid "tag.x" "c") '
        '(result eid))'
    )[0][0]
    aid = e._handle.lookup_attr("tag.x")
    return eid, aid


# ── Basic iteration ──────────────────────────────────────────────────────────


def test_iterate_emits_all_values(engine):
    """scanner-iterate over EAVT with eid+aid prefix emits all 'v' values."""
    eid, aid = _setup_tag_data(engine)
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    vals = [r[0] for r in rows]
    assert vals == ["a", "b", "c"]


def test_iterate_no_prefix_emits_all_datoms(engine):
    """scanner-iterate with no prefix push iterates over ALL EAVT keys
    (bootstrap entities, schema, etc.). This is correct — no prefix means
    no constraint."""
    rows = engine.run_scheme_select(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-iterate s (v) (result-row v)))'
    )
    # Should emit many rows (bootstrap datoms)
    assert len(rows) > 0


def test_iterate_single_value(engine):
    """Iterate over a single value."""
    engine.run_scheme('(declare-attr "user.name" "STRING" #f #f)')
    eid = engine.run_scheme(
        '(let* ((eid (alloc-entity))) '
        '(save eid "user.name" "Alice") '
        '(result eid))'
    )[0][0]
    aid = engine._handle.lookup_attr("user.name")
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    assert rows == [("Alice",)]


# ── Multiple columns in result-row ───────────────────────────────────────────


def test_iterate_with_attr_name(engine):
    """result-row can emit multiple columns: value + attr name."""
    eid, aid = _setup_tag_data(engine)
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v (attr-name {aid}))))'
    )
    assert all(r[1] == "tag.x" for r in rows)
    assert [r[0] for r in rows] == ["a", "b", "c"]


# ── AEVT index ───────────────────────────────────────────────────────────────


def test_iterate_aevt_finds_all_eids(engine):
    """Iterate over AEVT with aid prefix → all eids that have this attr."""
    eid, aid = _setup_tag_data(engine)
    # AEVT idx_order = [a, e, v, ...]
    # Push a=aid only → iterate over e position
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "AEVT"))) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (e) (result-row e)))'
    )
    eids = [r[0] for r in rows]
    assert eid in eids


# ── Param binding ────────────────────────────────────────────────────────────


def test_iterate_param_accessible_in_body(engine):
    """The param is bound in the current env and accessible in body."""
    eid, aid = _setup_tag_data(engine)
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v v)))'
    )
    assert all(r[0] == r[1] for r in rows)
    assert [r[0] for r in rows] == ["a", "b", "c"]


# ── scanner-iterate in non-yield path errors ─────────────────────────────────


def test_iterate_errors_in_dml_path(engine):
    """scanner-iterate requires yield-mode (SelectSchemeSession)."""
    with pytest.raises(ValueError, match="yield-mode"):
        engine.run_scheme(
            '(let* ((s (scanner-open "EAVT"))) '
            '(scanner-iterate s (v) (result v)))'
        )


# ── Arity / type errors ─────────────────────────────────────────────────────


def test_iterate_arity_error(engine):
    """Missing body → arity error."""
    with pytest.raises(ValueError, match="arity"):
        engine.run_scheme_select(
            '(let* ((s (scanner-open "EAVT"))) '
            '(scanner-iterate s (v)))'
        )


def test_iterate_param_not_list(engine):
    """Param must be a list of symbols."""
    with pytest.raises(ValueError):
        engine.run_scheme_select(
            '(let* ((s (scanner-open "EAVT"))) '
            '(scanner-iterate s v (result-row v)))'
        )


# ── Body with side effects ──────────────────────────────────────────────────


def test_iterate_body_can_save(engine):
    """Body can call save for each iterated value (side effect)."""
    eid, aid = _setup_tag_data(engine)
    # Create a new attr and save each tag.x value into it
    engine.run_scheme('(declare-attr "tag.copy" "STRING" #t #f)')
    copy_aid = engine._handle.lookup_attr("tag.copy")
    new_eid = engine.run_scheme("(result (alloc-entity))")[0][0]

    engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (save {new_eid} "tag.copy" v)))'
    )

    # Verify the copies were saved
    copies = list(engine.sql("SELECT d1.tag.copy WHERE d1.eid = %1", new_eid))
    assert {r[0] for r in copies} == {"a", "b", "c"}


# ── Iteration order ─────────────────────────────────────────────────────────


def test_iterate_order_is_sorted(engine):
    """Values are emitted in sorted order (EAVT key order)."""
    engine.run_scheme('(declare-attr "tag.x" "STRING" #t #f)')
    eid = engine.run_scheme(
        '(let* ((eid (alloc-entity))) '
        '(save eid "tag.x" "cherry") '
        '(save eid "tag.x" "apple") '
        '(save eid "tag.x" "banana") '
        '(result eid))'
    )[0][0]
    aid = engine._handle.lookup_attr("tag.x")
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    vals = [r[0] for r in rows]
    assert vals == sorted(vals)
    assert set(vals) == {"apple", "banana", "cherry"}


# ── Retract excluded ────────────────────────────────────────────────────────


def test_iterate_excludes_retracted(engine):
    """Retracted values are not emitted (as_of_tx filtering)."""
    engine.run_scheme('(declare-attr "tag.x" "STRING" #t #f)')
    eid = engine.run_scheme(
        '(let* ((eid (alloc-entity))) '
        '(save eid "tag.x" "a") '
        '(save eid "tag.x" "b") '
        '(retract eid "tag.x" "a") '
        '(save eid "tag.x" "c") '
        '(result eid))'
    )[0][0]
    aid = engine._handle.lookup_attr("tag.x")
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    vals = [r[0] for r in rows]
    assert "a" not in vals
    assert set(vals) == {"b", "c"}


# ── Index exhaustion ─────────────────────────────────────────────────────────


def test_iterate_second_call_empty(engine):
    """After full iteration, a second scanner-iterate yields no rows.

    The cursor is positioned past the prefix range (exhausted). Since
    scanner-iterate does NOT reopen the cursor, the second call sees
    the cursor past the prefix → at_end → empty.
    """
    eid, aid = _setup_tag_data(engine)
    prog = (
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    rows = engine.run_scheme_select(prog)
    vals = [r[0] for r in rows]
    # Second iteration is empty — index exhausted
    assert vals == ["a", "b", "c"]


def test_iterate_read_after_exhaustion_returns_void(engine):
    """After scanner-iterate completes, scanner-read returns Void (no active key).

    depth-cleanup has popped the position, so the scanner has no active key.
    scanner-read returns Void, which encodes as 0.
    """
    eid, aid = _setup_tag_data(engine)
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)) '
        f'(result-row (scanner-read s)))'
    )
    # Last row is the scanner-read after exhaustion → Void → 0
    assert rows[-1] == (0,)


def test_iterate_repush_does_not_reset_cursor(engine):
    """After exhaustion, scanner-pop + scanner-push does NOT reposition the cursor.

    scanner-push/scanner-pop only manipulate the prefix — they're orthogonal
    to the cursor. The cursor stays exhausted. A second scanner-iterate
    after repush is still empty because the cursor hasn't moved.
    """
    eid, aid = _setup_tag_data(engine)
    prog = (
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)) '
        f'(scanner-pop s) '
        f'(scanner-pop s) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    rows = engine.run_scheme_select(prog)
    vals = [r[0] for r in rows]
    # Second iteration still empty — cursor is past the prefix, push/pop
    # didn't reposition it
    assert vals == ["a", "b", "c"]


# ── Adjacent-prefix transition ────────────────────────────────────────────────


def test_iterate_adjacent_prefix_chain(engine):
    """Iterate P1, then immediately-adjacent P2, then P3; verify the cursor
    stops exactly at the first key of each next prefix (the transition point).

    Setup uses three attributes declared consecutively so their aids are
    lexicographically adjacent (aid_b == aid_a + 1, aid_c == aid_b + 1) on
    the same entity. In the EAVT index (idx_order = [e, a, v, t, added])
    the datoms are emitted as:

        [eid, aid_a, "aa", t1, ...]
        [eid, aid_b, "bb", t2, ...]
        [eid, aid_c, "cc", t3, ...]

    with NO keys between adjacent pairs.

    After iterating P1 = [eid, aid_a] the cursor must be positioned exactly
    at [eid, aid_b, "bb", ...] — the first key outside P1. When the prefix
    is then changed to P2 = [eid, aid_b], `scanner-seek-prefix` (called
    internally by `scanner-iterate`) recognizes the current cursor key as
    belonging to P2 and continues without reopen. Same applies for P2 → P3.

    Diagnostic value:
      - p2 == []           → cursor went at_end after P1 (transition broken)
      - p2 contains "aa"   → cursor didn't advance during P1 iteration
      - p2 skips "bb"      → cursor overshot the first P2 key (off-by-one)
      - same diagnostics apply to p3, proving the state survives multiple
        consecutive transitions (not just the first one).
    """
    engine.run_scheme('(declare-attr "tag.a" "STRING" #f #f)')
    engine.run_scheme('(declare-attr "tag.b" "STRING" #f #f)')
    engine.run_scheme('(declare-attr "tag.c" "STRING" #f #f)')
    aid_a = engine._handle.lookup_attr("tag.a")
    aid_b = engine._handle.lookup_attr("tag.b")
    aid_c = engine._handle.lookup_attr("tag.c")
    assert aid_b == aid_a + 1, f"aids not adjacent: aid_a={aid_a}, aid_b={aid_b}"
    assert aid_c == aid_b + 1, f"aids not adjacent: aid_b={aid_b}, aid_c={aid_c}"

    eid = engine.run_scheme(
        '(let* ((eid (alloc-entity))) '
        '(save eid "tag.a" "aa") '
        '(save eid "tag.b" "bb") '
        '(save eid "tag.c" "cc") '
        '(result eid))'
    )[0][0]

    prog = (
        f'(let* ((s (scanner-open "EAVT"))) '
        # P1 = [eid, aid_a]
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid_a}) '
        f'(scanner-iterate s (v) (result-row v "P1")) '
        # Transition 1: pop both, push P2 = [eid, aid_b] (adjacent)
        f'(scanner-pop s) '
        f'(scanner-pop s) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid_b}) '
        f'(scanner-iterate s (v) (result-row v "P2")) '
        # Transition 2: pop both, push P3 = [eid, aid_c] (adjacent)
        f'(scanner-pop s) '
        f'(scanner-pop s) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid_c}) '
        f'(scanner-iterate s (v) (result-row v "P3")))'
    )
    rows = engine.run_scheme_select(prog)

    p1_vals = [r[0] for r in rows if r[1] == "P1"]
    p2_vals = [r[0] for r in rows if r[1] == "P2"]
    p3_vals = [r[0] for r in rows if r[1] == "P3"]

    assert p1_vals == ["aa"], f"P1 must emit only 'aa', got {p1_vals}"
    assert p2_vals == ["bb"], (
        f"P2 must emit 'bb' (cursor must be at transition), got {p2_vals}"
    )
    assert p3_vals == ["cc"], (
        f"P3 must emit 'cc' (cursor must be at transition), got {p3_vals}"
    )
