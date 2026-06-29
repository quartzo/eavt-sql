from __future__ import annotations

import re
from datetime import datetime, tzinfo
from typing import Any, Generator

from ._ffi import load_spier
from .query_codec import encode_values, decode_values, decode_rows

U64_MAX = 0xFFFFFFFFFFFFFFFF


class EAVTEngine:
    """EAVT engine that talks to spier-eavt-query.so via DynSpire FFI."""

    def __init__(
        self,
        db_path: str,
        *,
        tz: tzinfo | None = None,
        read_only: bool = False,
        page_cache_size: int | None = None,
        flush_threshold: int | None = None,
        gc_max_root_count: int | None = None,
    ) -> None:
        self._tz = tz if tz is not None else datetime.now().astimezone().tzinfo
        self._lib = load_spier("spier_eavt_query")
        self._handle = self._open(db_path, read_only, page_cache_size, flush_threshold, gc_max_root_count)

    def _open(
        self,
        db_path: str,
        read_only: bool,
        page_cache_size: int | None = None,
        flush_threshold: int | None = None,
        gc_max_root_count: int | None = None,
    ) -> Any:
        if db_path == ":memory:":
            import tempfile

            self._tmpdir = tempfile.TemporaryDirectory()
            real_path = f"{self._tmpdir.name}/db"
            config = {"backend": "file", "path": real_path}
        elif db_path.startswith("s3://"):
            config = {"backend": "s3", "path": db_path}
        else:
            config = {"backend": "file", "path": db_path}
            if read_only:
                config["read_only"] = "true"
        if page_cache_size is not None:
            config["page_cache_size"] = str(page_cache_size)
        if flush_threshold is not None:
            config["flush_threshold"] = str(flush_threshold)
        if gc_max_root_count is not None:
            config["gc_max_root_count"] = str(gc_max_root_count)
        return self._lib.create_handle(config)

    @property
    def _db_path(self) -> str:
        return self._handle.path()

    def _parse_as_of(self, as_of: datetime | str | int | None) -> int:
        if as_of is None:
            return U64_MAX
        if isinstance(as_of, int):
            if as_of > (1 << 44):
                return as_of & ((1 << 44) - 1)
            return as_of
        if isinstance(as_of, str):
            dt = datetime.fromisoformat(as_of)
        else:
            dt = as_of
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=self._tz)
        return int(dt.timestamp() * 1_000_000)

    def sql(
        self,
        query: str,
        *params: Any,
        as_of: datetime | str | None = None,
        tz: tzinfo | None = None,
        limit: int | None = None,
    ) -> Generator[tuple, None, None]:
        stripped = query.strip()
        upper = stripped.upper()

        if upper.startswith("EXPLAIN "):
            inner = stripped[8:]
            params_bytes = encode_values(list(params))
            try:
                result = self._handle.explain(inner, params_bytes)
            except RuntimeError as e:
                raise ValueError(str(e)) from None
            for line in str(result).split("\n"):
                if line:
                    yield (line,)
            return

        params_bytes = encode_values(list(params))
        try:
            prog = self._handle.compile_sql(stripped, params_bytes)
        except RuntimeError as e:
            raise ValueError(str(e)) from None

        params_bytes = encode_values(list(params))
        limit_val = U64_MAX if limit is None else limit
        as_of_val = self._parse_as_of(as_of)

        try:
            session = self._handle.run_vm_cursor(prog, params_bytes, limit_val, as_of_val)
        except RuntimeError as e:
            raise ValueError(str(e)) from None

        try:
            while True:
                try:
                    batch_bytes = self._handle.session_next_batch(session, 1024)
                except RuntimeError as e:
                    raise ValueError(str(e)) from None

                batch_bytes = bytes(batch_bytes) if batch_bytes is not None else b""
                if not batch_bytes:
                    break
                for row in decode_rows(batch_bytes):
                    yield row
        finally:
            del session

    def sql1(
        self,
        query: str,
        *params: Any,
        as_of: datetime | str | None = None,
        tz: tzinfo | None = None,
    ) -> tuple | None:
        return next(self.sql(query, *params, as_of=as_of, tz=tz, limit=1), None)

    def prepare(self, query: str) -> PreparedStatement:
        return PreparedStatement(self, query)

    def explain(self, query: str, *params: Any) -> str:
        stripped = query.strip()
        if stripped.upper().startswith("EXPLAIN "):
            stripped = stripped[8:]
        params_bytes = encode_values(list(params)) if params else b"\x00\x00\x00\x00\x00"
        return self._handle.explain(stripped, params_bytes)

    def explain_plan(self, query: str, *params: Any) -> str:
        """Return plan traces only (join order, cost estimates, index selection).
        No bytecode disassembly."""
        stripped = query.strip()
        if stripped.upper().startswith("EXPLAIN "):
            stripped = stripped[8:]
        params_bytes = encode_values(list(params)) if params else b"\x00\x00\x00\x00\x00"
        return self._handle.explain_plan(stripped, params_bytes)

    def compile_sql_json(self, query: str, *params: Any) -> dict:
        import json

        params_bytes = encode_values(list(params))
        result = self._handle.compile_sql_json(query, params_bytes)
        return json.loads(str(result))

    def flush(self) -> None:
        self._handle.flush()

    def internal_status(self, target: str = "") -> str:
        return str(self._handle.internal_status(target))

    def partition_id_for(self, name: str) -> int | None:
        return self._handle.partition_id_for(name)

    def attr_name(self, attr_id: int) -> str:
        return str(self._handle.attr_name(attr_id))

    def export_jsonl(self, path: str) -> None:
        import gzip

        import orjson

        result_bytes = self._handle.scan_datoms(U64_MAX)
        result_bytes = bytes(result_bytes) if result_bytes is not None else b""
        with gzip.open(path, "wb") as f:
            if not result_bytes:
                return
            values = decode_values(result_bytes[4:])
            for i in range(0, len(values), 5):
                e, _a, attr_name, v, t = values[i : i + 5]
                if isinstance(v, bytes):
                    v_json: Any = list(v)
                else:
                    v_json = v
                row = {
                    "e": e,
                    "a": attr_name,
                    "v": v_json,
                    "+": True,
                    "tx": str(t),
                }
                f.write(orjson.dumps(row) + b"\n")

    def import_jsonl(self, path: str) -> None:
        import gzip

        import orjson

        with gzip.open(path, "rb") as f:
            lines = [orjson.loads(line) for line in f if line.strip()]

        for row in lines:
            v = row["v"]
            if isinstance(v, list):
                v = bytes(v)
            attr = row["a"]
            e = row["e"]
            list(self.sql(f"UPSERT AS D1 = %1 SET {attr} = %2", e, v))

    def close(self) -> None:
        try:
            self._handle.close()
        except Exception:
            pass
        if hasattr(self, "_tmpdir"):
            self._tmpdir.cleanup()


