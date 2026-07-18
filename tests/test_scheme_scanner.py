"""Direct Scheme scanner tests (scanner-open, scanner-push, scanner-pop, scanner-prefix).

These tests exercise the scanner prefix manipulation functions added to the
unified SchemeHostFns, without going through SQL parsing or the triejoin
scanner (scanner-push, scanner-pop, scanner-prefix, leapfrog).

The functions under test are native Scheme host fns:

    scanner-open, scanner-push, scanner-pop, scanner-prefix

All tests use `run_scheme` (DML path, SchemeSession) with `result` for
emission — no yield/resume needed.
"""
from __future__ import annotations

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    yield e
    e.close()


# ── scanner-open + scanner-prefix (empty) ────────────────────────────────────


def test_scanner_open_eavt_prefix_empty(engine):
    """scanner-open returns a resource; scanner-prefix on fresh scanner is empty."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) (result (scanner-prefix s)))'
    )
    assert len(rows) == 1
    assert rows[0][0] == b""


def test_scanner_open_aevt_prefix_empty(engine):
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "AEVT"))) (result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


def test_scanner_open_avet_prefix_empty(engine):
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "AVET"))) (result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


def test_scanner_open_vaet_prefix_empty(engine):
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "VAET"))) (result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


# ── scanner-push (eid) ───────────────────────────────────────────────────────


def test_scanner_push_eid_in_eavt(engine):
    """EAVT idx_order = [e, a, v, t, added]; push eid → 8-byte prefix."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-push s 1000) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) == 8, f"expected 8 bytes, got {len(pref)}"
    assert int.from_bytes(pref, "big") == 1000


def test_scanner_push_eid_in_aevt(engine):
    """AEVT idx_order = [a, e, v, ...]; push eid → 8 bytes at position 1."""
    # Push a dummy aid first (position 0 = "a"), then eid (position 1 = "e")
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "AEVT"))) '
        '(scanner-push s 0) '   # placeholder for "a" (position 0)
        '(scanner-push s 999) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    # prefix = [4 bytes aid][8 bytes eid] = 12 bytes
    assert len(pref) == 12, f"expected 12 bytes, got {len(pref)}"
    assert int.from_bytes(pref[4:12], "big") == 999


def test_scanner_push_eid_in_avet(engine):
    """AVET idx_order = [a, v, e, ...]; push eid → 8 bytes at position 2."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "AVET"))) '
        '(scanner-push s 0) '   # placeholder for "a" (position 0)
        '(scanner-push s 0) '   # placeholder for "v" (position 1)
        '(scanner-push s 777) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) >= 20  # 4 + 8 + 8
    assert int.from_bytes(pref[12:20], "big") == 777


def test_scanner_push_eid_in_vaet(engine):
    """VAET idx_order = [v, a, e, ...]; push eid → 8 bytes at position 2."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "VAET"))) '
        '(scanner-push s 0) '   # placeholder for "v" (position 0)
        '(scanner-push s 0) '   # placeholder for "a" (position 1)
        '(scanner-push s 555) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) >= 20
    assert int.from_bytes(pref[16:24], "big") == 555


# ── scanner-push (eid + attr) ────────────────────────────────────────────────


def test_scanner_push_eid_and_attr(engine):
    """Push eid then attr in EAVT → prefix = [8 bytes e][4 bytes a]."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-push s 1000) '
        '(scanner-push s 42) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) == 12, f"expected 12 bytes, got {len(pref)}"
    eid = int.from_bytes(pref[:8], "big")
    aid = int.from_bytes(pref[8:12], "big")
    assert eid == 1000
    assert aid == 42


# ── scanner-pop ──────────────────────────────────────────────────────────────


def test_scanner_pop_restores_prefix(engine):
    """Pop removes the last pushed element and restores the previous prefix."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-push s 1000) '
        '(scanner-push s 42) '
        '(scanner-pop s) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) == 8, f"expected 8 bytes after pop, got {len(pref)}"
    assert int.from_bytes(pref, "big") == 1000


