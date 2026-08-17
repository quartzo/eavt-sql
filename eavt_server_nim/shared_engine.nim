import std/tables
import kvstore, eavt, engine

type
  SharedEngine* = ref object
    kv*: KVStore
    store*: QueryStore

proc initSharedEngine*(cfg: Table[string, string]): SharedEngine =
  ## cfg must carry backend (file|s3) and a local path (WAL/journal).
  let kv = newKVStore(cfg)
  if kv == nil:
    raise newException(IOError, "cannot open store at " & cfg.getOrDefault("path", ""))
  let store = newQueryStore(kv)
  store.eavt.bootstrapSystemAttrs()
  SharedEngine(kv: kv, store: store)

proc close*(eng: SharedEngine) =
  eng.kv.close()
