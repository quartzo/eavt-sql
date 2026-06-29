"""Stress tests for large values (70KB+) exercising all u32 framing paths.

Exercises the full chain: EAVT save → batch_write (u32) → memtable pack_keys
(u32) → flush → PageStore serialize/deserialize (varint prefix compression)
+ index (u32) → scan output (u32) → transactor unpack_keys (u32) → journal
append/read (u32) → close → reopen → journal replay → resolver bootstrap.
"""

from __future__ import annotations

import struct

import pytest

from eavt_sql._ffi import load_spier
from helpers import unpack_keys

U64_MAX = 0xFFFFFFFFFFFFFFFF
LARGE_SIZE = 70_000


@pytest.fixture
def lib():
    return load_spier("spier_transactor")


@pytest.fixture
def Value(lib):
    return lib.Value


@pytest.fixture
def ValueType(lib):
    return lib.ValueType


def _scan(h, prefix):
    return unpack_keys(bytes(h.scan(**{"cf": 0, "prefix": prefix})))


def _make_payload(size: int, marker: str = "X") -> bytes:
    return ((marker * (size // len(marker) + 1))[:size]).encode()


class TestLargeValueSaveFlushScan:
    """Save a 70KB text value, flush to PageStore, scan it back."""

    def test_70kb_text_save_scan(self, lib, tmp_path, Value, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        h.eavt_declare_attr(**{
            "name": "doc.body", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "ABCD")
        h.eavt_save(**{
            "e_id": eid, "attr": "doc.body",
            "v": Value.Text(payload.decode()),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })

        keys = _scan(h, struct.pack(">Q", eid))
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, f"key should embed 70KB+ value, got {len(keys[0])}"

        h.flush()

        keys_after_flush = _scan(h, struct.pack(">Q", eid))
        assert len(keys_after_flush) == 1
        assert keys_after_flush == keys, "scan after flush must match scan before flush"
        h.close()

    def test_multiple_70kb_values_flush(self, lib, tmp_path, Value, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        h.eavt_declare_attr(**{
            "name": "doc.data", "value_type": ValueType.String(),
            "many": True, "current_t": U64_MAX,
        })
        eids = []
        payloads = []
        for i in range(5):
            eid = h.allocate_entity_id()
            payload = _make_payload(LARGE_SIZE, chr(65 + i))
            h.eavt_save(**{
                "e_id": eid, "attr": "doc.data",
                "v": Value.Text(payload.decode()),
                "t": U64_MAX, "as_of_us": U64_MAX,
            })
            eids.append(eid)
            payloads.append(payload)

        h.flush()

        all_keys = _scan(h, b"")
        large_keys = [k for k in all_keys if len(k) > LARGE_SIZE]
        assert len(large_keys) >= 5, f"expected >=5 large keys, got {len(large_keys)} among {len(all_keys)} total"
        h.close()

    def test_70kb_value_survives_reopen(self, lib, tmp_path, Value, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        h.eavt_declare_attr(**{
            "name": "doc.persisted", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "Z")
        h.eavt_save(**{
            "e_id": eid, "attr": "doc.persisted",
            "v": Value.Text(payload.decode()),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.flush()
        h.close()

        h2 = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        keys = _scan(h2, struct.pack(">Q", eid))
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, "70KB key must survive flush + reopen"
        h2.close()


class TestLargeValueJournalRecovery:
    """Exercise journal write/read/replay path with 70KB+ keys."""

    def test_70kb_value_journal_recovery(self, lib, tmp_path, Value, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        h.eavt_declare_attr(**{
            "name": "doc.journaled", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        payload = _make_payload(LARGE_SIZE, "J")
        h.eavt_save(**{
            "e_id": eid, "attr": "doc.journaled",
            "v": Value.Text(payload.decode()),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.close()

        h2 = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        keys = _scan(h2, struct.pack(">Q", eid))
        assert len(keys) == 1
        assert len(keys[0]) > LARGE_SIZE, "70KB key must survive journal recovery on reopen"
        h2.close()


class TestLargeValueBatchWrite:
    """Exercise batch_write FFI path directly with large keys."""

    def test_batch_write_70kb_key(self, lib, tmp_path):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        big_key = _make_payload(LARGE_SIZE, "K")
        ops = bytearray()
        ops.append(0)
        ops.extend(struct.pack(">I", len(big_key)))
        ops.extend(big_key)
        h.batch_write(**{"ops": bytes(ops)})
        assert h.get(**{"cf": 0, "key": big_key}) is True
        h.close()

    def test_batch_put_70kb_key(self, lib, tmp_path):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        big_key = _make_payload(LARGE_SIZE, "P")
        buf = bytearray()
        buf.extend(struct.pack(">I", len(big_key)))
        buf.extend(big_key)
        h.batch_put(**{"cf": 0, "keys": bytes(buf)})
        assert h.get(**{"cf": 0, "key": big_key}) is True
        h.close()


class TestLargeValueCursorScan:
    """Exercise cursor + scan output framing with 70KB+ keys."""

    def test_scan_returns_70kb_keys(self, lib, tmp_path):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        keys_in = []
        for i in range(3):
            k = struct.pack(">Q", 100 + i) + _make_payload(LARGE_SIZE, chr(65 + i))
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

    def test_items_returns_70kb_keys(self, lib, tmp_path):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        k = _make_payload(LARGE_SIZE, "I")
        h.put(**{"cf": 0, "key": k})
        h.flush()
        raw = bytes(h.items(**{"cf": 0}))
        keys_out = unpack_keys(raw)
        assert len(keys_out) == 1
        assert len(keys_out[0]) >= LARGE_SIZE
        h.close()
