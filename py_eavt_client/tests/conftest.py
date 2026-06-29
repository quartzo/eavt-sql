import os
import subprocess
import time
import tempfile
import grpc
import pytest

from eavt_client import EavtClient

SERVER_BIN = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "target", "debug", "eavt-server"
)


def _wait_for_server(addr: str, timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            ch = grpc.insecure_channel(addr)
            grpc.channel_ready_future(ch).result(timeout=1)
            ch.close()
            return True
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"server not ready at {addr}")


_next_port_counter = 50060

def _next_port():
    global _next_port_counter
    _next_port_counter += 1
    return _next_port_counter


@pytest.fixture(scope="session")
def server_bin():
    server_bin = os.path.abspath(SERVER_BIN)
    if not os.path.exists(server_bin):
        pytest.skip(f"eavt-server not built — run: cargo build -p eavt-server (looked at {server_bin})")
    return server_bin


@pytest.fixture
def client(server_bin):
    port = _next_port()
    db_dir = tempfile.mkdtemp(prefix="eavt-test-")
    db_path = os.path.join(db_dir, "test.db")
    addr = f"127.0.0.1:{port}"

    proc = subprocess.Popen(
        [server_bin, db_path, "--addr", addr],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    time.sleep(1)
    if proc.poll() is not None:
        out = proc.stdout.read().decode()
        pytest.skip(f"server crashed: {out}")

    _wait_for_server(addr)
    c = EavtClient(addr)
    yield c
    c.close()
    proc.terminate()
    proc.wait(timeout=5)
    import shutil
    shutil.rmtree(db_dir, ignore_errors=True)
