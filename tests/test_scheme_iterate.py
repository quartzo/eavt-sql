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


# ── scanner-iterate with :ranges keyword ──────────────────────────────────────


def _setup_long_data(e: EAVTEngine, values: list[int]) -> tuple[int, int]:
    """Declare tag.x as LONG MANY and save the given values on a new entity."""
    e.run_scheme('(declare-attr "tag.x" "LONG" #t #f)')
    saves = " ".join(f'(save eid "tag.x" {v})' for v in values)
    eid = e.run_scheme(
        f'(let* ((eid (alloc-entity))) {saves} (result eid))'
    )[0][0]
    aid = e._handle.lookup_attr("tag.x")
    return eid, aid


def test_iterate_with_ranges_filters_values(engine):
    """`:ranges` filters iterated values to those inside the merged intervals."""
    eid, aid = _setup_long_data(engine, [5, 10, 15, 20, 25])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT")) '
        f'       (r0 (ranges-create (and (>= 10) (<= 20))))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges r0 (result-row v)))'
    )
    assert [r[0] for r in rows] == [10, 15, 20]


def test_iterate_with_ranges_eq_single(engine):
    eid, aid = _setup_long_data(engine, [5, 10, 15, 20, 25])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges (ranges-create (= 15)) (result-row v)))'
    )
    assert [r[0] for r in rows] == [15]


def test_iterate_with_ranges_neq(engine):
    """NEQ splits the iterated range and skips the excluded value."""
    eid, aid = _setup_long_data(engine, [5, 10, 15, 20, 25])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges (ranges-create (!= 15)) (result-row v)))'
    )
    assert [r[0] for r in rows] == [5, 10, 20, 25]


def test_iterate_with_ranges_or_disjoint(engine):
    eid, aid = _setup_long_data(engine, [1, 5, 10, 15, 20])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges (ranges-create (or (= 1) (= 20))) '
        f'  (result-row v)))'
    )
    assert [r[0] for r in rows] == [1, 20]


def test_iterate_with_ranges_empty_filter_all(engine):
    """`:ranges` with an empty tree (from `(and)`) means no constraint."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT")) '
        f'       (r0 (ranges-create (and)))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges r0 (result-row v)))'
    )
    assert [r[0] for r in rows] == [5, 10, 15]


def test_iterate_with_ranges_in_middle_of_body(engine):
    """`:ranges` may appear at any position among body forms."""
    eid, aid = _setup_long_data(engine, [5, 10, 15, 20, 25])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT")) '
        f'       (r0 (ranges-create (>= 20)))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row "pre") :ranges r0 (result-row v)))'
    )
    # For each matched value: a "pre" row followed by the value row.
    assert rows == [("pre",), (20,), ("pre",), (25,)]


def test_iterate_with_ranges_can_be_inspected_with_ranges_show(engine):
    """`:ranges` value is reusable: pass it to ranges-show for debugging."""
    eid, aid = _setup_long_data(engine, [5, 10, 15, 20, 25])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT")) '
        f'       (r0 (ranges-create (and (>= 10) (<= 20))))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges r0 (result-row v)) '
        f'(result-row (ranges-show r0)))'
    )
    values = [r[0] for r in rows if not isinstance(r[0], str)]
    interval_str = [r[0] for r in rows if isinstance(r[0], str)]
    assert values == [10, 15, 20]
    assert interval_str == ["[10, 20]"]


def test_iterate_without_ranges_backward_compat(engine):
    """Forms without `:ranges` keep working exactly as before."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    assert [r[0] for r in rows] == [5, 10, 15]


def test_iterate_with_ranges_duplicate_keyword_errors(engine):
    """Specifying `:ranges` twice is an error."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    with pytest.raises(ValueError, match="more than once"):
        engine.run_scheme_select(
            f'(let* ((s (scanner-open "EAVT")) '
            f'       (r0 (ranges-create (>= 5)))) '
            f'(scanner-push s {eid}) '
            f'(scanner-push s {aid}) '
            f'(scanner-iterate s (v) :ranges r0 :ranges r0 (result-row v)))'
        )


def test_iterate_with_ranges_missing_value_errors(engine):
    """`:ranges` at the end with no value is an error."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    with pytest.raises(ValueError, match="requires a value"):
        engine.run_scheme_select(
            f'(let* ((s (scanner-open "EAVT"))) '
            f'(scanner-push s {eid}) '
            f'(scanner-push s {aid}) '
            f'(scanner-iterate s (v) :ranges))'
        )


