"""keys.py — EAVT key encoding for 4 column families.

Port of nim_eavt/keys.nim. All encodings must be byte-identical to the Nim
implementation for data compatibility.
"""
from __future__ import annotations

import struct
from .types import EncodeMode

# ═══════════════════════════════════════════════════════════════════════════════
# Big-endian helpers
# ═══════════════════════════════════════════════════════════════════════════════

_U64 = struct.Struct(">Q")
_U32 = struct.Struct(">I")


def be_uint64(data: bytes, start: int) -> int:
    return _U64.unpack_from(data, start)[0]


def be_uint32(data: bytes, start: int) -> int:
    return _U32.unpack_from(data, start)[0]


# ═══════════════════════════════════════════════════════════════════════════════
# Suffix: [tx 8 bytes big-endian sign-flipped] + [1 byte retracted: 0x00/0x01]
# ═══════════════════════════════════════════════════════════════════════════════

_SUFFIX_SIZE = 9


def encode_suffix(t: int, retracted: bool) -> tuple[bytes, int]:
    """Return (tx_bytes, retracted_byte) for the suffix."""
    tx_bytes = encode_int(t)
    ret_byte = 1 if retracted else 0
    return tx_bytes, ret_byte


def decode_suffix(tx_bytes: bytes, ret_byte: int) -> tuple[int, bool]:
    """Return (t, retracted) from suffix bytes."""
    raw = _U64.unpack_from(tx_bytes, 0)[0]
    t = decode_int64(raw)
    return t, (ret_byte & 1) != 0


# ═══════════════════════════════════════════════════════════════════════════════
# Integer encoding: sign-flip for lexicographic ordering
# ═══════════════════════════════════════════════════════════════════════════════


def encode_int(n: int) -> bytes:
    """Sign-flip + big-endian 8 bytes."""
    x = (n ^ (1 << 63)) & 0xFFFFFFFFFFFFFFFF
    return _U64.pack(x)


encode_eid = encode_int


def decode_int64(raw: int) -> int:
    """Reverse sign-flip from uint64."""
    x = raw ^ (1 << 63)
    if x >= (1 << 63):
        x -= 1 << 64
    return x


decode_eid = decode_int64


# ═══════════════════════════════════════════════════════════════════════════════
# Float encoding: IEEE 754 with sign-bit manipulation
# ═══════════════════════════════════════════════════════════════════════════════


def encode_float(f: float) -> bytes:
    """IEEE 754 with sign-bit flip for lexicographic ordering."""
    x = _U64.unpack(struct.pack(">d", f))[0]
    if (x >> 63) == 1:
        x = (~x) & 0xFFFFFFFFFFFFFFFF
    else:
        x = x ^ (1 << 63)
    return _U64.pack(x)


def decode_float64(raw: int) -> float:
    """Reverse of encode_float."""
    x = raw
    if (x >> 63) == 1:
        x = x ^ (1 << 63)
    else:
        x = (~x) & 0xFFFFFFFFFFFFFFFF
    return struct.unpack(">d", _U64.pack(x))[0]


# ═══════════════════════════════════════════════════════════════════════════════
# Variable-length encoding: 8+1 block encoding for strings
# ═══════════════════════════════════════════════════════════════════════════════


def encode_variable(s: str) -> bytes:
    """Encode a string for lexicographic ordering: 8-byte blocks + control byte.

    Control: 0xFF = more blocks follow; 0..7 = last block valid bytes.
    """
    raw = s.encode("utf-8")
    length = len(raw)
    out = bytearray()
    pos = 0
    while pos < length:
        remaining = length - pos
        block_len = min(remaining, 8)
        out.extend(raw[pos : pos + block_len])
        # Pad to 8 bytes
        out.extend(b"\x00" * (8 - block_len))
        if remaining <= 8:
            out.append(block_len)  # last block
        else:
            out.append(0xFF)  # more blocks follow
        pos += block_len
    return bytes(out)


def decode_variable_str(data: bytes, start: int = 0) -> str:
    """Decode an 8+1-block encoded string."""
    result = bytearray()
    pos = start
    while pos + 9 <= len(data):
        control = data[pos + 8]
        result.extend(data[pos : pos + 8])
        if control != 0xFF:
            valid_bytes = control
            if valid_bytes < 8:
                del result[len(result) - (8 - valid_bytes) :]
            return result.decode("utf-8", errors="replace")
        pos += 9
    return result.decode("utf-8", errors="replace")


# ═══════════════════════════════════════════════════════════════════════════════
# Unordered encoding: 4-byte length prefix + raw bytes
# ═══════════════════════════════════════════════════════════════════════════════


def encode_variable_unordered(data: bytes) -> bytes:
    """4-byte big-endian length prefix + raw bytes."""
    return _U32.pack(len(data)) + data


# ═══════════════════════════════════════════════════════════════════════════════
# Value encoding by mode
# ═══════════════════════════════════════════════════════════════════════════════


def encode_value(v: str, mode: EncodeMode, ref_eid: int = 0) -> bytes:
    """Encode a value string according to the given mode."""
    if mode == EncodeMode.REF:
        return encode_eid(ref_eid)
    if mode == EncodeMode.VARIABLE:
        return encode_variable(v)
    if mode == EncodeMode.BLOB:
        return encode_variable_unordered(v.encode("utf-8") if isinstance(v, str) else v)
    # FIXED: try int, then float, fallback 0
    try:
        return encode_int(int(v))
    except (ValueError, TypeError):
        try:
            return encode_float(float(v))
        except (ValueError, TypeError):
            return encode_int(0)


# ═══════════════════════════════════════════════════════════════════════════════
# Fixed-size encoding (for query engine scanner)
# ═══════════════════════════════════════════════════════════════════════════════


