"""scanner.py — V2Scanner + leapfrog triejoin.

Port of nim_query/query/scanner.nim + hostfns.nim. Implements the scanner
abstraction over RocksDB iterators and the leapfrog triejoin algorithm.
"""
from __future__ import annotations

from typing import Any

from . import keys
from .types import (
    DB_TYPE_BOOLEAN,
    DB_TYPE_BLOB,
    DB_TYPE_BYTES,
    DB_TYPE_FLOAT,
    DB_TYPE_INSTANT,
    DB_TYPE_LONG,
    DB_TYPE_REF,
    DB_TYPE_STRING,
    RANGE_LO_OPEN,
    RANGE_HI_OPEN,
    RANGE_OP_EQ,
    RANGE_OP_GT,
    RANGE_OP_GTE,
    RANGE_OP_IN,
    RANGE_OP_LT,
    RANGE_OP_LTE,
    RANGE_OP_NEQ,
    RangeSpec,
)


# ═══════════════════════════════════════════════════════════════════════════════
# KeyVsPrefix — result of classify_key
# ═══════════════════════════════════════════════════════════════════════════════

KVP_NO_PREFIX = 0
KVP_BEFORE = 1
KVP_MATCH = 2
KVP_AFTER = 3


class LeapIterator:
    """Encapsulates leapfrog state across multiple scanners with range filtering."""

    __slots__ = ("scanners", "raw_ops", "started")

    def __init__(self, scanners: list[V2Scanner], raw_ops: list, started: bool = False):
        self.scanners = scanners
        self.raw_ops = raw_ops
        self.started = started


# ═══════════════════════════════════════════════════════════════════════════════
# RocksDB Cursor wrapper
# ═══════════════════════════════════════════════════════════════════════════════


class RocksCursor:
    """Thin wrapper around rocksdict.RdictIter providing the cursor interface.

    Tracks `_fell_past_end`: True when a forward seek/step ran off the end of
    the key range. `advance_to_active_at` must NOT re-seek to the prefix in
    that case — the scanner is genuinely exhausted. Falling past the physical
    end of the index is level-independent: no push/pop or re-seek at any
    shallower level can find data beyond it, so the flag is only cleared by an
    explicit fresh scan (`iterate_init` calls `reset_fell()` + `seek`).
    """

    __slots__ = ("_it", "_fell_past_end")

    def __init__(self, it):
        self._it = it
        self._fell_past_end = False

    def is_valid(self) -> bool:
        return self._it.valid()

    def current_key(self) -> bytes | None:
        if not self._it.valid():
            return None
        return self._it.key()

    def step(self):
        self._it.next()
        if not self._it.valid():
            self._fell_past_end = True

    def seek(self, target: bytes):
        self._it.seek(target)
        self._fell_past_end = not self._it.valid()

    def invalidate(self):
        self._it.seek_to_last()
        self._it.next()  # move past last → invalid
        self._fell_past_end = True

    def fell_past_end(self) -> bool:
        return self._fell_past_end

    def reset_fell(self):
        self._fell_past_end = False


# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# V2Scanner
# ═══════════════════════════════════════════════════════════════════════════════


class PositionStack:
    __slots__ = ("cursor", "idx_order", "stack", "current_active_key", "at_end")

    def __init__(self, cursor: RocksCursor, idx_order: list[str]):
        self.cursor = cursor
        self.idx_order = idx_order
        self.stack: list = []  # list of (index, value) tuples
        self.current_active_key: bytes | None = None
        self.at_end = True

    def push_fixed(self, val):
        idx = len(self.stack)
        self.stack.append((idx, val))

    def pop_fixed(self):
        if self.stack:
            return self.stack.pop()
        return None

    def fixed_entries(self) -> list[tuple[int, Any]]:
        return list(self.stack)

    def current_position(self) -> int:
        return len(self.stack)

    def pos_name(self) -> str:
        ci = self.current_position()
        if ci < len(self.idx_order):
            return self.idx_order[ci]
        return "t"


