import std/[unittest, tables]
import parser, translate, datalog_ast

suite "translate: simple SELECT":
  test "eid param binding":
    let stmt = parse("SELECT d1.company.name WHERE d1.eid = %1")
    let ir = buildDatalogIr(stmt)
    check ir.findVars.len == 1
    check ir.findVars[0].kind == fvVar
    check ir.findVars[0].varName == "_v_d1_company_name"
    check ir.patterns.len == 1
    check ir.patterns[0].e.kind == dsConst
    check ir.patterns[0].e.constVal.kind == bvParam
    check ir.patterns[0].e.constVal.paramIdx == 1
    check ir.patterns[0].a.kind == dsConst
    check ir.patterns[0].a.constVal.kind == bvAttr
    check ir.patterns[0].a.constVal.attrName == "company.name"
    check ir.patterns[0].v.kind == dsVar
    check ir.patterns[0].v.varName == "_v_d1_company_name"
    check not ir.star
    check not ir.existsMode
    check not ir.history

  test "select without where":
    let stmt = parse("SELECT d1.company.name")
    let ir = buildDatalogIr(stmt)
    check ir.findVars.len == 1
    check ir.patterns.len == 1
    check ir.patterns[0].e.kind == dsVar
    check ir.patterns[0].e.varName == "_e_d1"
    check ir.patterns[0].a.kind == dsConst
    check ir.patterns[0].a.constVal.kind == bvAttr
    check ir.patterns[0].a.constVal.attrName == "company.name"

  test "star expansion":
    let stmt = parse("SELECT * WHERE d1.company.active = true")
    let ir = buildDatalogIr(stmt)
    check ir.findVars.len == 3
    check ir.findVars[0].kind == fvVar
    check ir.findVars[0].varName == "_e_d1"
    check ir.findVars[1].kind == fvVar
    check ir.findVars[1].varName == "_a_d1"
    check ir.findVars[2].kind == fvVar
    check ir.findVars[2].varName == "_vv_d1"
    check ir.patterns.len == 2

  test "star without conditions":
    let stmt = parse("SELECT *")
    let ir = buildDatalogIr(stmt)
    check ir.patterns.len == 1

  test "history metadata":
    let stmt = parse("SELECT HISTORY d1.company.name WHERE d1.eid = %1")
    let ir = buildDatalogIr(stmt)
    check ir.history

  test "exists mode":
    let stmt = parse("SELECT 1 WHERE d1.company.eid = %1 AND d1.company.partner = %2")
    let ir = buildDatalogIr(stmt)
    check ir.existsMode

suite "translate: joins":
  test "entity join via field ref":
    let stmt = parse("SELECT d2.company.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid")
    let ir = buildDatalogIr(stmt)
    check ir.patterns.len == 2
    check ir.patterns[0].e.kind == dsConst and ir.patterns[0].e.constVal.kind == bvParam
    check ir.patterns[0].a.constVal.attrName == "company.partner"
    check ir.patterns[0].v.kind == dsVar and ir.patterns[0].v.varName == "_e_d2"
    check ir.patterns[1].e.kind == dsVar and ir.patterns[1].e.varName == "_e_d2"
    check ir.patterns[1].a.constVal.attrName == "company.name"

  test "multi-projection":
    let stmt = parse("SELECT d1.eid, d1.company.name, d1.tx WHERE d1.eid = %1")
    let ir = buildDatalogIr(stmt)
    check ir.findVars.len == 3
    check ir.findVars[0].kind == fvConst
    check ir.findVars[0].cVal.kind == bvParam
    check ir.findVars[1].kind == fvVar
    check ir.findVars[1].varName == "_v_d1_company_name"
    check ir.findVars[2].kind == fvVar
    check ir.findVars[2].varName == "_t_d1"

suite "translate: ranges and operators":
  test "range gt":
    let stmt = parse("SELECT d1.company.name WHERE d1.company.price > 1000")
    let ir = buildDatalogIr(stmt)
    let key1 = "_v_d1_company_price"
    check ir.rangeBounds.hasKey(key1)
    check ir.rangeBounds[key1].len == 1
    check ir.rangeBounds[key1][0].len == 1
    check ir.rangeBounds[key1][0][0][0] == ">"

  test "range gte and lt with AND":
    let stmt = parse("SELECT d1.company.name WHERE d1.company.price >= 3.14 AND d1.company.price < 42")
    let ir = buildDatalogIr(stmt)
    let key2 = "_v_d1_company_price"
    check ir.rangeBounds.hasKey(key2)
    check ir.rangeBounds[key2][0].len == 2

  test "neq operator":
    let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val != %1")
    let ir = buildDatalogIr(stmt)
    let key = "_v_d1_ns_val"
    check ir.rangeBounds.hasKey(key)
    check ir.rangeBounds[key][0][0][0] == "!="

  test "neq angle bracket <>":
    let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val <> %1")
    let ir = buildDatalogIr(stmt)
    let key = "_v_d1_ns_val"
    check ir.rangeBounds.hasKey(key)

suite "translate: IN":
  test "in with params":
    let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val IN (%1, %2, %3)")
    let ir = buildDatalogIr(stmt)
    let key = "_v_d1_ns_val"
    check ir.rangeBounds.hasKey(key)
    check ir.rangeBounds[key].len == 1
    check ir.rangeBounds[key][0].len == 3
    for pair in ir.rangeBounds[key][0]:
      check pair[0] == "in"

  test "in with literals":
    let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val IN (10, 20, 30)")
    let ir = buildDatalogIr(stmt)
    let key = "_v_d1_ns_val"
    check ir.rangeBounds.hasKey(key)
    check ir.rangeBounds[key][0].len == 3

  test "in via bare equals-parenthesized":
    let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val = (10, %1, 'hello')")
    let ir = buildDatalogIr(stmt)
    let key = "_v_d1_ns_val"
    check ir.rangeBounds.hasKey(key)

suite "translate: OR":
  test "or condition":
    let stmt = parse("SELECT d1.company.name WHERE d1.eid = %1 OR d1.eid = %2")
    let ir = buildDatalogIr(stmt)
    check ir.rangeBounds.hasKey("_e_d1")
    check ir.rangeBounds["_e_d1"].len == 2

suite "translate: aliases from projections without WHERE":
  test "bare projection alias":
    let stmt = parse("SELECT d1.company.name")
    let ir = buildDatalogIr(stmt)
    check ir.findVars[0].varName == "_v_d1_company_name"
    check ir.patterns[0].e.kind == dsVar

suite "translate: errors":
  test "alias in SELECT but not in WHERE":
    expect CatchableError:
      let stmt = parse("SELECT d1.company.name WHERE d2.eid = %1")
      discard buildDatalogIr(stmt)

  test "OR on attr not supported":
    expect CatchableError:
      let stmt = parse("SELECT d1.company.name WHERE d1.attr = %1 OR d1.attr = %2")
      discard buildDatalogIr(stmt)

  test "non-SELECT statement":
    expect CatchableError:
      let stmt = parse("UPSERT AS D1 SET company.name = 'X'")
      discard buildDatalogIr(stmt)

  test "attribute name must have namespace in WHERE":
    expect CatchableError:
      let stmt = parse("SELECT d1.company.name WHERE d1.name = 'hello'")
      discard buildDatalogIr(stmt)

  test "attribute name must have namespace in projection":
    expect CatchableError:
      let stmt = parse("SELECT d1.name")
      discard buildDatalogIr(stmt)
