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

from dataclasses import dataclass
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
_SLOT_NAMES = ("e", "a", "v", "t", "added")


@dataclass
class Pattern:
    slots: tuple  # (e, a, v, t, added) — each is Slot
    clause_idx: int


@dataclass
class ClauseConfig:
    """Fixed scanner configuration — one per clause."""
    index: str
    cf: int


@dataclass
class DepthPlan:
    """Logical operation — one level in the binding order."""
    kind: str                             # "bind" | "validate"
    var: str | None                       # variable name for "bind", None for "validate"
    clause_indices: list[int]             # which scanners participate
    pushes: list[list[tuple[str, Any]]]   # pushes per participating scanner
    start_ips: list[int]                  # start position per clause in the index
    ranges: list | None = None
    label: str | None = None              # explain label for "validate"


@dataclass
class QueryPlan:
    clauses: list[ClauseConfig]  # scanner configs (one per clause)
    depths: list[DepthPlan]
    find_vars: list[str]
    patterns: list[Pattern]
    session: Any

    def execute(self):
        return execute(self)

    def explain(self) -> str:
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
    return x


def _is_var(s: Slot) -> bool:
    return isinstance(s, Var)


def _is_const(s: Slot) -> bool:
    return not isinstance(s, (Var, Wildcard))


def _parse_clause(session, clause: tuple, idx: int) -> Pattern:
    resolver = session.engine.resolver
    if len(clause) < 3 or len(clause) > 5:
        raise ValueError(
            f"clause {idx}: expected 3-5 elements (e, a, v[, t[, added]]), "
            f"got {len(clause)}"
        )
    e, a, v = _parse_slot(clause[0]), _parse_slot(clause[1]), _parse_slot(clause[2])
    # Resolve attr string → int EID
    if isinstance(a, str):
        aid = resolver.lookup_attr(a)
        if aid is None:
            raise ValueError(f"clause {idx}: attribute '{a}' not declared")
        a = aid
    t = _parse_slot(clause[3]) if len(clause) >= 4 else _WILD
    added = _parse_slot(clause[4]) if len(clause) >= 5 else _WILD
    return Pattern(slots=(e, a, v, t, added), clause_idx=idx)


# ═══════════════════════════════════════════════════════════════════════════════
# Index feasibility
# ═══════════════════════════════════════════════════════════════════════════════

def _slot_bound_at(s: Slot, bound_vars: set[str]) -> bool:
    """Is this slot bound as a pushable value (const or resolved var)?

    Wildcards return False — they match anything but can't be pushed
    into the scanner's position stack (which is sequential).
    The planner must pick an index where wildcards come AFTER the variable.
    """
    if isinstance(s, Wildcard):
        return False
    if isinstance(s, Var):
        return s.name in bound_vars
    return True


def _slot_index_in_pattern(var_name: str, pattern: Pattern) -> int | None:
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
    slot_idx = _slot_index_in_pattern(var_name, pattern)
    if slot_idx is None:
        return None

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

        if idx_name == "VAET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                vt = resolver.value_type_for(a_slot)
                if vt is None or vt != DB_TYPE_REF:
                    continue
            else:
                continue

        if idx_name == "AVET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                if not resolver.is_indexed(a_slot):
                    continue
            else:
                continue

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


def _find_feasible_index_for_slot(
    pattern: Pattern,
    slot_idx: int,
    bound_vars: set[str],
    resolver,
) -> str | None:
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

        if idx_name == "VAET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                vt = resolver.value_type_for(a_slot)
                if vt is None or vt != DB_TYPE_REF:
                    continue
            else:
                continue

        if idx_name == "AVET" and slot_name in ("e", "a", "v"):
            a_slot = pattern.slots[1]
            if _is_const(a_slot):
                if not resolver.is_indexed(a_slot):
                    continue
            else:
                continue

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


# ═══════════════════════════════════════════════════════════════════════════════
# Validation
# ═══════════════════════════════════════════════════════════════════════════════

def _build_pushes(pattern, vp, pos_order, start_ip=0):
    """Build pushes for positions start_ip to vp (exclusive) in index order."""
    pushes = []
    for ip in range(start_ip, vp):
        pn = pos_order[ip]
        if pn in ("t", "added"):
            continue
        slot_for_pos = _SLOT_NAMES.index(pn)
        s = pattern.slots[slot_for_pos]
        if _is_const(s):
            pushes.append(("const", s))
        elif _is_var(s):
            pushes.append(("var", s.name))
    return pushes