class V2Scanner:
    __slots__ = (
        "pos",
        "index_name",
        "as_of_tx",
        "value_attr_type",
        "history_mode",
        "prefix_cache",
        "t_in_prefix",
        "raw_ops",
        "_prefix_stack",
    )

    def __init__(
        self,
        index_name: str,
        idx_order: list[str],
        as_of_tx: int | None,
        value_attr_type: int | None,
    ):
        self.pos = PositionStack(RocksCursor(None), idx_order)
        self.index_name = index_name.upper()
        self.as_of_tx = as_of_tx
        self.value_attr_type = value_attr_type
        self.history_mode = False
        self.prefix_cache: bytes = b""
        self.t_in_prefix = False
        self.raw_ops: list = []
        self._prefix_stack: list[tuple[bytes, bool]] = []

    def set_cursor(self, cursor: RocksCursor):
        self.pos.cursor = cursor
        self.pos.at_end = False

    def at_end(self) -> bool:
        return self.pos.at_end

    # ── prefix_cache ──

    def _encode_position(self, pn: str, val) -> bytes:
        """Encode a value at a given position for the prefix."""
        if pn == "a":
            return keys._ATTR.pack(val & 0xFFFFFFFF)
        if pn == "e":
            return keys.encode_eid(val)
        if pn == "v":
            if self.value_attr_type == DB_TYPE_BLOB:
                if isinstance(val, (bytes, bytearray)):
                    return keys.encode_blob(bytes(val))
                return keys.encode_string(str(val))
            if self.value_attr_type == DB_TYPE_BYTES:
                if isinstance(val, (bytes, bytearray)):
                    return keys.encode_bytes(bytes(val))
                return keys.encode_bytes(str(val).encode("utf-8"))
            if isinstance(val, str):
                return keys.encode_string(val)
            if isinstance(val, bool):
                return keys.encode_bool(val)
            if isinstance(val, (bytes, bytearray)):
                return keys.encode_blob(bytes(val))
            if isinstance(val, float):
                return keys.encode_float(val)
            if isinstance(val, int):
                return keys.encode_int(val)
            return keys.encode_int(0)
        if pn == "t":
            tx_bytes, _ = keys.encode_suffix(val, False)
            return tx_bytes
        # generic
        if isinstance(val, str):
            return keys.encode_string(val)
        if isinstance(val, (bytes, bytearray)):
            return keys.encode_blob(bytes(val))
        if isinstance(val, float):
            return keys.encode_float(val)
        if isinstance(val, bool):
            return keys.encode_bool(val)
        if isinstance(val, int):
            return keys.encode_int(val)
        return b""

    def recompute_prefix(self):
        buf = bytearray()
        t_in_prefix = False
        fixed = self.pos.fixed_entries()
        for pi, pn in enumerate(self.pos.idx_order):
            found = False
            for idx, v in fixed:
                if idx == pi:
                    found = True
                    buf.extend(self._encode_position(pn, v))
                    if pn == "t":
                        t_in_prefix = True
                    break
            if not found:
                break
        self.prefix_cache = bytes(buf)
        self.t_in_prefix = t_in_prefix

    def save_value(self, val):
        self.pos.push_fixed(val)
        pn = self.pos.idx_order[len(self.pos.stack) - 1]
        encoded = self._encode_position(pn, val)
        self._prefix_stack.append((self.prefix_cache, self.t_in_prefix))
        self.prefix_cache = self.prefix_cache + encoded
        if pn == "t":
            self.t_in_prefix = True
        self.pos.cursor.reset_fell()
        self.raw_ops = []

    def pop_saved_value(self):
        self.pos.pop_fixed()
        if self._prefix_stack:
            self.prefix_cache, self.t_in_prefix = self._prefix_stack.pop()
        else:
            self.prefix_cache = b""
            self.t_in_prefix = False

    def set_value_attr_type(self, vt: int | None):
        self.value_attr_type = vt
        self.recompute_prefix()

    def set_ranges(self, ranges: list):
        self.raw_ops = ranges

    # ── classify_key ──

    def classify_key(self, key: bytes) -> int:
        bp = self.prefix_cache
        if len(bp) == 0:
            return KVP_NO_PREFIX
        n = min(len(bp), len(key))
        ord_result = 0
        for i in range(n):
            if key[i] < bp[i]:
                ord_result = -1
                break
            if key[i] > bp[i]:
                ord_result = 1
                break
        if ord_result < 0:
            return KVP_BEFORE
        if ord_result > 0:
            return KVP_AFTER
        if len(key) < len(bp):
            return KVP_BEFORE
        return KVP_MATCH

    # ── extract_current ──

    def extract_current(self):
        """Extract the current value at the scanner's position. Returns None if exhausted."""
        key = self.pos.current_active_key
        if key is None:
            return None
        if self.classify_key(key) not in (KVP_MATCH, KVP_NO_PREFIX):
            return None
        pn = self.pos.pos_name()
        ci = self.pos.current_position()

        if ci >= len(self.pos.idx_order) or pn in ("t", "added"):
            tx_raw = keys.be_uint64(key, len(key) - keys._SUFFIX_SIZE)
            t = keys.decode_int64(tx_raw)
            retracted = (key[-1] & 1) != 0
            if pn == "added":
                return (bool, not retracted)
            return (int, t)

        vs = len(self.prefix_cache)

        if pn == "a":
            return (int, keys.be_uint32(key, vs))
        if pn == "e":
            return (int, keys.decode_eid(keys.be_uint64(key, vs)))
        if pn == "v":
            vt = self.value_attr_type
            if vt == DB_TYPE_LONG:
                raw = keys.be_uint64(key, vs)
                return (int, keys.decode_int64(raw))
            if vt == DB_TYPE_STRING or vt is None:
                end = vs
                keylen = len(key)
                while end < keylen:
                    if key[end] == 0:
                        return (str, key[vs:end].decode("utf-8"))
                    end += 1
                return (str, key[vs:].decode("utf-8"))
            value, _ = keys.read_next(key, vs, vt)
            return (type(value), value)
        return None

    def peek_raw(self) -> bytes | None:
        """Return raw value bytes at the current position (without suffix).

        The value end is determined by the next element in the key layout:
        - EAVT/AEVT: value before suffix → ve = len(key) - SUFFIX_SIZE
        - AVET: value before eid+suffix → ve = len(key) - SUFFIX_SIZE - 8
        - VAET: value before attr+eid+suffix → ve = len(key) - SUFFIX_SIZE - 12
        """
        key = self.pos.current_active_key
        if key is None:
            return None
        if self.classify_key(key) not in (KVP_MATCH, KVP_NO_PREFIX):
            return None
        vs = len(self.prefix_cache)
        suffix_size = keys._SUFFIX_SIZE
        if self.index_name in ("EAVT", "AEVT"):
            ve = len(key) - suffix_size
        elif self.index_name == "AVET":
            ve = len(key) - suffix_size - 8  # eid(8B) before suffix
        elif self.index_name == "VAET":
            ve = len(key) - suffix_size - 12  # attr(4B)+eid(8B) before suffix
        else:
            ve = len(key) - suffix_size
        return key[vs:ve]

    # ── advance_to_active_at ──

    def advance_to_active_at(self):
        """Find the latest active (non-retracted) datom at current prefix."""
        pn = self.pos.pos_name()

        if pn == "added":
            self.pos.at_end = self.pos.current_active_key is None
            return

        as_of_tx = self.as_of_tx
        is_t_pos = pn == "t"

        if self.history_mode and is_t_pos:
            while self.pos.cursor.is_valid():
                key = self.pos.cursor.current_key()
                if key is None or len(key) < 8:
                    self.pos.cursor.step()
                    continue
                cls = self.classify_key(key)
                if cls in (KVP_BEFORE, KVP_AFTER):
                    self.pos.at_end = True
                    return
                tx_raw = keys.be_uint64(key, len(key) - keys._SUFFIX_SIZE)
                t = keys.decode_int64(tx_raw)
                if as_of_tx is not None and t > as_of_tx:
                    self.pos.cursor.step()
                    continue
                self.pos.current_active_key = key
                self.pos.at_end = False
                return
            self.pos.current_active_key = None
            self.pos.at_end = True
            return

        # Normal advance — read current key, no stepping
        if not self.pos.cursor.is_valid():
            if self.pos.cursor.fell_past_end():
                self.pos.current_active_key = None
                self.pos.at_end = True
                return
            if self.prefix_cache:
                self.pos.cursor.seek(self.prefix_cache)

        if not self.pos.cursor.is_valid():
            self.pos.current_active_key = None
            self.pos.at_end = True
            return

        key = self.pos.cursor.current_key()
        if key is None or len(key) < 8:
            self.pos.current_active_key = None
            self.pos.at_end = True
            return

        cls = self.classify_key(key)
        if cls == KVP_BEFORE:
            self.pos.cursor.seek(self.prefix_cache)
            if not self.pos.cursor.is_valid():
                self.pos.current_active_key = None
                self.pos.at_end = True
                return
            key = self.pos.cursor.current_key()
            if key is None:
                self.pos.current_active_key = None
                self.pos.at_end = True
                return
            cls = self.classify_key(key)

        if cls == KVP_AFTER:
            self.pos.current_active_key = None
            self.pos.at_end = True
            return

        retracted = (key[-1] & 1) != 0
        if retracted:
            self.pos.current_active_key = None
            self.pos.at_end = True
            return

        self.pos.current_active_key = key
        self.pos.at_end = False

    # ── leap_next_at ──

    def leap_next_at(self):
        pn = self.pos.pos_name()
        if pn == "added":
            self.pos.at_end = True
            return
        if self.pos.current_active_key is not None:
            self.pos.cursor.step()
        self.advance_to_active_at()

    # ── seek_to_value ──

    def seek_to_value(self, value):
        """Seek scanner to a specific value. value is raw bytes (already encoded)."""
        key = self.pos.current_active_key
        if key is None:
            self.pos.cursor.invalidate()
            return
        vs = len(self.prefix_cache)
        target = bytearray(key[:vs])
        if isinstance(value, (bytes, bytearray)):
            target.extend(value)
        else:
            # Legacy: (type, raw) tuple — encode to bytes
            vtype, vraw = value
            pn = self.pos.pos_name()
            if pn == "e":
                target.extend(keys.encode_eid(vraw))
            elif pn == "a":
                target.extend(keys._ATTR.pack(vraw & 0xFFFFFFFF))
            else:
                target.extend(keys.encode_int(vraw))
        target.extend(b"\x00" * keys._SUFFIX_SIZE)
        self.pos.cursor.seek(bytes(target))
        self.advance_to_active_at()

    # ── attr_id helpers ──

    def attr_id_from_prefix_bytes(self) -> int | None:
        off = 8 if self.index_name in ("EAVT", "VAET") else 0
        if len(self.prefix_cache) >= off + 4:
            return keys.be_uint32(self.prefix_cache, off)
        return None

    def attr_id_from_key(self) -> int | None:
        key = self.pos.current_active_key
        if key is None:
            return None
        off = 8 if self.index_name in ("EAVT", "VAET") else 0
        if len(key) >= off + 4:
            return keys.be_uint32(key, off)
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# Leapfrog converge
# ═══════════════════════════════════════════════════════════════════════════════


