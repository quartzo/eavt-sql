import pytest
from datetime import datetime, timedelta, timezone

from eavt_sql.engine import EAVTEngine

@pytest.fixture
def engine():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE company.partner REF MANY"))
    list(e.sql("ATTRIBUTE company.hq REF ONE"))
    list(e.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))
    list(e.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(e.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))

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


def test_sql_partners_by_entity(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        company_a,
    ))
    assert set(results) == {(partner_b,), (partner_c,)}


def test_sql_company_name(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.company.name WHERE d1.eid = %1",
        company_a,
    ))
    assert results == [("ACME Corp Ltd",)]


def test_sql_ref_filter(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.eid WHERE d1.company.hq = %1",
        ny_eid,
    ))
    assert set(results) == {(company_a,), (company_b,), (partner_b,)}


def test_sql_reverse_ref(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.eid WHERE d1.company.partner = %1",
        partner_b,
    ))
    assert set(results) == {(company_a,), (company_b,)}


def test_sql_join_partner_names(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid",
        company_a,
    ))
    assert set(results) == {("John Smith",), ("Jane Doe",)}


def test_sql_multi_attr_same_entity(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.eid, d1.company.partner WHERE d1.eid = d2.eid AND d2.company.hq = %1",
        ny_eid,
    ))
    relations = {(r[0], r[1]) for r in results}
    assert (company_a, partner_b) in relations
    assert (company_a, partner_c) in relations
    assert (company_b, partner_b) in relations


def test_sql_exists_true(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
        company_a, partner_b,
    ))
    assert results == [(1,)]


def test_sql_exists_false(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
        company_a, 999999,
    ))
    assert results == []


def test_sql_wildcard_attr_val(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.attr, d1.val WHERE d1.eid = %1",
        company_a,
    ))
    pairs = {r for r in results}
    assert len(pairs) >= 3


def test_sql_raw_eid(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    results = list(e.sql(
        "SELECT d1.eid WHERE d1.company.partner = %1",
        partner_b,
    ))
    assert len(results) == 2
    for r in results:
        assert isinstance(r[0], int)


def test_sql_as_of_string():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3, AS D2 SET person.name = 'John Smith', AS D3 SET person.name = 'Jane Doe'",
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    partner_c = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Jane Doe'"))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        company_a,
        as_of="2025-06-15T12:00:01+00:00",
    ))
    assert set(results) == {(partner_b,), (partner_c,)}
    engine.close()


def test_sql_as_of_datetime():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3, AS D2 SET person.name = 'John Smith', AS D3 SET person.name = 'Jane Doe'",
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    partner_c = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Jane Doe'"))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        company_a,
        as_of=datetime(2025, 6, 15, 12, 0, 1, tzinfo=timezone.utc),
    ))
    assert set(results) == {(partner_b,), (partner_c,)}
    engine.close()


def test_sql_timestamp():
    engine = EAVTEngine(":memory:", tz=timezone.utc)
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'partner-b'",
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-b'"))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert results[0][0] == partner_b
    assert isinstance(results[0][1], int)
    engine.close()


def test_sql_timestamp_code():
    engine = EAVTEngine(":memory:", tz=timezone.utc)
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'partner-b'",
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'partner-b'"))[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
    ))
    assert len(results) == 1
    assert results[0][0] == partner_b
    assert results[0][1] == (3 << 44) | 1002
    engine.close()


def test_sql_self_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("UPSERT AS D1 SET company.partner = d1, person.name = 'Selfie'"))

    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.company.partner = d1.eid AND d1.eid = d2.eid"
    ))
    assert results == [("Selfie",)]
    engine.close()


def test_sql1_returns_first(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    result = e.sql1(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        company_a,
    )
    assert result is not None
    assert result[0] in (partner_b, partner_c)


def test_sql1_returns_none(engine):
    e, company_a, company_b, partner_b, partner_c, ny_eid = engine
    result = e.sql1(
        "SELECT d1.company.partner WHERE d1.eid = %1",
        999999,
    )
    assert result is None


def test_sql_three_pattern_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET company.hq = d3, AS D3 SET person.name = 'Big Apple'"
    ))

    results = list(engine.sql(
        "SELECT d3.person.name WHERE d1.company.partner = d2.eid AND d2.company.hq = d3.eid"
    ))
    assert results == [("Big Apple",)]
    engine.close()


def test_sql_text_value_lookup():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME Corp'"))
    eid = rows[0][0]
    results = list(engine.sql(
        "SELECT 1 WHERE d1.eid = %1 AND d1.company.name = %2",
        eid, "ACME Corp",
    ))
    assert results == [(1,)]
    engine.close()


def test_explain_sql_variable_order():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_i = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'Bob'"
    ))
    eid_a = rows_i[0][0]

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.company.partner = d2.eid AND d1.eid = %1",
        eid_a,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "LEAP_INIT" in text
    assert text.count("DEPTH_OPEN") + text.count("DEPTH_ENTER") >= 2
    engine.close()


def test_explain_sql_index_selection():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_i = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'Bob'"
    ))
    eid_a = rows_i[0][0]

    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.company.partner = d2.eid AND d1.eid = %1",
        eid_a,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    assert text.count("CURSOR_DECLARE") + text.count("SCANNER_OPEN") >= 2
    engine.close()


def test_explain_sql_range_bounds():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.score LONG MANY"))
    list(engine.sql("UPSERT SET item.score = 10, item.score = 50"))

    rows = list(engine.sql(
        "EXPLAIN SELECT d1.item.score WHERE d1.item.score > %1",
        20,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "RANGE_OP" in text
    engine.close()


def test_explain_sql_no_patterns():
    engine = EAVTEngine(":memory:")
    rows = list(engine.sql("EXPLAIN SELECT 1 WHERE d1.eid = %1", 999999))
    text = "\n".join(row[0] for row in rows)
    assert "HALT" in text
    engine.close()


def _score_engine():
    e = EAVTEngine(":memory:")
    list(e.sql("ATTRIBUTE item.score LONG MANY"))
    list(e.sql("ATTRIBUTE person.name STRING ONE"))
    for i in range(1, 11):
        list(e.sql("UPSERT SET item.score = %1, person.name = %2", i * 10, f"name-{i}"))
    return e


def test_sql_range_gt():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score > %1",
        50,
    ))
    assert all(r[0] > 50 for r in results)
    assert len(results) == 5  # 60, 70, 80, 90, 100
    engine.close()


def test_sql_range_lt():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score < %1",
        50,
    ))
    assert all(r[0] < 50 for r in results)
    assert len(results) == 4  # 10, 20, 30, 40
    engine.close()


def test_sql_range_gte_lte():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2",
        30, 70,
    ))
    assert all(30 <= r[0] <= 70 for r in results)
    assert len(results) == 5  # 30, 40, 50, 60, 70
    engine.close()


def test_sql_range_with_join():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.item.score > %1 AND d1.eid = d2.eid",
        70,
    ))
    names = {r[0] for r in results}
    assert "name-9" in names
    assert "name-10" in names
    assert "name-5" not in names
    engine.close()


def test_sql_neq():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score != %1",
        50,
    ))
    scores = {r[0] for r in results}
    assert 50 not in scores
    assert 10 in scores
    assert 100 in scores
    assert len(results) == 9
    engine.close()


def test_sql_neq_diamond():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score != %1 AND d1.item.score != %2",
        30, 70,
    ))
    scores = {r[0] for r in results}
    assert 30 not in scores
    assert 70 not in scores
    assert 50 in scores
    assert len(results) == 8
    engine.close()


def test_sql_neq_with_range():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2 AND d1.item.score != %3",
        30, 70, 50,
    ))
    scores = {r[0] for r in results}
    assert 50 not in scores
    assert 30 in scores
    assert 70 in scores
    assert len(results) == 4  # 30, 40, 60, 70
    engine.close()


