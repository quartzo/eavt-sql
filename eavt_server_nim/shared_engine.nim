import std/tables
import kvstore, eavt, engine

type
  SharedEngine* = ref object
    kv*: KVStore
    store*: QueryStore

proc initSharedEngine*(cfg: Table[string, string] = initTable[string, string]()): SharedEngine =
  var c = cfg
  if not c.hasKey("backend"):
    c["backend"] = "memory"
  let kv = newKVStore(c)
  let store = newQueryStore(kv)
  store.eavt.bootstrapSystemAttrs()
  SharedEngine(kv: kv, store: store)

proc close*(eng: SharedEngine) =
  eng.kv.close()
