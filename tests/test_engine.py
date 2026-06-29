import gc
import gzip

import orjson
import pytest
from datetime import datetime, timedelta, timezone

from eavt_sql.engine import EAVTEngine
from eavt_sql.types import ref

ATTR_PARTNER = "company.partner"
ATTR_HQ = "company.hq"
ATTR_ACTIVE = "company.active"
ATTR_COMPANY_NAME = "company.name"
ATTR_PERSON_NAME = "person.name"


@pytest.fixture
def engine(tmp_path):
    e = EAVTEngine(str(tmp_path / "db"))
    list(e.sql("ATTRIBUTE company.partner REF MANY"))
    list(e.sql("ATTRIBUTE company.hq REF ONE"))
    list(e.sql("ATTRIBUTE city.name STRING ONE"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("ATTRIBUTE person.name STRING ONE"))

    rows = list(e.sql(
        "UPSERT AS D1 SET company.name = 'ACME Corp Ltd',"
        " AS D2 SET company.name = 'Globex Inc',"
        " AS D3 SET person.name = 'John Smith',"
        " AS D4 SET person.name = 'Jane Doe',"
        " AS D5 SET city.name = 'New York'"
    ))
    company_a = rows[0][0]
    company_b = list(e.sql("SELECT d1.eid WHERE d1.company.name = 'Globex Inc'"))[0][0]
    partner_b = list(e.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    partner_c = list(e.sql("SELECT d1.eid WHERE d1.person.name = 'Jane Doe'"))[0][0]
    ny_eid = list(e.sql("SELECT d1.eid WHERE d1.city.name = 'New York'"))[0][0]

    list(e.sql("UPSERT AS D1 = %1 SET company.partner = %2, company.partner = %3, company.hq = %4",
               company_a, partner_b, partner_c, ny_eid))
    list(e.sql("UPSERT AS D1 = %1 SET company.partner = %2, company.hq = %3",
               company_b, partner_b, ny_eid))
    list(e.sql("UPSERT AS D1 = %1 SET company.hq = %2", partner_b, ny_eid))

    yield (e, company_a, company_b, partner_b, partner_c, ny_eid)
    e.close()


def test_q_partners_by_entity(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert set(results) == {(partner_b,), (partner_c,)}


def test_q_by_attribute(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql("SELECT d1.eid, d1.company.partner"))
    assert len(results) == 3
    relations = {(r[0], r[1]) for r in results}
    assert (company_a, partner_b) in relations
    assert (company_a, partner_c) in relations
    assert (company_b, partner_b) in relations


def test_q_by_ref_value(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql("SELECT d1.eid WHERE d1.company.hq = %1", ny_eid))
    assert set(results) == {(company_a,), (company_b,), (partner_b,)}


def test_q_reverse_ref(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql("SELECT d1.eid WHERE d1.company.partner = %1", partner_b))
    assert set(results) == {(company_a,), (company_b,)}


def test_id_persistence(tmp_path):
    db_path = str(tmp_path / "db")
    engine = EAVTEngine(db_path)
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2,"
        " AS D2 SET person.name = 'Jane Doe'"
    ))
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Jane Doe'"))[0][0]
    e_id = list(engine.sql("SELECT d1.eid WHERE d1.company.partner = %1", partner_b))[0][0]
    engine.close()
    del engine
    gc.collect()

    engine2 = EAVTEngine(db_path)
    list(engine2.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine2.sql("ATTRIBUTE person.name STRING ONE"))
    results = list(engine2.sql("SELECT d1.eid WHERE d1.company.partner = %1", partner_b))
    assert len(results) >= 1
    assert results[0][0] == e_id
    engine2.close()


def test_entity_name_cross_session(tmp_path):
    db_path = str(tmp_path / "db")
    engine = EAVTEngine(db_path)
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3,"
        " AS D2 SET person.name = 'John Smith',"
        " AS D3 SET person.name = 'Jane Doe'"
    ))
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    company_a = rows[0][0]
    engine.close()

    engine2 = EAVTEngine(db_path)
    list(engine2.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine2.sql("ATTRIBUTE person.name STRING ONE"))
    results = list(engine2.sql("SELECT d1.eid WHERE d1.company.partner = %1", partner_b))
    assert len(results) == 1
    assert results[0][0] == company_a
    assert isinstance(results[0][0], int)
    engine2.close()


def test_idempotent_interning(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.hq = 1,"
        " AS D2 SET person.name = 'John Smith'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    eid_a = list(engine.sql("SELECT d1.eid WHERE d1.company.partner = %1 AND d1.eid = d2.eid", partner_b))[0][0]

    rows2 = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.hq = 2,"
        " AS D2 SET person.name = 'Jane Doe'"
    ))
    company_b = rows2[0][0]
    partner_c = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Jane Doe'"))[0][0]
    eid_b = list(engine.sql("SELECT d1.eid WHERE d1.company.partner = %1 AND d1.eid = d2.eid", partner_c))[0][0]
    assert eid_b != eid_a

    engine.close()


