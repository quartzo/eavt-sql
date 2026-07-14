"""Tests for the 17 EAVT IDL methods on spier-transactor via ctypes FFI.

These tests exercise the TransactorEngine IDL directly through the .so plugin,
bypassing PyO3 entirely. They verify the same EAVT semantics that test_engine.py
tests indirectly through the Python EAVTEngine layer.
"""
from __future__ import annotations

import struct

import pytest

from eavt_sql._ffi import load_spier
from helpers import unpack_keys

U64_MAX = 0xFFFFFFFFFFFFFFFF


def _scan(h, prefix):
    return unpack_keys(bytes(h.scan(**{"cf": 0, "prefix": prefix})))


@pytest.fixture
def lib():
    return load_spier("spier_transactor")


@pytest.fixture
def Value(lib):
    return lib.Value


@pytest.fixture
def ValueType(lib):
    return lib.ValueType


@pytest.fixture
def handle(lib, tmp_path):
    h = lib.create_handle({"backend": "file", "path": str(tmp_path)})
    yield h
    h.close()


# ---------------------------------------------------------------------------
# Typed client surface — verify EAVT methods are present on the generated client
# ---------------------------------------------------------------------------

class TestEavtSchemaReflection:
    def test_eavt_methods_exist(self, lib):
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
        missing = {n for n in expected if not hasattr(lib._client_class, n)}
        assert not missing, f"missing typed methods: {missing}"

    def test_value_is_generated_enum(self, lib):
        # The codegen bakes Value/ValueType as enum classes with variant ctors.
        for variant in ("Text", "Bytes", "Bool", "Int64", "Float64", "Timestamp"):
            assert hasattr(lib.Value, variant)


# ---------------------------------------------------------------------------
# EAVT Schema: declare_attr
# ---------------------------------------------------------------------------

