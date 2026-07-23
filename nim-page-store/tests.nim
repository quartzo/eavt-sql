## tests.nim — Unit tests for nim-page-store.

import std/[unittest, options, tables, strutils, math, os, times]
import memory/all
import abi
import pages
import page_store
import page_cursor

proc makeConfig(t: Table[string, string]): tuple[keys: CStringArr, vals: CStringArr, count: cint] =
  let n = t.len
  result.keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  result.vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var i = 0
  for k, v in t.pairs:
    result.keys[i] = k.cstring
    result.vals[i] = v.cstring
    inc i
  result.count = n.cint

proc freeConfig(cfg: tuple[keys: CStringArr, vals: CStringArr, count: cint]) =
  deallocShared(cfg.keys)
  deallocShared(cfg.vals)


