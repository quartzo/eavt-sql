"""keys.py — EAVT key encoding for 4 column families.

Value encoding:
  STRING/KEYWORD — null-terminated (lexicographic order)
  BYTES          — 8+1 block encoding (lexicographic order)
  BLOB           — 4B length prefix + raw (no order)
  LONG/INT/etc   — sign-flipped 8-byte big-endian
  REF            — same as LONG (entity reference)
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
# Boolean encoding (matches encode_int for scanner seek compatibility)
# ═══════════════════════════════════════════════════════════════════════════════


def encode_bool(b: bool) -> bytes:
    """Encode boolean as sign-flipped int (True=1, False=0)."""
    return encode_int(1 if b else 0)


# ═══════════════════════════════════════════════════════════════════════════════
# String encoding: null-terminated (lexicographic order)
# ═══════════════════════════════════════════════════════════════════════════════


def encode_string(s: str) -> bytes:
    """Null-terminated UTF-8 encoding. Truncates at embedded null bytes."""
    raw = s.encode("utf-8")
    idx = raw.find(b"\x00")
    if idx >= 0:
        raw = raw[:idx]
    return raw + b"\x00"


# ═══════════════════════════════════════════════════════════════════════════════
# Bytes encoding: 8+1 block encoding (lexicographic order)
# ═══════════════════════════════════════════════════════════════════════════════


def encode_bytes(data: bytes) -> bytes:
    """8+1 block encoding for lexicographic ordering of binary data."""
    length = len(data)
    out = bytearray()
    pos = 0
    while pos < length:
        remaining = length - pos
        block_len = min(remaining, 8)
        out.extend(data[pos : pos + block_len])
        out.extend(b"\x00" * (8 - block_len))
        if remaining <= 8:
            out.append(block_len)
        else:
            out.append(0xFF)
        pos += block_len
    return bytes(out)


# ═══════════════════════════════════════════════════════════════════════════════
# Blob encoding: 4-byte length prefix + raw bytes (no lexicographic order)
# ═══════════════════════════════════════════════════════════════════════════════


def encode_blob(data: bytes) -> bytes:
    """4-byte big-endian length prefix + raw bytes."""
    return _U32.pack(len(data)) + data


# ═══════════════════════════════════════════════════════════════════════════════
# Value encoding by mode
# ═══════════════════════════════════════════════════════════════════════════════


def encode_value(v, mode: EncodeMode, ref_eid: int = 0) -> bytes:
    """Encode a value according to the given mode.

    For VARIABLE (STRING/KEYWORD): v should be str.
    For BLOCK (BYTES): v should be bytes.
    For BLOB: v should be bytes.
    For FIXED: v can be str (parsed), int, float, or bool.
    For REF: v is ignored; ref_eid is used.
    """
    if mode == EncodeMode.REF:
        return encode_eid(ref_eid)
    if mode == EncodeMode.VARIABLE:
        return encode_string(str(v))
    if mode == EncodeMode.BLOCK:
        return encode_bytes(v if isinstance(v, bytes) else str(v).encode("utf-8"))
    if mode == EncodeMode.BLOB:
        return encode_blob(v if isinstance(v, bytes) else str(v).encode("utf-8"))
    # FIXED: bool → encode_bool, int → encode_int, float → encode_float
    if isinstance(v, bool):
        return encode_bool(v)
    if isinstance(v, float):
        return encode_float(v)
    if isinstance(v, int):
        return encode_int(v)
    # String: try int, then float, fallback 0
    try:
        return encode_int(int(v))
    except (ValueError, TypeError):
        try:
            return encode_float(float(v))
        except (ValueError, TypeError):
            return encode_int(0)


# ═══════════════════════════════════════════════════════════════════════════════
# Unified value decoder — single source of truth for decoding
# ═══════════════════════════════════════════════════════════════════════════════


def read_next(key: bytes, start: int, vt: int) -> tuple:
    """Read the element at position `start` in the key.

    The encoding is determined by `vt` (DB_TYPE_* constant).
    Returns (decoded_value, bytes_consumed).

    This is the ONLY place that decodes values from keys.
    The scanner calls this with start = len(prefix_cache).
    The engine calls this with start = known offset per CF layout.
    """
    from .types import (
        DB_TYPE_REF, DB_TYPE_BOOLEAN, DB_TYPE_LONG, DB_TYPE_INSTANT,
        DB_TYPE_FLOAT, DB_TYPE_BYTES, DB_TYPE_BLOB, DB_TYPE_STRING,
        DB_TYPE_KEYWORD,
    )

    if vt in (DB_TYPE_STRING, DB_TYPE_KEYWORD):
        # Null-terminated
        end = start
        keylen = len(key)
        while end < keylen:
            if key[end] == 0:
                return key[start:end].decode("utf-8", errors="replace"), end + 1
            end += 1
        return key[start:keylen].decode("utf-8", errors="replace"), keylen

    if vt == DB_TYPE_BYTES:
        # 8+1 block encoding
        result = bytearray()
        pos = start
        keylen = len(key)
        while pos + 9 <= keylen:
            control = key[pos + 8]
            result.extend(key[pos : pos + 8])
            if control != 0xFF:
                valid_bytes = control
                if valid_bytes < 8:
                    del result[len(result) - (8 - valid_bytes) :]
                return bytes(result), pos + 9
            pos += 9
        return bytes(result), keylen

    if vt == DB_TYPE_BLOB:
        # 4B length prefix + raw
        if start + 4 > len(key):
            return b"", len(key)
        n = be_uint32(key, start)
        end = start + 4 + n
        if end > len(key):
            end = len(key)
        return key[start + 4 : end], end

    # Fixed-size (8 bytes): LONG, REF, BOOLEAN, INSTANT, FLOAT
    if start + 8 > len(key):
        return 0, len(key)
    raw = be_uint64(key, start)
    if vt == DB_TYPE_FLOAT:
        return decode_float64(raw), start + 8
    if vt == DB_TYPE_BOOLEAN:
        return decode_int64(raw) != 0, start + 8
    if vt in (DB_TYPE_LONG, DB_TYPE_INSTANT, DB_TYPE_REF):
        return decode_int64(raw), start + 8
    return raw, start + 8


# ═══════════════════════════════════════════════════════════════════════════════
# Key builders — generate keys for each CF
# ═══════════════════════════════════════════════════════════════════════════════

_ATTR = struct.Struct(">I")


def _attr_bytes(attr: int) -> bytes:
    return _ATTR.pack(attr)


def _sf_bytes(t: int, retracted: bool) -> bytes:
    tx_bytes, ret_byte = encode_suffix(t, retracted)
    return tx_bytes + bytes([ret_byte])


def encode_suffix_bytes(t: int, retracted: bool) -> bytes:
    """Full 9-byte suffix: 8B tx + 1B retracted."""
    return _sf_bytes(t, retracted)


def _eid_bytes(eid: int) -> bytes:
    return encode_eid(eid)


def build_eavt_key(
    eid: int, attr: int, value_encoded: bytes, t: int, retracted: bool
) -> bytes:
    """CF 0: [eid 8B][attr 4B][value][suffix 9B]."""
    return _eid_bytes(eid) + _attr_bytes(attr) + value_encoded + _sf_bytes(t, retracted)


def build_aevt_key(
    attr: int, eid: int, value_encoded: bytes, t: int, retracted: bool
) -> bytes:
    """CF 1: [attr 4B][eid 8B][value][suffix 9B]."""
    return _attr_bytes(attr) + _eid_bytes(eid) + value_encoded + _sf_bytes(t, retracted)


def build_avet_key(
    attr: int, value_encoded: bytes, eid: int, t: int, retracted: bool
) -> bytes:
    """CF 2: [attr 4B][value][eid 8B][suffix 9B]."""
    return _attr_bytes(attr) + value_encoded + _eid_bytes(eid) + _sf_bytes(t, retracted)


def build_vaet_key(
    value_encoded: bytes, attr: int, eid: int, t: int, retracted: bool
) -> bytes:
    """CF 3: [value][attr 4B][eid 8B][suffix 9B]."""
    return value_encoded + _attr_bytes(attr) + _eid_bytes(eid) + _sf_bytes(t, retracted)


# ═══════════════════════════════════════════════════════════════════════════════
# EAVT entry builder — generates entries for all relevant CFs
# ═══════════════════════════════════════════════════════════════════════════════


class EavtEntry:
    __slots__ = ("cf", "key")

    def __init__(self, cf: int, key: bytes):
        self.cf = cf
        self.key = key


def build_eavt_entries(
    eid: int,
    attr: int,
    encoded_value: bytes,
    t: int,
    retracted: bool,
    mode: EncodeMode,
    indexed: bool,
) -> list[EavtEntry]:
    """Generate entries for all relevant column families.

    Uses pre-encoded fixed parts to avoid intermediate bytes objects.
    """
    val_len = len(encoded_value)
    key_size = 21 + val_len  # 8 (eid) + 4 (attr) + val_len + 9 (suffix)

    e_buf = encode_eid(eid)
    a_buf = _ATTR.pack(attr)
    sf_buf = encode_suffix_bytes(t, retracted)

    entries: list[EavtEntry] = []

    # CF 0: eavt [eid 8B][attr 4B][val][suffix 9B]
    k0 = bytearray(key_size)
    k0[0:8] = e_buf; k0[8:12] = a_buf
    k0[12:12 + val_len] = encoded_value; k0[12 + val_len:] = sf_buf
    entries.append(EavtEntry(0, bytes(k0)))

    # CF 1: aevt [attr 4B][eid 8B][val][suffix 9B]
    k1 = bytearray(key_size)
    k1[0:4] = a_buf; k1[4:12] = e_buf
    k1[12:12 + val_len] = encoded_value; k1[12 + val_len:] = sf_buf
    entries.append(EavtEntry(1, bytes(k1)))

    if mode == EncodeMode.REF:
        # CF 3: vaet [val][attr 4B][eid 8B][suffix 9B]
        k3 = bytearray(key_size)
        k3[0:val_len] = encoded_value; k3[val_len:val_len + 4] = a_buf
        k3[val_len + 4:val_len + 12] = e_buf; k3[val_len + 12:] = sf_buf
        entries.append(EavtEntry(3, bytes(k3)))
        if indexed:
            k2 = bytearray(key_size)
            k2[0:4] = a_buf; k2[4:4 + val_len] = encoded_value
            k2[4 + val_len:4 + val_len + 8] = e_buf; k2[4 + val_len + 8:] = sf_buf
            entries.append(EavtEntry(2, bytes(k2)))
    else:
        if indexed:
            k2 = bytearray(key_size)
            k2[0:4] = a_buf; k2[4:4 + val_len] = encoded_value
            k2[4 + val_len:4 + val_len + 8] = e_buf; k2[4 + val_len + 8:] = sf_buf
            entries.append(EavtEntry(2, bytes(k2)))

    return entries
