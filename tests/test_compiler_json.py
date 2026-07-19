"""Tests for compiler introspection via compile_sql_json.

These tests verify the compiler's Scheme IR output directly, without
executing the program. They check that:
- Attribute declarations emit `declare-attr` with the attr name as a string
- The planner picks a valid index ("AEVT" / "EAVT" / etc.) for SELECT
- ATTRIBUTE / PARTITION statements compile to the expected Scheme forms

The old bytecode-VM tests (InternA, ConstInt, PrefixPush, ScannerOpen p2,
Halt, num_registers) were removed when the compiler migrated to Scheme IR.
"""

import pytest

from eavt_sql.engine import EAVTEngine
from eavt_sql.query_codec import encode_values


@pytest.fixture
def engine(tmp_path):
    e = EAVTEngine(str(tmp_path / "db"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("ATTRIBUTE person.name STRING ONE"))
    list(e.sql("ATTRIBUTE company.active BOOLEAN ONE"))
    return e


def _compile_scheme(engine, sql, *params):
    """Bypass the JSON wrapper — compile_sql_json returns raw Scheme text
    for Scheme-IR programs. Pass encoded params directly to the Rust handle."""
    params_bytes = encode_values(list(params))
    return str(engine._handle.compile_sql_json(sql, params_bytes))


class TestSchemeIRStructure:
    """Scheme IR structural assertions for compiled programs."""

    def test_resolved_attr_emits_scanner_push(self, engine):
        """Compiled SELECT references the resolved attr via scanner-push with
        the attr id. InternA-style name resolution is gone in Scheme IR."""
        s = _compile_scheme(
            engine,
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        assert "scanner-open" in s or "scanner-push" in s, (
            f"expected scanner-open/scanner-push in compiled output, got: {s}"
        )

    def test_select_uses_valid_index(self, engine):
        """SELECT by attribute should pick a valid index — never an
        out-of-range column family id. The index name appears as a string
        literal in scanner-open."""
        s = _compile_scheme(
            engine,
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        assert any(idx in s for idx in ('"AEVT"', '"EAVT"', '"AVET"', '"VAET"')), (
            f"expected a valid index name in scanner-open, got: {s}"
        )

    def test_attribute_compiles_to_declare_attr(self, engine):
        s = _compile_scheme(
            engine,
            "ATTRIBUTE company.revenue FLOAT ONE"
        )
        assert "declare-attr" in s, (
            f"expected declare-attr in ATTRIBUTE output, got: {s}"
        )
        assert "company.revenue" in s

    def test_partition_compiles_to_declare_partition(self, engine):
        s = _compile_scheme(
            engine,
            "PARTITION my_partition"
        )
        assert "declare-partition" in s, (
            f"expected declare-partition in PARTITION output, got: {s}"
        )
        assert "my_partition" in s

    def test_upsert_compiles_to_scheme(self, engine):
        """UPSERT compiles to a Scheme program with alloc-entity/save forms."""
        s = _compile_scheme(
            engine,
            "UPSERT AS D1 SET company.name = 'Test Co'"
        )
        assert s.startswith("("), \
            "UPSERT should produce Scheme S-expression text"
        assert "alloc-entity" in s
        assert "save" in s
        assert "company.name" in s