def test_sql_neq_angle_bracket():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score <> %1",
        50,
    ))
    scores = {r[0] for r in results}
    assert 50 not in scores
    assert len(results) == 9
    engine.close()


def test_sql_in():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score IN (%1, %2, %3)",
        30, 50, 70,
    ))
    scores = {r[0] for r in results}
    assert scores == {30, 50, 70}
    assert len(results) == 3
    engine.close()


def test_sql_in_literals():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score IN (10, 20, 30)",
    ))
    scores = {r[0] for r in results}
    assert scores == {10, 20, 30}
    engine.close()


def test_sql_in_with_join():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d2.person.name WHERE d1.item.score IN (%1, %2) AND d1.eid = d2.eid",
        30, 70,
    ))
    names = {r[0] for r in results}
    assert names == {"name-3", "name-7"}
    engine.close()


def test_sql_explain_neq():
    engine = _score_engine()
    rows = list(engine.sql(
        "EXPLAIN SELECT d1.item.score WHERE d1.item.score != %1",
        50,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "RANGE_OP" in text
    engine.close()


def test_sql_explain_in():
    engine = _score_engine()
    rows = list(engine.sql(
        "EXPLAIN SELECT d1.item.score WHERE d1.item.score IN (%1, %2)",
        30, 50,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "RANGE_OP" in text
    engine.close()


def test_sql_or_simple():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE d1.item.score < %1 OR d1.item.score > %2",
        30, 70,
    ))
    scores = {r[0] for r in results}
    assert scores == {10, 20, 80, 90, 100}
    engine.close()


def test_sql_or_with_and_branch():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d1.item.score WHERE (d1.item.score > %1 AND d1.item.score < %2) OR d1.item.score = %3",
        70, 90, 10,
    ))
    scores = {r[0] for r in results}
    assert scores == {10, 80}
    engine.close()


def test_sql_or_with_join():
    engine = _score_engine()
    results = list(engine.sql(
        "SELECT d2.person.name WHERE (d1.item.score < %1 OR d1.item.score > %2) AND d1.eid = d2.eid",
        30, 70,
    ))
    names = {r[0] for r in results}
    assert "name-1" in names
    assert "name-2" in names
    assert "name-8" in names
    assert "name-5" not in names
    engine.close()


def test_sql_or_cross_field_error():
    engine = _score_engine()
    with pytest.raises(ValueError, match="same"):
        list(engine.sql(
            "SELECT d1.item.score WHERE d1.item.score > %1 OR d1.item.name = %2",
            50, "alice",
        ))
    engine.close()


def test_sql_or_join_blocked():
    engine = _score_engine()
    with pytest.raises(ValueError, match="join"):
        list(engine.sql(
            "SELECT d1.item.score WHERE d1.item.score = d2.eid OR d1.item.score > %1",
            50,
        ))
    engine.close()


def test_sql_explain_or():
    engine = _score_engine()
    rows = list(engine.sql(
        "EXPLAIN SELECT d1.item.score WHERE d1.item.score < %1 OR d1.item.score > %2",
        30, 70,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "RANGE_OP" in text
    engine.close()


def test_sql_entity_name_cross_session(tmp_path):
    db_path = str(tmp_path / "db")
    engine = EAVTEngine(db_path)
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3, AS D2 SET person.name = 'John Smith', AS D3 SET person.name = 'Jane Doe'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'John Smith'"))[0][0]
    engine.close()

    engine2 = EAVTEngine(db_path)
    list(engine2.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine2.sql("ATTRIBUTE person.name STRING ONE"))
    results = list(engine2.sql(
        "SELECT d1.eid WHERE d1.company.partner = %1",
        partner_b,
    ))
    assert len(results) == 1
    assert results[0][0] == company_a
    assert isinstance(results[0][0], int)
    engine2.close()


def test_sql_timezone_override():
    brt = timezone(timedelta(hours=-3))
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'partner-b'",
    ))
    company_a = rows[0][0]

    results = list(engine.sql(
        "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1",
        company_a,
        tz=brt,
    ))
    assert len(results) == 1
    assert results[0][1] == (3 << 44) | 1002
    engine.close()


def test_sql_bytes_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE blob.data BYTES ONE"))
    raw = b"\xde\xad\xbe\xef"
    rows = list(engine.sql("UPSERT SET blob.data = %1", raw))
    eid = rows[0][0]
    results = list(engine.sql(
        "SELECT d1.val WHERE d1.eid = %1 AND d1.attr = 'blob.data'",
        eid,
    ))
    assert len(results) == 1
    assert results[0][0] == raw
    engine.close()


def test_sql_lookup_plus_variable():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.partner = d2, company.partner = d3, AS D2 SET company.name = 'ACME', AS D3 SET person.name = 'dummy'"
    ))
    company_a = rows[0][0]
    partner_b = list(engine.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]

    results = list(engine.sql(
        "SELECT d2.company.name WHERE d1.eid = %1 AND d1.company.partner = %2 AND d1.company.partner = d2.eid",
        company_a, partner_b,
    ))
    assert results == [("ACME",)]
    engine.close()


def test_sql_error_missing_param():
    engine = EAVTEngine(":memory:")
    with pytest.raises(BaseException):
        list(engine.sql(
            "SELECT d1.company.name WHERE d1.eid = %1 AND d1.company.name = %2",
            1,
        ))
    engine.close()


def test_sql_error_select_not_in_where():
    engine = EAVTEngine(":memory:")
    with pytest.raises(ValueError, match="alias d2 in SELECT but not in WHERE"):
        list(engine.sql(
            "SELECT d2.person.name WHERE d1.eid = %1",
            1,
        ))
    engine.close()


def test_sql_error_attr_no_namespace():
    engine = EAVTEngine(":memory:")
    with pytest.raises(BaseException, match="attribute name must include namespace"):
        list(engine.sql("SELECT d1.name WHERE d1.eid = %1", 1))
    engine.close()


def test_sql_error_attr_no_namespace_in_where():
    engine = EAVTEngine(":memory:")
    with pytest.raises(BaseException, match="attribute name must include namespace"):
        list(engine.sql("SELECT 1 WHERE d1.eid = %1 AND d1.name = %2", 1, "hello"))
    engine.close()


# ── DML integration tests ──


def test_insert_basic():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    result = list(engine.sql("UPSERT SET company.name = %1", "ACME"))
    assert len(result) == 1
    eid = result[0][0]
    assert isinstance(eid, int)
    assert result[0][1] == 1

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert rows == [("ACME",)]
    engine.close()


def test_insert_ref_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))

    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    result = list(engine.sql("UPSERT SET company.partner = %1", partner_b))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert rows == [(partner_b,)]
    engine.close()


def test_insert_multiple_values():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))

    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    result = list(engine.sql(
        "UPSERT SET company.name = %1, company.partner = %2",
        "ACME", partner_b,
    ))
    eid = result[0][0]
    assert result[0][1] == 2

    rows = list(engine.sql(
        "SELECT d1.company.name, d1.company.partner WHERE d1.eid = %1",
        eid,
    ))
    assert len(rows) == 1
    assert rows[0][0] == "ACME"
    assert rows[0][1] == partner_b
    engine.close()


def test_insert_with_timestamp():
    engine = EAVTEngine(":memory:", tz=timezone.utc)
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))

    result = list(engine.sql(
        "UPSERT SET company.name = %1",
        "ACME",
    ))
    eid = result[0][0]

    rows = list(engine.sql(
        "SELECT d1.company.name, d1.tx WHERE d1.eid = %1",
        eid,
    ))
    assert len(rows) == 1
    assert rows[0][0] == "ACME"
    assert rows[0][1] == (3 << 44) | 1001
    engine.close()