class TestEavtDeclareAttr:
    def test_declare_attr_returns_aid(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        assert isinstance(aid, int)
        assert aid > 0

    def test_declare_attr_idempotent(self, handle, ValueType):
        h = handle
        aid1 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        aid2 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        assert aid1 == aid2

    def test_declare_attr_many(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": ValueType.String(),
            "many": True, "current_t": U64_MAX,
        })
        assert h.is_many(**{"aid": aid}) is True

    def test_declare_attr_cardinality_one(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        assert h.is_many(**{"aid": aid}) is False


# ---------------------------------------------------------------------------
# EAVT Resolver queries
# ---------------------------------------------------------------------------

class TestEavtResolver:
    def test_lookup_attr_found(self, handle, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
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

    def test_is_declared_true(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        assert h.is_declared(**{"aid": aid}) is True

    def test_is_declared_false(self, handle):
        h = handle
        assert h.is_declared(**{"aid": 99999}) is False

    def test_attr_name(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "person.age", "value_type": ValueType.Long(),
            "many": False, "current_t": U64_MAX,
        })
        name = h.attr_name(**{"aid": aid})
        assert name == "person.age"

    def test_value_type_for(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "person.age", "value_type": ValueType.Long(),
            "many": False, "current_t": U64_MAX,
        })
        vt = h.value_type_for(**{"aid": aid})
        assert vt == ValueType.Long()

    def test_value_type_for_unknown(self, handle):
        h = handle
        assert h.value_type_for(**{"aid": 99999}) == None

    def test_is_unique_false_by_default(self, handle, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
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
    def test_declare_string_from_sql(self, handle, ValueType):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.name", "type_name": "STRING",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "company.name"})
        assert aid is not None
        assert h.value_type_for(**{"aid": aid}) == ValueType.String()
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

    def test_declare_long_from_sql(self, handle, ValueType):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "person.age", "type_name": "LONG",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "person.age"})
        assert aid is not None
        assert h.value_type_for(**{"aid": aid}) == ValueType.Long()

    def test_declare_many_from_sql(self, handle):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.tags", "type_name": "STRING",
            "many": True, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "company.tags"})
        assert h.is_many(**{"aid": aid}) is True

    def test_declare_bytes_from_sql(self, handle, ValueType):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "file.data", "type_name": "BYTES",
            "many": False, "unique": False, "current_t": U64_MAX,
        })
        aid = h.lookup_attr(**{"name": "file.data"})
        assert h.value_type_for(**{"aid": aid}) == ValueType.Bytes()


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
    def test_save_text_value(self, handle, Value, ValueType):
        h = handle
        aid = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": Value.Text("Acme Inc"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys = _scan(h, b"")
        assert len(keys) > 0

    def test_save_long_value(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "person.age", "value_type": ValueType.Long(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "person.age",
            "v": Value.Int64(42),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys = _scan(h, b"")
        assert len(keys) > 0

    def test_save_boolean_value(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "flag.active", "value_type": ValueType.Boolean(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "flag.active",
            "v": Value.Bool(True),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys = _scan(h, b"")
        assert len(keys) > 0

    def test_save_float_value(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "sensor.temp", "value_type": ValueType.Float(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "sensor.temp",
            "v": Value.Float64(23.5),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys = _scan(h, b"")
        assert len(keys) > 0

    def test_save_bytes_value(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "file.data", "value_type": ValueType.Bytes(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "file.data",
            "v": Value.Bytes(b"\x00\x01\x02\xff"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys = _scan(h, b"")
        assert len(keys) > 0

    def test_save_cardinality_one_overwrites(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        eid_prefix = struct.pack(">Q", eid)
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": Value.Text("Old Name"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys_before = _scan(h, eid_prefix)
        assert len(keys_before) == 1

        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": Value.Text("New Name"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys_after = _scan(h, eid_prefix)
        # cardinality one: old value retracted + new value asserted
        assert len(keys_after) == 3

    def test_save_cardinality_many_adds(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": ValueType.String(),
            "many": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        eid_prefix = struct.pack(">Q", eid)
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": Value.Text("tag1"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys1 = _scan(h, eid_prefix)
        assert len(keys1) == 1

        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": Value.Text("tag2"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys2 = _scan(h, eid_prefix)
        # cardinality many: both values kept, no retraction
        assert len(keys2) == 2


# ---------------------------------------------------------------------------
# EAVT retract
# ---------------------------------------------------------------------------

class TestEavtRetract:
    def test_retract_removes_datom(self, handle, Value, ValueType):
        h = handle
        h.eavt_declare_attr(**{
            "name": "company.tags", "value_type": ValueType.String(),
            "many": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        eid_prefix = struct.pack(">Q", eid)
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": Value.Text("tag1"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.eavt_save(**{
            "e_id": eid, "attr": "company.tags",
            "v": Value.Text("tag2"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys_before = _scan(h, eid_prefix)
        assert len(keys_before) == 2

        h.eavt_retract(**{
            "e_id": eid, "attr": "company.tags",
            "v": Value.Text("tag1"),
            "current_t": U64_MAX, "as_of_us": U64_MAX,
        })
        keys_after = _scan(h, eid_prefix)
        # retract adds a retraction entry (2 assertions + 1 retraction)
        assert len(keys_after) == 3


# ---------------------------------------------------------------------------
# Lookup entity by unique attribute
# ---------------------------------------------------------------------------

class TestEavtLookupEntity:
    def test_lookup_entity_found(self, handle, Value):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.cnpj", "type_name": "STRING",
            "many": False, "unique": True, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        h.eavt_save(**{
            "e_id": eid, "attr": "company.cnpj",
            "v": Value.Text("12345678000190"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        result = h.lookup_entity(**{
            "attr_name": "company.cnpj",
            "value": Value.Text("12345678000190"),
        })
        assert result == eid

    def test_lookup_entity_not_found(self, handle, Value):
        h = handle
        h.eavt_declare_attr_from_sql(**{
            "attr": "company.cnpj", "type_name": "STRING",
            "many": False, "unique": True, "current_t": U64_MAX,
        })
        result = h.lookup_entity(**{
            "attr_name": "company.cnpj",
            "value": Value.Text("nonexistent"),
        })
        assert result is None


# ---------------------------------------------------------------------------
# Persistence: EAVT data survives reopen
# ---------------------------------------------------------------------------

class TestEavtPersistence:
    def test_declare_attr_survives_reopen(self, lib, tmp_path, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})

        aid1 = h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        h.flush()
        h.close()

        h2 = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        aid2 = h2.lookup_attr(**{"name": "company.name"})
        assert aid2 == aid1
        h2.close()

    def test_saved_data_survives_reopen(self, lib, tmp_path, Value, ValueType):
        h = lib.create_handle({"backend": "file", "path": str(tmp_path)})

        h.eavt_declare_attr(**{
            "name": "company.name", "value_type": ValueType.String(),
            "many": False, "current_t": U64_MAX,
        })
        eid = h.allocate_entity_id()
        eid_prefix = struct.pack(">Q", eid)
        h.eavt_save(**{
            "e_id": eid, "attr": "company.name",
            "v": Value.Text("Acme"),
            "t": U64_MAX, "as_of_us": U64_MAX,
        })
        h.flush()
        h.close()

        h2 = lib.create_handle({"backend": "file", "path": str(tmp_path)})
        keys = _scan(h2, eid_prefix)
        assert len(keys) == 1
        h2.close()