def _cmp_value(a, b) -> int:
    """Compare two (type, value) tuples."""
    at, av = a
    bt, bv = b
    if at != bt:
        return -1 if at.__name__ < bt.__name__ else 1
    if av < bv:
        return -1
    if av > bv:
        return 1
    return 0


def leap_converge(scanners: list[V2Scanner]) -> bool:
    """Classic leapfrog triejoin convergence.

    Find max value across all scanners, seek lagging scanners to max, repeat
    until all equal or exhausted.
    """
    max_iters = len(scanners) * 2 + 1
    for _ in range(max_iters):
        max_val = None
        all_equal = True
        at_end_indices: list[int] = []

        for i, sc in enumerate(scanners):
            v = sc.extract_current()
            if v is not None:
                if max_val is None:
                    max_val = v
                elif _cmp_value(v, max_val) != 0:
                    all_equal = False
                    if _cmp_value(v, max_val) > 0:
                        max_val = v
            else:
                at_end_indices.append(i)
                all_equal = False

        if all_equal:
            return True

        if max_val is not None:
            mv = max_val
            for i, sc in enumerate(scanners):
                needs_seek = False
                cv = sc.extract_current()
                if cv is not None and _cmp_value(cv, mv) < 0:
                    needs_seek = True
                if i in at_end_indices:
                    needs_seek = True
                if needs_seek:
                    sc.seek_to_value(mv)
                    if sc.at_end():
                        return False
        else:
            return False
    return False