def test_insert_integer_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.score LONG MANY"))

    result = list(engine.sql("UPSERT SET item.score = %1", 100))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.item.score WHERE d1.eid = %1", eid))
    assert rows == [(100,)]
    engine.close()


def test_insert_then_select_roundtrip():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))

    r_ldn = list(engine.sql("UPSERT SET city.name = 'London'"))
    london_eid = r_ldn[0][0]
    result = list(engine.sql(
        "UPSERT AS D1 SET company.name = %1, company.hq = %2, company.partner = d2, AS D2 SET person.name = %3",
        "Corp", london_eid, "Alice",
    ))
    eid_company = result[0][0]

    names = list(engine.sql(
        "SELECT d2.person.name WHERE d1.company.partner = d2.eid AND d1.eid = %1",
        eid_company,
    ))
    assert names == [("Alice",)]

    hq = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", eid_company))
    assert hq == [(london_eid,)]
    engine.close()


def test_insert_many_cardinality_accumulates():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))

    r_pb = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_b = r_pb[0][0]
    r_pc = list(engine.sql("UPSERT SET dummy.x = 1"))
    partner_c = r_pc[0][0]
    result = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2",
        partner_b, partner_c,
    ))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert set(rows) == {(partner_b,), (partner_c,)}
    engine.close()


def test_insert_one_cardinality_overwrites():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))

    result = list(engine.sql(
        "UPSERT SET company.name = %1, company.name = %2",
        "First", "Second",
    ))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert rows == [("Second",)]
    engine.close()


def test_insert_result_count_matches_values():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.a LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.b LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.c LONG ONE"))

    result = list(engine.sql("UPSERT SET ns.a = %1, ns.b = %2, ns.c = %3", 1, 2, 3))
    assert result[0][1] == 3
    engine.close()


# ── ATTRIBUTE integration tests ──


def test_attribute_many_then_insert():
    engine = EAVTEngine(":memory:")

    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    r_p1 = list(engine.sql("UPSERT SET dummy.x = 1"))
    p1 = r_p1[0][0]
    r_p2 = list(engine.sql("UPSERT SET dummy.x = 1"))
    p2 = r_p2[0][0]
    result = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2",
        p1, p2,
    ))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert set(rows) == {(p1,), (p2,)}
    engine.close()


def test_attribute_one_overwrites():
    engine = EAVTEngine(":memory:")

    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    result = list(engine.sql(
        "UPSERT SET company.name = %1, company.name = %2",
        "First", "Second",
    ))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert rows == [("Second",)]
    engine.close()


def test_attribute_result():
    engine = EAVTEngine(":memory:")

    result = list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    assert result == [("company.partner", "REF")]

    result = list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    assert result == [("company.name", "STRING")]
    engine.close()


def test_attribute_replaces_cardinality():
    engine = EAVTEngine(":memory:")

    list(engine.sql("ATTRIBUTE company.partner REF MANY"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    r_p1 = list(engine.sql("UPSERT SET dummy.x = 1"))
    p1 = r_p1[0][0]
    r_p2 = list(engine.sql("UPSERT SET dummy.x = 1"))
    p2 = r_p2[0][0]
    result = list(engine.sql(
        "UPSERT SET company.partner = %1, company.partner = %2",
        p1, p2,
    ))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert len(rows) == 2

    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    r_p3 = list(engine.sql("UPSERT SET dummy.x = 1"))
    p3 = r_p3[0][0]
    result2 = list(engine.sql(
        "UPSERT SET company.partner = %1", p3,
    ))
    eid2 = result2[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid2))
    assert rows == [(p3,)]
    engine.close()


# ── Auto-generated entity (ALLOC_ENT) ──


def test_insert_auto_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    assert len(rows) == 1
    eid = rows[0][0]
    assert isinstance(eid, int)
    assert eid >= 1000

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert rows == [("ACME",)]
    assert rows[0][0] == "ACME"
    engine.close()


def test_insert_auto_entity_count():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.active LONG ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET company.name = 'ACME', company.active = 1"))
    assert len(rows) == 1
    assert rows[0][1] == 2
    engine.close()


def test_insert_auto_entity_sequential():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    r1 = list(engine.sql("UPSERT SET company.name = 'First'"))
    r2 = list(engine.sql("UPSERT SET company.name = 'Second'"))
    assert r1[0][0] >= 1000
    assert r2[0][0] == r1[0][0] + 1
    engine.close()


# ── Multi-entity with tempids ──


def test_insert_multi_entity_explicit_tempids():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.employer REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        "       AS D2 SET person.name = 'John', person.employer = d1"
    ))
    assert len(rows) == 1
    eid_company = rows[0][0]
    assert isinstance(eid_company, int)

    names = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid_company))
    assert names == [("ACME",)]

    people = list(engine.sql("SELECT d1.person.name WHERE d1.person.employer = %1", eid_company))
    assert people == [("John",)]
    engine.close()


def test_insert_multi_entity_auto_tempids():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.employer REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        "       AS D2 SET person.name = 'John', person.employer = d1"
    ))
    assert len(rows) == 1
    eid_company = rows[0][0]

    people = list(engine.sql("SELECT d1.person.name WHERE d1.person.employer = %1", eid_company))
    assert people == [("John",)]
    engine.close()


def test_insert_tempid_ref_chain():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE city.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.resident REF ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.employer REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        "       AS D2 SET person.name = 'John', person.employer = d1,"
        "       AS D3 SET city.name = 'NY', city.resident = d2"
    ))
    eid_company = rows[0][0]

    people = list(engine.sql(
        "SELECT d1.person.name WHERE d1.person.employer = %1", eid_company
    ))
    assert people == [("John",)]

    person_eid = list(engine.sql("SELECT d1.eid WHERE d1.person.employer = %1", eid_company))
    cities = list(engine.sql(
        "SELECT d1.city.name WHERE d1.city.resident = %1", person_eid[0][0]
    ))
    assert cities == [("NY",)]
    engine.close()


def test_insert_mixed_explicit_and_auto_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))

    rows = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    assert isinstance(rows[0][0], int)
    assert rows[0][0] >= 1000

    rows = list(engine.sql("UPSERT SET company.name = 'Auto'"))
    assert isinstance(rows[0][0], int)
    assert rows[0][0] >= 1000
    engine.close()


def test_insert_tempid_with_timestamp():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql(
        "UPSERT SET company.name = 'ACME'"
    ))
    eid = rows[0][0]
    ts = list(engine.sql("SELECT d1.tx WHERE d1.eid = %1", eid))
    assert ts[0][0] == (3 << 44) | 1001
    engine.close()


# ── EXPLAIN with new features ──


def test_explain_insert_auto_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.attr STRING ONE"))
    rows = list(engine.sql("EXPLAIN UPSERT SET ns.attr = %1", "hello"))
    text = "\n".join(row[0] for row in rows)
    assert "ALLOC_ENT" in text
    engine.close()


def test_explain_insert_multi_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.a STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.b REF ONE"))
    rows = list(engine.sql(
        "EXPLAIN UPSERT AS D1 SET ns.a = %1, AS D2 SET ns.b = d1", "x"
    ))
    text = "\n".join(row[0] for row in rows)
    assert text.count("ALLOC_ENT") == 2
    assert "EXEC_INSERT" in text
    engine.close()


def test_insert_string_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    result = list(engine.sql("UPSERT SET company.name = 'Fabio'"))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", eid))
    assert rows == [("Fabio",)]
    engine.close()


def test_insert_integer_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.age LONG ONE"))
    result = list(engine.sql("UPSERT SET company.age = 42"))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.age WHERE d1.eid = %1", eid))
    assert rows == [(42,)]
    engine.close()


