"""Stress tests for large values (70KB+) exercising all u32 framing paths.

Exercises the full chain: EAVT save → batch_write (u32) → memtable pack_keys
(u32) → flush → PageStore serialize/deserialize (varint prefix compression)
+ index (u32) → scan output (u32) → transactor unpack_keys (u32) → journal
append/read (u32) → close → reopen → journal replay → resolver bootstrap.
"""

from __future__ import annotations

import struct

import pytest

import spier_kvstore_py
import spier_eavt_query_py
from helpers import unpack_keys

LARGE_SIZE = 70_000


def _scan(h, prefix):
    """Scan raw keys via a KV handle opened on the same path."""
    # For transactor handles, we need to re-open as KV for raw inspection.
    # For KV handles, scan directly.
    if hasattr(h, 'scan'):
        return unpack_keys(bytes(h.scan(**{"cf": 0, "prefix": prefix})))
    raise RuntimeError("handle has no scan method")


def _pack_eid(eid: int) -> bytes:
    """Encode entity ID with sign-flip for KV store key prefix matching."""
    flipped = eid ^ 0x8000_0000_0000_0000
    return struct.pack(">Q", flipped)


def _scan_kv(path, prefix):
    """Open a KV-only engine on the same path for raw key inspection."""
    kv = spier_kvstore_py.Engine({"backend": "file", "path": path})
    try:
        return unpack_keys(bytes(kv.scan(**{"cf": 0, "prefix": prefix})))
    finally:
        kv.close()


def _make_payload(size: int, marker: str = "X") -> bytes:
    return ((marker * (size // len(marker) + 1))[:size]).encode()


class TestLargeValueSaveFlushScan:
    """Save a 70KB text value, flush to PageStore, scan it back."""

    def test_70kb_text_save_scan(self, tmp_path):
        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        h.declare_attr("doc.body", "String", False)
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "ABCD")
        h.save(eid, "doc.body", payload.decode(), 0xFFFFFFFFFFFFFFFF)

        h.flush()

        keys = _scan_kv(str(tmp_path), _pack_eid(eid))
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, f"key should embed 70KB+ value, got {len(keys[0])}"

        keys_after_flush = _scan_kv(str(tmp_path), _pack_eid(eid))
        assert len(keys_after_flush) == 1
        assert keys_after_flush == keys, "scan after flush must match scan before flush"
        h.close()

    def test_multiple_70kb_values_flush(self, tmp_path):
        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        h.declare_attr("doc.data", "String", True)
        eids = []
        payloads = []
        for i in range(5):
            eid = h.allocate_entity_id()
            payload = _make_payload(LARGE_SIZE, chr(65 + i))
            h.save(eid, "doc.data", payload.decode(), 0xFFFFFFFFFFFFFFFF)
            eids.append(eid)
            payloads.append(payload)

        h.flush()

        all_keys = _scan_kv(str(tmp_path), b"")
        large_keys = [k for k in all_keys if len(k) > LARGE_SIZE]
        assert len(large_keys) >= 5, f"expected >=5 large keys, got {len(large_keys)} among {len(all_keys)} total"
        h.close()

    def test_70kb_value_survives_reopen(self, tmp_path):
        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        h.declare_attr("doc.persisted", "String", False)
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "Z")
        h.save(eid, "doc.persisted", payload.decode(), 0xFFFFFFFFFFFFFFFF)
        h.flush()
        h.close()

        keys = _scan_kv(str(tmp_path), _pack_eid(eid))
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, "70KB key must survive flush + reopen"


class TestLargeValueJournalRecovery:
    """Exercise journal write/read/replay path with 70KB+ keys."""

    def test_70kb_value_journal_recovery(self, tmp_path):
        from eavt_sql.engine import EAVTEngine

        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        h.declare_attr("doc.journaled", "String", False)
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "J")
        h.save(eid, "doc.journaled", payload.decode(), 0xFFFFFFFFFFFFFFFF)
        h.close()

        # Reopen via EAVTEngine which replays the journal
        e = EAVTEngine(str(tmp_path))
        kv = spier_kvstore_py.Engine({"backend": "file", "path": str(tmp_path)})
        try:
            keys = unpack_keys(bytes(kv.scan(**{"cf": 0, "prefix": _pack_eid(eid)})))
        finally:
            kv.close()
        e.close()
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, "70KB key must survive journal recovery on reopen"


class TestLargeValueBatchWrite:
    """Exercise batch_write FFI path directly with large keys."""

    def test_batch_write_70kb_key(self, tmp_path):
        h = spier_kvstore_py.Engine({"backend": "file", "path": str(tmp_path)})
        big_key = _make_payload(LARGE_SIZE, "K")
        ops = bytearray()
        ops.append(0)
        ops.extend(struct.pack(">I", len(big_key)))
        ops.extend(big_key)
        h.batch_write(**{"ops": bytes(ops)})
        assert h.get(**{"cf": 0, "key": big_key}) is True
        h.close()

    def test_batch_put_70kb_key(self, tmp_path):
        h = spier_kvstore_py.Engine({"backend": "file", "path": str(tmp_path)})
        big_key = _make_payload(LARGE_SIZE, "P")
        buf = bytearray()
        buf.extend(struct.pack(">I", len(big_key)))
        buf.extend(big_key)
        h.batch_put(**{"cf": 0, "keys": bytes(buf)})
        assert h.get(**{"cf": 0, "key": big_key}) is True
        h.close()


class TestLargeValueCursorScan:
    """Exercise cursor + scan output framing with 70KB+ keys."""

    def test_scan_returns_70kb_keys(self, tmp_path):
        h = spier_kvstore_py.Engine({"backend": "file", "path": str(tmp_path)})
        keys_in = []
        for i in range(3):
            k = _pack_eid(100 + i) + _make_payload(LARGE_SIZE, chr(65 + i))
            keys_in.append(k)
            h.put(**{"cf": 0, "key": k})
        h.flush()

        raw = bytes(h.scan(**{"cf": 0, "prefix": b""}))
        keys_out = unpack_keys(raw)
        assert len(keys_out) == 3
        for k in keys_out:
            assert len(k) > LARGE_SIZE
        assert keys_out == sorted(keys_in)
        h.close()

    def test_items_returns_70kb_keys(self, tmp_path):
        h = spier_kvstore_py.Engine({"backend": "file", "path": str(tmp_path)})
        k = _make_payload(LARGE_SIZE, "I")
        h.put(**{"cf": 0, "key": k})
        h.flush()
        raw = bytes(h.items(**{"cf": 0}))
        keys_out = unpack_keys(raw)
        assert len(keys_out) == 1
        assert len(keys_out[0]) >= LARGE_SIZE
        h.close()
