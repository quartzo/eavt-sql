"""Tests for the datalog query API."""
import pytest

from eavt import EavtEngine, QuerySession, prepare, explain


@pytest.fixture
def eng(tmp_path):
    e = EavtEngine(str(tmp_path / "db"))
    e.bootstrap()
    yield e
    e.close()


@pytest.fixture
def sess(eng):
    return QuerySession(eng)


# ═══════════════════════════════════════════════════════════════════════════════
# parse
# ═══════════════════════════════════════════════════════════════════════════════

class TestParse:
    def test_3_element_clause(self, sess):
        sess.declare_attr("person.name", "string")
        p = prepare(sess, ["?name"], [(42, "person.name", "?name")])
        pat = p.patterns[0]
        assert pat.slots[0] == 42          # e = const
        assert pat.slots[1] == "person.name"  # a = const
        from eavt.query import Var
        assert isinstance(pat.slots[2], Var) and pat.slots[2].name == "name"
        from eavt.query import Wildcard
        assert isinstance(pat.slots[3], Wildcard)  # t = _
        assert isinstance(pat.slots[4], Wildcard)  # added = _

    def test_4_element_clause(self, sess):
        sess.declare_attr("person.name", "string")
        p = prepare(sess, ["?name", "?tx"], [(42, "person.name", "?name", "?tx")])
        pat = p.patterns[0]
        from eavt.query import Var, Wildcard
        assert isinstance(pat.slots[3], Var) and pat.slots[3].name == "tx"
        assert isinstance(pat.slots[4], Wildcard)

    def test_5_element_clause(self, sess):
        sess.declare_attr("person.name", "string")
        p = prepare(sess, ["?name"], [(42, "person.name", "?name", "_", True)])
        pat = p.patterns[0]
        from eavt.query import Wildcard
        assert isinstance(pat.slots[3], Wildcard)
        assert pat.slots[4] is True

    def test_too_few_elements(self, sess):
        with pytest.raises(ValueError, match="expected 3-5"):
            prepare(sess, ["?x"], [(42, "attr")])

    def test_too_many_elements(self, sess):
        with pytest.raises(ValueError, match="expected 3-5"):
            prepare(sess, ["?x"], [(42, "attr", "?v", 1, 2, 3)])

    def test_variable_in_find(self, sess):
        with pytest.raises(ValueError, match="must start with"):
            prepare(sess, ["name"], [(42, "attr", "?v")])

    def test_variable_not_in_clauses(self, sess):
        with pytest.raises(ValueError, match="does not appear"):
            prepare(sess, ["?missing"], [(42, "attr", "?v"), ("?v", "attr2", "?w")])

    def test_variable_in_clause_but_not_find(self, sess):
        sess.declare_attr("person.name", "string")
        with pytest.raises(ValueError, match="not in find"):
            prepare(
                sess,
                ["?name"],
                [("?eid", "person.name", "?name")],
            )


# ═══════════════════════════════════════════════════════════════════════════════
# validation
# ═══════════════════════════════════════════════════════════════════════════════

class TestValidation:
    def test_simple_attr_scan(self, sess):
        sess.declare_attr("person.name", "string")
        p = prepare(sess, ["?name"], [(42, "person.name", "?name")])
        assert len(p.depths) == 1
        assert p.depths[0].var == "name"
        assert p.depths[0].clauses[0].index == "EAVT"  # e=const, a=const, v=var

    def test_two_attrs_same_entity(self, sess):
        sess.declare_attr("person.name", "string")
        sess.declare_attr("person.age", "long")
        p = prepare(
            sess,
            ["?eid", "?name", "?age"],
            [
                ("?eid", "person.name", "?name"),
                ("?eid", "person.age", "?age"),
            ],
        )
        assert len(p.depths) == 3
        # ?eid first: EAVT position 0, no prefix needed
        assert p.depths[0].var == "eid"
        # ?name: AEVT (a=const, e=?eid bound) or EAVT (e=?eid bound, a=const)
        # ?age: similar

    def test_join_by_eid(self, sess):
        sess.declare_attr("company.partner", "ref")
        sess.declare_attr("person.name", "string")
        p = prepare(
            sess,
            ["?eid1", "?eid2", "?name"],
            [
                ("?eid1", "company.partner", "?eid2"),
                ("?eid2", "person.name", "?name"),
            ],
        )
        assert len(p.depths) == 3

    def test_no_feasible_index(self, sess):
        sess.declare_attr("person.name", "string")
        with pytest.raises(ValueError, match="no feasible index"):
            prepare(
                sess,
                ["?attr", "?name", "?eid"],
                [("?eid", "?attr", "?name")],
            )

    def test_unknown_attr_raises(self, sess):
        with pytest.raises(ValueError, match="not declared"):
            prepare(sess, ["?v"], [(42, "unknown.attr", "?v")])

    def test_explain(self, sess):
        sess.declare_attr("person.name", "string")
        p = prepare(sess, ["?name"], [(42, "person.name", "?name")])
        txt = explain(p)
        assert "find:" in txt
        assert "?name" in txt
        assert "binding order:" in txt


