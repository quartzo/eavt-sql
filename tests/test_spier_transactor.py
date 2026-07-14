from __future__ import annotations

import struct

import pytest

from eavt_sql._ffi import load_spier
from helpers import unpack_keys


@pytest.fixture
def kv_lib():
    return load_spier("spier_transactor")


@pytest.fixture
def kv_instance(tmp_path):
    kv_lib = load_spier("spier_transactor")
    handle = kv_lib.create_handle({"backend": "file", "path": str(tmp_path)})
    yield handle
    handle.close()


class TestKVSchemaReflection:
    def test_idl_hash_matches(self, kv_lib):
        assert kv_lib.idl_hash() != 0

    def test_spier_name(self, kv_lib):
        assert kv_lib.name == "spier_transactor"

    def test_typed_methods_exist(self, kv_lib):
        cls = kv_lib._client_class
        for name in (
            "put", "get", "scan", "flush", "close", "journal_put",
            "journal_scan", "items", "batch_write", "path",
            "memtable_size", "memtable_count", "journal_size",
            "approximate_sizes", "cf_stats", "db_stats", "gc_full",
        ):
            assert hasattr(cls, name), f"missing typed method: {name}"


class TestKVPutGet:
    def test_put_then_get_found(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"key1"})
        assert kv_instance.get(**{"cf": 0, "key": b"key1"}) is True

    def test_get_missing(self, kv_instance, kv_lib):
        assert kv_instance.get(**{"cf": 0, "key": b"nonexistent"}) is False

    def test_put_multiple_cfs(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"cf0_key"})
        kv_instance.put(**{"cf": 1, "key": b"cf1_key"})
        kv_instance.put(**{"cf": 2, "key": b"cf2_key"})
        assert kv_instance.get(**{"cf": 0, "key": b"cf0_key"}) is True
        assert kv_instance.get(**{"cf": 1, "key": b"cf1_key"}) is True
        assert kv_instance.get(**{"cf": 2, "key": b"cf2_key"}) is True
        assert kv_instance.get(**{"cf": 0, "key": b"cf1_key"}) is False

    def test_put_overwrite(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"k"})
        kv_instance.put(**{"cf": 0, "key": b"k"})
        assert kv_instance.get(**{"cf": 0, "key": b"k"}) is True


class TestKVScan:
    def test_scan_empty(self, kv_instance, kv_lib):
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 0, "prefix": b""}))) == []

    def test_scan_returns_keys(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"aaa"})
        kv_instance.put(**{"cf": 0, "key": b"bbb"})
        kv_instance.put(**{"cf": 0, "key": b"ccc"})
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 0, "prefix": b""}))) == [b"aaa", b"bbb", b"ccc"]

    def test_scan_with_prefix(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"ns/aaa"})
        kv_instance.put(**{"cf": 0, "key": b"ns/bbb"})
        kv_instance.put(**{"cf": 0, "key": b"other"})
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 0, "prefix": b"ns/"}))) == [b"ns/aaa", b"ns/bbb"]

    def test_scan_separate_cfs(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        kv_instance.put(**{"cf": 1, "key": b"b"})
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 0, "prefix": b""}))) == [b"a"]
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 1, "prefix": b""}))) == [b"b"]

    def test_scan_reverse(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        kv_instance.put(**{"cf": 0, "key": b"b"})
        kv_instance.put(**{"cf": 0, "key": b"c"})
        assert unpack_keys(bytes(kv_instance.scan_reverse(**{"cf": 0, "prefix": b""}))) == [b"c", b"b", b"a"]


class TestKVFlush:
    def test_flush_then_scan(self, kv_instance, kv_lib, tmp_path):
        kv_instance.put(**{"cf": 0, "key": b"key1"})
        kv_instance.put(**{"cf": 0, "key": b"key2"})
        kv_instance.flush()
        assert unpack_keys(bytes(kv_instance.scan(**{"cf": 0, "prefix": b""}))) == [b"key1", b"key2"]


class TestKVJournal:
    def test_journal_put_scan(self, kv_instance, kv_lib):
        kv_instance.journal_put(**{"key": b"jk", "value": b"jv"})
        raw = bytes(kv_instance.journal_scan())
        pos = 0
        klen = int.from_bytes(raw[pos:pos + 4], "big"); pos += 4
        key = raw[pos:pos + klen]; pos += klen
        vlen = int.from_bytes(raw[pos:pos + 4], "big"); pos += 4
        val = raw[pos:pos + vlen]
        assert (key, val) == (b"jk", b"jv")


class TestKVClose:
    def test_close_then_error(self, kv_instance, kv_lib):
        kv_instance.close()
        with pytest.raises(RuntimeError, match="not open"):
            kv_instance.put(**{"cf": 0, "key": b"should_fail"})


class TestKVStorage:
    def test_creates_directories(self, tmp_path):
        data_dir = tmp_path / "deep"
        kv_lib = load_spier("spier_transactor")
        handle = kv_lib.create_handle({"backend": "file", "path": str(data_dir)})
        import os
        assert os.path.isdir(str(data_dir / "blobs"))
        handle.close()

    def test_empty_config_defaults_to_memory(self):
        kv_lib = load_spier("spier_transactor")
        handle = kv_lib.create_handle({})
        handle.put(**{"cf": 0, "key": b"k"})
        assert handle.get(**{"cf": 0, "key": b"k"}) is True
        handle.close()


class TestKVItems:
    def test_items_returns_all_keys(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"aaa"})
        kv_instance.put(**{"cf": 0, "key": b"bbb"})
        assert unpack_keys(bytes(kv_instance.items(**{"cf": 0}))) == [b"aaa", b"bbb"]

    def test_items_empty_cf(self, kv_instance, kv_lib):
        assert unpack_keys(bytes(kv_instance.items(**{"cf": 0}))) == []


