"""Conftest for spier-sql-parse Python tests.

Ensures LD_LIBRARY_PATH points to target/release so load_spier finds the .so.
"""
import os
import sys
from pathlib import Path

# Find workspace root (3 levels up: tests/ -> spier-sql-parse/ -> workspace root)
_root = Path(__file__).resolve().parents[2]
_release = _root / "target" / "release"

# Prepend to LD_LIBRARY_PATH so ctypes can find Rust .so deps
if _release.exists():
    existing = os.environ.get("LD_LIBRARY_PATH", "")
    os.environ["LD_LIBRARY_PATH"] = (
        f"{_release}:{existing}" if existing else str(_release)
    )

# Ensure src/ is on sys.path for eavt_sql package
_src = _root / "src"
if str(_src) not in sys.path:
    sys.path.insert(0, str(_src))