def test_scanner_pop_on_empty_no_error(engine):
    """Pop on empty stack is a no-op (returns Void, prefix unchanged)."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-pop s) '
        '(result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


def test_scanner_pop_returns_to_empty(engine):
    """Pop all pushes returns prefix to empty."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-push s 1000) '
        '(scanner-pop s) '
        '(result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


# ── scanner-push with intern-a + string value (AEVT) ─────────────────────────


def test_scanner_push_with_intern_a_and_string(engine):
    """Push attr aid (via intern-a) and a string value in AEVT.

    AEVT idx_order = [a, e, v, ...]; push order: a=eid, e=eid, v=string.
    The string is encoded via encode_variable (8-byte blocks + control byte).
    """
    engine.run_scheme('(declare-attr "user.name" "STRING" #f #f)')
    rows = engine.run_scheme(
        '(begin '
        '  (let* ((s (scanner-open "AEVT")) '
        '         (aid (intern-a "user.name"))) '
        '    (scanner-push s aid) '     # position 0 = "a"
        '    (scanner-push s 99999) '   # position 1 = "e"
        '    (scanner-push s "Alice") ' # position 2 = "v"
        '    (result (scanner-prefix s))))'
    )
    pref = rows[0][0]
    assert len(pref) > 12
    # First 4 bytes = aid
    aid = int.from_bytes(pref[:4], "big")
    assert aid > 0
    # Next 8 bytes = eid
    eid = int.from_bytes(pref[4:12], "big")
    assert eid == 99999
    # Remaining = encode_variable("Alice") = 8-byte block + control byte
    rest = pref[12:]
    assert rest.startswith(b"Alice"), f"expected Alice-encoded, got {rest!r}"
    # Control byte should be 5 (length of "Alice")
    assert rest[-1] == 5


# ── Multiple scanners ────────────────────────────────────────────────────────


def test_scanner_multiple_independent(engine):
    """Push/pop on one scanner does not affect another."""
    rows = engine.run_scheme(
        '(begin '
        '  (let* ((s0 (scanner-open "EAVT")) '
        '         (s1 (scanner-open "EAVT"))) '
        '    (scanner-push s0 100) '
        '    (scanner-push s1 200) '
        '    (result (scanner-prefix s0) (scanner-prefix s1))))'
    )
    pref0, pref1 = rows[0]
    assert int.from_bytes(pref0, "big") == 100
    assert int.from_bytes(pref1, "big") == 200


# ── scanner-push return value ────────────────────────────────────────────────


def test_scanner_push_returns_void(engine):
    """scanner-push returns Void (encoded as Timestamp 0)."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(result (scanner-push s 1)))'
    )
    assert rows == [(0,)]  # Void → Value::Timestamp(0) → 0


def test_scanner_pop_returns_void(engine):
    """scanner-pop returns Void."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(result (scanner-pop s)))'
    )
    assert rows == [(0,)]


# ── scanner-open with history mode ────────────────────────────────────────────


def test_scanner_open_history_mode(engine):
    """scanner-open with #t (history mode) creates a scanner normally."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT" #t))) '
        '(result (scanner-prefix s)))'
    )
    assert rows[0][0] == b""


# ── Combined: push/pop/push ──────────────────────────────────────────────────


def test_scanner_push_pop_push(engine):
    """Push e, push a, pop a, push a again — prefix should be re-created."""
    rows = engine.run_scheme(
        '(let* ((s (scanner-open "EAVT"))) '
        '(scanner-push s 1000) '
        '(scanner-push s 42) '
        '(scanner-pop s) '
        '(scanner-push s 99) '
        '(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert len(pref) == 12
    aid = int.from_bytes(pref[8:12], "big")
    assert aid == 99, f"expected 99, got {aid}"


# ── scanner-push with large numbers ──────────────────────────────────────────


def test_scanner_push_large_eid(engine):
    """Large eid (near u64 max) should work."""
    large = 2**63 - 1  # max i64
    rows = engine.run_scheme(
        f'(let* ((s (scanner-open "EAVT"))) '
        f'(scanner-push s {large}) '
        f'(result (scanner-prefix s)))'
    )
    pref = rows[0][0]
    assert int.from_bytes(pref, "big") == large