import json, os, socket, struct
from pathlib import Path

import msgpack


class EavtClient:
    """EAVT database client over Unix Domain Socket with msgpack streaming protocol."""

    def __init__(self, sock_path: str | None = None):
        if sock_path is None:
            sock_path = self._default_path()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(sock_path)

    @staticmethod
    def _default_path() -> str:
        xdg = Path("/run/user") / str(os.getuid()) / "eavt" / "eavt.sock"
        if xdg.exists() or "XDG_RUNTIME_DIR" in os.environ:
            return str(xdg)
        return str(Path.home() / ".local" / "state" / "eavt" / "eavt.sock")

    def close(self):
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _send_msg(self, data: bytes):
        self._sock.sendall(struct.pack(">I", len(data)) + data)

    def _recv_msg(self) -> bytes:
        raw = self._sock.recv(4)
        if len(raw) < 4:
            raise ConnectionError("server closed connection")
        size = struct.unpack(">I", raw)[0]
        data = b""
        while len(data) < size:
            chunk = self._sock.recv(size - len(data))
            if not chunk:
                raise ConnectionError("server closed connection mid-message")
            data += chunk
        return data

    def sql(self, query: str, *params) -> list[dict]:
        """Execute SQL and return all result chunks as list of dicts."""
        req = {"type": "sql", "sql": query}
        if params:
            req["params"] = list(params)
        self._send_msg(msgpack.packb(req))
        results = []
        while True:
            resp = msgpack.unpackb(self._recv_msg())
            if "error" in resp and resp["error"]:
                raise RuntimeError(resp["error"])
            results.append(resp)
            if not resp.get("more", False):
                break
        return results

    def execute(self, query: str, *params) -> list[tuple]:
        """Execute SQL and return rows as flat tuples."""
        chunks = self.sql(query, *params)
        rows = []
        for chunk in chunks:
            for row in chunk.get("rows", []):
                rows.append(tuple(row))
        return rows

    def sql1(self, query: str, *params) -> tuple | None:
        """Execute SQL and return first row as tuple, or None."""
        rows = self.execute(query, *params)
        return rows[0] if rows else None

    def admin(self, command: str) -> str:
        """Send admin command and return output."""
        req = {"type": "admin", "command": command}
        self._send_msg(msgpack.packb(req))
        resp = msgpack.unpackb(self._recv_msg())
        return resp.get("output", "")

    def flush(self):
        return self.admin("flush")

    def status(self) -> str:
        return self.admin("status")