def test_q_variable_by_entity(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert results == [("ACME Corp Ltd",)]


def test_q_variable_by_attribute():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows_a = list(engine.sql("UPSERT SET company.name = 'ACME Corp Ltd'"))
    company_a = rows_a[0][0]
    rows_b = list(engine.sql("UPSERT SET company.name = 'Globex Inc'"))
    company_b = rows_b[0][0]

    results = list(engine.sql("SELECT d1.eid, d1.company.name"))
    assert len(results) == 2
    names = {(r[0], r[1]) for r in results}
    assert (company_a, "ACME Corp Ltd") in names
    assert (company_b, "Globex Inc") in names
    engine.close()


def test_retract_datom_ref(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    list(e.sql(f"DELETE WHERE d1.eid = {company_a} AND d1.company.partner = {partner_b}"))

    results = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert partner_b not in {r[0] for r in results}
    assert partner_c in {r[0] for r in results}


def test_retract_does_not_affect_other_value(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    list(e.sql(f"DELETE WHERE d1.eid = {company_a} AND d1.company.partner = {partner_b}"))

    partners_a = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert partner_b not in {r[0] for r in partners_a}

    partners_b = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_b))
    assert partner_b in {r[0] for r in partners_b}


def test_reassert_after_retract(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    list(e.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_b))

    partners = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert partner_b not in {r[0] for r in partners}
    assert partner_c in {r[0] for r in partners}

    rows = list(e.sql("UPSERT SET company.partner = %1", partner_b))
    new_eid = rows[0][0]
    partners = list(e.sql("SELECT d1.company.partner WHERE d1.eid = %1", new_eid))
    assert partner_b in {r[0] for r in partners}


def test_retract_middle_leaves_two():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_b = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = rows_b[0][0]
    rows_c = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = rows_c[0][0]
    rows_d = list(engine.sql("UPSERT SET company.name = 'Globex'"))
    company_b = rows_d[0][0]
    rows_a = list(engine.sql(
        "UPSERT SET company.name = 'ACME', company.partner = %1, company.partner = %2, company.partner = %3",
        partner_b, partner_c, company_b,
    ))
    company_a = rows_a[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_c))

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    partners = {r[0] for r in results}
    assert partners == {partner_b, company_b}
    engine.close()


def test_retract_variable():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp Ltd'"))
    company_a = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {company_a} AND d1.company.name = 'ACME Corp Ltd'"))

    results = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert results == []
    engine.close()


def test_retract_variable_does_not_affect_other():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows_a = list(engine.sql("UPSERT SET company.name = 'ACME Corp Ltd'"))
    company_a = rows_a[0][0]
    rows_b = list(engine.sql("UPSERT SET company.name = 'Globex Inc'"))
    company_b = rows_b[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {company_a} AND d1.company.name = 'ACME Corp Ltd'"))

    results_a = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert results_a == []

    results_b = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_b))
    assert results_b == [("Globex Inc",)]
    engine.close()


