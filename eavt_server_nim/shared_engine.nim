import std/[locks, tables]
import kvstore, eavt, engine

type
  SharedEngine* = ref object
    lock*: Lock
    kv*: KVStore
    store*: QueryStore

proc initSharedEngine*(): SharedEngine =
  var cfg = initTable[string, string]()
  cfg["backend"] = "memory"
  let kv = newKVStore(cfg)
  let store = newQueryStore(kv)
  result = SharedEngine(kv: kv, store: store)
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
