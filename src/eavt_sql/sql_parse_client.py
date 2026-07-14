from __future__ import annotations

import json

import spier_sql_parse_py


class SqlParseClient:
    """Thin Python client for the SQL parser via PyO3 (test-only binding)."""

    def __init__(self) -> None:
        self._handle = spier_sql_parse_py.SqlParser()

    def parse(self, sql: str) -> dict:
        """Parse SQL and return AST as a dict."""
        return json.loads(self.parse_raw(sql))

    def parse_raw(self, sql: str) -> str:
        """Parse SQL and return AST as a raw JSON string."""
        return self._handle.parse_json(sql)

    def close(self) -> None:
        self._handle.close()
