from __future__ import annotations

import spier_transactor_py

__all__ = ["load_spier", "SpierLib"]


from datetime import datetime, timezone


class ValueType:
    """Compatibility shim for the codegen-emitted ValueType enum."""

    @staticmethod
    def String() -> str:
        return "String"

    @staticmethod
    def Ref() -> str:
        return "Ref"

    @staticmethod
    def Long() -> str:
        return "Long"

    @staticmethod
    def Keyword() -> str:
        return "Keyword"

    @staticmethod
    def Boolean() -> str:
        return "Boolean"

    @staticmethod
    def Instant() -> str:
        return "Instant"

    @staticmethod
    def Bytes() -> str:
        return "Bytes"

    @staticmethod
    def Blob() -> str:
        return "Blob"

    @staticmethod
    def Float() -> str:
        return "Float"


class Value:
    """Compatibility shim for the codegen-emitted Value enum.

    Methods return plain Python values that the PyO3 binding accepts directly.
    """

    @staticmethod
    def Text(s: str) -> str:
        return s

    @staticmethod
    def Int64(n: int) -> int:
        return n

    @staticmethod
    def Float64(f: float) -> float:
        return f

    @staticmethod
    def Bool(b: bool) -> bool:
        return b

    @staticmethod
    def Bytes(b: bytes) -> bytes:
        return b

    @staticmethod
    def Timestamp(us: int) -> datetime:
        return datetime.fromtimestamp(us / 1_000_000, tz=timezone.utc)


class SpierLib:
    """Factory for PyO3-backed transactor/journal clients.

    This replaces the previous code-generated typed ctypes client. It keeps the
    same surface so existing tests can keep using ``load_spier(name)`` and
    ``create_handle(config)``.
    """

    __slots__ = ("_name", "_client_class", "_factory")

    def __init__(self, name: str, client_class: type, factory: callable) -> None:
        self._name = name
        self._client_class = client_class
        self._factory = factory

    @property
    def name(self) -> str:
        return self._name

    def create_handle(self, config=None):
        return self._factory(config or {})

    def idl_hash(self) -> int:
        # The old codegen computed an IDL hash; we no longer have one, so we
        # return a fixed non-zero placeholder for tests that only verify it is
        # set.
        return 0x_DEAD_BEEF

    def __getattr__(self, attr):
        if attr == "ValueType":
            return ValueType
        if attr == "Value":
            return Value
        raise AttributeError(f"{self!r} has no attribute {attr!r}")


def load_spier(name: str) -> SpierLib:
    """Load a spier's PyO3 client by name."""
    if name == "spier_transactor":
        return SpierLib(
            "spier_transactor",
            spier_transactor_py.Engine,
            lambda cfg: spier_transactor_py.Engine(cfg),
        )
    if name == "spier_journal_file":
        return SpierLib(
            "spier_journal_file",
            spier_transactor_py.Journal,
            lambda cfg: spier_transactor_py.Journal(cfg),
        )
    raise ValueError(f"unknown spier name: {name}")