def test_insert_ref_tempid_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    result = list(engine.sql("UPSERT AS D1 SET company.partner = d2, AS D2 SET dummy.x = 1"))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert len(rows) == 1
    assert isinstance(rows[0][0], int)
    engine.close()


def test_insert_ref_integer_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    result = list(engine.sql("UPSERT SET company.partner = 42"))
    eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", eid))
    assert rows == [(42,)]
    engine.close()


# ── EXPLAIN integration tests ──


def test_explain_select():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows_i = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    eid = rows_i[0][0]
    rows = list(engine.sql("EXPLAIN SELECT d1.company.name WHERE d1.eid = %1", eid))
    text = "\n".join(row[0] for row in rows)
    assert "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    assert "LEAP_INIT" in text
    assert "HALT" in text
    engine.close()


def test_explain_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    rows_i = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME', company.partner = d2, "
        "AS D2 SET person.name = 'John'"
    ))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]
    rows = list(engine.sql(
        "EXPLAIN SELECT d2.person.name WHERE d1.company.partner = d2.eid AND d1.eid = %1",
        eid,
    ))
    text = "\n".join(row[0] for row in rows)
    assert "CURSOR_DECLARE" in text or "SCANNER_OPEN" in text
    assert text.count("CURSOR_DECLARE") + text.count("SCANNER_OPEN") >= 2
    assert "HALT" in text
    engine.close()


def test_explain_insert():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.attr STRING ONE"))
    rows = list(engine.sql("EXPLAIN UPSERT SET ns.attr = %1", "hello"))
    text = "\n".join(row[0] for row in rows)
    assert "EXEC_INSERT" in text
    engine.close()


def test_explain_attribute():
    engine = EAVTEngine(":memory:")
    rows = list(engine.sql("EXPLAIN ATTRIBUTE ns.attr STRING MANY"))
    text = "\n".join(row[0] for row in rows)
    assert "ATTRIBUTE" in text
    engine.close()


# ── Float/string/ref-literal in WHERE ──


def test_float_literal_in_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empr.cnt FLOAT ONE"))
    rows_i = list(engine.sql("UPSERT SET empr.cnt = 14.2"))
    eid = rows_i[0][0]
    rows = list(engine.sql("SELECT d1.eid, d1.attr, d1.val WHERE d1.empr.cnt = 14.2"))
    assert rows == [(eid, "empr.cnt", 14.2)]
    engine.close()


def test_string_literal_in_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows_i = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    eid = rows_i[0][0]
    rows = list(engine.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))
    assert rows == [(eid,)]
    engine.close()


def test_ref_literal_in_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    list(engine.sql("ATTRIBUTE empr.lba REF ONE"))
    rows_ent = list(engine.sql("UPSERT SET dummy.x = 1"))
    ent_eid = rows_ent[0][0]
    rows_i = list(engine.sql("UPSERT SET empr.lba = %1", ent_eid))
    eid = rows_i[0][0]
    rows = list(engine.sql("SELECT d1.eid WHERE d1.empr.lba = %1", ent_eid))
    assert rows == [(eid,)]
    engine.close()


def test_ref_integer_literal_in_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.partner REF ONE"))
    rows_i = list(engine.sql("UPSERT SET company.partner = 42"))
    eid = rows_i[0][0]
    rows = list(engine.sql("SELECT d1.eid WHERE d1.company.partner = 42"))
    assert rows == [(eid,)]
    engine.close()


def test_select_star_full_scan():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.name = 'Alice', ns.age = 30"))
    eid_e1 = rows1[0][0]
    rows2 = list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    eid_e2 = rows2[0][0]
    rows = list(engine.sql("SELECT *"))
    rows = [r for r in rows if not isinstance(r[1], str) or not r[1].startswith("db.")]
    assert len(rows) == 3
    assert set(rows) == {
        (eid_e1, "ns.name", "Alice"),
        (eid_e1, "ns.age", 30),
        (eid_e2, "ns.name", "Bob"),
    }
    engine.close()


def test_select_star_empty():
    engine = EAVTEngine(":memory:")
    rows = list(engine.sql("SELECT *"))
    # SELECT * now expands to d1.eid, d1.attr, d1.val — may return
    # built-in schema/partition datoms on a fresh engine.
    for row in rows:
        assert len(row) == 3
    engine.close()


def test_select_without_where_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'Alice', ns.age = 30"))
    list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    rows = list(engine.sql("SELECT d1.ns.name"))
    assert set(rows) == {("Alice",), ("Bob",)}
    engine.close()


def test_select_without_where_eid():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid_e1 = rows1[0][0]
    rows2 = list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    eid_e2 = rows2[0][0]
    rows = list(engine.sql("SELECT d1.eid"))
    eids = {r[0] for r in rows}
    assert eid_e1 in eids
    assert eid_e2 in eids
    engine.close()


def test_select_without_where_eid_and_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid_e1 = rows1[0][0]
    rows2 = list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    eid_e2 = rows2[0][0]
    rows = list(engine.sql("SELECT d1.eid, d1.ns.name"))
    assert set(rows) == {(eid_e1, "Alice"), (eid_e2, "Bob")}
    engine.close()


def test_select_star_with_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'Alice', ns.age = 30"))
    list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    rows = list(engine.sql("SELECT * WHERE d1.ns.name = %1", "Alice"))
    assert len(rows) >= 1
    engine.close()


def test_explain_select_star():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    result = list(engine.sql("EXPLAIN SELECT *"))
    text = "\n".join(row[0] for row in result)
    # SELECT * expands to d1.eid, d1.attr, d1.val — produces a real plan
    assert "SCANNER_OPEN" in text
    engine.close()


def test_explain_select_no_where():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    result = list(engine.sql("EXPLAIN SELECT d1.ns.name"))
    assert len(result) >= 1
    engine.close()


# ── d1.attr / d1.val literal filtering ──


def test_select_star_attr_equals_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    list(engine.sql("ATTRIBUTE empr.cnt FLOAT ONE"))
    list(engine.sql("ATTRIBUTE empr.lba REF ONE"))
    list(engine.sql("ATTRIBUTE empr.nome STRING ONE"))
    list(engine.sql("UPSERT SET empr.cnt = 14.2"))
    list(engine.sql("UPSERT SET empr.nome = 'Fabio Ferr'"))
    list(engine.sql("UPSERT SET empr.nome = 'Outro'"))
    r_ent = list(engine.sql("UPSERT SET dummy.x = 1"))
    ent_eid = r_ent[0][0]
    list(engine.sql("UPSERT SET empr.lba = %1", ent_eid))
    rows = list(engine.sql("SELECT * WHERE d1.attr = 'empr.nome'"))
    assert len(rows) == 2
    attrs = {r[1] for r in rows}
    assert attrs == {"empr.nome"}
    vals = {r[2] for r in rows}
    assert vals == {"Fabio Ferr", "Outro"}
    engine.close()


def test_select_star_val_equals_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    list(engine.sql("ATTRIBUTE empr.cnt FLOAT ONE"))
    list(engine.sql("ATTRIBUTE empr.lba REF ONE"))
    list(engine.sql("ATTRIBUTE empr.nome STRING ONE"))
    list(engine.sql("UPSERT SET empr.cnt = 14.2"))
    list(engine.sql("UPSERT SET empr.nome = 'Fabio Ferr'"))
    rows3 = list(engine.sql("UPSERT SET empr.nome = 'Outro'"))
    eid_empresa3 = rows3[0][0]
    r_ent = list(engine.sql("UPSERT SET dummy.x = 1"))
    ent_eid = r_ent[0][0]
    list(engine.sql("UPSERT SET empr.lba = %1", ent_eid))
    rows = list(engine.sql("SELECT * WHERE d1.val = 'Outro' AND d1.attr = 'empr.nome'"))
    assert len(rows) == 1
    assert rows[0] == (eid_empresa3, "empr.nome", "Outro")
    engine.close()