class TestKVBatchWrite:
    def test_batch_write_multi_cf(self, kv_instance, kv_lib):
        ops = bytearray()
        for cf, key in [(0, b"k0"), (1, b"k1"), (2, b"k2")]:
            ops.append(cf)
            ops.extend(struct.pack(">I", len(key)))
            ops.extend(key)
        kv_instance.batch_write(**{"ops": bytes(ops)})
        assert kv_instance.get(**{"cf": 0, "key": b"k0"}) is True
        assert kv_instance.get(**{"cf": 1, "key": b"k1"}) is True
        assert kv_instance.get(**{"cf": 2, "key": b"k2"}) is True

    def test_batch_put_multiple_keys(self, kv_instance, kv_lib):
        keys = [b"a", b"bb", b"ccc", b"dddd", b"eeeee"]
        buf = bytearray()
        for key in keys:
            buf.extend(struct.pack(">I", len(key)))
            buf.extend(key)
        kv_instance.batch_put(**{"cf": 0, "keys": bytes(buf)})
        for key in keys:
            assert kv_instance.get(**{"cf": 0, "key": key}) is True

    def test_batch_put_many_keys(self, kv_instance, kv_lib):
        keys = [f"key_{i:04d}".encode() for i in range(50)]
        buf = bytearray()
        for key in keys:
            buf.extend(struct.pack(">I", len(key)))
            buf.extend(key)
        kv_instance.batch_put(**{"cf": 0, "keys": bytes(buf)})
        for key in keys:
            assert kv_instance.get(**{"cf": 0, "key": key}) is True


class TestKVPath:
    def test_path_returns_string(self, kv_instance, kv_lib, tmp_path):
        p = str(kv_instance.path())
        assert isinstance(p, str)


class TestKVMemtable:
    def test_memtable_size_grows(self, kv_instance, kv_lib):
        size0 = kv_instance.memtable_size()
        assert isinstance(size0, int)
        kv_instance.put(**{"cf": 0, "key": b"somewhat_long_key"})
        size1 = kv_instance.memtable_size()
        assert size1 > size0

    def test_memtable_count(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        kv_instance.put(**{"cf": 0, "key": b"b"})
        count = kv_instance.memtable_count(**{"cf": 0})
        assert count == 2


class TestKVJournalSize:
    def test_journal_size(self, kv_instance, kv_lib):
        size = kv_instance.journal_size()
        assert isinstance(size, int)

    def test_journal_size_after_flush(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"test"})
        kv_instance.journal_put(**{"key": b"jk", "value": b"\x00"})
        kv_instance.flush()
        size = kv_instance.journal_size()
        assert isinstance(size, int)


class TestKVApproximateSizes:
    def test_approximate_sizes(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"key_a"})
        kv_instance.put(**{"cf": 0, "key": b"key_b"})
        sz = kv_instance.approximate_sizes(**{"cf": 0, "start": b"key_a", "end": b"key_c"})
        assert isinstance(sz, int)
        assert sz > 0


class TestKVCfStats:
    def test_cf_stats_packed(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"testkey"})
        raw = bytes(kv_instance.cf_stats(**{"cf": 0}))
        assert isinstance(raw, bytes)
        assert len(raw) > 2
        name_len = struct.unpack_from("<H", raw, 0)[0]
        name = raw[2:2 + name_len].decode()
        assert "eavt" in name or "cf" in name or name.startswith("cf")


class TestKVDbStats:
    def test_db_stats_packed(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"test"})
        raw = bytes(kv_instance.db_stats())
        assert isinstance(raw, bytes)
        assert len(raw) == 16
        sst = struct.unpack_from("<Q", raw, 0)[0]
        live = struct.unpack_from("<Q", raw, 8)[0]
        assert isinstance(sst, int)
        assert isinstance(live, int)


class TestKVGcFull:
    def test_gc_full_dry_run(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"test"})
        kv_instance.flush()
        raw = bytes(kv_instance.gc_full(**{"dry_run": True, "nowait": True}))
        assert isinstance(raw, bytes)
        assert len(raw) == 41
        roots_scanned = struct.unpack_from("<Q", raw, 0)[0]
        dry_run_flag = raw[40]
        assert isinstance(roots_scanned, int)
        assert dry_run_flag == 1


