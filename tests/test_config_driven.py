from __future__ import annotations

import os
import subprocess
import sys

import pytest


def _run_in_subprocess(script: str, tmp_path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=15,
        env={**os.environ, "TEST_TMP_PATH": str(tmp_path)},
    )


class TestConfigFileBackend:
    def test_put_get_no_set_path(self, tmp_path):
        script = '''
import os
tmp = os.environ["TEST_TMP_PATH"]
from eavt_sql._ffi import load_spier

kv_lib = load_spier("spier_transactor")
handle = kv_lib.create_handle({"backend": "file", "path": tmp})

handle.put(**{"cf": 0, "key": b"hello"})
assert handle.get(**{"cf": 0, "key": b"hello"}) is True
assert handle.get(**{"cf": 0, "key": b"world"}) is False
handle.close()
handle.close()
print("OK")
'''
        result = _run_in_subprocess(script, tmp_path)
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "OK" in result.stdout

    def test_scan_no_set_path(self, tmp_path):
        script = '''
import os
tmp = os.environ["TEST_TMP_PATH"]
from eavt_sql._ffi import load_spier

kv_lib = load_spier("spier_transactor")
handle = kv_lib.create_handle({"backend": "file", "path": tmp})

for i in range(5):
    handle.put(**{"cf": 0, "key": f"key{i:03d}".encode()})
handle.flush()

raw = handle.scan(**{"cf": 0, "prefix": b"key"})
keys = []
pos = 0
while pos + 4 <= len(raw):
    klen = int.from_bytes(raw[pos:pos + 4], "big"); pos += 4
    keys.append(raw[pos:pos + klen]); pos += klen
assert len(keys) == 5
assert keys[0] == b"key000"
assert keys[4] == b"key004"
handle.close()
handle.close()
print("OK")
'''
        result = _run_in_subprocess(script, tmp_path)
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "OK" in result.stdout

    def test_flush_and_cursor(self, tmp_path):
        script = '''
import os
tmp = os.environ["TEST_TMP_PATH"]
from eavt_sql._ffi import load_spier

kv_lib = load_spier("spier_transactor")
handle = kv_lib.create_handle({"backend": "file", "path": tmp})

for i in range(10):
    handle.put(**{"cf": 0, "key": f"k{i:04d}".encode()})
handle.flush()

ptr = handle.open_cursor_direct(**{"cf": 0, "prefix": b"k"})
keys = []
has_data, outs = handle.cursor_current_key(**{"cursor": ptr})
while has_data:
    keys.append(outs[0])
    handle.cursor_step(**{"cursor": ptr})
    has_data, outs = handle.cursor_current_key(**{"cursor": ptr})

assert len(keys) == 10
assert keys[0] == b"k0000"
assert keys[9] == b"k0009"
handle.close()
handle.close()
print("OK")
'''
        result = _run_in_subprocess(script, tmp_path)
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "OK" in result.stdout


class TestConfigMemoryBackend:
    def test_memory_auto_init(self, tmp_path):
        script = '''
from eavt_sql._ffi import load_spier

kv_lib = load_spier("spier_transactor")
handle = kv_lib.create_handle({"backend": "memory"})

handle.put(**{"cf": 1, "key": b"memkey"})
assert handle.get(**{"cf": 1, "key": b"memkey"}) is True
handle.close()
handle.close()
print("OK")
'''
        result = _run_in_subprocess(script, tmp_path)
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "OK" in result.stdout

    def test_memory_multi_cf(self, tmp_path):
        script = '''
from eavt_sql._ffi import load_spier

kv_lib = load_spier("spier_transactor")
handle = kv_lib.create_handle({"backend": "memory"})

for cf in range(4):
    handle.put(**{"cf": cf, "key": f"cf{cf}".encode()})
for cf in range(4):
    assert handle.get(**{"cf": cf, "key": f"cf{cf}".encode()}) is True
handle.close()
handle.close()
print("OK")
'''
        result = _run_in_subprocess(script, tmp_path)
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "OK" in result.stdout