def test_iterate_with_ranges_filters_out_everything(engine):
    """A range that matches no value emits zero rows."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) :ranges (ranges-create (and (> 100) (< 200))) '
        f'  (result-row v)))'
    )
    assert rows == []


# ── REF round-trip regression ────────────────────────────────────────────────


def test_iterate_ref_round_trip_via_scanner_iterate(engine):
    """Regression: REF values read via scanner-iterate must round-trip exactly.

    Before the fix in scanner-seek-prefix, value_attr_type was never set on
    the scanner-iterate path, so REF values fell into the LONG decoder path
    which applies decode_int64 (sign flip). The result was that entity IDs
    like 0x0000400000000001 came back as 0x8000400000000001 (i64 negative).
    """
    engine.run_scheme('(declare-attr "ref.x" "REF" #t #f)')
    aid = engine._handle.lookup_attr("ref.x")
    target_eid, src_eid = engine.run_scheme(
        '(let* ((target (alloc-entity)) '
        '       (src (alloc-entity))) '
        '(save src "ref.x" target) '
        '(result target src))'
    )[0]

    rows = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {src_eid}) (scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    assert rows == [(target_eid,)], (
        f"REF value should round-trip as {target_eid}, got {rows}"
    )


# ── Multi-scanner leapfrog triejoin ──────────────────────────────────────────


def _setup_two_entities_with_tag_x(e: EAVTEngine, vals1: list[int], vals2: list[int]):
    """Declare tag.x MANY LONG and create two entities with the given values."""
    e.run_scheme('(declare-attr "tag.x" "LONG" #t #f)')
    saves1 = " ".join(f'(save eid "tag.x" {v})' for v in vals1)
    saves2 = " ".join(f'(save eid "tag.x" {v})' for v in vals2)
    eid1 = e.run_scheme(
        f'(let* ((eid (alloc-entity))) {saves1} (result eid))'
    )[0][0]
    eid2 = e.run_scheme(
        f'(let* ((eid (alloc-entity))) {saves2} (result eid))'
    )[0][0]
    aid = e._handle.lookup_attr("tag.x")
    return eid1, eid2, aid


def test_iterate_multi_two_scanners_intersection(engine):
    """Two scanners on different eids emit only the intersection of values.

    eid1 has [10, 20, 30], eid2 has [20, 30, 40] → leapfrog converges only
    on 20 and 30.
    """
    eid1, eid2, aid = _setup_two_entities_with_tag_x(engine, [10, 20, 30], [20, 30, 40])
    rows = engine.run_scheme_select(
        f'(let* ((s1 (scanner-open "EAVT")) '
        f'       (s2 (scanner-open "EAVT"))) '
        f'(scanner-push s1 {eid1}) (scanner-push s1 {aid}) '
        f'(scanner-push s2 {eid2}) (scanner-push s2 {aid}) '
        f'(scanner-iterate (s1 s2) (v) (result-row v)))'
    )
    assert [r[0] for r in rows] == [20, 30]


def test_iterate_multi_no_intersection_empty(engine):
    """Scanners with disjoint value sets emit nothing."""
    eid1, eid2, aid = _setup_two_entities_with_tag_x(engine, [1, 2, 3], [100, 200])
    rows = engine.run_scheme_select(
        f'(let* ((s1 (scanner-open "EAVT")) '
        f'       (s2 (scanner-open "EAVT"))) '
        f'(scanner-push s1 {eid1}) (scanner-push s1 {aid}) '
        f'(scanner-push s2 {eid2}) (scanner-push s2 {aid}) '
        f'(scanner-iterate (s1 s2) (v) (result-row v)))'
    )
    assert rows == []


def test_iterate_multi_three_way_join(engine):
    """Three scanners converge only on values present in all three."""
    engine.run_scheme('(declare-attr "tag.x" "LONG" #t #f)')
    aid = engine._handle.lookup_attr("tag.x")
    eids = []
    for vals in ([10, 20, 30], [20, 30, 40], [30, 40, 50]):
        saves = " ".join(f'(save eid "tag.x" {v})' for v in vals)
        eid = engine.run_scheme(
            f'(let* ((eid (alloc-entity))) {saves} (result eid))'
        )[0][0]
        eids.append(eid)
    e0, e1, e2 = eids
    rows = engine.run_scheme_select(
        f'(let* ((s0 (scanner-open "EAVT")) '
        f'       (s1 (scanner-open "EAVT")) '
        f'       (s2 (scanner-open "EAVT"))) '
        f'(scanner-push s0 {e0}) (scanner-push s0 {aid}) '
        f'(scanner-push s1 {e1}) (scanner-push s1 {aid}) '
        f'(scanner-push s2 {e2}) (scanner-push s2 {aid}) '
        f'(scanner-iterate (s0 s1 s2) (v) (result-row v)))'
    )
    assert [r[0] for r in rows] == [30]


def test_iterate_multi_with_ranges(engine):
    """`:ranges` applies to the converged value across all scanners."""
    eid1, eid2, aid = _setup_two_entities_with_tag_x(engine, [10, 20, 30, 50], [20, 30, 50, 70])
    rows = engine.run_scheme_select(
        f'(let* ((s1 (scanner-open "EAVT")) '
        f'       (s2 (scanner-open "EAVT")) '
        f'       (r0 (ranges-create (>= 30)))) '
        f'(scanner-push s1 {eid1}) (scanner-push s1 {aid}) '
        f'(scanner-push s2 {eid2}) (scanner-push s2 {aid}) '
        f'(scanner-iterate (s1 s2) (v) :ranges r0 (result-row v)))'
    )
    # Intersection = [20, 30, 50]; filtered by >= 30 → [30, 50]
    assert [r[0] for r in rows] == [30, 50]


def test_iterate_multi_single_value_in_each(engine):
    """Both scanners have a single matching value → emits that one value."""
    eid1, eid2, aid = _setup_two_entities_with_tag_x(engine, [42], [42])
    rows = engine.run_scheme_select(
        f'(let* ((s1 (scanner-open "EAVT")) '
        f'       (s2 (scanner-open "EAVT"))) '
        f'(scanner-push s1 {eid1}) (scanner-push s1 {aid}) '
        f'(scanner-push s2 {eid2}) (scanner-push s2 {aid}) '
        f'(scanner-iterate (s1 s2) (v) (result-row v)))'
    )
    assert rows == [(42,)]


def test_iterate_multi_cross_index_ref_join(engine):
    """Join across two different indices using REF values.

    Setup: tag.x is a REF-type attribute.
      child.tag.x     = [parent1, parent2]      (stored in "v" as REF)
      parent1.tag.x   = [parent1]               (parent1 self-ref)

    Scanners:
      s_eavt: prefix [child, aid] → iterates "v" (the ref values: parent1, parent2)
      s_aevt: prefix [aid]        → iterates "e" (entities having tag.x: parent1, child)

    Leapfrog converges only on entities that are BOTH a ref of child AND have
    tag.x themselves — intersection is {parent1}.
    """
    engine.run_scheme('(declare-attr "tag.x" "REF" #t #f)')
    aid = engine._handle.lookup_attr("tag.x")
    rows = engine.run_scheme(
        '(let* ((p1 (alloc-entity)) '
        '       (p2 (alloc-entity)) '
        '       (c  (alloc-entity))) '
        '(save c "tag.x" p1) '
        '(save c "tag.x" p2) '
        '(save p1 "tag.x" p1) '
        '(result p1 p2 c))'
    )
    p1, p2, c = rows[0]

    rows = engine.run_scheme_select(
        f'(let* ((s_eavt (scanner-open "EAVT")) '
        f'       (s_aevt (scanner-open "AEVT"))) '
        f'(scanner-push s_eavt {c}) (scanner-push s_eavt {aid}) '
        f'(scanner-push s_aevt {aid}) '
        f'(scanner-iterate (s_eavt s_aevt) (v) (result-row v)))'
    )
    vals = [r[0] for r in rows]
    assert p1 in vals, f"parent1 ({p1}) should be in intersection, got {vals}"
    assert p2 not in vals, f"parent2 ({p2}) should NOT be in intersection, got {vals}"


def test_iterate_multi_empty_list_errors(engine):
    """Empty scanner list `()` is an error."""
    with pytest.raises(ValueError):
        engine.run_scheme_select(
            '(let* ((s (scanner-open "EAVT"))) '
            '(scanner-iterate () (v) (result-row v)))'
        )


def test_iterate_multi_single_atom_backward_compat(engine):
    """A single atom (not list) is equivalent to a single-element list.
    Existing single-scanner programs keep working unchanged."""
    eid, aid = _setup_long_data(engine, [5, 10, 15])
    # atom form
    rows_atom = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate s (v) (result-row v)))'
    )
    # single-element list form
    rows_list = engine.run_scheme_select(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {eid}) '
        f'(scanner-push s {aid}) '
        f'(scanner-iterate (s) (v) (result-row v)))'
    )
    assert rows_atom == rows_list == [(5,), (10,), (15,)]
