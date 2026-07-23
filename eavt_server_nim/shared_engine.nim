import std/[locks, tables]
import kvstore, eavt, engine, abi

type
  SharedEngine* = ref object
    lock*: Lock
    kv*: KVStore
    eavt*: EavtEngine
    store*: QueryStore

proc initSharedEngine*(): SharedEngine =
  var tbl = initTable[string, string]()
  tbl["backend"] = "memory"
  let n = tbl.len
  var keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var i = 0
  for k, v in tbl.pairs:
    keys[i] = k.cstring
    vals[i] = v.cstring
    inc i
  var err: cint
  let kv = newKVStore(keys, vals, n.cint, addr err)
  deallocShared(keys)
  deallocShared(vals)
  let eavt = newEavtEngine(kv)
  eavt.bootstrapResolver()
  let store = newQueryStore(kv)
  result = SharedEngine(kv: kv, eavt: eavt, store: store)
  initLock(result.lock)

proc close*(eng: SharedEngine) =
  deinitLock(eng.lock)
  eng.kv.close()

proc withLock*[T](eng: SharedEngine, action: proc (): T {.closure.}): T =
  acquire(eng.lock)
  try:
    return action()
  finally:
    release(eng.lock)
