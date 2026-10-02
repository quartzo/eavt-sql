## gen_explain.nim — render EXPLAIN for a query + CompileStats file, used as
## golden vectors for the Go explain port.  Run from the repo root:
##   nim c --hints:off --warnings:off -o:build/gen_explain go/testdata/gen_explain.nim
##   ./build/gen_explain go/testdata/golden/query/qNN.q go/testdata/golden/query/sNN.stats
import std/[os]
import stats, datalog_compile, explain

let q = readFile(paramStr(1))
let s = statsFromMsgpack(readFile(paramStr(2)))
var fv: seq[string] = @[]
let c = compileDatalogQuery(q, s, fv)
stdout.write(renderExplain(c))