def test_uint64_entity_fixed(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.active LONG ONE"))
    rows = list(engine.sql("UPSERT SET company.hq = 1, company.active = 1"))
    eid = rows[0][0]

    results = list(engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", eid))
    assert len(results) == 2
    attrs = {r[0] for r in results}
    assert "company.hq" in attrs
    assert "company.active" in attrs
    engine.close()


def test_uint64_entity_ref(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.id LONG ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'company-a', company.partner = d2,"
        " AS D2 SET company.id = 3001, company.partner = d1"
    ))
    company_a = rows[0][0]
    e3001 = list(engine.sql("SELECT d1.eid WHERE d1.company.id = 3001"))[0][0]

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", e3001))
    assert results == [(company_a,)]

    reverse = list(engine.sql("SELECT d1.eid WHERE d1.company.partner = %1", e3001))
    assert reverse == [(company_a,)]
    engine.close()


def test_uint64_entity_variable(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME uint64'"))
    eid = rows[0][0]

    results = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert results == [("ACME uint64",)]
    engine.close()


def test_uint64_entity_retract(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    rows = list(engine.sql("UPSERT SET company.hq = 1"))
    eid = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.company.hq = 1"))

    results = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", eid))
    assert results == []
    engine.close()


def test_uint64_entity_attribute_lookup(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows_a = list(engine.sql("UPSERT SET company.hq = 1"))
    eid_2001 = rows_a[0][0]
    rows_b = list(engine.sql("UPSERT SET company.name = 'company-a', company.hq = 2"))
    company_a = rows_b[0][0]

    results = list(engine.sql("SELECT d1.eid, d1.company.hq"))
    entities = {r[0] for r in results}
    assert eid_2001 in entities
    engine.close()


def test_memory_backend_fixed():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME', company.partner = d2, company.partner = d3,"
        " AS D2 SET person.name = 'partner-b',"
        " AS D3 SET person.name = 'partner-c'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-b'"))[0][0]
    partner_c = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-c'"))[0][0]
    rows_d = list(engine.sql("UPSERT SET company.hq = 1"))
    eid_2001 = rows_d[0][0]

    partners = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert set(partners) == {(partner_b,), (partner_c,)}

    r = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", eid_2001))
    assert len(r) == 1
    assert r[0][0] == 1
    engine.close()


def test_memory_backend_variable():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp'"))
    company_a = rows[0][0]

    r = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert r == [("ACME Corp",)]
    engine.close()


def test_memory_backend_retract():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_b = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = rows_b[0][0]
    rows_a = list(engine.sql("UPSERT SET company.name = 'ACME', company.partner = %1", partner_b))
    company_a = rows_a[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_b))

    r = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert r == []
    engine.close()


def test_q_multi_pattern_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_b = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = rows_b[0][0]
    rows_c = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = rows_c[0][0]
    rows_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = rows_ny[0][0]
    rows_chi = list(engine.sql("UPSERT SET city.name = 'Chicago'"))
    chi_eid = rows_chi[0][0]
    rows_a = list(engine.sql(
        "UPSERT SET company.name = 'ACME', company.partner = %1, company.partner = %2, company.hq = %3",
        partner_b, partner_c, ny_eid,
    ))
    company_a = rows_a[0][0]
    rows_d = list(engine.sql(
        "UPSERT SET company.name = 'Globex', company.partner = %1, company.hq = %2",
        partner_b, chi_eid,
    ))
    company_b = rows_d[0][0]

    results = list(engine.sql(
        "SELECT d1.eid, d2.company.partner WHERE d1.company.hq = %1 AND d1.eid = d2.eid",
        ny_eid,
    ))
    assert len(results) == 2
    companies = {r[0] for r in results}
    partners = {r[1] for r in results}
    assert companies == {company_a}
    assert partners == {partner_b, partner_c}
    engine.close()


def test_q_raw_int_projection():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_b = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = rows_b[0][0]
    rows_c = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = rows_c[0][0]
    rows_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = rows_ny[0][0]
    rows_a = list(engine.sql(
        "UPSERT SET company.name = 'ACME', company.partner = %1, company.partner = %2, company.hq = %3",
        partner_b, partner_c, ny_eid,
    ))
    company_a = rows_a[0][0]

    results = list(engine.sql(
        "SELECT d1.eid, d2.company.partner WHERE d1.company.hq = %1 AND d1.eid = d2.eid",
        ny_eid,
    ))
    assert all(isinstance(r[0], int) for r in results)
    assert all(isinstance(r[1], int) for r in results)
    assert len(results) == 2
    engine.close()


def test_q_retracted_excluded():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3,"
        " AS D2 SET person.name = 'partner-b',"
        " AS D3 SET person.name = 'partner-c'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-b'"))[0][0]
    partner_c = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-c'"))[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {company_a} AND d1.company.partner = {partner_b}"))

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert results == [(partner_c,)]
    engine.close()


def test_q_uint64_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.hq = 1, company.partner = d2,"
        " AS D2 SET company.hq = 1"
    ))
    eid_2001 = rows[0][0]
    eid_2002 = list(engine.sql(
        "SELECT d2.eid WHERE d1.company.partner = d2.eid AND d1.eid = %1", eid_2001
    ))[0][0]

    results = list(engine.sql("SELECT d1.eid WHERE d1.company.hq = %1", 1))
    assert set(results) == {(eid_2001,), (eid_2002,)}
    engine.close()


def test_q_empty_result():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_b = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = rows_b[0][0]
    rows_a = list(engine.sql(
        "UPSERT SET company.name = 'ACME', company.partner = %1", partner_b
    ))
    company_a = rows_a[0][0]
    rows_c = list(engine.sql("UPSERT SET company.name = 'Globex'"))
    company_b = rows_c[0][0]

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_b))
    assert results == []
    engine.close()


def test_q_var_a_pattern():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = rows_ny[0][0]
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.hq = %1,"
        " AS D2 SET person.name = 'partner-b'",
        ny_eid,
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", company_a))
    assert len(results) == 2
    engine.close()


def test_q_merge_fixed_and_variable_by_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.name = 'ACME Corp',"
        " AS D2 SET person.name = 'partner-b'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-b'"))[0][0]

    results = list(engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", company_a))
    attrs = {r[0] for r in results}
    vals = {r[1] for r in results}
    assert ATTR_PARTNER in attrs
    assert ATTR_COMPANY_NAME in attrs
    assert partner_b in vals
    assert "ACME Corp" in vals
    engine.close()


def test_q_merge_var_a_var_v_includes_fixed_and_variable():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.hq = d3, company.name = 'ACME Corp',"
        " AS D2 SET person.name = 'John',"
        " AS D3 SET city.name = 'New York'"
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.attr WHERE d1.eid = %1", company_a))
    attrs = {r[0] for r in results}
    assert attrs == {ATTR_PARTNER, ATTR_HQ, ATTR_COMPANY_NAME}
    engine.close()


def test_q_join_fixed_with_variable():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3, company.name = 'ACME Corp',"
        " AS D2 SET person.name = 'John',"
        " AS D3 SET person.name = 'Mary'"
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid", company_a))
    names = {r[0] for r in results}
    assert names == {"John", "Mary"}
    engine.close()


def test_q_variable_retracted_excluded():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(f"UPSERT SET {ATTR_COMPANY_NAME} = 'ACME Corp'"))
    eid = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.{ATTR_COMPANY_NAME} = 'ACME Corp'"))

    results = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert results == []
    engine.close()