class PreparedStatement:
    """Pre-compiled SQL statement — parse + compile once, execute many times.

    Usage::

        stmt = engine.prepare("SELECT d1.company.name WHERE d1.eid = %1")
        for row in stmt.execute(1000):
            print(row)
        for row in stmt.execute(2000):
            print(row)
        stmt.close()

    Or as a context manager::

        with engine.prepare("UPSERT AS D1 = %1 SET company.name = %2") as stmt:
            stmt.execute(1000, "ACME")
            stmt.execute(2000, "Globex")
    """

    def __init__(self, engine: EAVTEngine, query: str) -> None:
        self._engine = engine
        sql = query.strip()
        param_indices = [int(m) for m in re.findall(r"%(\d+)", sql)]
        num_params = max(param_indices) if param_indices else 0
        dummy = encode_values([0] * num_params) if num_params else b"\x00\x00\x00\x00\x00"
        try:
            self._prog = engine._handle.compile_sql(sql, dummy)
        except RuntimeError as e:
            raise ValueError(str(e)) from None
        self._closed = False

    def execute(
        self,
        *params: Any,
        as_of: datetime | str | None = None,
        tz: tzinfo | None = None,
        limit: int | None = None,
    ) -> Generator[tuple, None, None]:
        if self._closed:
            raise ValueError("PreparedStatement is closed")
        params_bytes = encode_values(list(params))
        limit_val = U64_MAX if limit is None else limit
        as_of_val = self._engine._parse_as_of(as_of)
        try:
            session = self._engine._handle.run_vm_cursor(
                self._prog, params_bytes, limit_val, as_of_val
            )
        except RuntimeError as e:
            raise ValueError(str(e)) from None

        try:
            while True:
                try:
                    batch_bytes = self._engine._handle.session_next_batch(session, 1024)
                except RuntimeError as e:
                    raise ValueError(str(e)) from None

                batch_bytes = bytes(batch_bytes) if batch_bytes is not None else b""
                if not batch_bytes:
                    break
                for row in decode_rows(batch_bytes):
                    yield row
        finally:
            del session

    def execute1(
        self,
        *params: Any,
        as_of: datetime | str | None = None,
        tz: tzinfo | None = None,
    ) -> tuple | None:
        return next(self.execute(*params, as_of=as_of, tz=tz, limit=1), None)

    def close(self) -> None:
        if not self._closed:
            self._prog = None
            self._closed = True

    def __enter__(self) -> PreparedStatement:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()
