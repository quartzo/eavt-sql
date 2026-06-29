"""Tests for spier-sql-parse via DynSpire FFI (parse_json).

Covers all RustStmt variants, entity_ref types, condition operators,
literal types, and error handling — all through the Python ctypes FFI.
"""
import json

import pytest

from eavt_sql.sql_parse_client import SqlParseClient


@pytest.fixture(scope="module")
def client():
    c = SqlParseClient()
    yield c
    c.close()


# ---------------------------------------------------------------------------
# FFI infrastructure
# ---------------------------------------------------------------------------

class TestFFI:
    def test_schema_has_parse_json(self, client):
        client.parse("SELECT d1.eid")  # smoke test

    def test_idl_hash_is_registered(self, client):
        # The codegen bakes the IDL hash; load() gates it against the .so.
        assert client._lib.idl_hash() != 0

    def test_methods_exposed(self, client):
        assert hasattr(client._handle, "parse_json")
        assert hasattr(client._handle, "parse")


# ---------------------------------------------------------------------------
# SELECT
# ---------------------------------------------------------------------------

class TestSelect:
    def test_field_projection(self, client):
        ast = client.parse("SELECT d1.eid WHERE d1.company.name = 'ACME'")
        assert "Select" in ast
        sel = ast["Select"]
        assert len(sel["projections"]) == 1
        assert sel["projections"][0]["field"] == {"alias": "d1", "field": "eid"}
        assert sel["projections"][0]["literal"] is None
        assert sel["star"] is False
        assert sel["exists_mode"] is False

    def test_star(self, client):
        ast = client.parse("SELECT *")
        assert ast["Select"]["star"] is True
        assert ast["Select"]["projections"] == []

    def test_condition_eq(self, client):
        ast = client.parse("SELECT d1.eid WHERE d1.x = 'hello'")
        cond = ast["Select"]["conditions"][0]
        assert cond["left"] == {"alias": "d1", "field": "x"}
        assert cond["op"] == "="
        assert cond["right"] == {"Literal": {"Str": "hello"}}

    def test_condition_in(self, client):
        ast = client.parse("SELECT d1.eid WHERE d1.eid IN (%1, %2, %3)")
        cond = ast["Select"]["conditions"][0]
        assert cond["op"] == "in"
        assert cond["right"] == {
            "In": [{"Param": 1}, {"Param": 2}, {"Param": 3}]
        }

    def test_condition_or(self, client):
        ast = client.parse(
            "SELECT d1.eid WHERE d1.x = 'A' OR d1.x = 'B'"
        )
        cond = ast["Select"]["conditions"][0]
        assert cond["op"] == "or"
        or_branches = cond["right"]["Or"]
        assert len(or_branches) == 2

    def test_condition_param(self, client):
        ast = client.parse("SELECT d1.eid WHERE d1.eid = %1")
        assert ast["Select"]["conditions"][0]["right"] == {"Param": 1}

    def test_multi_projections(self, client):
        ast = client.parse(
            "SELECT d1.company.name, d1.person.name WHERE d1.eid = %1"
        )
        assert len(ast["Select"]["projections"]) == 2


# ---------------------------------------------------------------------------
# UPSERT — entity_ref variants
# ---------------------------------------------------------------------------

