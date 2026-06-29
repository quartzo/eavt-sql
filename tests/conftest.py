"""Conftest for main Python test suite.

Sets DYNSPIRE_LIB_DIR so the Rust DynSpire runtime finds sub-spiers
(blobstore, journal, memtable, etc.) at runtime. Also ensures src/ is
on sys.path for the eavt_sql package.
"""
import os
import sys
from pathlib import Path

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

_src = _root / "src"
if str(_src) not in sys.path:
    sys.path.insert(0, str(_src))
