from __future__ import annotations

import importlib.util
from pathlib import Path

__all__ = ["load_spier", "SpierLib"]


def _workspace_root() -> Path:
    # This file lives at <root>/src/eavt_sql/_ffi.py.
    return Path(__file__).resolve().parents[2]


def _find_so(name: str) -> Path:
    root = _workspace_root()
    for variant in ("release", "debug"):
        so = root / "target" / variant / f"lib{name}.so"
        if so.exists():
            return so
    raise FileNotFoundError(
        f"spier .so not found: tried target/release/lib{name}.so "
        f"and target/debug/lib{name}.so"
    )


def _find_generated(name: str) -> Path:
    # Each spier crate emits its typed client to <crate>/generated/<name>.py.
    # Crate dir uses hyphens, spier name uses underscores.
    crate = name.replace("_", "-")
    py = _workspace_root() / crate / "generated" / f"{name}.py"
    if py.exists():
        return py
    raise FileNotFoundError(f"generated typed client not found: {py}")


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(f"_eavt_sql_gen_{name}", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _find_client_class(module):
    """Return the concrete SpierClient subclass defined in the module."""
    for attr in dir(module):
        obj = getattr(module, attr)
        if not isinstance(obj, type) or obj.__name__ == "SpierClient":
            continue
        if any(getattr(b, "__name__", "") == "SpierClient" for b in obj.__mro__):
            return obj
    raise RuntimeError(f"no SpierClient subclass found in {module.__file__}")


class SpierLib:
    """Factory for a code-generated typed ctypes spier client.

    ``create_handle(config)`` returns the generated typed client instance —
    call its typed methods directly (no dict dispatch, no schema introspection).
    Generated enums/structs (``Value``, ``ValueType``, ``CursorHandle``, ...)
    are accessible as attributes of the lib.
    """

    __slots__ = ("_name", "_client_class", "_so_path", "_module")

    def __init__(self, name, client_class, so_path, module) -> None:
        self._name = name
        self._client_class = client_class
        self._so_path = so_path
        self._module = module

    @property
    def name(self) -> str:
        return self._name

    def create_handle(self, config=None):
        return self._client_class(str(self._so_path), config)

    def idl_hash(self) -> int:
        return self._module._IDL_HASH

    def __getattr__(self, attr):
        # Expose generated types/enums (Value, ValueType, ...) by name.
        return getattr(self._module, attr)


def load_spier(name: str) -> SpierLib:
    """Load a spier's generated typed client by spier name.

    Locates the compiled ``lib<name>.so`` and the codegen-emitted
    ``<crate>/generated/<name>.py``, imports the typed client, and returns
    a :class:`SpierLib` factory. No runtime schema introspection — the slot
    layout, ``dynspire_free`` indices, and type classes are baked into the
    generated module at the spier's build time.
    """
    so = _find_so(name)
    module = _load_module(name, _find_generated(name))
    client_class = _find_client_class(module)
    return SpierLib(name, client_class, so, module)