def test_select_star_attr_and_val_equals_literal():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE dummy.x LONG ONE"))
    list(engine.sql("ATTRIBUTE empr.cnt FLOAT ONE"))
    list(engine.sql("ATTRIBUTE empr.lba REF ONE"))
    list(engine.sql("ATTRIBUTE empr.nome STRING ONE"))
    list(engine.sql("UPSERT SET empr.cnt = 14.2"))
    list(engine.sql("UPSERT SET empr.nome = 'Fabio Ferr'"))
    rows3 = list(engine.sql("UPSERT SET empr.nome = 'Outro'"))
    eid_empresa3 = rows3[0][0]
    r_ent = list(engine.sql("UPSERT SET dummy.x = 1"))
    ent_eid = r_ent[0][0]
    list(engine.sql("UPSERT SET empr.lba = %1", ent_eid))
    rows = list(engine.sql("SELECT * WHERE d1.val = 'Outro' AND d1.attr = 'empr.nome'"))
    assert len(rows) == 1
    assert rows[0] == (eid_empresa3, "empr.nome", "Outro")
    engine.close()


def test_select_eid_attr_val_where_attr_equals():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empr.cnt FLOAT ONE"))
    list(engine.sql("ATTRIBUTE empr.nome STRING ONE"))
    list(engine.sql("UPSERT SET empr.cnt = 14.2"))
    rows2 = list(engine.sql("UPSERT SET empr.nome = 'Fabio Ferr'"))
    eid2 = rows2[0][0]
    rows3 = list(engine.sql("UPSERT SET empr.nome = 'Outro'"))
    eid3 = rows3[0][0]
    rows = list(engine.sql("SELECT d1.eid, d1.attr, d1.val WHERE d1.attr = 'empr.nome'"))
    assert len(rows) == 2
    assert all(r[1] == "empr.nome" for r in rows)
    eids = {r[0] for r in rows}
    assert eids == {eid2, eid3}
    engine.close()