def _find_best_index_for_clause(
    pattern: Pattern,
    find_vars: list[str],
    resolver,
) -> str | None:
    """Find the best index for a clause, considering all variables.

    The index must be feasible for every variable in the clause.
    Returns the index with the most total prefix-bound positions.
    """
    best_index = None
    best_total_prefix = -1

    for idx_name in _INDEXES:
        positions = _INDEX_POSITIONS[idx_name]
        total_prefix = 0
        feasible = True

        # Check each variable in the clause
        for i, s in enumerate(pattern.slots):
            if not _is_var(s):
                continue
            if s.name not in find_vars:
                continue

            slot_name = _SLOT_NAMES[i]
            try:
                vp = positions.index(slot_name)
            except ValueError:
                feasible = False
                break

            # VAET requires REF attr
            if idx_name == "VAET" and slot_name in ("e", "a", "v"):
                a_slot = pattern.slots[1]
                if _is_const(a_slot):
                    vt = resolver.value_type_for(a_slot)
                    if vt is None or vt != DB_TYPE_REF:
                        feasible = False; break
                else:
                    feasible = False; break

            # AVET requires indexed attr
            if idx_name == "AVET" and slot_name in ("e", "a", "v"):
                a_slot = pattern.slots[1]
                if _is_const(a_slot):
                    if not resolver.is_indexed(a_slot):
                        feasible = False; break
                else:
                    feasible = False; break

            # Check all positions before vp are bound (const or var, not wildcard)
            for ip in range(vp):
                pn = positions[ip]
                if pn in ("t", "added"):
                    continue
                slot_for_pos = _SLOT_NAMES.index(pn)
                s_at_pos = pattern.slots[slot_for_pos]
                if isinstance(s_at_pos, Wildcard):
                    feasible = False
                    break
                if _is_const(s_at_pos):
                    total_prefix += 1
                elif _is_var(s_at_pos):
                    total_prefix += 1  # var will be bound by the time we reach this depth

        if feasible and total_prefix > best_total_prefix:
            best_total_prefix = total_prefix
            best_index = idx_name

    return best_index


