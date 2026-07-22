from __future__ import annotations

import re
from datetime import datetime, tzinfo
from typing import Any, Generator

import pynim_query as _nim

class _EngineWrapper:
    """Wraps pynim_query module-level functions as class methods."""
    def __init__(self, config):
        self._h = _nim.new(config)
    def compile_sql(self, sql, params): return _nim.compile_sql(self._h, sql, params)
    def run_vm(self, prog, params, limit, as_of): return _nim.run_vm(self._h, prog, params, limit, as_of)
    def run_vm_cursor(self, prog, params, limit, as_of): return _nim.run_vm_cursor(self._h, prog, params, limit, as_of)
    def session_next_batch(self, session, max_rows): return _nim.session_next_batch(self._h, session, max_rows)
    def explain(self, sql, params): return _nim.explain(self._h, sql, params)
    def compile_sql_json(self, sql, params): return _nim.compile_sql_json(self._h, sql, params)
    def scan_datoms(self, as_of): return _nim.scan_datoms(self._h, as_of)
    def compile_scheme(self, scheme): return _nim.compile_scheme(self._h, scheme)
    def compile_scheme_dml(self, scheme): return _nim.compile_scheme_dml(self._h, scheme)
    def compile_scheme_debug(self, scheme): return _nim.compile_scheme_debug(self._h, scheme)
    def flush(self): return _nim.flush(self._h)
    def close(self): return _nim.close(self._h)
    def path(self): return _nim.path(self._h)
    def save(self, e, attr, v, t): return _nim.save(self._h, e, attr, v, t)
    def retract(self, e, attr, v, t): return _nim.retract(self._h, e, attr, v, t)
    def declare_attr(self, name, vt, many): return _nim.declare_attr(self._h, name, vt, many)
    def declare_attr_from_sql(self, attr, type_name, many, unique): return _nim.declare_attr_from_sql(self._h, attr, type_name, many, unique)
    def lookup_attr(self, name): return _nim.lookup_attr(self._h, name)
    def attr_name(self, aid): return _nim.attr_name(self._h, aid)
    def is_declared(self, aid): return _nim.is_declared(self._h, aid)
    def value_type_for(self, aid): return _nim.value_type_for(self._h, aid)
    def is_many(self, aid): return _nim.is_many(self._h, aid)
    def is_unique_attr(self, name): return _nim.is_unique_attr(self._h, name)
    def declare_partition(self, name): return _nim.declare_partition(self._h, name)
    def partition_id_for(self, name): return _nim.partition_id_for(self._h, name)
    def is_unique(self, aid): return _nim.is_unique(self._h, aid)
    def allocate_entity_id(self): return _nim.allocate_entity_id(self._h)
    def allocate_tx(self): return _nim.allocate_tx(self._h)
    def allocate_in_partition(self, pid): return _nim.allocate_in_partition(self._h, pid)
    def default_user_partition(self): return _nim.default_user_partition(self._h)
    def lookup_entity(self, attr_name, value): return _nim.lookup_entity(self._h, attr_name, value)
    def internal_status(self, target): return _nim.internal_status(self._h, target)
    def memtable_size(self): return _nim.memtable_size(self._h)
    def memtable_count(self, cf): return _nim.memtable_count(self._h, cf)
    def journal_size(self): return _nim.journal_size(self._h)
    def cf_stats(self, cf): return _nim.cf_stats(self._h, cf)
    def db_stats(self): return _nim.db_stats(self._h)
    def gc_full(self, dry_run, nowait): return _nim.gc_full(self._h, dry_run, nowait)

spier_eavt_query_py = type('module', (), {'Engine': _EngineWrapper})()
from .query_codec import encode_values, decode_values, decode_rows

U64_MAX = 0xFFFFFFFFFFFFFFFF


class EAVTEngine:
    """EAVT engine backed by spier-eavt-query-py PyO3 bindings."""

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
        return spier_eavt_query_py.Engine(config)

    @property
    def _db_path(self) -> str:
        return self._handle.path()

    def _parse_as_of(self, as_of: datetime | str | int | None) -> int:
        if as_of is None:
            return U64_MAX
        if isinstance(as_of, int):
            # tx_eids have partition bits set (>= 1 << 44); pass through as-is.
            # Small integers are treated as raw tx seq or micros timestamp.
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
            except Exception as e:
                raise ValueError(str(e)) from None
            for line in str(result).split("\n"):
                if line:
                    yield (line,)
            return

        params_bytes = encode_values(list(params))
        try:
            prog = self._handle.compile_sql(stripped, params_bytes)
        except Exception as e:
            raise ValueError(str(e)) from None

        params_bytes = encode_values(list(params))
        limit_val = U64_MAX if limit is None else limit
        as_of_val = self._parse_as_of(as_of)

        try:
            session = self._handle.run_vm_cursor(prog, params_bytes, limit_val, as_of_val)
        except Exception as e:
            raise ValueError(str(e)) from None

        try:
            while True:
                try:
                    batch_bytes = self._handle.session_next_batch(session, 1024)
                except Exception as e:
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

    def compile_sql_json(self, query: str, *params: Any) -> dict:
        import json

        params_bytes = encode_values(list(params))
        result = self._handle.compile_sql_json(query, params_bytes)
        return json.loads(str(result))

    def run_scheme(self, scheme_text: str, *params: Any) -> list[tuple]:
        """Execute raw Scheme text against the DML host functions and return rows.

        Uses `Program::Scheme` (SchemeSession + SchemeHostFns), so the following
        host fns are available: `declare-attr`, `declare-partition`,
        `alloc-entity`, `tx-entity`, `save`, `retract`, `lookup-entity`,
        `lookup-value`, `param`, `result`.

        A program whose final value is `(result v1 v2 ...)` yields one row
        `(v1, v2, ...)`; a program returning Void yields no rows.
        """
        try:
            prog = self._handle.compile_scheme_dml(scheme_text)
        except Exception as e:
            raise ValueError(str(e)) from None
        params_bytes = encode_values(list(params))
        try:
            out = self._handle.run_vm(prog, params_bytes, U64_MAX, U64_MAX)
        except Exception as e:
            raise ValueError(str(e)) from None
        out = bytes(out) if out is not None else b""
        return decode_rows(out)

    def run_scheme_select(self, scheme_text: str, *params: Any) -> list[tuple]:
        """Execute raw Scheme text via SelectSchemeSession (yield-capable).

        Required for `scanner-iterate` and `result-row` — these use the
        yield/resume evaluator which is not available in `run_scheme` (DML
        path). The caller drives iteration by pulling batches until empty.
        """
        try:
            prog = self._handle.compile_scheme(scheme_text)
        except Exception as e:
            raise ValueError(str(e)) from None
        params_bytes = encode_values(list(params))
        try:
            session = self._handle.run_vm_cursor(prog, params_bytes, U64_MAX, U64_MAX)
        except Exception as e:
            raise ValueError(str(e)) from None
        try:
            rows: list[tuple] = []
            while True:
                try:
                    batch = self._handle.session_next_batch(session, 1024)
                except Exception as e:
                    raise ValueError(str(e)) from None
                batch = bytes(batch) if batch is not None else b""
                if not batch:
                    break
                rows.extend(decode_rows(batch))
            return rows
        finally:
            del session

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
                if e < 100:
                    continue  # skip bootstrap entities
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
        except Exception as e:
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
        except Exception as e:
            raise ValueError(str(e)) from None

        try:
            while True:
                try:
                    batch_bytes = self._engine._handle.session_next_batch(session, 1024)
                except Exception as e:
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