# ---------------------------------------------------------------------------
# Cursor tests — forward + reverse (direct CursorHandle transport)
# ---------------------------------------------------------------------------

class TestKVCursorForward:
    def test_open_cursor_direct_returns_handle(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        cursor = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        assert cursor is not None

    def test_open_cursor_current_key(self, kv_instance, kv_lib):
        for k in [b"aaa", b"bbb", b"ccc"]:
            kv_instance.put(**{"cf": 0, "key": k})
        cursor_ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": cursor_ptr})
        assert has_data
        assert outs[0] == b"aaa"

    def test_open_cursor_empty_scan(self, kv_instance, kv_lib):
        cursor_ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        has_data, _ = kv_instance.cursor_current_key(**{"cursor": cursor_ptr})
        assert not has_data

    def test_open_cursor_with_prefix(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"ns/a"})
        kv_instance.put(**{"cf": 0, "key": b"ns/b"})
        kv_instance.put(**{"cf": 0, "key": b"other"})
        cursor_ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b"ns/"})
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": cursor_ptr})
        assert has_data and outs[0] == b"ns/a"

    def test_cursor_iteration(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"aaa"})
        kv_instance.put(**{"cf": 0, "key": b"bbb"})
        kv_instance.put(**{"cf": 0, "key": b"ccc"})

        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert keys == [b"aaa", b"bbb", b"ccc"]

    def test_cursor_with_prefix(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"ns/a"})
        kv_instance.put(**{"cf": 0, "key": b"ns/b"})
        kv_instance.put(**{"cf": 0, "key": b"other"})

        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b"ns/"})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert keys == [b"ns/a", b"ns/b"]

    def test_cursor_empty_scan(self, kv_instance, kv_lib):
        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        has_data, _ = kv_instance.cursor_current_key(**{"cursor": ptr})
        assert not has_data

    def test_cursor_seek(self, kv_instance, kv_lib):
        for c in [b"a1", b"a2", b"a3", b"b1", b"b2"]:
            kv_instance.put(**{"cf": 0, "key": c})

        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        kv_instance.cursor_seek(**{"cursor": ptr, "target": b"b"})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert keys == [b"b1", b"b2"]

    def test_cursor_skip_group(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"aa1"})
        kv_instance.put(**{"cf": 0, "key": b"aa2"})
        kv_instance.put(**{"cf": 0, "key": b"aa3"})
        kv_instance.put(**{"cf": 0, "key": b"bb1"})

        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        assert has_data and outs[0] == b"aa1"
        kv_instance.cursor_skip_group(**{"cursor": ptr, "group_end": 2})
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        assert has_data and outs[0] == b"bb1"

    def test_cursor_update_end(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        kv_instance.put(**{"cf": 0, "key": b"b"})
        kv_instance.put(**{"cf": 0, "key": b"c"})

        ptr = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        kv_instance.cursor_update_end(**{"cursor": ptr, "end": b"b\xFF" * 16})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert b"a" in keys
        assert b"b" in keys
        assert b"c" not in keys

    def test_multiple_cursors(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"x"})
        kv_instance.put(**{"cf": 1, "key": b"y"})

        p0 = kv_instance.open_cursor_direct(**{"cf": 0, "prefix": b""})
        p1 = kv_instance.open_cursor_direct(**{"cf": 1, "prefix": b""})

        has_data, outs = kv_instance.cursor_current_key(**{"cursor": p0})
        assert has_data and outs[0] == b"x"
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": p1})
        assert has_data and outs[0] == b"y"



class TestKVCursorReverse:
    def test_reverse_iteration(self, kv_instance, kv_lib):
        kv_instance.put(**{"cf": 0, "key": b"a"})
        kv_instance.put(**{"cf": 0, "key": b"b"})
        kv_instance.put(**{"cf": 0, "key": b"c"})

        ptr = kv_instance.open_cursor_reverse_direct(**{"cf": 0, "prefix": b""})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert keys == [b"c", b"b", b"a"]

    def test_reverse_seek(self, kv_instance, kv_lib):
        for c in [b"a1", b"a2", b"b1", b"b2", b"c1"]:
            kv_instance.put(**{"cf": 0, "key": c})

        ptr = kv_instance.open_cursor_reverse_direct(**{"cf": 0, "prefix": b""})
        kv_instance.cursor_seek(**{"cursor": ptr, "target": b"b\xFF" * 8})
        keys = []
        has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})
        while has_data:
            keys.append(outs[0])
            kv_instance.cursor_step(**{"cursor": ptr})
            has_data, outs = kv_instance.cursor_current_key(**{"cursor": ptr})

        assert keys[0] in [b"b2", b"b1"]
        for k in keys:
            assert k <= b"b\xff" * 2
