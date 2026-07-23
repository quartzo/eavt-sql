"""Conftest for benchmarks — ensures py_eavt_client is on sys.path."""
import sys
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_src = _root / "py_eavt_client" / "src"
if str(_src) not in sys.path:
    sys.path.insert(0, str(_src))