def test_q_val_returns_mixed_types():
    engine = EAVTEngine(":memory:")
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(
        f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, {ATTR_COMPANY_NAME} = 'ACME Corp',"
        f" AS D2 SET {ATTR_COMPANY_NAME} = 'phantom'"
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.val WHERE d1.eid = %1", company_a))
    types = {type(r[0]) for r in results}
    assert int in types
    assert str in types
    assert len(results) == 2
    engine.close()


def test_q_rocksdb_merge_fixed_and_variable(tmp_path):
    engine = EAVTEngine(str(tmp_path / "db"))
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(
        f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, {ATTR_COMPANY_NAME} = 'ACME Corp',"
        f" AS D2 SET {ATTR_COMPANY_NAME} = 'phantom'"
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", company_a))
    attrs = {r[0] for r in results}
    assert ATTR_PARTNER in attrs
    assert ATTR_COMPANY_NAME in attrs
    engine.close()


def test_q_t_var_isotime():
    engine = EAVTEngine(":memory:", tz=timezone.utc)
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    rows = list(engine.sql(f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, AS D2 SET {ATTR_PARTNER} = d1"))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert results[0][0] == partner_b
    engine.close()


def test_q_t_var_raw_microseconds():
    engine = EAVTEngine(":memory:")
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    rows = list(engine.sql(f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, AS D2 SET {ATTR_PARTNER} = d1"))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert results[0][0] == partner_b
    engine.close()


def test_q_t_var_with_variable():
    engine = EAVTEngine(":memory:", tz=timezone.utc)
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(f"UPSERT SET {ATTR_COMPANY_NAME} = 'ACME Corp'"))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.company.name, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert results[0][0] == "ACME Corp"
    engine.close()


def test_q_t_var_tz_brt():
    brt = timezone(timedelta(hours=-3))
    engine = EAVTEngine(":memory:", tz=brt)
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    rows = list(engine.sql(f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, AS D2 SET {ATTR_PARTNER} = d1"))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert isinstance(results[0][1], int)
    engine.close()


def test_q_t_var_tz_override_in_query():
    brt = timezone(timedelta(hours=-3))
    engine = EAVTEngine(":memory:")
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    rows = list(engine.sql(f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, AS D2 SET {ATTR_PARTNER} = d1"))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
        tz=brt,
    ))
    assert isinstance(results[0][1], int)
    engine.close()



# ── Late variable classification & stratification ──────────────────


ATTR_DESC = "item.description"
ATTR_TAG = "tag.label"


def _make_engine_with_schema():
    engine = EAVTEngine(":memory:")
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    list(engine.sql(f"ATTRIBUTE {ATTR_HQ} REF ONE"))
    list(engine.sql(f"ATTRIBUTE {ATTR_COMPANY_NAME} STRING ONE"))
    return engine


def test_find_subset_of_where_vars_ok():
    engine = EAVTEngine(":memory:")
    list(engine.sql(f"ATTRIBUTE {ATTR_PARTNER} REF MANY"))
    rows = list(engine.sql(f"UPSERT AS D1 SET {ATTR_PARTNER} = d2, AS D2 SET {ATTR_PARTNER} = d1"))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        company_a,
    ))
    assert results == [(partner_b,)]
    engine.close()





def test_save_query_bytes_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    raw = b"\xde\xad\xbe\xef"
    rows = list(engine.sql("UPSERT SET company.name = 'temp', blob.data = %1", raw))
    eid = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", eid))
    assert len(results) == 1
    assert results[0][0] == raw
    engine.close()


def test_bytes_with_null_byte():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"hello\x00world"
    rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert len(results) == 1
    assert results[0][0] == raw
    engine.close()


def test_bytes_multiple_null():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"\x00\x00\x00"
    rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert len(results) == 1
    assert results[0][0] == raw
    engine.close()


def test_bytes_retract():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    rows = list(engine.sql("UPSERT SET blob.data = %1", b"\x01\x02\x03"))
    e1 = rows[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.blob.data = %2", e1, b"\x01\x02\x03"))
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert results == []
    engine.close()


def test_bytes_cardinality_many():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES MANY"))
    rows = list(engine.sql("UPSERT SET blob.data = %1, blob.data = %2, blob.data = %3", b"\xaa", b"\xbb", b"\xcc"))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    values = sorted(results)
    assert values == [(b"\xaa",), (b"\xbb",), (b"\xcc",)]
    engine.close()


def test_bytes_cardinality_one_overwrite():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    rows = list(engine.sql("UPSERT SET blob.data = %1, blob.data = %2", b"\x01", b"\x02"))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert results == [(b"\x02",)]
    engine.close()


def test_bytes_vs_string_distinct():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE doc.text STRING ONE"))
    list(engine.sql("ATTRIBUTE doc.data BYTES ONE"))
    rows = list(engine.sql("UPSERT SET doc.text = 'hello', doc.data = %1", b"hello"))
    e1 = rows[0][0]
    results_str = list(engine.sql("SELECT d1.doc.text WHERE d1.eid = %1", e1))
    results_bytes = list(engine.sql("SELECT d1.doc.data WHERE d1.eid = %1", e1))
    assert len(results_str) == 1
    assert len(results_bytes) == 1
    assert results_str[0][0] == "hello"
    assert results_bytes[0][0] == b"hello"
    engine.close()


def test_bytes_all_indices_round_trip():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"\xff\xfe\x00\x01\xde\xad"
    rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
    entity1 = rows[0][0]
    results = list(engine.sql("SELECT *"))
    found = [r for r in results if len(r) >= 3 and isinstance(r[2], bytes) and r[2] == raw]
    assert len(found) == 1
    engine.close()


def test_bytes_empty():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    rows = list(engine.sql("UPSERT SET blob.data = %1", b""))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert len(results) == 1
    assert results[0][0] == b""
    engine.close()


def test_bytes_large_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    rows = list(engine.sql("UPSERT SET blob.data = %1", b"\x00"))
    e1 = rows[0][0]
    raw = bytes(range(256)) * 4
    with pytest.raises(ValueError, match="too large"):
        list(engine.sql("UPSERT AS D1 = %1 SET blob.data = %2", e1, b"\x00" * 1_048_577))
    engine.close()


def test_bytes_at_max_ok():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"\xAB" * 1_048_576
    rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
    e1 = rows[0][0]
    results = list(engine.sql("SELECT d1.blob.data WHERE d1.eid = %1", e1))
    assert len(results) == 1
    assert results[0][0] == raw
    engine.close()


def test_bytes_over_max_rejected():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"\x00" * 1_048_577
    with pytest.raises(ValueError, match="too large"):
        list(engine.sql("UPSERT SET blob.data = %1", raw))
    engine.close()


# ── JSONL Exporter ──────────────────────────────────────────────────


def _read_jsonl(path: str) -> list[dict]:
    with gzip.open(path, "rb") as f:
        return [orjson.loads(line) for line in f if line.strip()]


def test_export_current_state():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.dummy.x = 1", partner_b))
    r_pc = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_c = r_pc[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.dummy.x = 1", partner_c))
    r_ca = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2, company.name = 'ACME Corp'",
        partner_b, partner_c,
    ))
    company_a = r_ca[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_b))

    out = "/tmp/opencode/test_export.jsonl.gz"
    engine.export_jsonl(out)
    engine.close()

    rows = [r for r in _read_jsonl(out) if not r["a"].startswith("db.")]
    assert len(rows) == 2

    ref_socio = [r for r in rows if r["a"] == ATTR_PARTNER]
    assert {r["v"] for r in ref_socio} == {partner_c}

    var_name = [r for r in rows if r["a"] == ATTR_COMPANY_NAME]
    assert var_name[0]["v"] == "ACME Corp"
    assert "r" not in var_name[0]


def test_export_entity_all_uint64():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.active LONG ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.dummy.x = 1", partner_b))
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    company_a = r_ca[0][0]
    r_2001 = list(engine.sql("UPSERT SET company.partner = %1, company.active = 1", company_a))
    e2001 = r_2001[0][0]

    out = "/tmp/opencode/test_entity.jsonl.gz"
    engine.export_jsonl(out)
    engine.close()

    rows = [r for r in _read_jsonl(out) if not r["a"].startswith("db.")]
    assert len(rows) == 3

    partners = [r for r in rows if r["a"] == ATTR_PARTNER]
    e_vals = {r["e"] for r in partners}
    assert company_a in e_vals
    assert e2001 in e_vals
    r_vals = {r["v"] for r in partners}
    assert partner_b in r_vals
    assert company_a in r_vals

    active = [r for r in rows if r["a"] == ATTR_ACTIVE]
    assert active[0]["e"] == e2001
    assert active[0]["v"] == 1


def test_import_jsonl_current_state_round_trip():
    engine1 = EAVTEngine(":memory:")
    list(engine1.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine1.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine1.sql("ATTRIBUTE company.name STRING ONE"))
    r_pb = list(engine1.sql("UPSERT SET person.name = 'John'"))
    partner_b = r_pb[0][0]
    r_ca = list(engine1.sql(
        "UPSERT SET company.partner = %1, company.name = 'ACME'",
        partner_b,
    ))
    company_a = r_ca[0][0]

    out = "/tmp/opencode/test_current_rt.jsonl.gz"
    engine1.export_jsonl(out)
    engine1.close()

    engine2 = EAVTEngine(":memory:")
    list(engine2.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine2.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine2.sql("ATTRIBUTE person.name STRING ONE"))
    engine2.import_jsonl(out)

    partners = list(engine2.sql(
        "SELECT d2.person.name WHERE d1.company.name = 'ACME' AND d1.company.partner = d2.eid"
    ))
    assert partners == [("John",)]

    engine2.close()


# ── Cardinality put (one) / add (many) ─────────────────────────────

def test_put_ref_replaces_int_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    rows = list(engine.sql("UPSERT SET company.hq = 2"))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", company_a))
    assert results == [(2,)]
    engine.close()


def test_save_ref_replaces_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pc = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = r_pc[0][0]
    rows = list(engine.sql("UPSERT SET company.partner = %1", partner_c))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert results == [(partner_c,)]
    engine.close()


def test_put_var_replaces_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'New Name'"))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert results == [("New Name",)]
    engine.close()


def test_put_idempotent():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = r_pb[0][0]
    rows = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert results == [(partner_b,)]
    engine.close()


def test_put_retract_all():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp'"))
    company_a = rows[0][0]

    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.name = 'ACME Corp'", company_a))

    results = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_a))
    assert results == []
    engine.close()


def test_save_retract_all_with_one_cardinality():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pc = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = r_pc[0][0]
    rows = list(engine.sql("UPSERT SET company.partner = %1", partner_c))
    company_a = rows[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_c))

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert results == []
    engine.close()


def test_add_allows_multiple():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'partner-b'"))
    partner_b = r_pb[0][0]
    r_pc = list(engine.sql("UPSERT SET person.name = 'partner-c'"))
    partner_c = r_pc[0][0]
    r_cb = list(engine.sql("UPSERT SET company.name = 'company-b'"))
    company_b = r_cb[0][0]
    rows = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2, company.partner = %3",
        partner_b, partner_c, company_b,
    ))
    company_a = rows[0][0]

    results = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", company_a))
    assert len(results) == 3
    engine.close()


