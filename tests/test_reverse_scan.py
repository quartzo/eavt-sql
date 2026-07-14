from __future__ import annotations

import pytest

from eavt_sql._ffi import load_spier
from helpers import unpack_keys


CF = 0


@pytest.fixture
def kv_lib():
    return load_spier("spier_transactor")


@pytest.fixture
def kv(kv_lib, tmp_path):
    handle = kv_lib.create_handle({"backend": "file", "path": str(tmp_path)})
    yield handle
    handle.close()


def _scan_keys(kv, prefix=b""):
    return unpack_keys(bytes(kv.scan(**{"cf": CF, "prefix": prefix})))


def _scan_reverse_keys(kv, prefix=b""):
    return unpack_keys(bytes(kv.scan_reverse(**{"cf": CF, "prefix": prefix})))


def _cursor_collect(kv, ptr):
    keys = []
    has_data, outs = kv.cursor_current_key(**{"cursor": ptr})
    while has_data:
        keys.append(outs[0])
        kv.cursor_step(**{"cursor": ptr})
        has_data, outs = kv.cursor_current_key(**{"cursor": ptr})
    return keys


class TestScanReverseBasic:
    def test_empty_store(self, kv):
        h = kv
        assert _scan_reverse_keys(h) == []

    def test_memtable_only(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"key_01"})
        h.put(**{"cf": CF, "key": b"key_02"})
        h.put(**{"cf": CF, "key": b"key_03"})
        assert _scan_reverse_keys(h) == [b"key_03", b"key_02", b"key_01"]

    def test_single_region(self, kv):
        h = kv
        for i in range(5):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
        h.flush()
        result = _scan_reverse_keys(h)
        assert len(result) == 5
        assert result[0] == b"key_0004"
        assert result[len(result) - 1] == b"key_0000"

    def test_multiple_regions(self, kv):
        h = kv
        for i in range(3):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
            h.flush()
        result = _scan_reverse_keys(h)
        assert len(result) == 3
        assert result[0] == b"key_0002"
        assert result[len(result) - 1] == b"key_0000"

    def test_forward_equals_reverse_of_reverse(self, kv):
        h = kv
        for i in range(10):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
        h.flush()
        forward = _scan_keys(h)
        reverse = _scan_reverse_keys(h)
        assert forward == list(reversed(reverse))


class TestScanReversePrefix:
    def test_prefix_filter(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"aa_1"})
        h.put(**{"cf": CF, "key": b"aa_2"})
        h.put(**{"cf": CF, "key": b"bb_1"})
        h.put(**{"cf": CF, "key": b"bb_2"})
        h.flush()
        assert _scan_reverse_keys(h, b"aa") == [b"aa_2", b"aa_1"]

    def test_prefix_no_match(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"aa_1"})
        h.flush()
        assert _scan_reverse_keys(h, b"zz") == []

    def test_prefix_single_result(self, kv):
        h = kv
        for c in "abcdefgh":
            h.put(**{"cf": CF, "key": c.encode()})
        h.flush()
        assert _scan_reverse_keys(h, b"c") == [b"c"]


class TestScanReverseIterator:
    def test_iter_basic(self, kv):
        h = kv
        for i in range(5):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
        h.flush()
        ptr = h.open_cursor_reverse_direct(**{"cf": CF, "prefix": b""})
        result = _cursor_collect(h, ptr)
        assert len(result) == 5
        assert result[0] == b"key_0004"
        assert result[-1] == b"key_0000"

    def test_iter_seek_reverse(self, kv):
        h = kv
        for i in range(10):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
        h.flush()
        ptr = h.open_cursor_reverse_direct(**{"cf": CF, "prefix": b""})
        h.cursor_seek(**{"cursor": ptr, "target": b"key_0005"})
        has_data, outs = h.cursor_current_key(**{"cursor": ptr})
        assert has_data and outs[0] == b"key_0005"
        h.cursor_step(**{"cursor": ptr})
        has_data, outs = h.cursor_current_key(**{"cursor": ptr})
        assert has_data and outs[0] == b"key_0004"

    def test_iter_seek_before_all(self, kv):
        h = kv
        for i in range(5):
            h.put(**{"cf": CF, "key": f"key_{i:04d}".encode()})
        h.flush()
        ptr = h.open_cursor_reverse_direct(**{"cf": CF, "prefix": b"key_"})
        h.cursor_seek(**{"cursor": ptr, "target": b"key_0000"})
        has_data, outs = h.cursor_current_key(**{"cursor": ptr})
        assert has_data and outs[0] == b"key_0000"
        h.cursor_step(**{"cursor": ptr})
        has_data, _ = h.cursor_current_key(**{"cursor": ptr})
        assert not has_data


class TestScanReverseMerge:
    def test_memtable_and_region(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"key_0001"})
        h.put(**{"cf": CF, "key": b"key_0003"})
        h.flush()
        h.put(**{"cf": CF, "key": b"key_0002"})
        result = _scan_reverse_keys(h)
        assert len(result) == 3
        assert result == [b"key_0003", b"key_0002", b"key_0001"]

    def test_overwrite_memtable_wins(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"key_0001"})
        h.flush()
        h.put(**{"cf": CF, "key": b"key_0001"})
        fwd = _scan_keys(h)
        rev = _scan_reverse_keys(h)
        assert len(fwd) == 1
        assert len(rev) == 1


class TestScanReverseSingleEntry:
    def test_one_entry(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"only"})
        h.flush()
        assert _scan_reverse_keys(h) == [b"only"]

    def test_one_entry_memtable(self, kv):
        h = kv
        h.put(**{"cf": CF, "key": b"only"})
        assert _scan_reverse_keys(h) == [b"only"]


class TestScanReverseLargeRestartBlock:
    def test_crosses_restart_boundary(self, kv):
        h = kv
        n = 300
        for i in range(n):
            h.put(**{"cf": CF, "key": f"k{i:06d}".encode()})
        h.flush()
        forward = _scan_keys(h)
        reverse = _scan_reverse_keys(h)
        assert len(forward) == n
        assert len(reverse) == n
        assert forward == list(reversed(reverse))

    def test_crosses_restart_with_prefix(self, kv):
        h = kv
        for i in range(300):
            h.put(**{"cf": CF, "key": f"aa{i:06d}".encode()})
        for i in range(10):
            h.put(**{"cf": CF, "key": f"bb{i:06d}".encode()})
        h.flush()
        forward_aa = _scan_keys(h, b"aa")
        reverse_aa = _scan_reverse_keys(h, b"aa")
        assert len(forward_aa) == 300
        assert len(reverse_aa) == 300
        assert forward_aa == list(reversed(reverse_aa))
        forward_bb = _scan_keys(h, b"bb")
        reverse_bb = _scan_reverse_keys(h, b"bb")
        assert len(forward_bb) == 10
        assert forward_bb == list(reversed(reverse_bb))
