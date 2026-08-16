## wire.nim — Tagged AST transport encoding for SExpr.
##
## Encodes/decodes SExpr trees as 2-element tagged JSON arrays
## (`[tag, value]`) suitable for msgpack transport via msgpack2json.
## The tag preserves distinctions plain JSON cannot express:
## symbol × string, int64 × float64, and raw bytes.
##
## Tag table (see docs/scheme-transport.md §3.3):
##   0 = int, 1 = float, 2 = str, 3 = symbol, 4 = bool,
##   5 = bytes, 6 = void, 7 = list

import std/[json, strutils]
import scheme

type
  WireError* = object of CatchableError

const
  tagInt = 0
  tagFloat = 1
  tagStr = 2
  tagSymbol = 3
  tagBool = 4
  tagBytes = 5
  tagVoid = 6
  tagList = 7

proc sexprToWire*(e: SExpr): JsonNode =
  case e.kind
  of sInt:    %*[tagInt, e.ival]
  of sFloat:  %*[tagFloat, e.fval]
  of sStr:    %*[tagStr, e.sval]
  of sSymbol: %*[tagSymbol, e.symval]
  of sBool:   %*[tagBool, e.bval]
  of sBytes:
    var arr = newJArray()
    for b in e.bytesval: arr.add(%b)
    %*[tagBytes, arr]
  of sVoid:   %*[tagVoid, newJNull()]
  of sList:
    var arr = newJArray()
    for item in e.items: arr.add(sexprToWire(item))
    %*[tagList, arr]
  of sResource:
    raise newException(WireError, "cannot encode sResource on the wire")

proc expectArr(n: JsonNode; what: string): JsonNode =
  if n.kind != JArray:
    raise newException(WireError, "wire node for " & what & " must be an array, got " & $n.kind)
  result = n

proc wireToSexpr*(n: JsonNode): SExpr =
  let arr = expectArr(n, "node")
  if arr.len != 2:
    raise newException(WireError, "wire node must be [tag, value], got " & $arr.len & " elements")
  if arr[0].kind != JInt:
    raise newException(WireError, "wire tag must be an int, got " & $arr[0].kind)
  let tag = arr[0].getInt
  let v = arr[1]
  case tag
  of tagInt:
    if v.kind != JInt: raise newException(WireError, "tag 0 (int) value must be a number")
    newInt(v.getInt)
  of tagFloat:
    if v.kind notin {JInt, JFloat}: raise newException(WireError, "tag 1 (float) value must be a number")
    newFloat(v.getFloat)
  of tagStr:
    if v.kind != JString: raise newException(WireError, "tag 2 (str) value must be a string")
    newStr(v.getStr)
  of tagSymbol:
    if v.kind != JString: raise newException(WireError, "tag 3 (symbol) value must be a string")
    newSymbol(v.getStr)
  of tagBool:
    if v.kind != JBool: raise newException(WireError, "tag 4 (bool) value must be a bool")
    newBool(v.getBool)
  of tagBytes:
    let barr = expectArr(v, "bytes value")
    var bs: seq[byte]
    for b in barr:
      if b.kind != JInt: raise newException(WireError, "bytes array items must be ints")
      let i = b.getInt
      if i < 0 or i > 255: raise newException(WireError, "bytes array item out of range: " & $i)
      bs.add(byte(i))
    newBytes(bs)
  of tagVoid: newVoid()
  of tagList:
    let larr = expectArr(v, "list value")
    var items: seq[SExpr]
    for item in larr: items.add(wireToSexpr(item))
    newList(items)
  else:
    raise newException(WireError, "unknown wire tag: " & $tag)
