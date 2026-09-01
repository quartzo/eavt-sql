## test_query_edn.nim — Unit tests for the Datalog EDN surface parser.

import std/[unittest, tables, options]
import scheme, edn
import query_edn, datalog_ast, stats

proc parseQ(src: string): DatalogIR = parseDatalogQuery(src)

suite "datalog-edn.patterns":
  test "simple pattern with find":
    let ir = parseQ("[:find ?name :where [?e :person/name ?name]]")
    check ir.patterns.len == 1
    check ir.findVars.len == 1
    check ir.findVars[0].kind == fvVar and ir.findVars[0].varName == "name"
    check ir.patterns[0].e.kind == dsVar and ir.patterns[0].e.varName == "e"
    check ir.patterns[0].a.kind == dsConst
    check ir.patterns[0].a.constVal.kind == bvAttr
    check ir.patterns[0].a.constVal.attrName == "person/name"
    check ir.patterns[0].v.kind == dsVar and ir.patterns[0].v.varName == "name"

  test "blank slots become missing":
    let ir = parseQ("[:find ?v :where [?e :person/name ?v]]")
    discard ir
    let ir2 = parseQ("[:find ?v :where [_ :person/name ?v]]")
    check ir2.patterns[0].e.kind == dsMissing

  test "constant value in v slot":
    let ir = parseQ("[:find ?e :where [?e :person/name \"Alice\"]]")
    check ir.patterns[0].v.kind == dsConst
    check ir.patterns[0].v.constVal.kind == bvStr
    check ir.patterns[0].v.constVal.sval == "Alice"

  test "int eid in e slot":
    let ir = parseQ("[:find ?name :where [101 :person/name ?name]]")
    check ir.patterns[0].e.kind == dsConst
    check ir.patterns[0].e.constVal.ival == 101

  test "join via shared var":
    let ir = parseQ("[:find ?name :where [?e :person/employer ?emp] [?emp :company/name ?name]]")
    check ir.patterns.len == 2
    # both patterns share the ?emp var in the join positions
    check ir.patterns[0].v.varName == "emp"
    check ir.patterns[1].e.varName == "emp"

suite "datalog-edn.params":
  test ":in vars bind positionally to params":
    let ir = parseQ("[:find ?name :in $ ?email :where [?e :person/email ?email] [?e :person/name ?name]]")
    check ir.patterns.len == 2
    # the email pattern's v slot is a param (positional 1)
    let emailPat = ir.patterns[0]
    check emailPat.v.kind == dsConst
    check emailPat.v.constVal.kind == bvParam
    check emailPat.v.constVal.paramIdx == 1

suite "datalog-edn.ranges":
  test "range predicate on a var":
    let ir = parseQ("[:find ?name :where [?e :fin/price ?p] [(> ?p 5)] [?e :fin/name ?name]]")
    check ir.rangeBounds.hasKey("p")
    check ir.rangeBounds["p"][0].len == 1
    check ir.rangeBounds["p"][0][0][0] == ">"
    check ir.rangeBounds["p"][0][0][1].kind == bvInt
    check ir.rangeBounds["p"][0][0][1].ival == 5

  test "multiple predicates on the same var are AND":
    let ir = parseQ("[:find ?name :where [?e :fin/price ?p] [(> ?p 5)] [(< ?p 100)] [?e :fin/name ?name]]")
    check ir.rangeBounds["p"][0].len == 2

  test "or creates branches":
    let ir = parseQ("[:find ?name :where [?e :fin/price ?p] [(or [(> ?p 5)] [(< ?p 0)])] [?e :fin/name ?name]]")
    check ir.rangeBounds["p"].len == 2
    check ir.rangeBounds["p"][0][0][0] == ">"
    check ir.rangeBounds["p"][1][0][0] == "<"

  test "param in predicate":
    let ir = parseQ("[:find ?name :in $ ?lim :where [?e :fin/price ?p] [(> ?p ?lim)] [?e :fin/name ?name]]")
    check ir.rangeBounds["p"][0][0][1].kind == bvParam
    check ir.rangeBounds["p"][0][0][1].paramIdx == 1

  test ":history sets the flag":
    let ir = parseQ("[:find ?name :where [?e :person/name ?name] :history]")
    check ir.history

suite "datalog-edn.errors":
  test "non-namespaced attr keyword rejected":
    expect DatalogSyntaxError:
      discard parseQ("[:find ?v :where [?e name ?v]]")
  test "unsupported op rejected":
    expect DatalogSyntaxError:
      discard parseQ("[:find ?v :where [?e :a/b ?v] [(:?? ?v 1)]]")
  test "missing :find rejected":
    expect DatalogSyntaxError:
      discard parseQ("[:where [?e :a/b ?v]]")
  test "not a vector rejected":
    expect DatalogSyntaxError:
      discard parseQ("[:find ?v :where {:e :a/b}]")
  test "unbound var in value position rejected":
    expect DatalogSyntaxError:
      discard parseQ("[:find ?v :where [?e :a/b ?v] [(> ?other 5)]]")