# ═══════════════════════════════════════════════════════════════════════════════
# Interval merging + apply_ranges
# ═══════════════════════════════════════════════════════════════════════════════


def _ops_to_intervals(ops: list[tuple[int, Any]]) -> list[tuple]:
    """Convert range ops into canonical intervals."""
    neq_vals = []
    range_ops = []
    in_vals = []

    for op, val in ops:
        if op == RANGE_OP_NEQ:
            neq_vals.append(val)
        elif op == RANGE_OP_IN:
            in_vals.append(val)
        else:
            range_ops.append((op, val))

    if in_vals and not range_ops and not neq_vals:
        sorted_vals = sorted(in_vals)
        intervals = [(v, v, 0) for v in sorted_vals]
        return _merge_intervals(intervals)

    lo = None
    hi = None
    lo_open = False
    hi_open = False

    for op, val in range_ops:
        if op in (RANGE_OP_GT, RANGE_OP_GTE):
            if lo is None or val > lo or (val == lo and op == RANGE_OP_GT):
                lo = val
                lo_open = op == RANGE_OP_GT
        elif op in (RANGE_OP_LT, RANGE_OP_LTE):
            if hi is None or val < hi or (val == hi and op == RANGE_OP_LT):
                hi = val
                hi_open = op == RANGE_OP_LT
        elif op == RANGE_OP_EQ:
            lo = val
            hi = val
            lo_open = False
            hi_open = False

    if lo is not None and hi is not None and lo > hi:
        return []

    flags = 0
    if lo_open:
        flags |= RANGE_LO_OPEN
    if hi_open:
        flags |= RANGE_HI_OPEN

    intervals = [(lo, hi, flags)]

    for nv in neq_vals:
        new_intervals = []
        for iv_lo, iv_hi, iv_flags in intervals:
            in_range = True
            if iv_lo is not None:
                if iv_flags & RANGE_LO_OPEN:
                    if nv <= iv_lo:
                        in_range = False
                else:
                    if nv < iv_lo:
                        in_range = False
            if in_range and iv_hi is not None:
                if iv_flags & RANGE_HI_OPEN:
                    if nv >= iv_hi:
                        in_range = False
                else:
                    if nv > iv_hi:
                        in_range = False
            if not in_range:
                new_intervals.append((iv_lo, iv_hi, iv_flags))
            else:
                left_flags = (iv_flags & ~RANGE_HI_OPEN) | RANGE_HI_OPEN
                new_intervals.append((iv_lo, nv, left_flags))
                right_flags = (iv_flags & ~RANGE_LO_OPEN) | RANGE_LO_OPEN
                new_intervals.append((nv, iv_hi, right_flags))
        intervals = new_intervals

    return _merge_intervals(intervals)