def encode_fixed_int(n: int) -> bytes:
    return encode_int(n)


def encode_fixed_float(f: float) -> bytes:
    return encode_float(f)


def encode_fixed_bool(b: bool) -> bytes:
    out = bytearray(8)
    out[0] = 0x80 if b else 0x00
    return bytes(out)


# ═══════════════════════════════════════════════════════════════════════════════
# Key builders — generate keys for each CF
# ═══════════════════════════════════════════════════════════════════════════════

_ATTR = struct.Struct(">I")


def _attr_bytes(attr: int) -> bytes:
    return _ATTR.pack(attr)


def _sf_bytes(t: int, retracted: bool) -> bytes:
    tx_bytes, ret_byte = encode_suffix(t, retracted)
    return tx_bytes + bytes([ret_byte])


def _eid_bytes(eid: int) -> bytes:
    return encode_eid(eid)


def build_eavt_key(
    eid: int, attr: int, value_encoded: bytes, t: int, retracted: bool
) -> bytes:
    """CF 0: [eid 8B][attr 4B][value][suffix 8B]."""
    return _eid_bytes(eid) + _attr_bytes(attr) + value_encoded + _sf_bytes(t, retracted)


def build_aevt_key(
    attr: int, eid: int, value_encoded: bytes, t: int, retracted: bool
) -> bytes:
    """CF 1: [attr 4B][eid 8B][value][suffix 8B]."""
    return _attr_bytes(attr) + _eid_bytes(eid) + value_encoded + _sf_bytes(t, retracted)


def build_avet_key(
    attr: int, value_encoded: bytes, eid: int, t: int, retracted: bool
) -> bytes:
    """CF 2: [attr 4B][value][eid 8B][suffix 8B]."""
    return _attr_bytes(attr) + value_encoded + _eid_bytes(eid) + _sf_bytes(t, retracted)


def build_vaet_key(
    value_encoded: bytes, attr: int, eid: int, t: int, retracted: bool
) -> bytes:
    """CF 3: [value][attr 4B][eid 8B][suffix 8B]."""
    return value_encoded + _attr_bytes(attr) + _eid_bytes(eid) + _sf_bytes(t, retracted)


# ═══════════════════════════════════════════════════════════════════════════════
# EAVT entry builder — generates entries for all relevant CFs
# ═══════════════════════════════════════════════════════════════════════════════


class EavtEntry:
    __slots__ = ("cf", "key")

    def __init__(self, cf: int, key: bytes):
        self.cf = cf
        self.key = key


def _make_key(parts: tuple[bytes, ...]) -> bytes:
    """Build a key from parts using a single bytearray allocation."""
    total = sum(len(p) for p in parts)
    buf = bytearray(total)
    pos = 0
    for p in parts:
        buf[pos : pos + len(p)] = p
        pos += len(p)
    return bytes(buf)


def build_eavt_entries(
    eid: int,
    attr: int,
    encoded_value: bytes,
    t: int,
    retracted: bool,
    mode: EncodeMode,
    indexed: bool,
) -> list[EavtEntry]:
    """Generate entries for all relevant column families."""
    a_bytes = _attr_bytes(attr)
    e_bytes = _eid_bytes(eid)
    sf_bytes = _sf_bytes(t, retracted)

    entries: list[EavtEntry] = []

    # CF 0: eavt [eid][attr][val][sf]
    entries.append(EavtEntry(0, _make_key((e_bytes, a_bytes, encoded_value, sf_bytes))))
    # CF 1: aevt [attr][eid][val][sf]
    entries.append(EavtEntry(1, _make_key((a_bytes, e_bytes, encoded_value, sf_bytes))))

    if mode == EncodeMode.REF:
        # CF 3: vaet [val][attr][eid][sf]
        entries.append(EavtEntry(3, _make_key((encoded_value, a_bytes, e_bytes, sf_bytes))))
        if indexed:
            # CF 2: avet [attr][val][eid][sf]
            entries.append(EavtEntry(2, _make_key((a_bytes, encoded_value, e_bytes, sf_bytes))))
    else:
        if indexed:
            entries.append(EavtEntry(2, _make_key((a_bytes, encoded_value, e_bytes, sf_bytes))))

    return entries


# ═══════════════════════════════════════════════════════════════════════════════
# Stored value decoding (query engine)
# ═══════════════════════════════════════════════════════════════════════════════


def decode_stored_value(data: bytes, vt: int):
    """Decode a stored EAVT value given its db valueType. Returns Python native."""
    from .types import (
        DB_TYPE_REF, DB_TYPE_BOOLEAN, DB_TYPE_LONG, DB_TYPE_INSTANT,
        DB_TYPE_FLOAT, DB_TYPE_BYTES, DB_TYPE_BLOB,
    )

    if vt == DB_TYPE_REF:
        if len(data) >= 8:
            return decode_int64(be_uint64(data, 0))
        return 0
    if vt == DB_TYPE_BOOLEAN:
        if len(data) >= 8:
            return decode_int64(be_uint64(data, 0)) != 0
        return False
    if vt in (DB_TYPE_LONG, DB_TYPE_INSTANT):
        if len(data) >= 8:
            return decode_int64(be_uint64(data, 0))
        return 0
    if vt == DB_TYPE_FLOAT:
        if len(data) >= 8:
            return decode_float64(be_uint64(data, 0))
        return 0.0
    if vt in (DB_TYPE_BYTES, DB_TYPE_BLOB):
        if len(data) >= 4:
            n = be_uint32(data, 0)
            m = min(n, len(data) - 4)
            return data[4 : 4 + m]
        return b""
    # Default: string
    return decode_variable_str(data, 0)
