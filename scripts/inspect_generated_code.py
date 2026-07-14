#!/usr/bin/env python3
"""Inspect generated VM bytecode for a SELECT query.

Shows: AST → plan traces → bytecode disassembly.

Usage:
    uv run python scripts/inspect_generated_code.py 'SQL' [params...] [--db PATH]

Examples:
    uv run python scripts/inspect_generated_code.py 'SELECT d2.person.name WHERE d1.eid = 1000 AND d1.company.partner = d2.eid'
    uv run python scripts/inspect_generated_code.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000
    uv run python scripts/inspect_generated_code.py 'SELECT d1.company.name WHERE d1.eid = %1' 1000 --db /path/to/db
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
    raw_params = args[1:]
    params = [int(p) if p.lstrip("-").isdigit() else p for p in raw_params]

    # 1. AST
    parser = spier_sql_parse_py.SqlParser()
    ast_json = parser.parse_json(sql)

    print("=== AST ===")
    print(ast_json)

    # 2. Plan traces + bytecode disassembly via EAVTEngine.explain()
    engine = EAVTEngine(db_path)
    if db_path == ":memory:":
        ast_obj = json.loads(ast_json)
        for attr_name in extract_attr_names(ast_obj):
            try:
                list(engine.sql(f"ATTRIBUTE {attr_name} STRING ONE"))
            except Exception:
                pass

    explanation = engine.explain(sql, *params)

    print("\n=== EXPLAIN (plan traces + bytecode) ===")
    print(explanation)

    engine.close()


if __name__ == "__main__":
    main()
