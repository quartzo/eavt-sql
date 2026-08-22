import json, os, socket, struct
from pathlib import Path

import msgpack

# Shared Packer — packb() builds a new Packer per call; reusing one skips
# that setup cost on every request (single-threaded use only).
_PACKER = msgpack.Packer()
_UNPACKER_KW = {"raw": False}


class Sym(str):
    """Marks a string as a Scheme symbol (wire tag 3). Plain `str` values
    are encoded as Scheme strings (tag 2)."""


def to_wire(v):
    """Convert a Python value to the tagged AST wire form (docs/scheme-transport.md §3.3).

    int → [0, i], float → [1, f], str → [2, s], Sym → [3, s], bool → [4, b],
    bytes → [5, [...]], None → [6, null], list/tuple → [7, [children]].
    """
    if isinstance(v, Sym):
        return [3, str(v)]
    if v is None:
        return [6, None]
    if isinstance(v, bool):
        return [4, v]
    if isinstance(v, int):
        return [0, v]
    if isinstance(v, float):
        return [1, v]
    if isinstance(v, str):
        return [2, v]
    if isinstance(v, (bytes, bytearray)):
        return [5, list(v)]
    if isinstance(v, (list, tuple)):
        return [7, [to_wire(x) for x in v]]
    raise TypeError(f"cannot encode {type(v).__name__} as scheme AST")


class EavtClient:
    """EAVT database client over Unix Domain Socket with msgpack streaming protocol."""

    def __init__(self, sock_path: str | None = None):
        if sock_path is None:
            sock_path = self._default_path()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(sock_path)

    @staticmethod
    def _default_path() -> str:
        xdg = Path("/run/user") / str(os.getuid()) / "eavt" / "eavt-query.sock"
        if xdg.exists() or "XDG_RUNTIME_DIR" in os.environ:
            return str(xdg)
        return str(Path.home() / ".local" / "state" / "eavt" / "eavt-query.sock")

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
            req["params"] = [to_wire(p) for p in params]
        self._send_msg(_PACKER.pack(req))
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
        self._send_msg(_PACKER.pack(req))
        resp = msgpack.unpackb(self._recv_msg())
        return resp.get("output", "")

    def _recv_loop(self):
        """Read response chunks until more=false; raises on error frames."""
        results = []
        while True:
            resp = msgpack.unpackb(self._recv_msg(), **_UNPACKER_KW)
            if "error" in resp and resp["error"]:
                raise RuntimeError(resp["error"])
            results.append(resp)
            if not resp.get("more", False):
                break
        return results

    def scheme_wire(self, program, *params, mode: str = "exec") -> list[dict]:
        """Execute a program already in tagged-wire form (lists of
        [tag, value] nodes) — skips the to_wire() conversion pass.

        Wire tag table (docs/scheme-transport.md §3.3):
          0=int, 1=float, 2=str, 3=symbol, 4=bool, 5=bytes, 6=void, 7=list
        """
        req = {"type": "scheme", "program": program, "mode": mode}
        if params:
            req["params"] = list(params)
        self._send_msg(_PACKER.pack(req))
        return self._recv_loop()

    def scheme(self, program, *params, mode: str = "query") -> list[dict]:
        """Execute a Scheme program (tagged AST, see to_wire) on the server.

        mode="query" streams rows; mode="exec" runs to completion.
        Returns all result chunks as a list of dicts, like sql().
        """
        req = {"type": "scheme", "program": to_wire(program), "mode": mode}
        if params:
            req["params"] = [to_wire(p) for p in params]
        self._send_msg(_PACKER.pack(req))
        return self._recv_loop()

    def schema(self) -> dict:
        """Fetch the schema snapshot (attrIds, indexEstimates, partitionIds, refAttrs)."""
        req = {"type": "schema"}
        self._send_msg(_PACKER.pack(req))
        resp = msgpack.unpackb(self._recv_msg())
        if resp.get("error"):
            raise RuntimeError(resp["error"])
        return resp["schema"]

    def flush(self):
        return self.admin("flush")

    def status(self) -> str:
        return self.admin("status")
