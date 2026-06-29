from __future__ import annotations

import struct
from datetime import datetime
from typing import Any

_TAG_TEXT = 1
_TAG_INT64 = 2
_TAG_FLOAT64 = 3
_TAG_BOOL = 4
_TAG_BYTES = 5
_TAG_TIMESTAMP = 6
_TAG_UNKNOWN = 99


def encode_values(values: list[Any]) -> bytes:
    buf = bytearray()
    buf += struct.pack(">I", len(values))
    for v in values:
        _encode_one(buf, v)
    return bytes(buf)


def decode_values(buf: bytes) -> list[Any]:
    if len(buf) < 4:
        raise ValueError("decode_values: buffer too short")
    n = struct.unpack_from(">I", buf, 0)[0]
    pos = 4
    out: list[Any] = []
    for _ in range(n):
        val, pos = _decode_one(buf, pos)
        out.append(val)
    return out


def _encode_one(buf: bytearray, v: Any) -> None:
    if isinstance(v, bool):
        buf.append(_TAG_BOOL)
        buf.append(1 if v else 0)
    elif isinstance(v, int):
        buf.append(_TAG_INT64)
        buf += struct.pack(">q", v)
    elif isinstance(v, float):
        buf.append(_TAG_FLOAT64)
        buf += struct.pack(">d", v)
    elif isinstance(v, str):
        _encode_bytes_payload(buf, _TAG_TEXT, v.encode("utf-8"))
    elif isinstance(v, (bytes, bytearray)):
        _encode_bytes_payload(buf, _TAG_BYTES, bytes(v))
    elif isinstance(v, datetime):
        buf.append(_TAG_TIMESTAMP)
        us = int(v.timestamp() * 1_000_000)
        buf += struct.pack(">q", us)
    elif v is None:
        buf.append(_TAG_INT64)
        buf += struct.pack(">q", 0)
    else:
        raise TypeError(f"unsupported value type: {type(v).__name__}")


def _encode_bytes_payload(buf: bytearray, tag: int, data: bytes) -> None:
    buf.append(tag)
    buf += struct.pack(">I", len(data))
    buf += data


def _decode_one(buf: bytes, pos: int) -> tuple[Any, int]:
    tag = buf[pos]
    pos += 1
    if tag == _TAG_TEXT:
        s, pos = _decode_bytes(buf, pos)
        return s.decode("utf-8"), pos
    elif tag == _TAG_INT64:
        n = struct.unpack_from(">q", buf, pos)[0]
        return n, pos + 8
    elif tag == _TAG_FLOAT64:
        f = struct.unpack_from(">d", buf, pos)[0]
        return f, pos + 8
    elif tag == _TAG_BOOL:
        return buf[pos] != 0, pos + 1
    elif tag == _TAG_BYTES:
        return _decode_bytes(buf, pos)
    elif tag == _TAG_TIMESTAMP:
        us = struct.unpack_from(">q", buf, pos)[0]
        return us, pos + 8
    elif tag == _TAG_UNKNOWN:
        t = buf[pos]
        payload = struct.unpack_from(">Q", buf, pos + 1)[0]
        return (t, payload), pos + 9
    else:
        raise ValueError(f"decode_one: unknown tag {tag}")


def _decode_bytes(buf: bytes, pos: int) -> tuple[bytes, int]:
    length = struct.unpack_from(">I", buf, pos)[0]
    start = pos + 4
    return buf[start : start + length], start + length


def decode_rows(buf: bytes) -> list[tuple]:
    """Decode cursor batch format: [u32 num_cols][encoded values]... per row.

    Rows with num_cols == 0 are skipped (internal VM bookkeeping).
    """
    rows: list[tuple] = []
    pos = 0
    while pos < len(buf):
        num_cols = struct.unpack_from(">I", buf, pos)[0]
        pos += 4
        row: list[Any] = []
        for _ in range(num_cols):
            val, pos = _decode_one(buf, pos)
            row.append(val)
        if num_cols > 0:
            rows.append(tuple(row))
    return rows