def test_select_eid_where_val_and_attr_equals():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid_e1 = rows1[0][0]
    list(engine.sql("UPSERT SET ns.name = 'Bob'"))
    list(engine.sql("UPSERT SET ns.age = 30"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.val = 'Alice' AND d1.attr = 'ns.name'"))
    assert rows == [(eid_e1,)]
    engine.close()


def test_select_star_attr_equals_integer():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.score LONG ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.score = 10"))
    eid_e1 = rows1[0][0]
    list(engine.sql("UPSERT SET ns.name = 'test'"))
    rows = list(engine.sql("SELECT * WHERE d1.val = 10 AND d1.attr = 'ns.score'"))
    assert len(rows) == 1
    assert rows[0] == (eid_e1, "ns.score", 10)
    engine.close()


def test_open_scan_mixed_with_triejoin():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.color STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.shape STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.status STRING ONE"))
    rows1 = list(engine.sql("UPSERT SET ns.color = 'red', ns.shape = 'blue'"))
    eid_e1 = rows1[0][0]
    rows2 = list(engine.sql("UPSERT SET ns.color = 'red', ns.status = 'blue'"))
    eid_e2 = rows2[0][0]
    rows = list(engine.sql(
        "SELECT d1.eid, d2.attr WHERE d1.ns.color = 'red' "
        "AND d1.eid = d2.eid AND d2.val = 'blue'"
    ))
    assert len(rows) == 2
    pairs = {(r[0], r[1]) for r in rows}
    assert (eid_e1, "ns.shape") in pairs
    assert (eid_e2, "ns.status") in pairs
    engine.close()


def test_sql_mixed_type_attribute():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.value LONG MANY"))
    list(engine.sql("ATTRIBUTE item.sval STRING MANY"))
    rows1 = list(engine.sql("UPSERT SET item.value = 42"))
    eid_e1 = rows1[0][0]
    list(engine.sql("UPSERT SET item.sval = 'hello'"))
    list(engine.sql("UPSERT SET item.value = 99"))

    int_results = list(engine.sql(
        "SELECT d1.item.value WHERE d1.item.value >= %1 AND d1.item.value <= %2",
        10, 50,
    ))
    int_vals = {r[0] for r in int_results}
    assert int_vals == {42}

    all_results = list(engine.sql("SELECT d1.item.value WHERE d1.eid = %1", eid_e1))
    assert all_results[0][0] == 42
    engine.close()


def test_sql_neq_mixed_types():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.val LONG MANY"))
    list(engine.sql("ATTRIBUTE item.sval STRING MANY"))
    list(engine.sql("UPSERT SET item.val = 10"))
    list(engine.sql("UPSERT SET item.sval = 'ten'"))
    list(engine.sql("UPSERT SET item.val = 20"))
    list(engine.sql("UPSERT SET item.sval = 'twenty'"))

    results = list(engine.sql(
        "SELECT d1.item.val WHERE d1.item.val != %1",
        10,
    ))
    vals = {r[0] for r in results}
    assert 10 not in vals
    assert 20 in vals
    engine.close()


def test_open_scan_value_only_filter():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.color STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.color = 'red'"))
    eid = rows[0][0]
    result = list(engine.sql("SELECT d1.eid, d1.attr WHERE d1.val = 'red'"))
    assert len(result) == 1
    assert result[0][0] == eid
    assert result[0][1] == "ns.color"
    engine.close()


def test_delete_where_basic():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.color STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.color = 'red'"))
    eid = rows[0][0]
    assert list(engine.sql(f"SELECT d1.ns.color WHERE d1.eid = {eid}")) == [("red",)]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.ns.color = 'red'"))
    assert list(engine.sql(f"SELECT d1.ns.color WHERE d1.eid = {eid}")) == []
    engine.close()


def test_delete_where_multiple_attrs():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'alice', ns.age = 30"))
    eid = rows[0][0]
    assert len(list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}"))) == 1
    assert len(list(engine.sql(f"SELECT d1.ns.age WHERE d1.eid = {eid}"))) == 1
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.ns.name = 'alice'"))
    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == []
    assert len(list(engine.sql(f"SELECT d1.ns.age WHERE d1.eid = {eid}"))) == 1
    engine.close()


def test_delete_where_with_param():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.color STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.color = 'blue'"))
    eid = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = %1 AND d1.ns.color = %2", eid, "blue"))
    assert list(engine.sql(f"SELECT d1.ns.color WHERE d1.eid = {eid}")) == []
    engine.close()


def test_delete_where_with_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.target REF ONE"))
    rows_a = list(engine.sql("UPSERT SET ns.name = 'target'"))
    eid_target = rows_a[0][0]
    rows_b = list(engine.sql("UPSERT SET ns.name = 'owner', ns.target = %1", eid_target))
    eid_owner = rows_b[0][0]
    assert len(list(engine.sql(f"SELECT d1.ns.target WHERE d1.eid = {eid_owner}"))) == 1
    list(engine.sql(f"DELETE WHERE d1.eid = {eid_owner} AND d1.ns.target = {eid_target}"))
    assert list(engine.sql(f"SELECT d1.ns.target WHERE d1.eid = {eid_owner}")) == []
    engine.close()


def test_explain_delete():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.attr STRING ONE"))
    rows = list(engine.sql("EXPLAIN DELETE WHERE d1.eid = 42 AND d1.ns.attr = 'x'"))
    text = "\n".join(row[0] for row in rows)
    assert "EXEC_RETRACT" in text
    engine.close()


# ── Type validation tests ──


def test_type_validation_string_accepts_string():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'hello'"))
    engine.close()


def test_type_validation_string_rejects_long():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    with pytest.raises(ValueError, match="type mismatch"):
        list(engine.sql("UPSERT SET ns.name = 42"))
    engine.close()


def test_type_validation_long_accepts_int():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    list(engine.sql("UPSERT SET ns.age = 42"))
    engine.close()


def test_type_validation_long_rejects_string():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.age LONG ONE"))
    with pytest.raises(ValueError, match="type mismatch"):
        list(engine.sql("UPSERT SET ns.age = 'hello'"))
    engine.close()


def test_type_validation_ref_accepts_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.partner REF ONE"))
    r = list(engine.sql("UPSERT SET ns.partner = 1"))
    assert len(r) == 1
    engine.close()


def test_type_validation_ref_rejects_string():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.partner REF ONE"))
    with pytest.raises(ValueError, match="type mismatch"):
        list(engine.sql("UPSERT SET ns.partner = 'hello'"))
    engine.close()


def test_type_validation_boolean():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.active BOOLEAN ONE"))
    r = list(engine.sql("UPSERT SET ns.active = %1", True))
    assert len(r) == 1
    engine.close()


def test_type_validation_float():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.score FLOAT ONE"))
    r = list(engine.sql("UPSERT SET ns.score = 3.14"))
    assert len(r) == 1
    engine.close()


# ── ATTRIBUTE idempotency tests ──


def test_attribute_idempotent_same_type_same_card():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT SET ns.name = 'ok'"))
    engine.close()


def test_attribute_idempotent_same_type_many():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.tags STRING MANY"))
    list(engine.sql("ATTRIBUTE ns.tags STRING MANY"))
    r = list(engine.sql("UPSERT SET ns.tags = 'a', ns.tags = 'b'"))
    eid = r[0][0]
    rows = list(engine.sql("SELECT d1.ns.tags WHERE d1.eid = %1", eid))
    assert set(rows) == {("a",), ("b",)}
    engine.close()


def test_attribute_change_cardinality_one_to_many():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    r = list(engine.sql("UPSERT SET ns.name = 'first'"))
    eid = r[0][0]
    rows = list(engine.sql("SELECT d1.ns.name WHERE d1.eid = %1", eid))
    assert rows == [("first",)]
    list(engine.sql("ATTRIBUTE ns.name STRING MANY"))
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'second'", eid))
    rows = list(engine.sql("SELECT d1.ns.name WHERE d1.eid = %1", eid))
    assert set(rows) == {("first",), ("second",)}
    engine.close()


def test_attribute_change_cardinality_many_to_one():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING MANY"))
    r = list(engine.sql("UPSERT SET ns.name = 'a', ns.name = 'b'"))
    eid = r[0][0]
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'c'", eid))
    rows = list(engine.sql("SELECT d1.ns.name WHERE d1.eid = %1", eid))
    assert rows == [("c",)]
    engine.close()


def test_attribute_change_type_fails():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    with pytest.raises(Exception, match="cannot change to"):
        list(engine.sql("ATTRIBUTE ns.name LONG ONE"))
    engine.close()


# ── Cardinality enforcement tests ──


def test_cardinality_one_replaces_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    r = list(engine.sql("UPSERT SET ns.name = 'old'"))
    eid = r[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'new'", eid))
    rows = list(engine.sql("SELECT d1.ns.name WHERE d1.eid = %1", eid))
    assert rows == [("new",)]
    engine.close()


def test_cardinality_many_accumulates():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.tag STRING MANY"))
    r = list(engine.sql("UPSERT SET ns.tag = 'a'"))
    eid = r[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.tag = 'b'", eid))
    rows = list(engine.sql("SELECT d1.ns.tag WHERE d1.eid = %1", eid))
    assert set(rows) == {("a",), ("b",)}
    engine.close()


def test_cardinality_one_idempotent_same_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    r = list(engine.sql("UPSERT SET ns.name = 'same'"))
    eid = r[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'same'", eid))
    rows = list(engine.sql("SELECT d1.ns.name WHERE d1.eid = %1", eid))
    assert rows == [("same",)]
    engine.close()


# ── Schema query tests ──


def test_schema_query_db_ident():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.db.ident = 'company.name'"))
    assert len(rows) == 1
    assert rows[0][0] >= 100
    engine.close()


def test_schema_query_db_value_type():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.db.valueType = 0"))
    eids = {r[0] for r in rows}
    r = list(engine.sql("SELECT d1.eid WHERE d1.db.ident = 'company.name'"))
    assert r[0][0] in eids
    engine.close()


def test_schema_query_db_cardinality():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.tags STRING MANY"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.db.cardinality = 36"))
    eids = {r[0] for r in rows}
    r = list(engine.sql("SELECT d1.eid WHERE d1.db.ident = 'company.tags'"))
    assert r[0][0] in eids
    engine.close()


# ── Uniqueness tests ──


def test_unique_allows_first_insert():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    engine.close()


def test_unique_rejects_duplicate():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    with pytest.raises(ValueError, match="unique constraint violation"):
        list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    engine.close()


def test_unique_allows_different_values():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    list(engine.sql("UPSERT SET company.email = 'b@co.com'"))
    engine.close()


def test_unique_allows_update_same_entity():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    r = list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    eid = r[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET company.email = 'b@co.com'", eid))
    rows = list(engine.sql("SELECT d1.company.email WHERE d1.eid = %1", eid))
    assert rows == [("b@co.com",)]
    engine.close()


def test_unique_with_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.code REF ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE ns.x LONG ONE"))
    r1 = list(engine.sql("UPSERT SET ns.x = 1"))
    e1 = r1[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.code = %2", e1, 42))
    with pytest.raises(ValueError, match="unique constraint violation"):
        r2 = list(engine.sql("UPSERT SET ns.x = 2"))
        list(engine.sql("UPSERT AS D1 = %1 SET ns.code = %2", r2[0][0], 42))
    engine.close()


def test_unique_without_keyword_not_enforced():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    engine.close()


def test_unique_persists_across_reopen(tmp_path):
    from eavt_sql.engine import EAVTEngine as Eng
    db = str(tmp_path / "test.db")
    e1 = Eng(db)
    list(e1.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    list(e1.sql("UPSERT SET company.email = 'a@co.com'"))
    e1.close()
    e2 = Eng(db)
    with pytest.raises(ValueError, match="unique constraint violation"):
        list(e2.sql("UPSERT SET company.email = 'a@co.com'"))
    e2.close()


def test_unique_violation_caught_at_commit():
    """UNIQUE constraint should be caught at commit even when deferred."""
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    # Second insert with same value should fail
    with pytest.raises(ValueError, match="unique constraint violation"):
        list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    # Engine should still be usable after the failed transaction
    list(engine.sql("UPSERT SET company.email = 'b@co.com'"))
    engine.close()


def test_tx_rollback_after_constraint_error():
    """Engine remains functional after a constraint violation + rollback."""
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE"))
    eid = list(engine.sql("UPSERT SET company.email = 'a@co.com'"))[0][0]
    with pytest.raises(ValueError):
        list(engine.sql("UPSERT SET company.email = 'a@co.com'"))
    # Engine should still work — rollback cleaned up
    rows = list(engine.sql("SELECT d1.company.email WHERE d1.eid = %1", eid))
    assert rows == [("a@co.com",)]
    engine.close()


def test_insert_entity_lookup_in_entity_position():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = 'New York'"))[0][0]

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'New York') SET company.name = 'ACME Corp'"
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", company_eid))
    assert rows == []

    list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'New York') SET company.hq = %1",
        ny_eid,
    ))
    rows = list(engine.sql("SELECT d1.company.name WHERE d1.company.hq = %1", ny_eid))
    assert rows == [("ACME Corp",)]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert rows == [("ACME Corp",)]
    engine.close()


def test_insert_entity_lookup_in_value_position():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    ny_result = list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = ny_result[0][0]

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'New York') SET company.name = 'ACME', company.hq = %1",
        ny_eid,
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", company_eid))
    assert rows == [(ny_eid,)]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.company.hq = %1", ny_eid))
    assert rows == [("ACME",)]
    engine.close()


def test_insert_entity_lookup_not_found():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'London') SET company.name = 'ACME'"
    ))
    assert result == []
    engine.close()


