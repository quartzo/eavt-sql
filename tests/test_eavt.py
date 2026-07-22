"""Tests for the EAVT methods on spier-transactor via PyO3 bindings.

Schema/save/retract/lookup tests are now covered in Nim (query/tests.nim).
Kept: method existence and persistence tests."""
from __future__ import annotations

import pytest

import spier_eavt_query_py


@pytest.fixture
def handle(tmp_path):
    h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
    yield h
    h.close()


class TestEavtSchemaReflection:
    def test_eavt_methods_exist(self):
        expected = {
            "save", "retract",
            "declare_attr", "declare_attr_from_sql",
            "declare_partition", "allocate_tx",
            "lookup_attr", "is_declared", "attr_name",
            "value_type_for", "is_many", "is_unique",
            "allocate_in_partition", "is_unique_attr", "default_user_partition",
            "partition_id_for", "lookup_entity",
            "allocate_entity_id", "allocate_tx",
        }
        missing = {n for n in expected if not hasattr(spier_eavt_query_py.Engine, n)}
        assert not missing, f"missing typed methods: {missing}"


class TestEavtPersistence:
    def test_declare_attr_survives_reopen(self, tmp_path):
        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        aid1 = h.declare_attr("company.name", "String", False)
        h.flush()
        h.close()

        h2 = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})
        aid2 = h2.lookup_attr(**{"name": "company.name"})
        assert aid2 == aid1
        h2.close()
