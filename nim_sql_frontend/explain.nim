## explain.nim — EXPLAIN renderer for compiled programs.
##
## Extracted from the server's execQuery so the gateway (which owns SQL
## compilation) can render EXPLAIN locally; the data server never sees it.

import std/[strutils, sequtils]
import frontend, planner_ast
import scheme

proc renderExplain*(compiled: CompileResult): string =
  result = ""
  if compiled.iterPlans.len > 0:
    result.add("Plan:\n")
    let histTag = if compiled.history: " (history)" else: ""
    let existsTag = if compiled.existsMode: " (exists)" else: ""
    result.add("  Join order: [" & compiled.orderedVars.join(", ") & "]" & histTag & existsTag & "\n")
    for i, ip in compiled.iterPlans:
      result.add("  p" & $i & " @ " & ip.indexName & "\n")
      for posIdx, pos in ip.idxOrder:
        let spec = ip.specs[posIdx]
        var varLabel = ""
        for (d, p) in ip.varDepths:
          if p == pos:
            varLabel = " [depth " & $d & "]"
            break
        case spec.kind
        of skVar:
          result.add("    " & pos & " = ?" & spec.varName & varLabel & "\n")
        of skBound:
          if spec.boundVal != 0:
            result.add("    " & pos & " = #" & $spec.boundVal & varLabel & "\n")
          else:
            result.add("    " & pos & " = _" & varLabel & "\n")
        of skBoundAttr:
          result.add("    " & pos & " = attr(id=" & $spec.attrId & ")" & varLabel & "\n")
        of skBoundValue:
          if spec.bvStr != "":
            result.add("    " & pos & " = \"" & spec.bvStr & "\"" & varLabel & "\n")
          elif spec.bvFloat != 0:
            result.add("    " & pos & " = " & $spec.bvFloat & varLabel & "\n")
          else:
            result.add("    " & pos & " = " & $spec.bvInt & varLabel & "\n")
        of skBoundParam:
          result.add("    " & pos & " = %" & $spec.paramIdx & varLabel & "\n")
        of skBoundExpr:
          result.add("    " & pos & " = expr(" & spec.bvExprRepr & ")" & varLabel & "\n")
    result.add("\n")
  for t in compiled.traces:
    result.add($t & "\n")
  result.add("\n" & writeSchemePretty(compiled.program))
