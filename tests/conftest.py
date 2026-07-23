"""Conftest for main Python test suite.
Ensures src/ is on sys.path for the eavt_sql package
and pynim_query.so (nimpy bridge) is findable.
"""
import sys
from pathlib import Path

_root = Path(__file__).resolve().parent.parent

_src = _root / "src"
if str(_src) not in sys.path:
    sys.path.insert(0, str(_src))

# pynim_query.so (nimpy bridge) is built at the repo root.
if str(_root) not in sys.path:
    sys.path.insert(0, str(_root))