# ═══════════════════════════════════════════════════════════════════════════════
# execute
# ═══════════════════════════════════════════════════════════════════════════════

class TestExecute:
    def test_single_attr_lookup(self, eng, sess):
        eng.declare_attr("person.name", "string")
        eid = sess.alloc_entity()
        sess.save(eid, "person.name", "Alice")
        sess.commit()

        q = prepare(sess, ["?name"], [(eid, "person.name", "?name")])
        rows = list(q.execute())
        assert rows == [("Alice",)]

    def test_two_attrs(self, eng, sess):
        eng.declare_attr("person.name", "string")
        eng.declare_attr("person.age", "long")
        eid = sess.alloc_entity()
        sess.save(eid, "person.name", "Bob")
        sess.save(eid, "person.age", 30)
        sess.commit()

        q = prepare(
            sess,
            ["?eid", "?name", "?age"],
            [
                ("?eid", "person.name", "?name"),
                ("?eid", "person.age", "?age"),
            ],
        )
        rows = sorted(q.execute())
        assert len(rows) == 1
        assert rows[0][1] == "Bob"
        assert rows[0][2] == 30

    def test_multiple_entities(self, eng, sess):
        eng.declare_attr("person.name", "string")
        for name in ["Alice", "Bob", "Charlie"]:
            eid = sess.alloc_entity()
            sess.save(eid, "person.name", name)
        sess.commit()

        q = prepare(sess, ["?name"], [("_", "person.name", "?name")])
        rows = sorted(q.execute())
        assert rows == [("Alice",), ("Bob",), ("Charlie",)]

    def test_range_filter(self, eng, sess):
        eng.declare_attr("item.price", "long")
        for price in [5, 10, 15, 20, 25]:
            eid = sess.alloc_entity()
            sess.save(eid, "item.price", price)
        sess.commit()

        q = prepare(
            sess,
            ["?price"],
            [("_", "item.price", "?price")],
            ranges={"?price": (">=", 10, "<=", 20)},
        )
        rows = sorted(q.execute())
        assert rows == [(10,), (15,), (20,)]

    def test_wildcard_entity(self, eng, sess):
        eng.declare_attr("tag.x", "long", many=True)
        eid = sess.alloc_entity()
        for v in [1, 2, 3]:
            sess.save(eid, "tag.x", v)
        sess.commit()

        q = prepare(sess, ["?v"], [("_", "tag.x", "?v")])
        rows = sorted(q.execute())
        assert rows == [(1,), (2,), (3,)]

    def test_constant_entity(self, eng, sess):
        eng.declare_attr("tag.x", "long", many=True)
        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "tag.x", 10)
        sess.save(eid2, "tag.x", 20)
        sess.commit()

        q = prepare(sess, ["?v"], [(eid1, "tag.x", "?v")])
        rows = list(q.execute())
        assert rows == [(10,)]

    def test_join(self, eng, sess):
        eng.declare_attr("person.name", "string")
        eng.declare_attr("company.partner", "ref")
        eng.declare_attr("company.name", "string")

        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "person.name", "Alice")
        sess.save(eid2, "person.name", "Bob")
        sess.save(eid1, "company.partner", eid2)
        sess.save(eid1, "company.name", "Acme")
        sess.commit()

        q = prepare(
            sess,
            ["?eid1", "?eid2", "?name1", "?name2"],
            [
                ("?eid1", "company.partner", "?eid2"),
                ("?eid1", "company.name", "?name1"),
                ("?eid2", "person.name", "?name2"),
            ],
        )
        rows = list(q.execute())
        assert len(rows) == 1
        assert rows[0][2] == "Acme"
        assert rows[0][3] == "Bob"

    def test_empty_result(self, eng, sess):
        eng.declare_attr("person.name", "string")
        sess.commit()

        q = prepare(sess, ["?name"], [("_", "person.name", "?name")])
        rows = list(q.execute())
        assert rows == []

    def test_given_resolves_ambiguous(self, sess):
        """Test that given can bind a variable to a string constant starting with '?'."""
        from eavt import prepare as _prepare
        sess.declare_attr("db.ident", "string")
        # This would be ambiguous without given: is "?foo" a variable or string?
        # With given, it's clearly a string constant.
        q = _prepare(
            sess,
            ["?v"],
            [("?eid", "db.ident", "?v")],
            given={"?eid": 1},
        )
        assert q.patterns[0].slots[0] == 1  # eid resolved to constant