def _validate_plan(
    find_vars: list[str],
    patterns: list[Pattern],
    ranges: dict[str, list],
    session,
) -> tuple[list[ClauseConfig], list[DepthPlan]]:
    """Validate and build clause configs + depth plans."""
    resolver = session.engine.resolver
    bound_vars: set[str] = set()
    depths: list[DepthPlan] = []

    all_var_names = set()
    for p in patterns:
        for s in p.slots:
            if _is_var(s):
                all_var_names.add(s.name)

    for var_name in find_vars:
        if var_name not in all_var_names:
            raise ValueError(f"variable '?{var_name}' does not appear in any clause")

    find_set = set(find_vars)
    for var_name in all_var_names:
        if var_name not in find_set:
            raise ValueError(
                f"variable '?{var_name}' appears in clauses but not in find. "
                f"All variables must be listed in find in binding order."
            )

    # Step 1: Choose index for each clause (one scanner per clause)
    clause_configs: list[ClauseConfig] = []
    clause_idx_map: dict[int, int] = {}  # pattern.clause_idx → clause_configs index
    for p in patterns:
        index = _find_best_index_for_clause(p, find_vars, resolver)
        if index is None:
            raise ValueError(f"clause {p.clause_idx}: no feasible index")
        cf = _INDEX_CF[index]
        clause_configs.append(ClauseConfig(index=index, cf=cf))
        clause_idx_map[p.clause_idx] = len(clause_configs) - 1

    # Step 2: Build depths (binding order)
    last_vp: dict[int, int] = {}  # clause_idx → last pushed position in index

    for var_name in find_vars:
        var_clauses = []
        for p in patterns:
            for i, s in enumerate(p.slots):
                if _is_var(s) and s.name == var_name:
                    var_clauses.append((p, i))
                    break

        if not var_clauses:
            raise ValueError(f"variable '?{var_name}' not found in any clause")

        clause_indices = []
        pushes_per_clause = []
        start_ips = []
        for p, slot_idx in var_clauses:
            ci = clause_idx_map[p.clause_idx]
            cc = clause_configs[ci]
            pos_order = _INDEX_POSITIONS[cc.index]
            slot_name = _SLOT_NAMES[slot_idx]

            try:
                vp = pos_order.index(slot_name)
            except ValueError:
                raise ValueError(
                    f"clause {p.clause_idx}: variable '?{var_name}' at slot "
                    f"'{slot_name}' not in index {cc.index}"
                )

            # Check feasibility: all positions before vp must be bound
            for ip in range(vp):
                pn = pos_order[ip]
                if pn in ("t", "added"):
                    continue
                slot_for_pos = _SLOT_NAMES.index(pn)
                s_at_pos = p.slots[slot_for_pos]
                if not _slot_bound_at(s_at_pos, bound_vars):
                    raise ValueError(
                        f"clause {p.clause_idx}: position '{pn}' before "
                        f"'?{var_name}' in {cc.index} is not bound"
                    )

            prev_vp = last_vp.get(p.clause_idx, -1)
            start_ip = prev_vp + 1 if prev_vp >= 0 else 0
            pushes = _build_pushes(p, vp, pos_order, start_ip)

            clause_indices.append(ci)
            pushes_per_clause.append(pushes)
            start_ips.append(start_ip)

            if vp > last_vp.get(p.clause_idx, -1):
                last_vp[p.clause_idx] = vp

        bound_vars.add(var_name)
        depths.append(DepthPlan(
            kind="bind",
            var=var_name,
            clause_indices=clause_indices,
            pushes=pushes_per_clause,
            start_ips=start_ips,
            ranges=ranges.get(var_name),
        ))

        # Detect trailing constants/variables → validation depths
        for p, slot_idx in var_clauses:
            var_occurrences: dict[str, list[int]] = {}
            for i, s in enumerate(p.slots):
                if _is_var(s):
                    var_occurrences.setdefault(s.name, []).append(i)

            ci = clause_idx_map[p.clause_idx]
            cc = clause_configs[ci]
            main_pos_order = _INDEX_POSITIONS[cc.index]
            main_vp = main_pos_order.index(_SLOT_NAMES[slot_idx])

            for i, s in enumerate(p.slots):
                if i == slot_idx:
                    continue

                pn = _SLOT_NAMES[i]
                range_val = None
                is_trailing = False

                if _is_const(s):
                    try:
                        ip = main_pos_order.index(pn)
                    except ValueError:
                        continue
                    if ip <= main_vp:
                        continue
                    range_val = s
                    is_trailing = True
                elif _is_var(s):
                    if len(var_occurrences.get(s.name, [])) > 1:
                        range_val = Var(s.name)
                        is_trailing = True

                if not is_trailing:
                    continue

                # Validation scanner uses the same index as the clause
                val_ci = len(clause_configs)
                clause_configs.append(ClauseConfig(index=cc.index, cf=cc.cf))

                val_ip = main_pos_order.index(pn)
                val_pushes = _build_pushes(p, val_ip, main_pos_order, 0)

                label = f"[clause {p.clause_idx}, validate {pn}="
                if isinstance(range_val, Var):
                    label += f"?{range_val.name}"
                else:
                    label += repr(range_val)
                label += "]"

                depths.append(DepthPlan(
                    kind="validate",
                    var=None,
                    clause_indices=[val_ci],
                    pushes=[val_pushes],
                    start_ips=[0],
                    ranges=[["=", range_val]],
                    label=label,
                ))

    return clause_configs, depths


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
    if ranges is None:
        ranges = {}
    if given is None:
        given = {}

    find_vars = []
    for f in find:
        if not isinstance(f, str) or not f.startswith("?"):
            raise ValueError(f"find entries must start with '?', got: {f!r}")
        find_vars.append(f[1:])

    patterns = [_parse_clause(session, c, i) for i, c in enumerate(where)]

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

    parsed_ranges = {}
    op_set = {"=", "!=", ">", ">=", "<", "<=", "in"}
    for k, v in ranges.items():
        var_name = k[1:] if k.startswith("?") else k
        if isinstance(v, tuple) and len(v) >= 2:
            if isinstance(v[0], str) and v[0] in op_set:
                if len(v) == 2:
                    parsed_ranges[var_name] = [list(v)]
                else:
                    branches = []
                    for i in range(0, len(v), 2):
                        branches.append([v[i], v[i + 1]])
                    parsed_ranges[var_name] = [["and"] + branches]
            else:
                parsed_ranges[var_name] = [list(v)]
        elif isinstance(v, list):
            parsed_ranges[var_name] = v
        else:
            parsed_ranges[var_name] = [[v]]

    clause_configs, depths = _validate_plan(find_vars, patterns, parsed_ranges, session)

    return QueryPlan(
        clauses=clause_configs,
        depths=depths,
        find_vars=find_vars,
        patterns=patterns,
        session=session,
    )


