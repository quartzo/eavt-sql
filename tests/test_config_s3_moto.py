from __future__ import annotations

import boto3
import pytest
from moto.moto_server.threaded_moto_server import ThreadedMotoServer


@pytest.fixture
def s3_endpoint(tmp_path):
    """Start ThreadedMotoServer and yield its endpoint URL."""
    port = 5630
    server = ThreadedMotoServer(port=port, verbose=False)
    server.start()
    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=f"http://127.0.0.1:{port}",
            region_name="us-east-1",
            aws_access_key_id="testing",
            aws_secret_access_key="testing",
        )
        s3.create_bucket(Bucket="test-bucket")
        yield f"http://127.0.0.1:{port}"
    finally:
        server.stop()


def _s3_config(endpoint: str, path: str) -> dict:
    return {
        "backend": "s3",
        "path": path,
        "endpoint": endpoint,
        "bucket_name": "test-bucket",
        "region": "us-east-1",
        "access_key": "testing",
        "secret_key": "testing",
    }


class TestS3Backend:
    def test_s3_put_get(self, s3_endpoint, tmp_path):
        from eavt_sql._ffi import load_spier

        kv_lib = load_spier("spier_transactor")
        handle = kv_lib.create_handle(_s3_config(s3_endpoint, str(tmp_path)))

        handle.put(**{"cf": 0, "key": b"s3key1"})
        assert handle.get(**{"cf": 0, "key": b"s3key1"}) is True
        assert handle.get(**{"cf": 0, "key": b"s3missing"}) is False
        handle.close()

    def test_s3_scan_and_flush(self, s3_endpoint, tmp_path):
        from eavt_sql._ffi import load_spier

        kv_lib = load_spier("spier_transactor")
        handle = kv_lib.create_handle(_s3_config(s3_endpoint, str(tmp_path)))

        for i in range(5):
            handle.put(**{"cf": 0, "key": f"item{i:03d}".encode()})
        handle.flush()

        raw = handle.scan(**{"cf": 0, "prefix": b"item"})
        keys = []
        pos = 0
        while pos + 4 <= len(raw):
            klen = int.from_bytes(raw[pos : pos + 4], "big")
            pos += 4
            keys.append(raw[pos : pos + klen])
            pos += klen
        assert len(keys) == 5
        assert keys == [b"item000", b"item001", b"item002", b"item003", b"item004"]
        handle.close()

    def test_s3_cursor(self, s3_endpoint, tmp_path):
        from eavt_sql._ffi import load_spier

        kv_lib = load_spier("spier_transactor")
        handle = kv_lib.create_handle(_s3_config(s3_endpoint, str(tmp_path)))

        for i in range(3):
            handle.put(**{"cf": 1, "key": f"cur{i}".encode()})
        handle.flush()

        cur = handle.open_cursor_direct(**{"cf": 1, "prefix": b"cur"})
        keys = []
        has_data, outs = handle.cursor_current_key(**{"cursor": cur})
        while has_data:
            keys.append(outs[0])
            handle.cursor_step(**{"cursor": cur})
            has_data, outs = handle.cursor_current_key(**{"cursor": cur})

        assert keys == [b"cur0", b"cur1", b"cur2"]
        handle.close()