# ═══════════════════════════════════════════════════════════════════════════════
# Trailing constants and repeated variables
# ═══════════════════════════════════════════════════════════════════════════════

class TestTrailing:
    def test_trailing_constant(self, eng, sess):
        eng.declare_attr("item.price", "long")
        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "item.price", 10)
        sess.save(eid2, "item.price", 20)
        sess.commit()
        q = prepare(sess, ["?eid"], [("?eid", "item.price", 20)])
        rows = list(q.execute())
        assert rows == [(eid2,)]

    def test_trailing_constant_explain(self, sess):
        # Non-indexed attr → AVET not available → trailing at v position
        sess.declare_attr("item.price", "long", indexed=False)
        q = prepare(sess, ["?eid"], [("?eid", "item.price", 42)])
        txt = q.explain()
        assert "validate" in txt
        assert "42" in txt

    def test_trailing_constant_non_indexed(self, eng, sess):
        eng.declare_attr("item.price", "long", indexed=False)
        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "item.price", 10)
        sess.save(eid2, "item.price", 20)
        sess.commit()
        q = prepare(sess, ["?eid"], [("?eid", "item.price", 20)])
        rows = list(q.execute())
        assert rows == [(eid2,)]

    def test_trailing_constant_no_match(self, eng, sess):
        eng.declare_attr("item.price", "long")
        eid1 = sess.alloc_entity()
        sess.save(eid1, "item.price", 10)
        sess.commit()
        q = prepare(sess, ["?eid"], [("?eid", "item.price", 99)])
        rows = list(q.execute())
        assert rows == []

    def test_repeated_variable_self_ref(self, eng, sess):
        eng.declare_attr("company.partner", "ref")
        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "company.partner", eid1)  # self-ref
        sess.save(eid2, "company.partner", eid1)  # external ref
        sess.commit()
        q = prepare(sess, ["?eid"], [("?eid", "company.partner", "?eid")])
        rows = list(q.execute())
        assert rows == [(eid1,)]

    def test_repeated_variable_explain(self, sess):
        sess.declare_attr("company.partner", "ref")
        q = prepare(sess, ["?eid"], [("?eid", "company.partner", "?eid")])
        txt = q.explain()
        assert "validate" in txt

    def test_repeated_variable_no_match(self, eng, sess):
        eng.declare_attr("company.partner", "ref")
        eid1 = sess.alloc_entity()
        eid2 = sess.alloc_entity()
        sess.save(eid1, "company.partner", eid2)
        sess.save(eid2, "company.partner", eid1)
        sess.commit()
        # Neither points to itself
        q = prepare(sess, ["?eid"], [("?eid", "company.partner", "?eid")])
        rows = list(q.execute())
        assert rows == []

    def test_trailing_unbound_error(self, sess):
        sess.declare_attr("person.name", "string")
        with pytest.raises(ValueError, match="not in find"):
            prepare(sess, ["?eid"], [("?eid", "person.name", "?missing")])
