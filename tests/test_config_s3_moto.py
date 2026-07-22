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


# spier_kvstore_py was merged into spier-page-store-nim.
# S3 backend KV-level tests need re-implementation via spier_eavt_query_py.
# Mark xfail until KV-level bindings are re-exposed.

@pytest.mark.xfail(reason="spier_kvstore_py deleted; KV-level put/get/scan not yet re-exposed")
class TestS3Backend:
    def test_s3_put_get(self, s3_endpoint, tmp_path):
        import spier_eavt_query_py
        handle = spier_eavt_query_py.Engine(_s3_config(s3_endpoint, str(tmp_path)))
        handle.save(1, "test.attr", "hello", 1)
        handle.flush()
        handle.close()

    def test_s3_scan_and_flush(self, s3_endpoint, tmp_path):
        import spier_eavt_query_py
        handle = spier_eavt_query_py.Engine(_s3_config(s3_endpoint, str(tmp_path)))
        for i in range(5):
            handle.save(i + 1, "test.item", f"item{i:03d}", 1)
        handle.flush()
        handle.close()

    def test_s3_cursor(self, s3_endpoint, tmp_path):
        import spier_eavt_query_py
        handle = spier_eavt_query_py.Engine(_s3_config(s3_endpoint, str(tmp_path)))
        for i in range(3):
            handle.save(i + 1, "test.cur", f"cur{i}", 1)
        handle.flush()
        handle.close()