class TestUpsert:
    def test_new_entity(self, client):
        ast = client.parse("UPSERT AS D1 SET company.name = 'X'")
        clause = ast["Upsert"]["clauses"][0]
        assert clause["alias"] == "D1"
        assert clause["entity_ref"] == "New"
        assert clause["values"][0]["attr"] == "company.name"

    def test_explicit_eid(self, client):
        ast = client.parse("UPSERT AS D1 = %1 SET company.name = 'X'")
        assert ast["Upsert"]["clauses"][0]["entity_ref"] == {"ExplicitEid": 1}

    def test_tx_entity(self, client):
        ast = client.parse("UPSERT AS TX SET tx.user = 'bob'")
        clause = ast["Upsert"]["clauses"][0]
        assert clause["alias"] == "TX"
        assert clause["entity_ref"] == "Tx"

    def test_lookup_entity(self, client):
        ast = client.parse(
            "UPSERT AS D1 = eid('company.name', 'X') SET company.hq = %1"
        )
        ref = ast["Upsert"]["clauses"][0]["entity_ref"]
        assert ref == {
            "Lookup": {
                "attr": {"Literal": {"Str": "company.name"}},
                "value": {"Literal": {"Str": "X"}},
            }
        }

    def test_eid_func_lookup(self, client):
        ast = client.parse(
            "UPSERT AS D1 = eid('company.name', 'X') SET company.hq = %1"
        )
        ref = ast["Upsert"]["clauses"][0]["entity_ref"]
        assert ref == {
            "Lookup": {
                "attr": {"Literal": {"Str": "company.name"}},
                "value": {"Literal": {"Str": "X"}},
            }
        }

    def test_eid_func_lookup_params(self, client):
        ast = client.parse(
            "UPSERT AS D1 = eid(%1, %2) SET company.hq = %3"
        )
        ref = ast["Upsert"]["clauses"][0]["entity_ref"]
        assert ref == {
            "Lookup": {
                "attr": {"Param": 1},
                "value": {"Param": 2},
            }
        }

    def test_eid_in_set_value(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET company.ceo = eid('person.name', 'Alice')"
        )
        val = ast["Upsert"]["clauses"][0]["values"][0]
        assert val["attr"] == "company.ceo"
        assert val["value"] == {
            "EidLookup": {
                "attr": {"Literal": {"Str": "person.name"}},
                "value": {"Literal": {"Str": "Alice"}},
            }
        }

    def test_eid_unquoted_attr(self, client):
        ast = client.parse(
            "UPSERT AS D1 = eid(company.name, 'X') SET company.hq = %1"
        )
        ref = ast["Upsert"]["clauses"][0]["entity_ref"]
        assert ref == {
            "Lookup": {
                "attr": {"Literal": {"Str": "company.name"}},
                "value": {"Literal": {"Str": "X"}},
            }
        }

    def test_eid_unquoted_attr_in_set(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET company.ceo = eid(person.name, 'Alice')"
        )
        val = ast["Upsert"]["clauses"][0]["values"][0]
        assert val["value"] == {
            "EidLookup": {
                "attr": {"Literal": {"Str": "person.name"}},
                "value": {"Literal": {"Str": "Alice"}},
            }
        }

    def test_val_in_set_value(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET order.total = val(eid('item.codigo', 'ABC'), 'item.preco')"
        )
        val = ast["Upsert"]["clauses"][0]["values"][0]
        assert val["value"] == {
            "ValLookup": {
                "entity": {
                    "EidLookup": {
                        "attr": {"Literal": {"Str": "item.codigo"}},
                        "value": {"Literal": {"Str": "ABC"}},
                    }
                },
                "attr": {"Literal": {"Str": "item.preco"}},
            }
        }

    def test_val_with_param_entity(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET order.total = val(%1, item.preco)"
        )
        val = ast["Upsert"]["clauses"][0]["values"][0]
        assert val["value"] == {
            "ValLookup": {
                "entity": {"Param": 1},
                "attr": {"Literal": {"Str": "item.preco"}},
            }
        }

    def test_eid_in_set_value_params(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET company.ceo = eid(%1, %2)"
        )
        val = ast["Upsert"]["clauses"][0]["values"][0]
        assert val["value"] == {
            "EidLookup": {
                "attr": {"Param": 1},
                "value": {"Param": 2},
            }
        }

    def test_multi_clause(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET company.name = 'A', AS D2 SET person.name = 'B'"
        )
        assert len(ast["Upsert"]["clauses"]) == 2

    def test_alias_ref_value(self, client):
        ast = client.parse(
            "UPSERT AS D1 SET company.partner = d2, "
            "AS D2 SET person.name = 'Bob'"
        )
        vals = ast["Upsert"]["clauses"][0]["values"]
        assert vals[0]["value"] == {"AliasRef": "D2"}

    def test_no_alias(self, client):
        ast = client.parse("UPSERT SET company.name = 'X'")
        clause = ast["Upsert"]["clauses"][0]
        assert clause["alias"] is None
        assert clause["entity_ref"] == "New"


