#!/usr/bin/env python3
"""Inspect SQL compilation: shows the Datalog IR and Query Plan.

Usage:
    uv run python scripts/inspect_plan.py 'SQL' [params...] [--db PATH]

Examples:
    uv run python scripts/inspect_plan.py 'SELECT d2.person.name WHERE d1.eid = 1000 AND d1.company.partner = d2.eid'
    uv run python scripts/inspect_plan.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000
    uv run python scripts/inspect_plan.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000 --db /path/to/db
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# ── Spier path setup (same as tests/conftest.py) ─────────────────────
_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
_debug = _root / "target" / "debug"
_so_dir = _release if _release.exists() else _debug

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


def show_datalog(sql: str, params: list) -> None:
    """Parse SQL → AST → Datalog IR (via spier-sql-parse + spier-datalog).

    Accepts ``%N`` parameter placeholders — values are passed through to
    spier-datalog's ``build()``.
    """
    parse_lib = load_spier("spier_sql_parse")
    parse_handle = parse_lib.create_handle({})
    ast_json = parse_handle.parse_json(sql)

    print("=== AST ===")
    print(ast_json)

    try:
        datalog_lib = load_spier("spier_datalog")
        datalog_handle = datalog_lib.create_handle({})
        stmt = parse_handle.parse(sql)
        params_bytes = encode_values(
            [int(p) if p.lstrip("-").isdigit() else p for p in params]
        )
        ir = datalog_handle.build(stmt, params_bytes)
        dl_str = datalog_handle.to_string(ir)

        print("\n=== DATALOG IR ===")
        print(dl_str)
    except RuntimeError as e:
        print(f"\n=== DATALOG IR ===\n(skipped: {e})")


def show_plan(sql: str, params: list, db_path: str) -> None:
    """Show plan traces + bytecode via EAVTEngine.explain().

    The planner needs a transactor for cost estimation (index sizes, attr
    lookups). For ``:memory:`` with no declared schema, traces show blind
    estimates but join ordering and index selection are still visible.
    """
    engine = EAVTEngine(db_path)
    explanation = engine.explain(sql, *params)

    print("\n=== PLAN ===")
    print(explanation)


def main() -> None:
    db_path = ":memory:"
    args: list[str] = []
    i = 1
    while i < len(sys.argv):
        a = sys.argv[i]
        if a == "--db":
            i += 1
            db_path = sys.argv[i]
        elif a.startswith("--db="):
            db_path = a.split("=", 1)[1]
        else:
            args.append(a)
        i += 1

    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    sql = args[0]
    params = args[1:]

    show_datalog(sql, params)
    show_plan(sql, params, db_path)


if __name__ == "__main__":
    main()
