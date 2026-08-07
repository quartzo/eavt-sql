"""Tests for the ranges system — mirrors nim_query/query/test_query.nim.

The canonical leapfrog pattern from the Nim tests:
  - open an EAVT scanner, push eid + aid (value position)
  - scanner-set-ranges with ranges built by ranges-create
  - scanner-iterate-init, then scanner-iterate-next yields each matching value
"""
import pytest

from eavt import EavtEngine, QuerySession


@pytest.fixture
def tag_engine(tmp_path):
    eng = EavtEngine(str(tmp_path / "db"))
    eng.bootstrap()
    sess = QuerySession(eng)
    sess.declare_attr("tag.x", "long", many=True)
    yield eng, sess
    eng.close()


def setup_values(eng, sess, vals):
    eid = sess.alloc_entity()
    for v in vals:
        sess.save(eid, "tag.x", v)
    aid = sess.intern_a("tag.x")
    return eid, aid


def iterate(sess, eid, aid, ranges):
    s = sess.scanner_open("EAVT")
    sess.scanner_push(s, eid)
    sess.scanner_push(s, aid)
    sess.scanner_set_ranges(s, ranges)
    it = sess.scanner_iterate_init(s)
    out = []
    while True:
        v = sess.scanner_iterate_next(it)
        if v is None:
            break
        out.append(v)
    return out


def test_ranges_create_and(tag_engine):
    _, sess = tag_engine
    r = sess.ranges_create(["and", [">=", 10], ["<=", 20]])
    assert r == [[3, 10], [5, 20]]


def test_ranges_create_or_branches(tag_engine):
    _, sess = tag_engine
    r = sess.ranges_create(["or", ["=", 1], ["=", 20]])
    assert r == [["branch"], [0, 1], ["branch"], [0, 20]]


def test_ranges_filters_values(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [5, 10, 15, 20, 25])
    got = iterate(sess, eid, aid, sess.ranges_create(["and", [">=", 10], ["<=", 20]]))
    assert got == [10, 15, 20]


def test_ranges_eq_single_value(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [5, 10, 15, 20, 25])
    got = iterate(sess, eid, aid, sess.ranges_create(["=", 15]))
    assert got == [15]


def test_ranges_neq_excludes_value(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [5, 10, 15, 20, 25])
    got = iterate(sess, eid, aid, sess.ranges_create(["!=", 15]))
    assert got == [5, 10, 20, 25]


def test_ranges_or_disjoint(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [1, 2, 5, 20])
    got = iterate(sess, eid, aid, sess.ranges_create(["or", ["=", 1], ["=", 20]]))
    assert got == [1, 20]


def test_ranges_empty_filter_all(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [5, 10, 15])
    got = iterate(sess, eid, aid, sess.ranges_create(["and"]))
    assert got == [5, 10, 15]


def test_ranges_filters_out_everything(tag_engine):
    eng, sess = tag_engine
    eid, aid = setup_values(eng, sess, [5, 10, 15])
    got = iterate(sess, eid, aid, sess.ranges_create(["and", [">", 100], ["<", 200]]))
    assert got == []


def test_multi_scanner_intersection_with_ranges(tag_engine):
    eng, sess = tag_engine
    e1 = sess.alloc_entity()
    e2 = sess.alloc_entity()
    for v in [10, 20, 30, 50]:
        sess.save(e1, "tag.x", v)
    for v in [20, 30, 50, 70]:
        sess.save(e2, "tag.x", v)
    aid = sess.intern_a("tag.x")

    s1 = sess.scanner_open("EAVT")
    s2 = sess.scanner_open("EAVT")
    sess.scanner_push(s1, e1)
    sess.scanner_push(s1, aid)
    sess.scanner_push(s2, e2)
    sess.scanner_push(s2, aid)
    sess.scanner_set_ranges(s1, sess.ranges_create([">=", 30]))

    it = sess.scanner_iterate_init(s1, s2)
    got = []
    while True:
        v = sess.scanner_iterate_next(it)
        if v is None:
            break
        got.append(v)
    assert got == [30, 50]
