"""session.py — QuerySession: unified API replicating the 22 Scheme host functions.

Mirrors nim_query/query/hostfns.nim SchemeHostFns + engine.nim QuerySession.
Each Scheme host function maps 1:1 to a Python method.
"""
from __future__ import annotations

from typing import Any

from .engine import EavtEngine
from .scanner import (
    V2Scanner,
    RocksCursor,
    LeapIterator,
    leap_converge,
    apply_ranges,
    parse_ranges,
)
from .types import DB_TYPE_REF, index_order


# ═══════════════════════════════════════════════════════════════════════════════
# QuerySession
# ═══════════════════════════════════════════════════════════════════════════════


class QuerySession:
    """Replicates SchemeHostFns — all 22 host functions as Python methods.

    Usage:
        engine = EavtEngine(path)
        engine.bootstrap()
        sess = QuerySession(engine, tx=engine.allocate_tx())

        # DML
        eid = sess.alloc_entity()
        sess.save(eid, "person.name", "Alice")

        # Query (leapfrog triejoin)
        sc1 = sess.scanner_open("AEVT")
        sess.scanner_push(sc1, sess.intern_a("person.name"))
        sc2 = sess.scanner_open("AEVT")
        sess.scanner_push(sc2, sess.intern_a("person.age"))
        iter_h = sess.scanner_iterate_init(sc1, sc2)
        while True:
            val = sess.scanner_iterate_next(iter_h)
            if val is None:
                break
            eid = val[1]
            name = sess.lookup_value(eid, "person.name")
            print(eid, name)
    """

    def __init__(
        self,
        engine: EavtEngine,
        tx: int | None = None,
        as_of_tx: int | None = None,
        params: list[Any] | None = None,
    ):
        self.engine = engine
        self.tx = tx if tx is not None else engine.allocate_tx()
        self.as_of_tx = as_of_tx
        self.params = params or []
        self.scanners: list[V2Scanner] = []
        self.leap_iters: dict[int, LeapIterator] = {}

    # ──────────────────────────────────────────────────────────────────────
    # Scanner ops
    # ──────────────────────────────────────────────────────────────────────

    def scanner_open(self, index_name: str, history: bool = False) -> int:
        """(scanner-open index-name [history]) → scanner handle.

        Opens a scanner on the given index (EAVT/AEVT/AVET/VAET).
        Returns an integer handle for use with other scanner methods.
        """
        upper = index_name.upper()
        base_order = index_order(upper)
        idx_order = base_order + ["t", "added"]

        value_attr_type = None
        scanner = V2Scanner(upper, idx_order, self.as_of_tx, value_attr_type)
        if history:
            scanner.history_mode = True

        cf_id = {"AEVT": 1, "AVET": 2, "VAET": 3}.get(upper, 0)
        raw_it = self.engine.open_iterator(cf_id)
        raw_it.seek_to_first()
        scanner.set_cursor(RocksCursor(raw_it))
        scanner.advance_to_active_at()

        handle = len(self.scanners)
        self.scanners.append(scanner)
        return handle

    def scanner_read(self, handle: int):
        """(scanner-read scanner) → current value or None.

        Returns the value at the scanner's current position, or None if exhausted.
        """
        sc = self._find_scanner(handle)
        return self._unwrap(sc.extract_current())

    def scanner_push(self, handle: int, value):
        """(scanner-push scanner value) → void.

        Pushes a value onto the scanner's position stack, narrowing the prefix.
        """
        sc = self._find_scanner(handle)
        sc.save_value(value)

    def scanner_pop(self, handle: int):
        """(scanner-pop scanner) → void.

        Pops the last pushed value from the scanner's position stack.
        """
        sc = self._find_scanner(handle)
        sc.pop_saved_value()

    def scanner_prefix(self, handle: int) -> bytes:
        """(scanner-prefix scanner) → bytes.

        Returns the current prefix cache bytes for the scanner.
        """
        sc = self._find_scanner(handle)
        return sc.prefix_cache

    # ──────────────────────────────────────────────────────────────────────
    # Leapfrog triejoin
    # ──────────────────────────────────────────────────────────────────────

    def ranges_create(self, expr) -> list:
        """(ranges-create expr) → flat list of (op val) pairs.

        Mirrors nim_scheme/scheme.nim ranges-create. Converts a comparison
        expression tree into the flat ranges list consumed by scanner_set_ranges:

            ['>', 28]              → [[2, 28]]
            ['and', ['>', 28], ['=', "SP"]]  → [[2, 28], [0, "SP"]]
            ['or', ['>', 28], ['<', 5]]      → [[2, 28], ['branch'], [4, 5]]

        Op codes: =:0 !=:1 >:2 >=:3 <:4 <=:5 in:6. Each `or` branch is
        separated by a ['branch'] marker.
        """
        op_map = {"=": 0, "!=": 1, ">": 2, ">=": 3, "<": 4, "<=": 5, "in": 6}
        out: list = []

        def walk(node) -> None:
            if not isinstance(node, list) or not node:
                return
            head = node[0]
            if isinstance(head, str) and head in ("and", "or"):
                if head == "and":
                    for child in node[1:]:
                        walk(child)
                else:
                    for child in node[1:]:
                        out.append(["branch"])
                        walk(child)
            elif isinstance(head, str) and head in op_map:
                if len(node) >= 2:
                    out.append([op_map[head], node[1]])
            elif isinstance(head, list):
                for child in node:
                    walk(child)

        walk(expr)
        return out

    def scanner_iterate_init(self, *handles: int) -> int:
        """(scanner-iterate-init scanner...) → iterator handle.

        Creates a LeapIterator over the given scanners. Each scanner is
        repositioned to its current prefix (re-seek), so a scanner consumed
        by a previous loop can be reused — cursors are jump resources, not
        one-shot. Range filters set via scanner-set-ranges on a scanner are
        applied to the loop (the first scanner carrying ranges wins); must be
        set before init. Pushing (descending) clears the scanner's ranges —
        they only apply at the position they were set for.
        """
        scanners = [self._find_scanner(h) for h in handles]
        if not scanners:
            return -1

        for sc in scanners:
            vt = self._resolve_value_attr_type(sc)
            sc.set_value_attr_type(vt)
            sc.pos.cursor.reset_fell()
            if sc.prefix_cache:
                sc.pos.cursor.seek(sc.prefix_cache)
            sc.advance_to_active_at()

        raw_ops = []
        for sc in scanners:
            if sc.raw_ops:
                raw_ops = sc.raw_ops
                break

        it = LeapIterator(scanners=scanners, raw_ops=raw_ops, started=False)
        idx = len(self.leap_iters)
        self.leap_iters[idx] = it
        return idx

    def scanner_set_ranges(self, handle: int, ranges) -> None:
        """(scanner-set-ranges scanner ranges) → void.

        Sets the range filter on a scanner for the next scanner-iterate-init.
        Ranges are position-scoped: pushing (descending) clears them, so set
        them after the pushes that establish the position to filter.
        """
        sc = self._find_scanner(handle)
        sc.set_ranges(parse_ranges(ranges) if ranges else [])

    def scanner_iterate_next(self, iter_handle: int) -> tuple | None:
        """(scanner-iterate-next iter) → next value or None.

        On first call: converge + apply ranges, return first value.
        On subsequent calls: advance smallest scanner + converge + ranges.
        Returns None when exhausted.
        """
        it = self._find_leap_iter(iter_handle)
        if not it.scanners:
            return None

        if not it.started:
            ok = (
                leap_converge(it.scanners)
                if not it.raw_ops
                else apply_ranges(it.scanners, it.raw_ops)
            )
            if not ok:
                return None
            it.started = True
        else:
            # Advance the scanner with the smallest current value
            min_idx = 0
            min_val = None
            for i, sc in enumerate(it.scanners):
                val = sc.extract_current()
                if min_val is None:
                    min_val = val
                    min_idx = i
                elif val is not None and self._cmp(val, min_val) < 0:
                    min_val = val
                    min_idx = i

            it.scanners[min_idx].leap_next_at()
            if it.scanners[min_idx].at_end():
                return None
            if not leap_converge(it.scanners):
                return None
            if it.raw_ops and not apply_ranges(it.scanners, it.raw_ops):
                return None

        val = it.scanners[0].extract_current()
        return self._unwrap(val)

    # ──────────────────────────────────────────────────────────────────────
    # Attribute access
    # ──────────────────────────────────────────────────────────────────────

    def intern_a(self, name: str) -> int | None:
        """(intern-a name) → attribute ID or None.

        Looks up the attribute ID for a given name. Returns None if not found.
        """
        return self.engine.lookup_attr(name)

    def attr_name(self, aid: int) -> str:
        """(attr-name aid) → attribute name string.

        Returns the attribute name for a given ID.
        """
        return self.engine.attr_name(aid)

    def param(self, idx: int) -> Any:
        """(param index) → parameter value (1-indexed).

        Returns the query parameter at the given 1-based index.
        """
        if idx < 1 or idx > len(self.params):
            raise IndexError(f"param index out of range: {idx}")
        return self.params[idx - 1]

    def resolve_val(self, expr) -> Any:
        """(resolve-val expr) → expr (identity).

        Returns the value as-is. Used by the compiler for constant folding.
        """
        return expr

    # ──────────────────────────────────────────────────────────────────────
    # DML
    # ──────────────────────────────────────────────────────────────────────

    def save(self, eid: int, attr: str, val):
        """(save eid attr val) → void.

        Saves a datom. For not-many attrs, retracts existing active datoms first.
        """
        self.engine.save(eid, attr, val, self.tx)

    def retract(self, eid: int, attr: str, val):
        """(retract eid attr val) → void.

        Writes retraction entries for a datom.
        """
        self.engine.retract(eid, attr, val, self.tx)

    # ──────────────────────────────────────────────────────────────────────
    # Entity / Tx allocation
    # ──────────────────────────────────────────────────────────────────────

    def alloc_entity(self, partition: int = 4) -> int:
        """(alloc-entity [partition]) → new entity ID.

        Allocates a new entity ID in the given partition (default: user=4).
        """
        return self.engine.alloc_entity(partition)

    def tx_entity(self) -> int:
        """(tx-entity) → current transaction entity ID.

        Returns the tx entity ID for this session.
        """
        return self.tx

    # ──────────────────────────────────────────────────────────────────────
    # Lookup
    # ──────────────────────────────────────────────────────────────────────

    def lookup_entity(self, attr: str, val) -> int | None:
        """(lookup-entity attr val) → entity ID or None.

        Unique-attr lookup via AVET index. Raises if attr is not unique.
        """
        aid = self.engine.lookup_attr(attr)
        if aid is None:
            return None
        if not self.engine.is_unique(aid):
            raise ValueError(f"lookup-entity: attribute '{attr}' is not UNIQUE")
        return self.engine.lookup_entity(attr, val)

    def lookup_value(self, eid: int, attr: str):
        """(lookup-value eid attr) → value or None.

        Looks up the current active value for an entity+attribute.
        """
        return self.engine.lookup_value(eid, attr)

    # ──────────────────────────────────────────────────────────────────────
    # Schema declaration
    # ──────────────────────────────────────────────────────────────────────

    def declare_attr(self, attr: str, type_name: str, many: bool = False, unique: bool = False, indexed: bool = True):
        """(declare-attr attr type [many] [unique] [indexed]) → void.

        Declares an attribute with its type, persisting as db.* datoms.
        Attributes are value-indexed (AVET/VAET) by default so ranges work.
        """
        self.engine.declare_attr(attr, type_name, many, unique, indexed, self.tx)

    def declare_partition(self, name: str) -> int:
        """(declare-partition name) → partition ID.

        Declares a new partition and returns its ID.
        """
        return self.engine.declare_partition(name)

    # ──────────────────────────────────────────────────────────────────────
    # Result
    # ──────────────────────────────────────────────────────────────────────

    def result(self, *vals) -> list:
        """(result val...) → list of values.

        Returns a result list (used for non-streaming queries).
        """
        return list(vals)

    # ──────────────────────────────────────────────────────────────────────
    # Debug
    # ──────────────────────────────────────────────────────────────────────

    def dbg_scanners(self):
        """(dbg-scanners) → void.

        Prints scanner state to stderr for debugging.
        """
        import sys

        for i, sc in enumerate(self.scanners):
            key_len = len(sc.pos.current_active_key) if sc.pos.current_active_key else None
            print(
                f"scanner[{i}] at_end={sc.at_end()} key={key_len}",
                file=sys.stderr,
            )

    def ranges_show(self, ranges) -> str:
        """(ranges-show ranges) → human-readable string.

        Returns a human-readable description of range intervals.
        """
        from .scanner import _ops_to_intervals, _merge_intervals, RANGE_LO_OPEN, RANGE_HI_OPEN

        raw_ops = parse_ranges(ranges)
        if not raw_ops:
            return "(-inf, +inf)"

        all_intervals = _ops_to_intervals(raw_ops[0])
        for branch in raw_ops[1:]:
            all_intervals.extend(_ops_to_intervals(branch))
        merged = _merge_intervals(all_intervals)

        descriptions = []
        for lo, hi, flags in merged:
            lo_str = "-inf" if lo is None else str(lo)
            hi_str = "+inf" if hi is None else str(hi)
            l = "(" if (lo is None or (flags & RANGE_LO_OPEN)) else "["
            r = ")" if (hi is None or (flags & RANGE_HI_OPEN)) else "]"
            descriptions.append(f"{l}{lo_str}, {hi_str}{r}")

        return ", ".join(descriptions)

    # ──────────────────────────────────────────────────────────────────────
    # Internal helpers
    # ──────────────────────────────────────────────────────────────────────

    def _unwrap(self, val):
        """Extract raw value from scanner (type, value) tuple."""
        if val is None:
            return None
        return val[1]

    def _find_scanner(self, handle: int) -> V2Scanner:
        if handle < 0 or handle >= len(self.scanners):
            raise IndexError(f"invalid scanner handle: {handle}")
        return self.scanners[handle]

    def _find_leap_iter(self, handle: int) -> LeapIterator:
        if handle not in self.leap_iters:
            raise IndexError(f"invalid leap-iterator handle: {handle}")
        return self.leap_iters[handle]

    def _resolve_value_attr_type(self, sc: V2Scanner):
        """Resolve the value attribute type for a scanner from its prefix."""
        aid = sc.attr_id_from_prefix_bytes()
        if aid is not None:
            return self.engine.value_type_for(aid)
        # Try from current key
        aid = sc.attr_id_from_key()
        if aid is not None:
            return self.engine.value_type_for(aid)
        return None

    @staticmethod
    def _cmp(a, b) -> int:
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
