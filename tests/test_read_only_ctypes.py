from __future__ import annotations

import pytest

from eavt_sql._ffi import load_spier
from helpers import unpack_keys


CF = 0


def _file_config(tmp_path, read_only=False):
    config = {"backend": "file", "path": str(tmp_path)}
    if read_only:
        config["read_only"] = "true"
    return config


def _open_writable(tmp_path):
    kv_lib = load_spier("spier_transactor")
    handle = kv_lib.create_handle(_file_config(tmp_path, read_only=False))
    return handle


def _open_read_only(tmp_path):
    kv_lib = load_spier("spier_transactor")
    handle = kv_lib.create_handle(_file_config(tmp_path, read_only=True))
    return handle


class TestReadOnlyBasic:
    def test_read_only_can_read_committed_data(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01key"})
        h.flush()
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        assert ro.get(**{"cf": CF, "key": b"\x01key"}) is True
        ro.close()
        ro.close()

    def test_read_only_can_list_items(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01a"})
        h.put(**{"cf": CF, "key": b"\x01b"})
        h.flush()
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        keys = unpack_keys(bytes(ro.items(**{"cf": CF})))
        assert len(keys) == 2
        assert b"\x01a" in keys
        assert b"\x01b" in keys
        ro.close()
        ro.close()

    def test_read_only_put_raises(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01key"})
        h.flush()
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        with pytest.raises(RuntimeError, match="read-only"):
            ro.put(**{"cf": CF, "key": b"\x01key"})
        ro.close()
        ro.close()

    def test_read_only_flush_raises(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01key"})
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        with pytest.raises(RuntimeError, match="read-only"):
            ro.flush()
        ro.close()
        ro.close()

    def test_read_only_replays_wal(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01key"})
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        assert ro.get(**{"cf": CF, "key": b"\x01key"}) is True
        ro.close()
        ro.close()

    def test_read_only_scan(self, tmp_path):
        h = _open_writable(tmp_path)
        h.put(**{"cf": CF, "key": b"\x01a"})
        h.put(**{"cf": CF, "key": b"\x01b"})
        h.flush()
        h.close()
        h.close()

        ro = _open_read_only(tmp_path)
        result = unpack_keys(bytes(ro.scan(**{"cf": CF, "prefix": b"\x01"})))
        assert len(result) == 2
        ro.close()
        ro.close()
