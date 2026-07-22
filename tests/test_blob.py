"""Tests for BLOB attribute type — u32 length prefix + raw bytes (no ordering encoding)."""

import pytest
from eavt_sql.engine import EAVTEngine


def _make_engine():
    engine = EAVTEngine(":memory:")
    return engine


class TestBlobBasic:
    def test_declare_and_save(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        raw = b"\xde\xad\xbe\xef\xca\xfe"
        rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
        eid = rows[0][0]
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == raw
        engine.close()

    def test_empty_bytes(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        rows = list(engine.sql("UPSERT SET blob.data = %1", b""))
        eid = rows[0][0]
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == b""
        engine.close()

    def test_short_bytes_collision_with_fixed_key_len(self):
        """4 bytes of data → key length == 28 (FIXED_KEY_LEN). Must still decode correctly."""
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        raw = b"\x01\x02\x03\x04"
        rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
        eid = rows[0][0]
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == raw
        engine.close()

    def test_large_bytes(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        raw = bytes(range(256)) * 100  # 25.6KB
        rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
        eid = rows[0][0]
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == raw
        engine.close()

    def test_bytes_with_nulls(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        raw = b"\x00\x00\xff\x00\xfe\x00"
        rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
        eid = rows[0][0]
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert results[0][0] == raw
        engine.close()


class TestBlobCardinality:
    def test_many_accumulates(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB MANY"))
        list(engine.sql("UPSERT SET blob.data = %1", b"\x01\x02"))
        list(engine.sql("UPSERT SET blob.data = %1", b"\x03\x04"))
        results = list(engine.sql("SELECT d1.blob.data"))
        vals = {r[0] for r in results}
        assert vals == {b"\x01\x02", b"\x03\x04"}
        engine.close()

    def test_one_overwrites(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        rows1 = list(engine.sql("UPSERT SET blob.data = %1", b"\xaa\xbb"))
        eid = rows1[0][0]
        list(engine.sql("UPSERT AS D1 = %1 SET blob.data = %2", eid, b"\xcc\xdd"))
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == b"\xcc\xdd"
        engine.close()

    def test_retract(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        rows = list(engine.sql("UPSERT SET blob.data = %1", b"\x01\x02\x03"))
        eid = rows[0][0]
        list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.blob.data = %2", eid, b"\x01\x02\x03"))
        results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert results == []
        engine.close()


class TestBlobPersistence:
    def test_survives_reopen(self, tmp_path):
        engine = EAVTEngine(str(tmp_path / "db"))
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        raw = b"\xde\xad\xbe\xef" * 100
        rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
        eid = rows[0][0]
        engine.close()

        engine2 = EAVTEngine(str(tmp_path / "db"))
        results = list(engine2.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
        assert len(results) == 1
        assert results[0][0] == raw
        engine2.close()


class TestBlobTypeValidation:
    def test_rejects_string(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        with pytest.raises(Exception, match="type mismatch"):
            list(engine.sql("UPSERT SET blob.data = %1", "not bytes"))
        engine.close()

    def test_accepts_bytes(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.data BLOB ONE"))
        rows = list(engine.sql("UPSERT SET blob.data = %1", b"\xff\xfe"))
        assert len(rows) == 1
        engine.close()


class TestBlobCoexistsWithOrdered:
    def test_both_types_same_engine(self):
        engine = _make_engine()
        list(engine.sql("ATTRIBUTE blob.ordered BYTES ONE"))
        list(engine.sql("ATTRIBUTE blob.unordered BLOB ONE"))

        ordered_data = b"\xde\xad\xbe\xef"
        unordered_data = b"\xca\xfe\xf0\x0d" * 50

        rows = list(engine.sql(
            "UPSERT SET blob.ordered = %1, blob.unordered = %2",
            ordered_data, unordered_data,
        ))
        eid = rows[0][0]

        r1 = list(engine.sql("SELECT d1.blob.ordered WHERE d1.eid = %1", eid))
        r2 = list(engine.sql("SELECT d1.blob.unordered WHERE d1.eid = %1", eid))
        assert r1[0][0] == ordered_data
        assert r2[0][0] == unordered_data
        engine.close()