def _merge_intervals(intervals: list[tuple]) -> list[tuple]:
    if len(intervals) <= 1:
        return intervals

    def sort_key(item):
        lo = item[0]
        if lo is None:
            return (0, 0)
        if isinstance(lo, bool):
            return (1, int(lo))
        if isinstance(lo, str):
            return (2, lo)
        if isinstance(lo, (int, float)):
            return (3, lo)
        if isinstance(lo, (bytes, bytearray)):
            return (4, lo)
        return (5, 0)

    sorted_intervals = sorted(intervals, key=sort_key)
    result = [sorted_intervals[0]]

    for lo, hi, flags in sorted_intervals[1:]:
        prev_lo, prev_hi, prev_flags = result[-1]

        can_merge = False
        if prev_hi is None:
            can_merge = True
        elif lo is not None:
            if type(lo) == type(prev_hi):
                if lo < prev_hi:
                    can_merge = True
                elif lo == prev_hi:
                    prev_hi_closed = (prev_flags & RANGE_HI_OPEN) == 0
                    lo_closed = (flags & RANGE_LO_OPEN) == 0
                    can_merge = prev_hi_closed and lo_closed

        if can_merge:
            if prev_hi is None:
                new_hi = hi
            elif hi is None:
                new_hi = None
            elif hi > prev_hi:
                new_hi = hi
            else:
                new_hi = prev_hi

            if prev_hi is None:
                new_hi_open = (flags & RANGE_HI_OPEN) != 0
            elif hi is None:
                new_hi_open = False
            elif hi > prev_hi:
                new_hi_open = (flags & RANGE_HI_OPEN) != 0
            elif hi < prev_hi:
                new_hi_open = (prev_flags & RANGE_HI_OPEN) != 0
            else:
                new_hi_open = (prev_flags & RANGE_HI_OPEN) != 0 and (flags & RANGE_HI_OPEN) != 0

            new_flags = (prev_flags & RANGE_LO_OPEN) | (RANGE_HI_OPEN if new_hi_open else 0)
            result[-1] = (prev_lo, new_hi, new_flags)
        else:
            result.append((lo, hi, flags))

    return result