# ── Chunked Merge Join & Planner ────────────────────────────────────


def test_planner_avet_for_v_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'John'"))
    partner_b = r_pb[0][0]
    r_pc = list(engine.sql("UPSERT SET person.name = 'Mary'"))
    partner_c = r_pc[0][0]
    r_ca = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2",
        partner_b, partner_c,
    ))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.eid = %1 AND d2.eid = d1.company.partner",
        company_a,
    ))
    assert set(results) == {("John",), ("Mary",)}
    engine.close()


def test_chunked_join_three_patterns():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'John'"))
    partner_b = r_pb[0][0]
    r_pc = list(engine.sql("UPSERT SET person.name = 'Mary'"))
    partner_c = r_pc[0][0]
    r_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = r_ny[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1, company.partner = %2, company.hq = %3", partner_b, partner_c, ny_eid))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT d3.person.name WHERE d1.eid = %1 AND d2.eid = %1 AND d2.company.hq = %2 AND d3.eid = d1.company.partner",
        company_a, ny_eid,
    ))
    assert set(results) == {("John",), ("Mary",)}
    engine.close()


def test_chunked_join_large_dataset():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    eids = {}
    for i in range(500):
        r = list(engine.sql("UPSERT AS D1 SET company.partner = d1, person.name = %1", f"name-{i}"))
        eids[i] = r[0][0]

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.company.partner = d1.eid AND d2.eid = d1.eid",
    ))
    assert len(results) == 500
    engine.close()


