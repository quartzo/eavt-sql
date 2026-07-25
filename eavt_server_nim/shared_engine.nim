import std/tables
import kvstore, eavt, engine

type
  SharedEngine* = ref object
    kv*: KVStore
    store*: QueryStore

proc initSharedEngine*(): SharedEngine =
  var cfg = initTable[string, string]()
  cfg["backend"] = "memory"
  let kv = newKVStore(cfg)
  let store = newQueryStore(kv)
  store.eavt.bootstrapSystemAttrs()
  SharedEngine(kv: kv, store: store)

proc close*(eng: SharedEngine) =
  eng.kv.close()