def test_insert_entity_lookup_with_param_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET city.name = 'Paris'"))
    paris_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = 'Paris'"))[0][0]

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', %1) SET company.name = 'ACME'",
        "Paris",
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert rows == [("ACME",)]
    engine.close()


def test_insert_entity_lookup_fallback_finds_existing():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET city.name = 'London'"))
    london_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = 'London'"))[0][0]

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'London') SET company.name = 'ACME'"
    ))
    company_eid = result[0][0]
    assert company_eid == london_eid

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert rows == [("ACME",)]
    engine.close()


def test_insert_entity_lookup_fallback_value_position():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))

    list(engine.sql("UPSERT SET city.name = 'Tokyo'"))
    tokyo_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = 'Tokyo'"))[0][0]

    result = list(engine.sql(
        "UPSERT SET company.name = 'ACME', company.hq = %1",
        tokyo_eid,
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.hq WHERE d1.eid = %1", company_eid))
    assert rows == [(tokyo_eid,)]
    engine.close()


def test_upsert_insert_new():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    rows = list(engine.sql(
        "UPSERT SET person.name = 'Alice', person.age = 30"
    ))
    assert len(rows) == 1
    alice_eid = rows[0][0]
    assert isinstance(alice_eid, int)

    rows = list(engine.sql("SELECT d1.person.name, d1.person.age WHERE d1.eid = %1", alice_eid))
    assert rows == [("Alice", 30)]
    engine.close()


def test_upsert_find_existing():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    rows = list(engine.sql(
        "UPSERT AS D1 SET person.name = 'Alice', person.age = 25"
    ))
    alice_eid = rows[0][0]

    rows = list(engine.sql(
        "UPSERT AS D1 = eid('person.name', 'Alice') SET person.age = 30"
    ))
    assert rows[0][0] == alice_eid

    rows = list(engine.sql("SELECT d1.person.age WHERE d1.eid = %1", alice_eid))
    assert rows == [(30,)]
    engine.close()


def test_upsert_with_alias():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))

    rows = list(engine.sql("UPSERT AS D1 SET company.name = 'ACME'"))
    acme_eid = rows[0][0]

    rows = list(engine.sql("UPSERT AS D1 SET person.name = 'Bob'"))
    bob_eid = rows[0][0]

    list(engine.sql("UPSERT AS D1 = eid('company.name', 'ACME') SET company.ceo = %1", bob_eid))

    rows = list(engine.sql("SELECT d1.company.ceo WHERE d1.eid = %1", acme_eid))
    assert rows == [(bob_eid,)]
    engine.close()


def test_update_simple():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    rows = list(engine.sql("UPSERT SET person.name = 'Alice', person.age = 25"))
    alice_eid = rows[0][0]

    list(engine.sql("UPDATE SET person.age = 99 WHERE d1.person.name = 'Alice'"))

    rows = list(engine.sql("SELECT d1.person.age WHERE d1.eid = %1", alice_eid))
    assert rows == [(99,)]
    engine.close()


def test_update_with_join():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))

    rows = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    acme_eid = rows[0][0]
    rows = list(engine.sql("UPSERT SET company.name = 'Globex'"))
    globex_eid = rows[0][0]
    rows = list(engine.sql("UPSERT SET person.name = 'Alice'"))
    alice_eid = rows[0][0]
    rows = list(engine.sql("UPSERT SET person.name = 'Bob'"))
    bob_eid = rows[0][0]

    list(engine.sql("UPSERT AS D1 = eid('company.name', 'ACME') SET company.ceo = %1", alice_eid))
    list(engine.sql("UPSERT AS D1 = eid('company.name', 'Globex') SET company.ceo = %1", bob_eid))

    list(engine.sql("UPDATE SET company.name = 'ACME Updated' WHERE d1.company.ceo = d2 AND d2.person.name = 'Alice'"))

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", acme_eid))
    assert rows == [("ACME Updated",)]
    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", globex_eid))
    assert rows == [("Globex",)]
    engine.close()


def test_select_bare_alias_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))

    rows = list(engine.sql("UPSERT SET city.name = 'NYC'"))
    nyc_eid = rows[0][0]
    rows = list(engine.sql("UPSERT SET city.name = 'London'"))
    london_eid = rows[0][0]

    list(engine.sql("UPSERT AS D1 = eid('city.name', 'NYC') SET company.hq = %1", nyc_eid))

    rows = list(engine.sql("SELECT d1.eid WHERE d1.company.hq = d2 AND d2.city.name = 'NYC'"))
    assert len(rows) == 1
    engine.close()


def test_upsert_with_param():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    list(engine.sql("UPSERT AS D1 SET person.name = %1, person.age = 25", "Alice"))

    rows = list(engine.sql("UPSERT AS D1 = eid('person.name', %1) SET person.age = %2", "Alice", 30))
    assert len(rows) == 1
    alice_eid = rows[0][0]

    rows = list(engine.sql("SELECT d1.person.age WHERE d1.eid = %1", alice_eid))
    assert rows == [(30,)]
    engine.close()


def test_upsert_as_tx():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE tx.user STRING ONE"))

    rows = list(engine.sql("UPSERT AS D1 SET person.name = 'Alice', AS TX SET tx.user = 'bob'"))
    alice_eid = rows[0][0]

    rows = list(engine.sql("SELECT d2.tx.user WHERE d1.eid = %1 AND d1.tx = d2", alice_eid))
    assert rows == [("bob",)]
    engine.close()


def test_upsert_multi_clause_alias_ref():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))
    list(engine.sql("ATTRIBUTE person.employer REF ONE"))

    rows = list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME',"
        " AS D2 SET person.name = 'Alice', person.employer = d1"
    ))
    acme_eid = rows[0][0]

    bob_rows = list(engine.sql("SELECT d1.person.employer WHERE d1.person.name = 'Alice'"))
    assert bob_rows[0][0] == acme_eid
    engine.close()


def test_upsert_explicit_eid():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))

    rows = list(engine.sql("UPSERT SET person.name = 'Alice'"))
    alice_eid = rows[0][0]

    rows = list(engine.sql("UPSERT AS D1 = %1 SET person.name = 'Updated Alice'", alice_eid))
    assert rows[0][0] == alice_eid

    rows = list(engine.sql("SELECT d1.person.name WHERE d1.eid = %1", alice_eid))
    assert rows == [("Updated Alice",)]
    engine.close()


def test_upsert_where_requires_unique():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE"))

    with pytest.raises(ValueError, match="UNIQUE"):
        list(engine.sql("UPSERT AS D1 = eid('person.name', 'Alice') SET person.age = 30"))
    engine.close()


def test_update_multi_alias():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    rows = list(engine.sql("UPSERT SET company.name = 'ACME'"))
    acme_eid = rows[0][0]
    rows = list(engine.sql("UPSERT SET person.name = 'Alice'"))
    alice_eid = rows[0][0]

    list(engine.sql("UPSERT AS D1 = eid('company.name', 'ACME') SET company.ceo = %1", alice_eid))

    list(engine.sql("UPDATE AS D1 SET company.name = 'ACME Corp', AS D2 SET person.age = 42 WHERE d1.company.ceo = d2 AND d2.person.name = 'Alice'"))

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", acme_eid))
    assert rows == [("ACME Corp",)]
    rows = list(engine.sql("SELECT d1.person.age WHERE d1.eid = %1", alice_eid))
    assert rows == [(42,)]
    engine.close()