# ---------------------------------------------------------------------------
# UPDATE
# ---------------------------------------------------------------------------

class TestUpdate:
    def test_basic_update(self, client):
        ast = client.parse(
            "UPDATE AS D1 SET company.name = 'X' WHERE d1.eid = %1"
        )
        assert "Update" in ast
        upd = ast["Update"]
        assert upd["clauses"][0]["alias"] == "D1"
        assert len(upd["conditions"]) == 1


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------

class TestDelete:
    def test_delete_where(self, client):
        ast = client.parse("DELETE WHERE d1.company.name = 'ACME'")
        assert "Delete" in ast
        assert len(ast["Delete"]["conditions"]) == 1
        cond = ast["Delete"]["conditions"][0]
        assert cond["left"]["field"] == "company.name"


# ---------------------------------------------------------------------------
# ATTRIBUTE
# ---------------------------------------------------------------------------

class TestAttribute:
    def test_string_unique(self, client):
        ast = client.parse("ATTRIBUTE company.name STRING ONE UNIQUE")
        attr = ast["Attribute"]
        assert attr["attr"] == "company.name"
        assert attr["value_type"] == "STRING"
        assert attr["many"] is False
        assert attr["unique"] is True

    def test_many_not_unique(self, client):
        ast = client.parse("ATTRIBUTE company.partner REF MANY")
        attr = ast["Attribute"]
        assert attr["many"] is True
        assert attr["unique"] is False


# ---------------------------------------------------------------------------
# PARTITION
# ---------------------------------------------------------------------------

class TestPartition:
    def test_partition(self, client):
        ast = client.parse("PARTITION my_partition")
        assert ast == {"Partition": {"name": "my_partition"}}


# ---------------------------------------------------------------------------
# Literal types
# ---------------------------------------------------------------------------

class TestLiterals:
    def test_int(self, client):
        ast = client.parse("SELECT d1.x WHERE d1.eid = 42")
        right = ast["Select"]["conditions"][0]["right"]
        assert right == {"Literal": {"Int": 42}}

    def test_float(self, client):
        ast = client.parse("SELECT d1.x WHERE d1.eid = 3.14")
        right = ast["Select"]["conditions"][0]["right"]
        assert right == {"Literal": {"Float": 3.14}}

    def test_bool_true(self, client):
        ast = client.parse("SELECT d1.x WHERE d1.active = true")
        right = ast["Select"]["conditions"][0]["right"]
        assert right == {"Literal": {"Bool": True}}

    def test_bool_false(self, client):
        ast = client.parse("SELECT d1.x WHERE d1.active = false")
        right = ast["Select"]["conditions"][0]["right"]
        assert right == {"Literal": {"Bool": False}}

    def test_string(self, client):
        ast = client.parse("SELECT d1.x WHERE d1.name = 'hello world'")
        right = ast["Select"]["conditions"][0]["right"]
        assert right == {"Literal": {"Str": "hello world"}}


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

class TestErrors:
    def test_invalid_sql_raises(self, client):
        with pytest.raises(RuntimeError, match="unexpected character"):
            client.parse("NOT VALID SQL !!!")

    def test_unexpected_eof(self, client):
        with pytest.raises(RuntimeError):
            client.parse("SELECT d1.eid WHERE")

    def test_empty_string(self, client):
        with pytest.raises(RuntimeError):
            client.parse("")


# ---------------------------------------------------------------------------
# parse_raw returns JSON string
# ---------------------------------------------------------------------------

class TestParseRaw:
    def test_returns_json_string(self, client):
        raw = client.parse_raw("SELECT d1.eid")
        assert isinstance(raw, str)
        parsed = json.loads(raw)
        assert "Select" in parsed
