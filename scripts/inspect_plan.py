#!/usr/bin/env python3
"""Inspect SQL planning: AST → Explain (resolved IR + plan traces + bytecode).

Uses spier_sql_parse_py directly for AST, then EAVTEngine for plan/codegen.
Attrs are auto-declared into a temp :memory: DB (unless --db is given), so
the script works standalone.

Usage:
    uv run python scripts/inspect_plan.py [--db PATH] 'SQL' [params...]

Examples:
    uv run python scripts/inspect_plan.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000
    uv run python scripts/inspect_plan.py 'SELECT d2.person.name WHERE d1.item.score > %1 AND d1.eid = d2.eid' 70
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# ── Path setup (same as tests/conftest.py) ─────────────────────────
_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
_debug = _root / "target" / "debug"
_so_dir = _release if _release.exists() else _debug

existing = os.environ.get("LD_LIBRARY_PATH", "")
if str(_so_dir) not in existing:
    os.environ["LD_LIBRARY_PATH"] = (
        f"{_so_dir}:{existing}" if existing else str(_so_dir)
    )
sys.path.insert(0, str(_root / "src"))

import spier_sql_parse_py
from eavt_sql.engine import EAVTEngine


def extract_attr_names(ast: dict) -> list[str]:
    """Extract unique attribute names from an AST (fields like 'company.name')."""
    seen: list[str] = []

    def add(name: str) -> None:
        if name not in seen:
            seen.append(name)

    def walk(obj: object) -> None:
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k == "field" and isinstance(v, str) and "." in v:
                    add(v)
                else:
                    walk(v)
        elif isinstance(obj, list):
            for item in obj:
                walk(item)

    walk(ast)
    return seen


def main() -> None:
    args: list[str] = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    db_path = ":memory:"
    if args and args[0] == "--db":
        if len(args) < 2:
            print("error: --db requires a path", file=sys.stderr)
            sys.exit(1)
        db_path = args[1]
        args = args[2:]

    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    sql = args[0]
    raw_params = args[1:]
    params = [int(p) if p.lstrip("-").isdigit() else p for p in raw_params]

    # 1. Parse SQL → AST
    parser = spier_sql_parse_py.SqlParser()
    ast_json = parser.parse_json(sql)

    print("=== AST ===")
    print(ast_json)

    # 2. Plan (join order, cost estimates, index selection)
    #    For :memory: DBs, auto-declare attrs found in the query so
    #    schema resolution succeeds. For --db, assume schema exists.
    engine = EAVTEngine(db_path)
    if db_path == ":memory:":
        ast_obj = json.loads(ast_json)
        for attr_name in extract_attr_names(ast_obj):
            try:
                list(engine.sql(f"ATTRIBUTE {attr_name} STRING ONE"))
            except Exception:
                pass  # attr may already exist or type mismatch — skip

    # 3. Resolved IR + plan traces
    if raw_params:
        plan_out = engine.explain_plan(sql, *params)
    else:
        plan_out = engine.explain_plan(sql)

    # explain_plan returns resolved IR (DatalogNumIR) + plan traces.
    # Split: resolved IR ends at the first line starting with '[' (plan trace).
    lines = plan_out.split("\n")
    split_idx = next(
        (i for i, ln in enumerate(lines) if ln.strip().startswith("[")),
        len(lines),
    )
    num_ir_str = "\n".join(lines[:split_idx]).strip()
    plan_str = "\n".join(lines[split_idx:]).strip()

    print("\n=== DATALOG NUM IR (resolved) ===")
    print(num_ir_str)

    print("\n=== PLAN ===")
    print(plan_str)

    # 4. Bytecode disassembly
    if raw_params:
        explain_out = engine.explain(sql, *params)
    else:
        explain_out = engine.explain(sql)

    # explain returns plan traces + bytecode disassembly.
    # The disassembly starts at the first all-caps opcode line.
    bc_lines = explain_out.split("\n")
    bc_start = next(
        (i for i, ln in enumerate(bc_lines) if ln.strip()[:3].isdigit()),
        len(bc_lines),
    )
    bytecode_str = "\n".join(bc_lines[bc_start:]).strip()

    if bytecode_str:
        print("\n=== BYTECODE ===")
        print(bytecode_str)

    engine.close()


if __name__ == "__main__":
    main()