def test_retract_hides_datom():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid = rows[0][0]
    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == [("Alice",)]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.ns.name = 'Alice'"))
    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == []
    engine.close()


def test_readd_after_retract():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.ns.name = 'Alice'"))
    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == []
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'Bob'", eid))
    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == [("Bob",)]
    engine.close()


def test_select_history_returns_all_versions():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid = rows[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'Bob'", eid))

    normal = list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}"))
    assert normal == [("Bob",)]

    history = list(engine.sql(f"SELECT HISTORY d1.ns.name WHERE d1.eid = {eid}"))
    values = [r[0] for r in history]
    assert "Alice" in values
    assert "Bob" in values
    assert len(history) == 2
    engine.close()


def test_select_history_shows_retracted():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid = rows[0][0]
    list(engine.sql(f"DELETE WHERE d1.eid = {eid} AND d1.ns.name = 'Alice'"))

    assert list(engine.sql(f"SELECT d1.ns.name WHERE d1.eid = {eid}")) == []

    history = list(engine.sql(f"SELECT HISTORY d1.ns.name WHERE d1.eid = {eid}"))
    assert len(history) == 1
    assert history[0][0] == "Alice"
    engine.close()


def test_select_history_star():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    rows = list(engine.sql("UPSERT SET ns.name = 'Alice'"))
    eid = rows[0][0]
    list(engine.sql("UPSERT AS D1 = %1 SET ns.name = 'Bob'", eid))

    history = list(engine.sql(f"SELECT HISTORY * WHERE d1.eid = {eid}"))
    assert len(history) == 3
    assert all(len(row) == 5 for row in history)

    values = [(row[2], row[4]) for row in history]
    assert ("Alice", True) in values
    assert ("Alice", False) in values
    assert ("Bob", True) in values
    engine.close()


def test_eid_func_lookup():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.hq REF ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET city.name = 'New York'"))
    ny_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = 'New York'"))[0][0]

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'New York') SET company.name = 'ACME Corp'"
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert rows == [("ACME Corp",)]

    list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'New York') SET company.hq = %1",
        ny_eid,
    ))
    rows = list(engine.sql("SELECT d1.company.name WHERE d1.company.hq = %1", ny_eid))
    assert rows == [("ACME Corp",)]
    engine.close()


def test_eid_func_lookup_not_found():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    result = list(engine.sql(
        "UPSERT AS D1 = eid('city.name', 'London') SET company.name = 'ACME'"
    ))
    assert result == []
    engine.close()


def test_eid_func_lookup_with_params():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET city.name = 'Paris'"))

    result = list(engine.sql(
        "UPSERT AS D1 = eid(%1, %2) SET company.name = 'ACME'",
        "city.name",
        "Paris",
    ))
    company_eid = result[0][0]

    rows = list(engine.sql("SELECT d1.company.name WHERE d1.eid = %1", company_eid))
    assert rows == [("ACME",)]
    engine.close()


def test_eid_in_set_value():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET person.name = 'Alice'"))

    list(engine.sql(
        "UPSERT AS D1 SET company.name = 'ACME', company.ceo = eid('person.name', 'Alice')"
    ))
    acme_eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]
    alice_eid = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Alice'"))[0][0]

    rows = list(engine.sql("SELECT d1.company.ceo WHERE d1.eid = %1", acme_eid))
    assert rows == [(alice_eid,)]
    engine.close()


def test_eid_in_set_value_with_params():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET person.name = 'Bob'"))

    list(engine.sql(
        "UPSERT AS D1 SET company.name = %1, company.ceo = eid(%2, %3)",
        "ACME",
        "person.name",
        "Bob",
    ))
    acme_eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = 'ACME'"))[0][0]
    bob_eid = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Bob'"))[0][0]

    rows = list(engine.sql("SELECT d1.company.ceo WHERE d1.eid = %1", acme_eid))
    assert rows == [(bob_eid,)]
    engine.close()


def test_eid_in_set_combined_with_entity_lookup():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.ceo REF ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))

    list(engine.sql("UPSERT SET person.name = 'Alice'"))
    list(engine.sql("UPSERT SET company.name = 'ACME'"))

    rows = list(engine.sql(
        "UPSERT AS D1 = eid('company.name', 'ACME') SET company.ceo = eid('person.name', 'Alice')"
    ))
    acme_eid = rows[0][0]
    alice_eid = list(engine.sql("SELECT d1.eid WHERE d1.person.name = 'Alice'"))[0][0]

    rows = list(engine.sql("SELECT d1.company.ceo WHERE d1.eid = %1", acme_eid))
    assert rows == [(alice_eid,)]
    engine.close()


def test_val_from_eid():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.codigo STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE item.preco FLOAT ONE"))
    list(engine.sql("ATTRIBUTE order.total FLOAT ONE"))

    list(engine.sql("UPSERT SET item.codigo = 'ABC', item.preco = 99.90"))

    list(engine.sql(
        "UPSERT AS D1 SET order.total = val(eid('item.codigo', 'ABC'), 'item.preco')"
    ))
    order_eid = list(engine.sql("SELECT d1.eid WHERE d1.order.total = 99.90"))
    assert len(order_eid) == 1
    engine.close()


def test_val_with_param_eid():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.codigo STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE item.preco FLOAT ONE"))
    list(engine.sql("ATTRIBUTE order.total FLOAT ONE"))

    rows = list(engine.sql("UPSERT SET item.codigo = 'XYZ', item.preco = 42.50"))
    item_eid = rows[0][0]

    list(engine.sql(
        "UPSERT AS D1 SET order.total = val(%1, 'item.preco')",
        item_eid,
    ))
    order_eid = list(engine.sql("SELECT d1.eid WHERE d1.order.total = 42.50"))
    assert len(order_eid) == 1
    engine.close()


def test_val_unquoted_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE item.codigo STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE item.preco FLOAT ONE"))
    list(engine.sql("ATTRIBUTE order.total FLOAT ONE"))

    list(engine.sql("UPSERT SET item.codigo = 'DEF', item.preco = 10.00"))

    list(engine.sql(
        "UPSERT AS D1 SET order.total = val(eid(item.codigo, 'DEF'), item.preco)"
    ))
    rows = list(engine.sql("SELECT d1.order.total WHERE d1.order.total = 10.00"))
    assert len(rows) == 1
    engine.close()


def test_bug_float_range_large_resultset():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE company.name STRING ONE"))
    list(engine.sql("ATTRIBUTE company.revenue FLOAT ONE"))
    for i in range(10000):
        list(engine.sql("UPSERT AS D1 SET company.name = %1, company.revenue = %2", f"c{i:06d}", float(i * 100)))
    rows = list(engine.sql(
        "SELECT d1.company.name WHERE d1.company.revenue >= %1 AND d1.company.revenue < %2",
        0.0, 100000.0,
    ))
    assert len(rows) == 1000
    engine.close()


def test_bug_eid_range_query():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE ns.name STRING ONE"))
    for i in range(100):
        list(engine.sql("UPSERT AS D1 SET ns.name = %1", f"e{i:03d}"))
    e25 = list(engine.sql("SELECT d1.eid WHERE d1.ns.name = %1", "e025"))[0][0]
    e75 = list(engine.sql("SELECT d1.eid WHERE d1.ns.name = %1", "e075"))[0][0]
    rows = list(engine.sql(
        "SELECT d1.ns.name WHERE d1.eid >= %1 AND d1.eid < %2",
        e25, e75,
    ))
    assert len(rows) == 50
    engine.close()