def test_timestamp_not_shared_ok():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.name = 'ACME Corp',"
        " AS D2 SET person.name = 'x'",
    ))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    engine.close()


def test_planner_aevt_for_e_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    r_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = r_ny[0][0]
    r_ca = list(engine.sql("UPSERT SET company.hq = %1, company.name = 'ACME'", ny_eid))
    company_a = r_ca[0][0]
    r_cb = list(engine.sql("UPSERT SET company.hq = %1, company.name = 'Globex'", ny_eid))
    company_b = r_cb[0][0]

    results = list(engine.sql(
        "SELECT d1.eid, d2.company.name WHERE d1.company.hq = %1 AND d1.eid = d2.eid",
        ny_eid,
    ))
    assert len(results) == 2
    names = {r[1] for r in results}
    assert names == {"ACME", "Globex"}
    engine.close()


def test_single_pattern_unchanged():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'John'"))
    partner_b = r_pb[0][0]

    results = list(engine.sql(
        "SELECT d1.person.name WHERE d1.eid = %1",
        partner_b,
    ))
    assert results == [("John",)]
    engine.close()


def test_entity_dump_all_attrs():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE company.active LONG ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.hq = d3, company.name = 'ACME', company.active = 1,"
        " AS D2 SET person.name = 'x', AS D3 SET city.name = 'New York'"
    ))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.attr, d1.val WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 4
    engine.close()


def test_reverse_ref_cross_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.dummy.x = 1", partner_b))
    r_ca = list(engine.sql("UPSERT SET company.partner = %1, company.hq = %1", partner_b))

    results = list(engine.sql(
        "SELECT d1.eid, d1.attr",
    ))
    results = [r for r in results if not r[1].startswith("db.")]
    assert len(results) == 2
    engine.close()


# ── Stress tests for AVET merge / scanner grouping ─────────────────


ATTR_TAG = "tag.label"
ATTR_LABEL = "label.name"
ATTR_STATUS = "status.code"


def test_avet_mixed_ref_variable_v_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE tag.label REF MANY"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_tgt = list(engine.sql("UPSERT SET person.name = 'Alice'"))
    target_a = r_tgt[0][0]
    r_na = list(engine.sql("UPSERT SET city.name = 'not-a-ref'"))
    not_a_ref = r_na[0][0]
    list(engine.sql("UPSERT SET tag.label = %1", target_a))
    list(engine.sql("UPSERT SET tag.label = %1", not_a_ref))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.tag.label = d2.eid",
    ))
    assert results == [("Alice",)]
    engine.close()


