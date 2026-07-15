"""Tests for the EAVT methods on spier-transactor via PyO3 bindings."""
from __future__ import annotations

import struct

import pytest

import spier_transactor_py
from eavt_sql.engine import EAVTEngine

U64_MAX = 0xFFFFFFFFFFFFFFFF


def _scan_via_sql(path, eid, handle=None):
    """Open a Python EAVTEngine on the same path and query the entity's datoms.
    If handle is provided and open, flush it first so uncommitted data is visible."""
    if handle is not None:
        try:
            handle.flush()
        except Exception:
            pass  # handle may already be closed
    e = EAVTEngine(path)
    try:
        return list(e.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", eid))
    finally:
        e.close()


@pytest.fixture
def handle(tmp_path):
    h = spier_transactor_py.Engine({"backend": "file", "path": str(tmp_path)})
    yield h
    h.close()


class TestEavtSchemaReflection:
    def test_eavt_methods_exist(self):
        expected = {
            "eavt_save", "eavt_retract",
            "eavt_declare_attr", "eavt_declare_attr_from_sql",
            "eavt_declare_partition", "eavt_allocate_tx",
            "lookup_attr", "is_declared", "attr_name",
            "value_type_for", "is_many", "is_unique",
            "is_unique_attr", "default_user_partition",
            "partition_id_for", "lookup_entity",
            "allocate_entity_id", "allocate_in_partition", "allocate_t",
        }
        missing = {n for n in expected if not hasattr(spier_transactor_py.Engine, n)}
        assert not missing, f"missing typed methods: {missing}"

# ---------------------------------------------------------------------------
# EAVT Schema: declare_attr
# ---------------------------------------------------------------------------

class TestEavtDeclareAttr:
    def test_declare_attr_returns_aid(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        assert isinstance(aid, int)
        assert aid > 0

    def test_declare_attr_idempotent(self, handle):
        h = handle
        aid1 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        aid2 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        assert aid1 == aid2

    def test_declare_attr_many(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": "String",
            "many": True, "current_t": U64_MAX,
        })
        assert h.is_many(**{"aid": aid}) is True

    def test_declare_attr_cardinality_one(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        assert h.is_many(**{"aid": aid}) is False


# ---------------------------------------------------------------------------
# EAVT Resolver queries
# ---------------------------------------------------------------------------

class TestEavtResolver:
    def test_lookup_attr_found(self, handle):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        result = h.lookup_attr(**{"name": "company.name"})
        assert result is not None
        assert isinstance(result, int)
        assert result > 0

    def test_lookup_attr_not_found(self, handle):
        h = handle
        result = h.lookup_attr(**{"name": "nonexistent.attr"})
        assert result is None

    def test_is_declared_true(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        assert h.is_declared(**{"aid": aid}) is True

    def test_is_declared_false(self, handle):
        h = handle
        assert h.is_declared(**{"aid": 99999}) is False

    def test_attr_name(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "person.age", "value_type": "Long",
            "many": False, "current_t": U64_MAX,
        })
        name = h.attr_name(**{"aid": aid})
        assert name == "person.age"

    def test_value_type_for(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "person.age", "value_type": "Long",
            "many": False, "current_t": U64_MAX,
        })
        vt = h.value_type_for(**{"aid": aid})
        assert vt == "Long"

    def test_value_type_for_unknown(self, handle):
        h = handle
        assert h.value_type_for(**{"aid": 99999}) == None

    def test_is_unique_false_by_default(self, handle):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        assert h.is_unique(**{"aid": aid}) is False

    def test_is_unique_attr_false(self, handle):
        h = handle
        assert h.is_unique_attr(**{"name": "company.name"}) is False


# ---------------------------------------------------------------------------
# EAVT declare_attr_from_sql
# ---------------------------------------------------------------------------

class TestEavtDeclareAttrFromSql:
    def test_declare_string_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.name", "type_name": "STRING",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "company.name"})
        assert aid is not None
        assert h.value_type_for(**{"aid": aid}) == "String"
        assert h.is_unique(**{"aid": aid}) is False

    def test_declare_unique_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.cnpj", "type_name": "STRING",
            "many": False, "unique": True, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "company.cnpj"})
        assert aid is not None
        assert h.is_unique(**{"aid": aid}) is True
        assert h.is_unique_attr(**{"name": "company.cnpj"}) is True

    def test_declare_long_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "person.age", "type_name": "LONG",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "person.age"})
        assert aid is not None
        assert h.value_type_for(**{"aid": aid}) == "Long"

    def test_declare_many_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.tags", "type_name": "STRING",
            "many": True, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "company.tags"})
        assert h.is_many(**{"aid": aid}) is True

    def test_declare_bytes_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "file.data", "type_name": "BYTES",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "file.data"})
        assert h.value_type_for(**{"aid": aid}) == "Bytes"


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
        t1 = h.allocate_t()
        t2 = h.allocate_t()
        assert t2 > t1

    def test_allocate_tx(self, handle):
        h = handle
        t = h.eavt_allocate_tx()
        assert isinstance(t, int)
        assert t > 0

    def test_allocate_tx_creates_tx_entity(self, handle):
        h = handle
        t1 = h.eavt_allocate_tx()
        t2 = h.eavt_allocate_tx()
        assert t2 > t1


