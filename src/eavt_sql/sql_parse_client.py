from __future__ import annotations

import json

from ._ffi import SpierLib, load_spier


class SqlParseClient:
    """Thin Python client for spier-sql-parse via the generated typed client."""

    def __init__(self) -> None:
        self._lib: SpierLib = load_spier("spier_sql_parse")
        self._handle = self._lib.create_handle({})

    def parse(self, sql: str) -> dict:
        """Parse SQL and return AST as a dict."""
        return json.loads(self.parse_raw(sql))

    def parse_raw(self, sql: str) -> str:
        """Parse SQL and return AST as a raw JSON string."""
        return self._handle.parse_json(sql)

    def close(self) -> None:
        self._handle.close()