def test_avet_ref_only_v_join_many_entities():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE tag.label REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(120):
        list(engine.sql("UPSERT AS D1 SET tag.label = d2, AS D2 SET person.name = %1", f"name-{i}"))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.tag.label = d2.eid",
    ))
    assert len(results) == 120
    names = {r[0] for r in results}
    for i in range(120):
        assert f"name-{i}" in names
    engine.close()


def test_avet_ref_join_with_retracts():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE tag.label REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r3 = list(engine.sql("UPSERT SET person.name = 'Alpha'"))
    tgt1 = r3[0][0]
    r4 = list(engine.sql("UPSERT SET person.name = 'Beta'"))
    tgt2 = r4[0][0]
    r1 = list(engine.sql(
        "UPSERT SET tag.label = %1, tag.label = %2",
        tgt1, tgt2,
    ))
    src1 = r1[0][0]
    r2 = list(engine.sql("UPSERT SET tag.label = %1", tgt2))
    src2 = r2[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.tag.label = %2", src1, tgt1))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.tag.label = d2.eid",
    ))
    names = {r[0] for r in results}
    assert "Alpha" not in names
    assert "Beta" in names
    engine.close()


def test_chunked_join_300_entities_across_chunks():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE tag.label REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(300):
        list(engine.sql("UPSERT AS D1 SET tag.label = d2, AS D2 SET person.name = %1", f"name-{i}"))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.tag.label = d2.eid",
    ))
    assert len(results) == 300
    names = {r[0] for r in results}
    for i in range(300):
        assert f"name-{i}" in names
    engine.close()


# ── Lookup probes (Leapfrog Triejoin step 1) ──────────────────────


def test_lookup_exists():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    partner_b = r_pb[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT d2.company.partner WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.partner = %2",
        company_a, partner_b,
    ))
    assert results == [(partner_b,)]
    engine.close()


def test_lookup_not_exists_returns_empty():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    r_pc = list(engine.sql("UPSERT SET person.name = 'y'"))
    partner_c = r_pc[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", r_pb[0][0]))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT d2.company.partner WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.partner = %2",
        company_a, partner_c,
    ))
    assert results == []
    engine.close()


def test_lookup_retracted_returns_empty():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    partner_b = r_pb[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    company_a = r_ca[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.partner = %2", company_a, partner_b))

    results = list(engine.sql(
        "SELECT d2.company.partner WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.partner = %2",
        company_a, partner_b,
    ))
    assert results == []
    engine.close()


def test_lookup_multiple_one_fails():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    partner_b = r_pb[0][0]
    r_ny = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = r_ny[0][0]
    r_chi = list(engine.sql("UPSERT SET city.name = 'Chicago'"))
    chi_eid = r_chi[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1, company.hq = %2", partner_b, ny_eid))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner WHERE d1.eid = %1 AND d1.company.partner = %2 AND d1.company.hq = %3",
        company_a, partner_b, chi_eid,
    ))
    assert results == []
    engine.close()


def test_lookup_only_patterns_returns_unit():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    partner_b = r_pb[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
        company_a, partner_b,
    ))
    assert results == [(1,)]
    engine.close()


def test_lookup_only_patterns_all_fail():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_pb = list(engine.sql("UPSERT SET person.name = 'x'"))
    r_pc = list(engine.sql("UPSERT SET person.name = 'y'"))
    partner_c = r_pc[0][0]
    r_ca = list(engine.sql("UPSERT SET company.partner = %1", r_pb[0][0]))
    company_a = r_ca[0][0]

    results = list(engine.sql(
        "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
        company_a, partner_c,
    ))
    assert results == []
    engine.close()


def test_lookup_text_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp'"))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d2.company.name WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.name = %2",
        company_a, "ACME Corp",
    ))
    assert results == [("ACME Corp",)]
    engine.close()


def test_lookup_text_not_exists():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp'"))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d2.company.name WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.name = %2",
        company_a, "Globex Inc",
    ))
    assert results == []
    engine.close()



# ── Same-variable constraints & variable ordering stress tests ─────


def test_same_var_e_and_v_filters_non_self_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_c = list(engine.sql(
        "UPSERT AS D1 SET person.name = 'Carol', company.partner = d1"
    ))
    c = r_c[0][0]
    r_e = list(engine.sql("UPSERT SET person.name = 'Eve'"))
    e = r_e[0][0]
    r_a = list(engine.sql("UPSERT AS D1 SET company.partner = d1, person.name = 'Alice'"))
    a = r_a[0][0]
    r_b = list(engine.sql("UPSERT SET company.partner = %1, person.name = 'Bob'", c))
    b = r_b[0][0]
    r_d = list(engine.sql("UPSERT SET company.partner = %1, person.name = 'Dave'", e))
    d = r_d[0][0]

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.eid = d2.eid AND d1.company.partner = d1.eid",
    ))
    names = {r[0] for r in results}
    assert names == {"Alice", "Carol"}
    engine.close()


