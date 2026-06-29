import pytest


def test_status(client):
    status = client.status()
    assert "db_path" in status
    assert status["storage_mode"] == "file"


def test_sql_attribute_and_upsert(client):
    client.execute("ATTRIBUTE test.name STRING ONE")
    client.execute("ATTRIBUTE test.score STRING ONE")
    rows = client.execute("UPSERT SET test.name = 'Alice', test.score = '42'")
    assert len(rows) == 1
    assert rows[0][0] > 0


def test_sql_select(client):
    client.execute("ATTRIBUTE sel.ns STRING ONE")
    client.execute("UPSERT SET sel.ns = 'hello'")
    rows = list(client.sql("SELECT d1.sel.ns WHERE d1.sel.ns = 'hello'"))
    assert len(rows) == 1
    assert rows[0][0] == "hello"


def test_sql_select_eid(client):
    client.execute("ATTRIBUTE sel.eid_test STRING ONE")
    rows = client.execute("UPSERT SET sel.eid_test = 'find-me'")
    eid = rows[0][0]
    found = list(client.sql("SELECT d1.eid WHERE d1.sel.eid_test = 'find-me'"))
    assert len(found) == 1
    assert found[0][0] == eid


def test_sql_join(client):
    client.execute("ATTRIBUTE join.company STRING ONE")
    client.execute("ATTRIBUTE join.person STRING ONE")
    client.execute("ATTRIBUTE join.employer REF ONE")
    r1 = client.execute("UPSERT SET join.company = 'Acme'")
    company_eid = r1[0][0]
    client.execute("UPSERT SET join.person = 'Bob', join.employer = %1", company_eid)

    rows = list(client.sql(
        "SELECT d2.join.person WHERE d1.join.company = 'Acme' AND d1.eid = d2.join.employer"
    ))
    assert len(rows) == 1
    assert rows[0][0] == "Bob"


def test_sql_multiple_attributes(client):
    client.execute("ATTRIBUTE multi.a STRING ONE")
    client.execute("ATTRIBUTE multi.b STRING ONE")
    client.execute("UPSERT SET multi.a = 'x', multi.b = 'y'")
    rows = list(client.sql(
        "SELECT d1.multi.a, d1.multi.b WHERE d1.multi.a = 'x' AND d1.multi.b = 'y'"
    ))
    assert len(rows) == 1
    assert rows[0] == ("x", "y")


def test_sql_delete(client):
    client.execute("ATTRIBUTE del.x STRING ONE")
    client.execute("UPSERT SET del.x = 'temp'")
    assert len(list(client.sql("SELECT d1.del.x WHERE d1.del.x = 'temp'"))) == 1
    client.execute("DELETE WHERE d1.del.x = 'temp'")
    assert len(list(client.sql("SELECT d1.del.x WHERE d1.del.x = 'temp'"))) == 0


def test_sql1(client):
    client.execute("ATTRIBUTE s1.val STRING ONE")
    client.execute("UPSERT SET s1.val = 'only-one'")
    row = client.sql1("SELECT d1.s1.val WHERE d1.s1.val = 'only-one'")
    assert row is not None
    assert row[0] == "only-one"


def test_sql1_empty(client):
    client.execute("ATTRIBUTE s1e.val STRING ONE")
    row = client.sql1("SELECT d1.s1e.val WHERE d1.s1e.val = 'nonexistent'")
    assert row is None


def test_flush(client):
    client.flush()


def test_ref_many(client):
    client.execute("ATTRIBUTE rmany.tag STRING ONE")
    client.execute("ATTRIBUTE rmany.item REF MANY")
    r1 = client.execute("UPSERT SET rmany.tag = 't1'")
    tag_eid = r1[0][0]
    r2 = client.execute("UPSERT SET rmany.item = %1", tag_eid)
    item_eid = r2[0][0]
    rows = list(client.sql("SELECT d1.rmany.item WHERE d1.eid = %1", item_eid))
    assert len(rows) >= 1
    assert tag_eid in [r[0] for r in rows]


def test_not_equal(client):
    client.execute("ATTRIBUTE neq.val STRING ONE")
    client.execute("UPSERT SET neq.val = 'a'")
    client.execute("UPSERT SET neq.val = 'b'")
    client.execute("UPSERT SET neq.val = 'c'")
    rows = list(client.sql("SELECT d1.neq.val WHERE d1.neq.val != 'a'"))
    values = [r[0] for r in rows]
    assert 'a' not in values


def test_range(client):
    client.execute("ATTRIBUTE rng.score STRING ONE")
    client.execute("UPSERT SET rng.score = '10'")
    client.execute("UPSERT SET rng.score = '20'")
    client.execute("UPSERT SET rng.score = '30'")
    rows = list(client.sql(
        "SELECT d1.rng.score WHERE d1.rng.score >= '15' AND d1.rng.score <= '25'"
    ))
    values = [r[0] for r in rows]
    assert '20' in values
    assert '10' not in values
    assert '30' not in values