def explain(plan: QueryPlan) -> str:
    resolver = plan.session.engine.resolver
    lines = []
    lines.append("=== Query Plan ===")
    lines.append(f"find: {' '.join('?' + v for v in plan.find_vars)}")
    lines.append("")

    for i, p in enumerate(plan.patterns):
        e, a, v, t, added = p.slots
        def _fmt(s):
            if isinstance(s, Var): return f"?{s.name}"
            if isinstance(s, Wildcard): return "_"
            if isinstance(s, int):
                name = resolver.attr_name(s)
                return name if name != str(s) else str(s)
            return repr(s)
        lines.append(f"  [{i}] ({_fmt(e)}, {_fmt(a)}, {_fmt(v)}, {_fmt(t)}, {_fmt(added)})")

    lines.append("")
    lines.append("scanners:")
    for i, cc in enumerate(plan.clauses):
        lines.append(f"  [{i}] {cc.index}[{cc.cf}]")

    lines.append("")
    lines.append("binding order:")
    for depth in plan.depths:
        parts = []
        for ci, pushes in zip(depth.clause_indices, depth.pushes):
            cc = plan.clauses[ci]
            push_strs = []
            for kind, val in pushes:
                push_strs.append(f"{'const' if kind == 'const' else '?'+val}={val if kind == 'const' else val}")
            push_desc = " ".join(push_strs) if push_strs else "(no pushes)"
            parts.append(f"[{ci}]{cc.index} {push_desc}")
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
    if isinstance(expr, list):
        return [_resolve_range(e, bindings) for e in expr]
    if isinstance(expr, Var):
        return bindings[expr.name]
    return expr


def _push_scanner(session, h, kind, val, bindings, pos_name):
    """Push a value onto a scanner. Set value_attr_type if pushing an aid at 'a'."""
    if kind == "var":
        val = bindings[val]
    session.scanner_push(h, val)
    if kind == "const" and isinstance(val, int) and pos_name == "a":
        sc = session._find_scanner(h)
        sc.set_value_attr_type(session.engine.value_type_for(val))
    return val


def execute(plan: QueryPlan):
    """Execute the query, yielding tuples of find_vars values."""
    if not plan.depths:
        return
    session = plan.session
    # Open scanners once — one per clause config
    handles = [session.scanner_open(cc.index) for cc in plan.clauses]
    yield from _exec_recurse(0, plan, session, {}, handles)


def _exec_recurse(depth_idx: int, plan: QueryPlan, session, bindings: dict,
                  handles: list[int]):
    if depth_idx >= len(plan.depths):
        yield tuple(bindings[v] for v in plan.find_vars)
        return

    depth = plan.depths[depth_idx]
    participating = [handles[i] for i in depth.clause_indices]

    # Push values onto participating scanners
    push_counts = []
    for h, pushes, start_ip in zip(participating, depth.pushes, depth.start_ips):
        cc = plan.clauses[depth.clause_indices[participating.index(h)]]
        pos_order = _INDEX_POSITIONS[cc.index]
        for pi, (kind, val) in enumerate(pushes):
            pos_name = pos_order[start_ip + pi]
            _push_scanner(session, h, kind, val, bindings, pos_name)
        push_counts.append(len(pushes))

    # Set ranges (resolved via bindings)
    if depth.ranges:
        for h in participating:
            resolved = _resolve_range(depth.ranges, bindings)
            flat = session.ranges_create(resolved)
            if flat:
                session.scanner_set_ranges(h, flat)

    # Iterate
    if len(participating) == 1:
        iter_h = session.scanner_iterate_init(participating[0])
    else:
        iter_h = session.scanner_iterate_init(*participating)

    while True:
        val = session.scanner_iterate_next(iter_h)
        if val is None:
            break

        if depth.kind == "bind":
            bindings[depth.var] = val
            for h in participating:
                session.scanner_push(h, val)

        yield from _exec_recurse(depth_idx + 1, plan, session, bindings, handles)

        if depth.kind == "bind":
            for h in participating:
                session.scanner_pop(h)

    # Pop the pushes for this depth (both bind and validate)
    for h, count in zip(participating, push_counts):
        for _ in range(count):
            session.scanner_pop(h)
