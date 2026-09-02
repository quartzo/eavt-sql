## test_golden_tx.nim — Golden tests: the SQL-compiled Scheme program and the
## EDN tx interpreter produce the SAME final datoms (docs/tx-protocol.md F4
## acceptance: "golden tests SQL↔EDN (same final datoms via both paths)").

import std/[unittest, options, tables, algorithm, strutils, sequtils]
import scheme, hostfns, engine, edn_tx, kvstore, edn, resolver, keys, eavt
import compiler

proc newMemoryKVStore(): KVStore = newTempFileKVStore()

proc dumpUserDatoms(q: QueryStore): seq[(int64, string, string)] =
  ## (eid, attrName, value-as-string) for all active user datoms, sorted.
  let ks = q.eavt.scanPrefix(0, @[])
  for k in ks:
    if k.len < 24: continue
    let eid = decodeEid(beUint64(k, 0))
    let aid = beUint32(k, 8)
    let name = q.eavt.attrName(aid)
    if name.startsWith("db/"): continue
    let vt = q.eavt.valueTypeFor(aid).get(resolver.DbTypeString)
    let v = decodeStoredValue(k[12 ..< k.len - 8], vt)
    result.add (eid, name, $v)
  result.sort(proc (a, b: (int64, string, string)): int = system.cmp(a[2], b[2]))

