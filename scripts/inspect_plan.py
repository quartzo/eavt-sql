#!/usr/bin/env python3
"""Inspect SQL planning: AST → DatalogIR → Explain (disassembly + traces).

Calls spier-sql-parse and spier-datalog directly for AST/DatalogIR.
Uses EAVTEngine.explain() for the plan+codegen stage. Attrs are
auto-declared into a temp :memory: DB (unless --db is given), so the
script works standalone.

Usage:
    uv run python scripts/inspect_plan.py [--db PATH] 'SQL' [params...]

Examples:
    uv run python scripts/inspect_plan.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000
    uv run python scripts/inspect_plan.py 'SELECT d2.person.name WHERE d1.item.score > %1 AND d1.eid = d2.eid' 70
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# ── Spier path setup (same as tests/conftest.py) ─────────────────────
_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
_debug = _root / "target" / "debug"
_so_dir = _release if _release.exists() else _debug

import os

os.environ.setdefault("DYNSPIRE_LIB_DIR", str(_so_dir))
existing = os.environ.get("LD_LIBRARY_PATH", "")
if str(_so_dir) not in existing:
    os.environ["LD_LIBRARY_PATH"] = (
        f"{_so_dir}:{existing}" if existing else str(_so_dir)
    )
sys.path.insert(0, str(_root / "src"))

from eavt_sql._ffi import load_spier
from eavt_sql.engine import EAVTEngine
from eavt_sql.query_codec import encode_values


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

    # 1. Parse SQL → AST (standalone spier, no transactor needed)
    parse_lib = load_spier("spier_sql_parse")
    parse_handle = parse_lib.create_handle({})
    ast_json = parse_handle.parse_json(sql)

    print("=== AST ===")
    print(ast_json)

    # 2. Build DatalogIR (standalone spier, no transactor needed)
    params = [int(p) if p.lstrip("-").isdigit() else p for p in raw_params]
    params_bytes = encode_values(params)
    stmt = parse_handle.parse(sql)

    datalog_lib = load_spier("spier_datalog")
    datalog_handle = datalog_lib.create_handle({})
    ir = datalog_handle.build(stmt, params_bytes)
    dl_str = datalog_handle.to_string(ir)

    print("\n=== DATALOG IR ===")
    print(dl_str)

    # 3. Plan (join order, cost estimates, index selection)
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

    print("\n=== DATALOG NUM IR ===")
    print(num_ir_str)

    print("\n=== PLAN ===")
    print(plan_str)


if __name__ == "__main__":
    main()