def _cmp_bytes(a: bytes, b: bytes) -> int:
    """Lexicographic comparison of raw bytes."""
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def apply_ranges(scanners: list[V2Scanner], raw_ops: list[list[tuple[int, bytes]]]) -> bool:
    """After convergence, check if current value falls within merged range intervals.

    Bounds are raw bytes for lexicographic comparison without decoding.
    """
    if not raw_ops:
        return True

    all_intervals = []
    for branch in raw_ops:
        all_intervals.extend(_ops_to_intervals(branch))
    merged = _merge_intervals(all_intervals)
    range_specs = [RangeSpec(lo=lo, hi=hi, flags=flags) for lo, hi, flags in merged]

    if not range_specs:
        return False

    max_iter = len(range_specs) + 2
    for _ in range(max_iter):
        cur = scanners[0].peek_raw()
        if cur is None:
            return False

        any_applied = False
        for spec in range_specs:
            past_hi = False
            if spec.hi is not None:
                hi_open = (spec.flags & RANGE_HI_OPEN) != 0
                if hi_open:
                    past_hi = _cmp_bytes(cur, spec.hi) >= 0
                else:
                    past_hi = _cmp_bytes(cur, spec.hi) > 0
            if past_hi:
                continue

            before_lo = False
            if spec.lo is not None:
                lo_open = (spec.flags & RANGE_LO_OPEN) != 0
                if lo_open:
                    before_lo = _cmp_bytes(cur, spec.lo) <= 0
                else:
                    before_lo = _cmp_bytes(cur, spec.lo) < 0
            if before_lo:
                for sc in scanners:
                    sc.seek_to_value(spec.lo)
                if not leap_converge(scanners):
                    return False
                if lo_open:
                    cv = scanners[0].peek_raw()
                    if cv is not None and _cmp_bytes(cv, spec.lo) == 0:
                        for sc in scanners:
                            sc.leap_next_at()
                        if not leap_converge(scanners):
                            return False
                any_applied = True
                break
            else:
                return True

        if not any_applied:
            return False
    return False


def parse_ranges(sexpr) -> list[list[tuple[int, Any]]]:
    """Parse a ranges expression (list of lists of (op, val) tuples)."""
    if not isinstance(sexpr, list):
        return []
    result = []
    branch = []
    for item in sexpr:
        if isinstance(item, list):
            if len(item) == 1 and item[0] == "branch":
                if branch:
                    result.append(branch)
                    branch = []
                continue
            if len(item) >= 2 and isinstance(item[0], int):
                branch.append((item[0], item[1]))
                continue
        elif isinstance(item, str) and item == "branch":
            if branch:
                result.append(branch)
                branch = []
            continue
    if branch:
        result.append(branch)
    return result
