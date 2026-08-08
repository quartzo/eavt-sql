"""query.py — Datalog query API over the scanner infrastructure.

Usage:
    q = prepare(
        session=sess,
        find=["?eid", "?name", "?age"],
        where=[
            ("?eid", "person.name", "?name"),
            ("?eid", "person.age",  "?age"),
        ],
        ranges={"?age": (">=", 18)},
    )
    for eid, name, age in q.execute():
        print(eid, name, age)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .types import DB_TYPE_REF


# ═══════════════════════════════════════════════════════════════════════════════
# Types
# ═══════════════════════════════════════════════════════════════════════════════

@dataclass(frozen=True)
class Var:
    name: str  # without "?" prefix


@dataclass(frozen=True)
class Wildcard:
    pass


_WILD = Wildcard()

Slot = Var | Wildcard | Any  # Any = constant (int, str, float, bytes, bool)

_INDEXES = ("EAVT", "AEVT", "AVET", "VAET")
_INDEX_POSITIONS = {
    "EAVT": ("e", "a", "v", "t", "added"),
    "AEVT": ("a", "e", "v", "t", "added"),
    "AVET": ("a", "v", "e", "t", "added"),
    "VAET": ("v", "a", "e", "t", "added"),
}
_INDEX_CF = {"EAVT": 0, "AEVT": 1, "AVET": 2, "VAET": 3}


@dataclass
class Pattern:
    slots: tuple  # (e, a, v, t, added) — each is Slot
    clause_idx: int


@dataclass
class ClausePlan:
    clause_idx: int
    index: str
    cf: int
    pushes: list[tuple[str, Any]]  # [("const"|"var", value_or_name)] in index order
    var_position: str               # "e"|"a"|"v"|"t"|"added" — position being iterated


@dataclass
class DepthPlan:
    kind: str  # "bind" | "validate"
    var: str | None  # variable name for "bind", None for "validate"
    clauses: list[ClausePlan]
    ranges: list | None = None
    label: str | None = None  # explain label for "validate" depths


@dataclass
class QueryPlan:
    depths: list[DepthPlan]
    find_vars: list[str]
    patterns: list[Pattern]
    session: Any  # QuerySession

    def execute(self):
        """Execute the query, yielding tuples of find_vars values."""
        return execute(self)

    def explain(self) -> str:
        """Return a human-readable description of the query plan."""
        return explain(self)


# ═══════════════════════════════════════════════════════════════════════════════
# Slot helpers
# ═══════════════════════════════════════════════════════════════════════════════

def _parse_slot(x) -> Slot:
    if isinstance(x, str):
        if x.startswith("?"):
            return Var(x[1:])
        if x == "_":
            return _WILD
    return x  # constant


def _is_var(s: Slot) -> bool:
    return isinstance(s, Var)


def _is_const(s: Slot) -> bool:
    return not isinstance(s, (Var, Wildcard))


def _parse_clause(clause: tuple, idx: int) -> Pattern:
    if len(clause) < 3 or len(clause) > 5:
        raise ValueError(
            f"clause {idx}: expected 3-5 elements (e, a, v[, t[, added]]), "
            f"got {len(clause)}"
        )
    e, a, v = _parse_slot(clause[0]), _parse_slot(clause[1]), _parse_slot(clause[2])
    t = _parse_slot(clause[3]) if len(clause) >= 4 else _WILD
    added = _parse_slot(clause[4]) if len(clause) >= 5 else _WILD
    return Pattern(slots=(e, a, v, t, added), clause_idx=idx)


# ═══════════════════════════════════════════════════════════════════════════════
# Index feasibility
# ═══════════════════════════════════════════════════════════════════════════════

def _slot_bound_at(s: Slot, bound_vars: set[str]) -> bool:
    """Is this slot bound as a pushable value (const or resolved var)?

    Wildcards return False — they match anything but can't be pushed
    into the scanner's position stack, so they block feasibility.
    """
    if isinstance(s, Wildcard):
        return False
    if isinstance(s, Var):
        return s.name in bound_vars
    return True  # constant


_SLOT_NAMES = ("e", "a", "v", "t", "added")


def _slot_index_in_pattern(var_name: str, pattern: Pattern) -> int | None:
    """Return the pattern slot index (0-4) for a variable, or None."""
    for i, s in enumerate(pattern.slots):
        if _is_var(s) and s.name == var_name:
            return i
    return None


def _find_feasible_index(
    pattern: Pattern,
    var_name: str,
    bound_vars: set[str],
    resolver,
) -> str | None:
    """Find the best index for binding var_name in this pattern.

    Pattern slots are always in EAVT order: (e, a, v, t, added).
    Index positions vary: EAVT=(e,a,v,t,added), AEVT=(a,e,v,t,added), etc.

    Returns index name or None if no index is feasible.
    """
    slot_idx = _slot_index_in_pattern(var_name, pattern)
    if slot_idx is None:
        return None

    slot_name = _SLOT_NAMES[slot_idx]  # "e", "a", "v", "t", or "added"
    if slot_name not in ("e", "a", "v", "t", "added"):
        return None

    best_index = None
    best_prefix_len = -1

    for idx_name in _INDEXES:
        positions = _INDEX_POSITIONS[idx_name]

        # Find the index position of this slot
        try:
            vp = positions.index(slot_name)
        except ValueError:
            continue

        # VAET requires REF attr (only relevant for e/a/v positions)
        if idx_name == "VAET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                aid = resolver.lookup_attr(str(a_slot))
                if aid is None:
                    continue
                vt = resolver.value_type_for(aid)
                if vt != DB_TYPE_REF:
                    continue
            else:
                continue

        # AVET requires indexed attr (only relevant for e/a/v positions)
        if idx_name == "AVET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                aid = resolver.lookup_attr(str(a_slot))
                if aid is None:
                    continue
                if not resolver.is_indexed(aid):
                    continue
            else:
                continue

        # Check all index positions before vp are bound
        all_before_bound = True
        for ip in range(vp):
            pos_name = positions[ip]
            if pos_name in ("t", "added"):
                continue
            # Map index position back to pattern slot
            slot_for_pos = _SLOT_NAMES.index(pos_name)
            if not _slot_bound_at(pattern.slots[slot_for_pos], bound_vars):
                all_before_bound = False
                break

        if not all_before_bound:
            continue

        # Count how many e/a/v positions before vp are bound
        prefix_len = sum(
            1 for ip in range(vp)
            if positions[ip] in ("e", "a", "v")
            and _slot_bound_at(pattern.slots[_SLOT_NAMES.index(positions[ip])], bound_vars)
        )

        if prefix_len > best_prefix_len:
            best_prefix_len = prefix_len
            best_index = idx_name

    return best_index


# ═══════════════════════════════════════════════════════════════════════════════
# Validation
# ═══════════════════════════════════════════════════════════════════════════════

def _find_feasible_index_for_slot(
    pattern: Pattern,
    slot_idx: int,
    bound_vars: set[str],
    resolver,
) -> str | None:
    """Find the best index for a specific slot in the pattern.

    Like _find_feasible_index but takes a slot index instead of a variable name.
    Used for trailing slots where we need the best index for that specific position.
    """
    slot_name = _SLOT_NAMES[slot_idx]
    if slot_name not in ("e", "a", "v", "t", "added"):
        return None

    best_index = None
    best_prefix_len = -1

    for idx_name in _INDEXES:
        positions = _INDEX_POSITIONS[idx_name]
        try:
            vp = positions.index(slot_name)
        except ValueError:
            continue

        # VAET requires REF attr (only for e/a/v positions)
        if idx_name == "VAET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                aid = resolver.lookup_attr(str(a_slot))
                if aid is None:
                    continue
                vt = resolver.value_type_for(aid)
                if vt != DB_TYPE_REF:
                    continue
            else:
                continue

        # AVET requires indexed attr (only for e/a/v positions)
        if idx_name == "AVET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                aid = resolver.lookup_attr(str(a_slot))
                if aid is None:
                    continue
                if not resolver.is_indexed(aid):
                    continue
            else:
                continue

        # Check all positions before vp are bound
        all_before_bound = True
        for ip in range(vp):
            pos_name = positions[ip]
            if pos_name in ("t", "added"):
                continue
            slot_for_pos = _SLOT_NAMES.index(pos_name)
            if not _slot_bound_at(pattern.slots[slot_for_pos], bound_vars):
                all_before_bound = False
                break

        if not all_before_bound:
            continue

        prefix_len = sum(
            1 for ip in range(vp)
            if positions[ip] in ("e", "a", "v")
            and _slot_bound_at(pattern.slots[_SLOT_NAMES.index(positions[ip])], bound_vars)
        )

        if prefix_len > best_prefix_len:
            best_prefix_len = prefix_len
            best_index = idx_name

    return best_index


def _validate_plan(
    find_vars: list[str],
    patterns: list[Pattern],
    ranges: dict[str, list],
    session,
) -> list[DepthPlan]:
    """Validate that each variable can be bound in the given order."""
    resolver = session.engine.resolver
    bound_vars: set[str] = set()
    depths: list[DepthPlan] = []

    # Collect all variable names from clauses
    all_var_names = set()
    for p in patterns:
        for s in p.slots:
            if _is_var(s):
                all_var_names.add(s.name)

    for var_name in find_vars:
        if var_name not in all_var_names:
            raise ValueError(f"variable '?{var_name}' does not appear in any clause")

    # Validate: all variables in clauses must be in find
    find_set = set(find_vars)
    for var_name in all_var_names:
        if var_name not in find_set:
            raise ValueError(
                f"variable '?{var_name}' appears in clauses but not in find. "
                f"All variables must be listed in find in binding order."
            )

    for var_name in find_vars:
        var_clauses = []
        for p in patterns:
            for i, s in enumerate(p.slots):
                if _is_var(s) and s.name == var_name:
                    var_clauses.append((p, i))
                    break

        if not var_clauses:
            raise ValueError(f"variable '?{var_name}' not found in any clause")

        clause_plans = []
        for p, slot_idx in var_clauses:
            index = _find_feasible_index(p, var_name, bound_vars, resolver)
            if index is None:
                reasons = []
                for idx_name in _INDEXES:
                    pos_list = _INDEX_POSITIONS[idx_name]
                    slot_name = _SLOT_NAMES[slot_idx]
                    try:
                        vp = pos_list.index(slot_name)
                    except ValueError:
                        continue
                    unbound = []
                    for ip in range(vp):
                        pn = pos_list[ip]
                        if pn in ("t", "added"):
                            continue
                        slot_for_pos = _SLOT_NAMES.index(pn)
                        if not _slot_bound_at(p.slots[slot_for_pos], bound_vars):
                            unbound.append(f"'{pn}'")
                    if unbound:
                        reasons.append(f"{idx_name}: needs {', '.join(unbound)} bound")
                    else:
                        reasons.append(f"{idx_name}: attr type incompatible")
                detail = "; ".join(reasons) if reasons else "no compatible index"
                raise ValueError(
                    f"clause {p.clause_idx}: no feasible index for "
                    f"'?{var_name}' ({detail})"
                )

            cf = _INDEX_CF[index]
            pos_order = _INDEX_POSITIONS[index]
            slot_name = _SLOT_NAMES[slot_idx]
            var_pos_in_index = slot_name

            # Build pushes list in index order for positions before the variable
            pushes = []
            vp = pos_order.index(var_pos_in_index)
            for ip in range(vp):
                pn = pos_order[ip]
                if pn in ("t", "added"):
                    continue
                slot_for_pos = _SLOT_NAMES.index(pn)
                s = p.slots[slot_for_pos]
                if _is_const(s):
                    val = s
                    if pn == "a" and isinstance(val, str):
                        aid = resolver.lookup_attr(val)
                        if aid is None:
                            raise ValueError(
                                f"clause {p.clause_idx}: attribute '{val}' not declared"
                            )
                        val = aid
                    pushes.append(("const", val))
                elif _is_var(s):
                    pushes.append(("var", s.name))

            clause_plans.append(ClausePlan(
                clause_idx=p.clause_idx,
                index=index,
                cf=cf,
                pushes=pushes,
                var_position=var_pos_in_index,
            ))

        bound_vars.add(var_name)
        depths.append(DepthPlan(
            kind="bind",
            var=var_name,
            clauses=clause_plans,
            ranges=ranges.get(var_name),
        ))

        # Detect trailing constants/variables in each clause → validation depths
        # Constants: only at positions AFTER the variable in the index
        # Repeated variables: ALWAYS trailing (regardless of index position)
        for p, slot_idx in var_clauses:
            # Count occurrences of each variable in this clause
            var_occurrences: dict[str, list[int]] = {}
            for i, s in enumerate(p.slots):
                if _is_var(s):
                    var_occurrences.setdefault(s.name, []).append(i)

            # Check ALL slots in the clause (except the main variable's slot)
            for i, s in enumerate(p.slots):
                if i == slot_idx:
                    continue

                pn = _SLOT_NAMES[i]
                range_val = None
                is_trailing = False

                if _is_const(s):
                    # Only trailing if there's an index where this position comes AFTER the main var
                    # Check using the main var's index: is this position after vp?
                    main_index = _find_feasible_index(p, var_name, bound_vars, resolver)
                    if main_index is None:
                        continue
                    main_pos_order = _INDEX_POSITIONS[main_index]
                    main_vp = main_pos_order.index(_SLOT_NAMES[slot_idx])
                    try:
                        ip = main_pos_order.index(pn)
                    except ValueError:
                        continue
                    if ip <= main_vp:
                        continue
                    range_val = s
                    if pn == "a" and isinstance(range_val, str):
                        aid = resolver.lookup_attr(range_val)
                        if aid is not None:
                            range_val = aid
                    is_trailing = True
                elif _is_var(s):
                    # Trailing if this variable appears MORE than once in the clause
                    if len(var_occurrences.get(s.name, [])) > 1:
                        range_val = Var(s.name)
                        is_trailing = True

                if not is_trailing:
                    continue

                # Find the best index for THIS trailing slot (not the main var's index)
                val_index = _find_feasible_index_for_slot(p, i, bound_vars, resolver)
                if val_index is None:
                    continue

                val_cf = _INDEX_CF[val_index]
                val_pos_order = _INDEX_POSITIONS[val_index]
                val_ip = val_pos_order.index(pn)

                # Build pushes for positions before val_ip in the index
                val_pushes = []
                for jp in range(val_ip):
                    jpn = val_pos_order[jp]
                    if jpn in ("t", "added"):
                        continue
                    jslot_for_pos = _SLOT_NAMES.index(jpn)
                    js = p.slots[jslot_for_pos]
                    if _is_const(js):
                        jval = js
                        if jpn == "a" and isinstance(jval, str):
                            jaid = resolver.lookup_attr(jval)
                            if jaid is not None:
                                jval = jaid
                        val_pushes.append(("const", jval))
                    elif _is_var(js):
                        val_pushes.append(("var", js.name))

                label = f"[clause {p.clause_idx}, validate {pn}="
                if isinstance(range_val, Var):
                    label += f"?{range_val.name}"
                else:
                    label += repr(range_val)
                label += "]"

                val_clause = ClausePlan(
                    clause_idx=p.clause_idx,
                    index=val_index,
                    cf=val_cf,
                    pushes=val_pushes,
                    var_position=pn,
                )

                val_range = [["=", range_val]]

                depths.append(DepthPlan(
                    kind="validate",
                    var=None,
                    clauses=[val_clause],
                    ranges=val_range,
                    label=label,
                ))

    return depths


# ═══════════════════════════════════════════════════════════════════════════════
# prepare / explain
# ═══════════════════════════════════════════════════════════════════════════════

def prepare(
    session,
    find: list[str],
    where: list[tuple],
    ranges: dict[str, tuple | list] | None = None,
    given: dict[str, Any] | None = None,
) -> QueryPlan:
    """Prepare a datalog query plan.

    Args:
        session: QuerySession instance.
        find: Output variables in binding order, e.g. ["?eid", "?name"].
        where: Clauses as tuples of 3-5 elements: (e, a, v[, t[, added]]).
        ranges: Range filters per variable, e.g. {"?age": (">=", 18, "<=", 65)}.
        given: Bind variables to constants (for ambiguous string constants).

    Returns:
        QueryPlan ready for execution via plan.execute().
    """
    if ranges is None:
        ranges = {}
    if given is None:
        given = {}

    find_vars = []
    for f in find:
        if not isinstance(f, str) or not f.startswith("?"):
            raise ValueError(f"find entries must start with '?', got: {f!r}")
        find_vars.append(f[1:])

    patterns = [_parse_clause(c, i) for i, c in enumerate(where)]

    # Apply given
    if given:
        given_parsed = {}
        for k, v in given.items():
            key = k[1:] if isinstance(k, str) and k.startswith("?") else k
            given_parsed[key] = v

        new_patterns = []
        for p in patterns:
            new_slots = tuple(
                given_parsed[s.name] if isinstance(s, Var) and s.name in given_parsed else s
                for s in p.slots
            )
            new_patterns.append(Pattern(slots=new_slots, clause_idx=p.clause_idx))
        patterns = new_patterns

    # Parse ranges — convert to ranges_create expression tree format
    # Input: {"?price": (">=", 10, "<=", 20)} or {"?price": ['and', ['>=', 10], ['<=', 20]]}
    # Output: {"price": [['and', ['>=', 10], ['<=', 20]]]}
    parsed_ranges = {}
    op_set = {"=", "!=", ">", ">=", "<", "<=", "in"}
    for k, v in ranges.items():
        var_name = k[1:] if k.startswith("?") else k
        if isinstance(v, tuple) and len(v) >= 2:
            # Flat tuple: (">=", 10, "<=", 20) → ['and', ['>=', 10], ['<=', 20]]
            if isinstance(v[0], str) and v[0] in op_set:
                if len(v) == 2:
                    # Single op: (">=", 10) → ['>=', 10]
                    parsed_ranges[var_name] = [list(v)]
                else:
                    # Multiple ops: (">=", 10, "<=", 20) → ['and', ['>=', 10], ['<=', 20]]
                    branches = []
                    for i in range(0, len(v), 2):
                        branches.append([v[i], v[i + 1]])
                    expr = ["and"] + branches
                    parsed_ranges[var_name] = [expr]
            else:
                parsed_ranges[var_name] = [list(v)]
        elif isinstance(v, list):
            parsed_ranges[var_name] = v
        else:
            parsed_ranges[var_name] = [[v]]

    depths = _validate_plan(find_vars, patterns, parsed_ranges, session)

    return QueryPlan(
        depths=depths,
        find_vars=find_vars,
        patterns=patterns,
        session=session,
    )


def explain(plan: QueryPlan) -> str:
    """Return a human-readable description of the query plan."""
    lines = []
    lines.append("=== Query Plan ===")
    lines.append(f"find: {' '.join('?' + v for v in plan.find_vars)}")
    lines.append("")

    for i, p in enumerate(plan.patterns):
        e, a, v, t, added = p.slots
        def _fmt(s):
            if isinstance(s, Var): return f"?{s.name}"
            if isinstance(s, Wildcard): return "_"
            return repr(s)
        lines.append(f"  [{i}] ({_fmt(e)}, {_fmt(a)}, {_fmt(v)}, {_fmt(t)}, {_fmt(added)})")

    lines.append("")
    lines.append("binding order:")
    for depth in plan.depths:
        parts = []
        for cp in depth.clauses:
            push_strs = []
            for kind, val in cp.pushes:
                push_strs.append(f"{'const' if kind == 'const' else '?'+val}={val if kind == 'const' else val}")
            push_desc = " ".join(push_strs) if push_strs else "(no pushes)"
            parts.append(f"{cp.index}[{cp.cf}] {push_desc}")
        ranges_str = f"  ranges={depth.ranges}" if depth.ranges else ""
        if depth.kind == "validate":
            lines.append(f"  {depth.label}: {'; '.join(parts)}{ranges_str}")
        else:
            lines.append(f"  ?{depth.var}: {'; '.join(parts)}{ranges_str}")

    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════════════════
# execute
# ═══════════════════════════════════════════════════════════════════════════════

def _resolve_range(expr, bindings: dict):
    """Resolve Var references in range expressions via bindings."""
    if isinstance(expr, list):
        return [_resolve_range(e, bindings) for e in expr]
    if isinstance(expr, Var):
        return bindings[expr.name]
    return expr


def _open_and_push(depth_plan: DepthPlan, session, bindings: dict) -> list[int]:
    """Open scanners for a depth, push constants and bound vars, set ranges."""
    handles = []
    for cp in depth_plan.clauses:
        h = session.scanner_open(cp.index)

        # Push in index order (pre-computed at plan time)
        for kind, val in cp.pushes:
            if kind == "var":
                val = bindings[val]
            session.scanner_push(h, val)

        # Set value attr type for "v" position
        if cp.var_position == "v":
            for kind, val in cp.pushes:
                if kind == "const":
                    aid = val if isinstance(val, int) else session.intern_a(str(val))
                    if aid is not None:
                        sc = session._find_scanner(h)
                        sc.set_value_attr_type(session.engine.value_type_for(aid))
                    break

        # Set ranges (resolve Var references via bindings)
        if depth_plan.ranges:
            for range_expr in depth_plan.ranges:
                resolved = _resolve_range(range_expr, bindings)
                flat = session.ranges_create(resolved)
                if flat:
                    session.scanner_set_ranges(h, flat)

        handles.append(h)
    return handles


def execute(plan: QueryPlan):
    """Execute the query plan, yielding tuples of find_vars values."""
    if not plan.depths:
        return
    yield from _exec_recurse(0, plan, plan.session, {})


def _exec_recurse(depth_idx: int, plan: QueryPlan, session, bindings: dict):
    if depth_idx >= len(plan.depths):
        yield tuple(bindings[v] for v in plan.find_vars)
        return

    depth = plan.depths[depth_idx]
    handles = _open_and_push(depth, session, bindings)

    if len(handles) == 1:
        iter_h = session.scanner_iterate_init(handles[0])
    else:
        iter_h = session.scanner_iterate_init(*handles)

    while True:
        val = session.scanner_iterate_next(iter_h)
        if val is None:
            break

        if depth.kind == "bind":
            bindings[depth.var] = val
            for h in handles:
                session.scanner_push(h, val)

        yield from _exec_recurse(depth_idx + 1, plan, session, bindings)

        if depth.kind == "bind":
            for h in handles:
                session.scanner_pop(h)