def test_same_var_e_and_v_large_dataset_most_non_self():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    eids = []
    for i in range(200):
        if i % 10 == 0:
            r = list(engine.sql(
                "UPSERT AS D1 SET person.name = %1, company.partner = d1",
                f"name-{i}",
            ))
        else:
            r = list(engine.sql("UPSERT SET person.name = %1", f"name-{i}"))
        eids.append(r[0][0])
    for i in range(200):
        if i % 10 != 0:
            list(engine.sql(
                "UPSERT SET company.partner = %1, dummy.x = %2",
                eids[i - 1], i,
            ))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.eid = d2.eid AND d1.company.partner = d1.eid",
    ))
    assert len(results) == 20
    names = {r[0] for r in results}
    for i in range(0, 200, 10):
        assert f"name-{i}" in names
    engine.close()


def test_three_variable_chain_join_200_entities():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(200):
        list(engine.sql(
            "UPSERT AS D1 SET company.partner = d2,"
            " AS D2 SET company.hq = d3,"
            " AS D3 SET person.name = %1",
            f"name-{i}",
        ))

    results = list(engine.sql(
        "SELECT d3.person.name WHERE d1.company.partner = d2.eid AND d2.company.hq = d3.eid",
    ))
    assert len(results) == 200
    names = {r[0] for r in results}
    for i in range(200):
        assert f"name-{i}" in names
    engine.close()


def test_variable_as_entity_in_p1_and_value_in_p2():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(100):
        list(engine.sql(
            "UPSERT AS D1 SET person.name = %1, company.partner = d2,"
            " AS D2 SET person.name = %2, company.hq = d1",
            f"name-{i}", f"target-{i}",
        ))

    results = list(engine.sql(
        "SELECT d1.person.name, d2.person.name WHERE d2.company.hq = d1.eid AND d1.company.partner = d2.eid",
    ))
    assert len(results) == 100
    pairs = {(r[0], r[1]) for r in results}
    for i in range(100):
        assert (f"name-{i}", f"target-{i}") in pairs
    engine.close()


def test_circular_join_two_variables():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, person.name = 'Alice',"
        " AS D2 SET company.hq = d1, person.name = 'Bob'"
    ))
    a = rows[0][0]
    r_y = list(engine.sql("UPSERT AS D1 SET company.hq = d1"))
    y = r_y[0][0]
    r_x = list(engine.sql("UPSERT SET company.partner = %1, person.name = 'Xavier'", y))
    x = r_x[0][0]

    results = list(engine.sql(
        "SELECT d1.person.name, d2.person.name WHERE d2.company.hq = d1.eid AND d1.company.partner = d2.eid",
    ))
    assert set(results) == {("Alice", "Bob")}
    engine.close()


def test_same_var_1000_entities_self_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(1000):
        list(engine.sql("UPSERT AS D1 SET company.partner = d1, person.name = %1", f"name-{i}"))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.eid = d2.eid AND d1.company.partner = d1.eid",
    ))
    assert len(results) == 1000
    names = {r[0] for r in results}
    for i in range(1000):
        assert f"name-{i}" in names
    engine.close()


# ── Query explain ──────────────────────────────────────────────────


def test_explain_variable_order_and_estimates():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r = list(engine.sql("UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'Bob', AS D3 SET person.name = 'Carol'"))

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.company.partner = d2.eid",
    ))
    assert rows
    text = "\n".join(row[0] for row in rows)
    assert "LEAP_INIT" in text
    engine.close()


def test_explain_same_var_constraints():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r = list(engine.sql("UPSERT AS D1 SET company.partner = d1, person.name = 'Alice'"))

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.eid = d2.eid AND d1.company.partner = d1.eid",
    ))
    assert rows
    text = "\n".join(row[0] for row in rows)
    assert "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    engine.close()


def test_explain_lookups():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_b = list(engine.sql("UPSERT SET person.name = 'x'"))
    b = r_b[0][0]
    r_a = list(engine.sql("UPSERT SET company.partner = %1", b))
    a = r_a[0][0]

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.company.partner WHERE d1.eid = %1 AND d1.eid = d2.eid AND d1.company.partner = %2",
        a, b,
    ))
    assert rows
    text = "\n".join(row[0] for row in rows)
    assert "PROBE" in text or "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    engine.close()


def test_explain_index_selection():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r_b = list(engine.sql("UPSERT SET person.name = 'Bob'"))
    b = r_b[0][0]
    r_a = list(engine.sql("UPSERT SET company.partner = %1", b))
    a = r_a[0][0]

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = %2 AND d1.company.partner = d2.eid",
        a, b,
    ))
    assert rows
    text = "\n".join(row[0] for row in rows)
    assert "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    engine.close()


def test_explain_depth_iterator_mapping():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    r = list(engine.sql("UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'Bob'"))

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.company.partner = d2.eid",
    ))
    assert rows
    text = "\n".join(row[0] for row in rows)
    assert "DEPTH_OPEN" in text or "DEPTH_ENTER" in text
    assert "LEAP_INIT" in text
    engine.close()