# ---------------------------------------------------------------------------
# Partitions
# ---------------------------------------------------------------------------

class TestEavtPartitions:
    def test_declare_partition(self, handle):
        h = handle
        pid = h.eavt_declare_partition(**{
            "name": "cnpj", "current_t": U64_MAX,
        })
        assert isinstance(pid, int)

    def test_declare_partition_idempotent(self, handle):
        h = handle
        pid1 = h.eavt_declare_partition(**{
            "name": "cnpj", "current_t": U64_MAX,
        })
        pid2 = h.eavt_declare_partition(**{
            "name": "cnpj", "current_t": U64_MAX,
        })
        assert pid1 == pid2

    def test_partition_id_for(self, handle):
        h = handle
        pid = h.eavt_declare_partition(**{
            "name": "cnpj", "current_t": U64_MAX,
        })
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
        pid = h.eavt_declare_partition(**{
            "name": "cnpj", "current_t": U64_MAX,
        })
        eid1 = h.allocate_in_partition(**{"partition_id": pid})
        eid2 = h.allocate_in_partition(**{"partition_id": pid})
        assert eid2 > eid1
        assert (eid1 >> 44) == pid
        assert (eid2 >> 44) == pid


# ---------------------------------------------------------------------------
# EAVT writes: save
# ---------------------------------------------------------------------------

class TestEavtSave:
    def test_save_text_value(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": "Acme Inc",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) > 0

    def test_save_long_value(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "person.age", "value_type": "Long",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "person.age",
            "v": 42,
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) > 0

    def test_save_boolean_value(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "flag.active", "value_type": "Boolean",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "flag.active",
            "v": True,
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) > 0

    def test_save_float_value(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "sensor.temp", "value_type": "Float",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "sensor.temp",
            "v": 23.5,
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) > 0

    def test_save_bytes_value(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "file.data", "value_type": "Bytes",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "file.data",
            "v": b"\x00\x01\x02\xff",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) > 0

    def test_save_cardinality_one_overwrites(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": "Old Name",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows_before = _scan_via_sql(str(tmp_path), eid, h)
        assert any(r[1] == "Old Name" for r in rows_before)

        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": "New Name",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows_after = _scan_via_sql(str(tmp_path), eid, h)
        # cardinality one: only "New Name" should be visible
        assert any(r[1] == "New Name" for r in rows_after)
        assert not any(r[1] == "Old Name" for r in rows_after)

    def test_save_cardinality_many_adds(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": "String",
            "many": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": "tag1",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows1 = _scan_via_sql(str(tmp_path), eid, h)
        assert any(r[1] == "tag1" for r in rows1)

        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": "tag2",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows2 = _scan_via_sql(str(tmp_path), eid, h)
        # cardinality many: both values visible
        values = {r[1] for r in rows2}
        assert "tag1" in values
        assert "tag2" in values


# ---------------------------------------------------------------------------
# EAVT retract
# ---------------------------------------------------------------------------

class TestEavtRetract:
    def test_retract_removes_datom(self, handle, tmp_path):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": "String",
            "many": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": "tag1",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": "tag2",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows_before = _scan_via_sql(str(tmp_path), eid, h)
        values_before = {r[1] for r in rows_before}
        assert "tag1" in values_before
        assert "tag2" in values_before

        h.eavt_retract(**{
            "e_id": eid, "attr": "company.tags",
            "v": "tag1",
            "current_t": U64_MAX, "as_of_us": U64_MAX,
        })
        rows_after = _scan_via_sql(str(tmp_path), eid, h)
        values_after = {r[1] for r in rows_after}
        assert "tag1" not in values_after
        assert "tag2" in values_after


# ---------------------------------------------------------------------------
# Lookup entity by unique attribute
# ---------------------------------------------------------------------------

class TestEavtLookupEntity:
    def test_lookup_entity_found(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.cnpj", "type_name": "STRING",
            "many": False, "unique": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.cnpj",
            "v": "12345678000190",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        result = h.lookup_entity(**{
            "attr_name": "company.cnpj",
            "value": "12345678000190",
        })
        assert result == eid

    def test_lookup_entity_not_found(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.cnpj", "type_name": "STRING",
            "many": False, "unique": True, "current_t": U64_MAX,
        })
        result = h.lookup_entity(**{
            "attr_name": "company.cnpj",
            "value": "nonexistent",
        })
        assert result is None


# ---------------------------------------------------------------------------
# Persistence: EAVT data survives reopen
# ---------------------------------------------------------------------------

class TestEavtPersistence:
    def test_declare_attr_survives_reopen(self, tmp_path):
        h = spier_transactor_py.Engine({"backend": "file", "path": str(tmp_path)})

        aid1 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        h.flush()
        h.close()

        h2 = spier_transactor_py.Engine({"backend": "file", "path": str(tmp_path)})
        aid2 = h2.lookup_attr(**{"name": "company.name"})
        assert aid2 == aid1
        h2.close()

    def test_saved_data_survives_reopen(self, tmp_path):
        h = spier_transactor_py.Engine({"backend": "file", "path": str(tmp_path)})

        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": "String",
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": "Acme",
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.flush()
        h.close()

        rows = _scan_via_sql(str(tmp_path), eid, h)
        assert len(rows) == 1
        assert rows[0][1] == "Acme"
