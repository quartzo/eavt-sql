"""Tests for the EAVT methods on spier-transactor via PyO3 bindings.

Schema/save/retract/lookup tests are now covered in Nim (query/tests.nim).
Kept: method existence, entity allocation, partitions, and persistence tests."""

from __future__ import annotations

import pytest

import spier_eavt_query_py
from eavt_sql.engine import EAVTEngine


def _scan_via_sql(path, eid, handle=None):
    if handle is not None:
        try:
            handle.flush()
        except Exception:
            pass
    e = EAVTEngine(path)
    try:
        return list(e.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", eid))
    finally:
        e.close()


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


# ---------------------------------------------------------------------------
# Entity ID allocation
# ---------------------------------------------------------------------------

class TestEntityAllocation:
    def test_allocate_entity_id(self, handle):
        h = handle
        eid = h.allocate_entity_id()
        assert isinstance(eid, int)
        assert eid > 0

    def test_allocate_entity_ids_increasing(self, handle):
        h = handle
        eid1 = h.allocate_entity_id()
        eid2 = h.allocate_entity_id()
        assert eid2 > eid1

    def test_allocate_t(self, handle):
        h = handle
        t1 = h.allocate_tx()
        t2 = h.allocate_tx()
        assert t2 > t1

    def test_allocate_tx(self, handle):
        h = handle
        t = h.allocate_tx()
        assert isinstance(t, int)
        assert t > 0

    def test_allocate_tx_creates_tx_entity(self, handle):
        h = handle
        t1 = h.allocate_tx()
        t2 = h.allocate_tx()
        assert t2 > t1


# ---------------------------------------------------------------------------
# Partitions
# ---------------------------------------------------------------------------

class TestEavtPartitions:
    def test_declare_partition(self, handle):
        h = handle
        pid = h.declare_partition("cnpj")
        assert isinstance(pid, int)

    def test_declare_partition_idempotent(self, handle):
        h = handle
        pid1 = h.declare_partition("cnpj")
        pid2 = h.declare_partition("cnpj")
        assert pid1 == pid2

    def test_partition_id_for(self, handle):
        h = handle
        pid = h.declare_partition("cnpj")
        result = h.partition_id_for(**{"name": "cnpj"})
        assert result == pid

    def test_partition_id_for_not_found(self, handle):
        h = handle
        assert h.partition_id_for(**{"name": "nonexistent"}) is None

    def test_default_user_partition(self, handle):
        h = handle
        pid = h.default_user_partition()
        assert isinstance(pid, int)

    def test_allocate_in_partition(self, handle):
        h = handle
        pid = h.declare_partition("cnpj")
        eid1 = h.allocate_in_partition(**{"partition_id": pid})
        eid2 = h.allocate_in_partition(**{"partition_id": pid})
        assert eid2 > eid1
        assert (eid1 >> 44) == pid
        assert (eid2 >> 44) == pid

# ---------------------------------------------------------------------------
# Persistence: EAVT data survives reopen
# ---------------------------------------------------------------------------

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

    def test_saved_data_survives_reopen(self, tmp_path):
        h = spier_eavt_query_py.Engine({"backend": "file", "path": str(tmp_path)})

        h.declare_attr("company.name", "String", False)
        eid = h.allocate_entity_id()
        h.save(eid, "company.name", "Acme", 0xFFFFFFFFFFFFFFFF)
        h.flush()
        h.close()

        rows = _scan_via_sql(str(tmp_path), eid, None)
        assert len(rows) == 1
        assert rows[0][1] == "Acme"
