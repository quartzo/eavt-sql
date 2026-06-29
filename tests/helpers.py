"""Shared test helpers for packed Vec<u8> formats."""


def unpack_keys(buf: bytes) -> list[bytes]:
    """Unpack packed [u32 klen][key]... format."""
    keys = []
    pos = 0
    while pos + 4 <= len(buf):
        klen = int.from_bytes(buf[pos:pos + 4], "big")
        pos += 4
        keys.append(buf[pos:pos + klen])
        pos += klen
    return keys


def unpack_kv(buf: bytes) -> list[tuple[bytes, bytes]]:
    """Unpack packed [u32 klen][key][u32 vlen][value]... format."""
    entries = []
    pos = 0
    while pos + 4 <= len(buf):
        klen = int.from_bytes(buf[pos:pos + 4], "big"); pos += 4
        key = buf[pos:pos + klen]; pos += klen
        vlen = int.from_bytes(buf[pos:pos + 4], "big"); pos += 4
        val = buf[pos:pos + vlen]; pos += vlen
        entries.append((key, val))
    return entries
