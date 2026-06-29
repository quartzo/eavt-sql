from eavt_sql.engine import EAVTEngine


def test_dedup_attr_many():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.nome STRING ONE"))
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.nome = %1, empresa.tag = %2, empresa.tag = %3", "teste", "a", "b"))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.nome = %1", "teste"))[0][0]
    rows = list(engine.sql("SELECT d1.attr WHERE d1.eid = %1", eid))
    attrs = [r[0] for r in rows]
    assert attrs == ["empresa.nome", "empresa.tag"]
    engine.close()


def test_dedup_attr_many_large():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.nome STRING ONE"))
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    vals = [f"val_{i:04d}" for i in range(100)]
    sql = "UPSERT SET empresa.nome = %1" + "".join(
        f", empresa.tag = %{i+2}" for i in range(len(vals))
    )
    list(engine.sql(sql, "teste", *vals))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.nome = %1", "teste"))[0][0]
    rows = list(engine.sql("SELECT d1.attr WHERE d1.eid = %1", eid))
    attrs = [r[0] for r in rows]
    assert attrs == ["empresa.nome", "empresa.tag"]
    engine.close()


def test_dedup_entity_many_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.tag = %1", "shared"))
    list(engine.sql("UPSERT SET empresa.tag = %1", "shared"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.empresa.tag = %1", "shared"))
    assert len(rows) == 2
    eids = sorted(r[0] for r in rows)
    assert eids[0] != eids[1]
    engine.close()


def test_dedup_preserves_star():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.nome STRING ONE"))
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.nome = %1, empresa.tag = %2, empresa.tag = %3", "teste", "a", "b"))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.nome = %1", "teste"))[0][0]
    rows = list(engine.sql("SELECT * WHERE d1.eid = %1", eid))
    attrs = [r[1] for r in rows]
    assert "empresa.nome" in attrs
    assert "empresa.tag" in attrs
    tag_rows = [r for r in rows if r[1] == "empresa.tag"]
    assert len(tag_rows) == 2
    engine.close()


def test_dedup_val_projection():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.tag = %1, empresa.tag = %2, empresa.tag = %3", "a", "b", "c"))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.tag = %1", "a"))[0][0]
    rows = list(engine.sql("SELECT d1.empresa.tag WHERE d1.eid = %1", eid))
    vals = sorted(r[0] for r in rows)
    assert vals == ["a", "b", "c"]
    engine.close()


def test_dedup_attr_one():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.nome STRING ONE"))
    list(engine.sql("ATTRIBUTE empresa.id LONG ONE"))
    list(engine.sql("UPSERT SET empresa.nome = %1, empresa.id = %2", "teste", 42))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.nome = %1", "teste"))[0][0]
    rows = list(engine.sql("SELECT d1.attr WHERE d1.eid = %1", eid))
    attrs = [r[0] for r in rows]
    assert len(attrs) == 2
    assert "empresa.nome" in attrs
    assert "empresa.id" in attrs
    engine.close()


def test_dedup_with_retraction():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.tag = %1, empresa.tag = %2", "a", "b"))
    eid = list(engine.sql("SELECT d1.eid WHERE d1.empresa.tag = %1", "a"))[0][0]
    list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.empresa.tag = %2", eid, "a"))
    rows = list(engine.sql("SELECT d1.attr WHERE d1.eid = %1", eid))
    attrs = [r[0] for r in rows]
    assert attrs == ["empresa.tag"]
    engine.close()


def test_dedup_eid_with_bound_attr():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE empresa.tag STRING MANY"))
    list(engine.sql("UPSERT SET empresa.tag = %1, empresa.tag = %2", "x", "x"))
    rows = list(engine.sql("SELECT d1.eid WHERE d1.empresa.tag = %1", "x"))
    assert len(rows) == 1
    engine.close()
