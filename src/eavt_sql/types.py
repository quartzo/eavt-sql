from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

_TAG_STR = 2
_TAG_BYTES = 3
_TAG_BOOL = 4
_TAG_INT64 = 12
_TAG_FLOAT64 = 14

_SIGN_FLIP = 0x8000000000000000


def _encode_int64(n: int) -> int:
    return n ^ _SIGN_FLIP


def _decode_int64(bits: int) -> int:
    return bits ^ _SIGN_FLIP


def _encode_float64(f: float) -> int:
    bits = struct.unpack(">Q", struct.pack(">d", f))[0]
    if bits & _SIGN_FLIP:
        return ~bits & 0xFFFFFFFFFFFFFFFF
    return bits | _SIGN_FLIP


def _decode_float64(bits: int) -> float:
    if bits & _SIGN_FLIP:
        raw = bits & ~_SIGN_FLIP
    else:
        raw = ~bits & 0xFFFFFFFFFFFFFFFF
    return struct.unpack(">d", struct.pack(">Q", raw))[0]


_MAX_ATTR_ID = 0xFFFF


@dataclass(frozen=True, slots=True, order=True)
class Timestamp:
    t: int
    retracted: bool


@dataclass(frozen=True, slots=True)
class Datom:
    e: int
    a: int
    v: Value
    t: Timestamp


class Value:
    __slots__ = ("_tag", "_raw")

    def __init__(self, v: str | int | float | bool | bytes | ref) -> None:
        if isinstance(v, ref):
            self._tag = _TAG_INT64
            self._raw = v.name
        elif isinstance(v, bool):
            self._tag = _TAG_BOOL
            self._raw = int(v)
        elif isinstance(v, int):
            self._tag = _TAG_INT64
            self._raw = v
        elif isinstance(v, float):
            self._tag = _TAG_FLOAT64
            self._raw = v
        elif isinstance(v, bytes):
            self._tag = _TAG_BYTES
            self._raw = v
        elif isinstance(v, str):
            self._tag = _TAG_STR
            self._raw = v
        else:
            raise TypeError(f"unsupported value type: {type(v)}")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        return self._tag == other._tag and self._raw == other._raw

    def __ne__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        return self._tag != other._tag or self._raw != other._raw

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        if self._tag != other._tag:
            return self._tag < other._tag
        sr, orr = self._raw, other._raw
        if isinstance(sr, int) and isinstance(orr, int):
            return sr < orr
        if isinstance(sr, float) and isinstance(orr, float):
            return sr < orr
        if isinstance(sr, str) and isinstance(orr, str):
            return sr < orr
        return isinstance(sr, (int, float))

    def __le__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        return self == other or self < other

    def __gt__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        if self._tag != other._tag:
            return self._tag > other._tag
        sr, orr = self._raw, other._raw
        if isinstance(sr, int) and isinstance(orr, int):
            return sr > orr
        if isinstance(sr, float) and isinstance(orr, float):
            return sr > orr
        if isinstance(sr, str) and isinstance(orr, str):
            return sr > orr
        return isinstance(sr, str)

    def __ge__(self, other: object) -> bool:
        if not isinstance(other, Value):
            return NotImplemented
        return self == other or self > other

    def __hash__(self) -> int:
        return hash((self._tag, self._raw))

    def __repr__(self) -> str:
        return f"Value({self._raw!r}, tag={self._tag})"

    def __str__(self) -> str:
        if isinstance(self._raw, str):
            return self._raw
        return repr(self._raw)

    @property
    def tag(self) -> int:
        return self._tag

    @property
    def raw(self) -> int | str | float | bytes:
        return self._raw

    @property
    def raw_int(self) -> int:
        assert isinstance(self._raw, int)
        return self._raw

    @property
    def raw_str(self) -> str:
        assert isinstance(self._raw, str)
        return self._raw

    @property
    def raw_bytes(self) -> bytes:
        assert isinstance(self._raw, bytes)
        return self._raw

    @property
    def raw_float(self) -> float:
        assert isinstance(self._raw, float)
        return self._raw

    def is_variable(self) -> bool:
        return self._tag in (_TAG_STR, _TAG_BYTES)

    def is_timestamp(self) -> bool:
        return False

    def resolve(self, lookup: Callable[[int], str]) -> str | int | float | bytes:
        return self._raw

    @staticmethod
    def text(s: str) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_STR
        v._raw = s
        return v

    @staticmethod
    def int64(n: int) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_INT64
        v._raw = n
        return v

    @staticmethod
    def float64(f: float) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_FLOAT64
        v._raw = f
        return v

    @staticmethod
    def bool_(b: bool) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_BOOL
        v._raw = int(b)
        return v

    @staticmethod
    def ref(name: int) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_INT64
        v._raw = name
        return v

    @staticmethod
    def bytes_(b: bytes) -> Value:
        v = object.__new__(Value)
        v._tag = _TAG_BYTES
        v._raw = b
        return v

    @staticmethod
    def timestamp(us: int) -> Value:
        v = object.__new__(_TimestampValue)
        v._tag = -1
        v._raw = us
        return v

    def encode_fixed(self) -> bytes:
        if self._tag == _TAG_BOOL:
            return struct.pack(">Q", self._raw)
        if self._tag == _TAG_INT64:
            return struct.pack(">Q", _encode_int64(self._raw))
        if self._tag == _TAG_FLOAT64:
            return struct.pack(">Q", _encode_float64(self._raw))
        raise ValueError(f"cannot encode tag {self._tag} as fixed")

    @staticmethod
    def decode_fixed(tag: int, bits: int) -> Value:
        v = object.__new__(Value)
        v._tag = tag
        if tag == _TAG_BOOL:
            v._raw = bits
        elif tag == _TAG_INT64:
            v._raw = _decode_int64(bits)
        elif tag == _TAG_FLOAT64:
            v._raw = _decode_float64(bits)
        else:
            v._raw = bits
        return v


class _TimestampValue(Value):
    def is_timestamp(self) -> bool:
        return True

    def __repr__(self) -> str:
        return f"Value.timestamp({self._raw})"


class ref:
    __slots__ = ("name",)

    def __init__(self, name: str | int):
        self.name = name

    def __eq__(self, other):
        return isinstance(other, ref) and self.name == other.name

    def __hash__(self):
        return hash(("ref", self.name))

    def __repr__(self):
        return f"ref({self.name!r})"

V = str | int | float | bool | bytes | ref | Value


@dataclass(frozen=True, slots=True)
class Var:
    name: str
    kind: str  # "entity" | "attr" | "value" | "ts"


@dataclass(frozen=True, slots=True)
class Const:
    value: object


Slot = Var | Const
