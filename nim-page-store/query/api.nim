## query/api.nim — C-ABI functions for the query engine.
##
## Called by Rust spier-page-store-nim/src/lib.rs.
## Each function returns 0 on success, -1 on error (writes to errOut).

import std/[options, strutils]
import ../eavt
import ../resolver
import ../keys
import ../abi
import ../transactor

# ═══════════════════════════════════════════════════════════════════════════════
# Handle type
# ═══════════════════════════════════════════════════════════════════════════════

type
  QueryHandle = object
    kv: NimKVStoreVtablePtr
    eavt: EavtEngine

# ═══════════════════════════════════════════════════════════════════════════════
# open / close
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_open*(keys, vals: CStringArr; count: cint;
                      errOut: ptr cint): pointer {.cdecl, exportc, dynlib.} =
  var cfg: seq[(string, string)] = @[]
  for i in 0..<count.int:
    cfg.add ( ($keys[i], $vals[i]) )

  let kvHandle = openKvStore(keys, vals, count, errOut)
  if kvHandle == nil:
    return nil

  let eavtEng = newEavtEngine(kvHandle)
  eavtEng.bootstrapResolver()

  var h = createShared(QueryHandle)
  h.kv = kvHandle
  h.eavt = eavtEng
  result = cast[pointer](h)

proc nim_query_close*(handle: pointer) {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  var err: cint
  discard h.kv.close(h.kv.handle, addr err)
  freeKVVtable(h.kv)
  deallocShared(h)

# ═══════════════════════════════════════════════════════════════════════════════
# save / retract
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_save*(handle: pointer; eid: uint64; attr: cstring;
                      val: cstring; t: uint64; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let attrName = $attr
  let valStr = $val
  discard h.eavt.eavtSave(eid, attrName, valStr, t)
  0

proc nim_query_retract*(handle: pointer; eid: uint64; attr: cstring;
                         val: cstring; t: uint64; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  h.eavt.eavtRetract(eid, $attr, $val, t)
  0

# ═══════════════════════════════════════════════════════════════════════════════
# flush
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_flush*(handle: pointer; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let rc = h.kv.flush(h.kv.handle, errOut)
  rc

# ═══════════════════════════════════════════════════════════════════════════════
# Schema
# ═══════════════════════════════════════════════════════════════════════════════

proc parseVtName(name: string): uint32 =
  case name.toUpperAscii()
  of "STRING":  DbTypeString
  of "REF":     DbTypeRef
  of "LONG":    DbTypeLong
  of "KEYWORD": DbTypeKeyword
  of "BOOLEAN": DbTypeBoolean
  of "INSTANT": DbTypeInstant
  of "BYTES":   DbTypeBytes
  of "BLOB":    DbTypeBlob
  of "FLOAT":   DbTypeFloat
  else: DbTypeString

proc nim_query_declare_attr*(handle: pointer; name: cstring;
    vtName: cstring; many: cint; errOut: ptr cint): uint32 {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let vt = parseVtName($vtName)
  h.eavt.eavtDeclareAttr($name, vt, many != 0)[0]

proc nim_query_lookup_attr*(handle: pointer; name: cstring;
    outAid: ptr uint32; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let r = h.eavt.lookupAttr($name)
  if r.isSome:
    outAid[] = r.get
    return 0
  return -1

proc nim_query_attr_name*(handle: pointer; aid: uint32;
    outName: ptr cstring; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let name = h.eavt.attrName(aid)
  outName[] = name.cstring  # caller must not free — points to Nim heap
  0

proc nim_query_value_type_for*(handle: pointer; aid: uint32;
    outVt: ptr uint32; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let r = h.eavt.valueTypeFor(aid)
  if r.isSome:
    outVt[] = r.get
    return 0
  -1

proc nim_query_is_declared*(handle: pointer; aid: uint32;
    errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  if h.eavt.isDeclared(aid): 1 else: 0

proc nim_query_is_many*(handle: pointer; aid: uint32;
    errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  if h.eavt.isMany(aid): 1 else: 0

# ═══════════════════════════════════════════════════════════════════════════════
# Entity allocation
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_allocate_entity*(handle: pointer; errOut: ptr cint): uint64 {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  h.eavt.allocateInPartition(PartUser)

proc nim_query_allocate_in_partition*(handle: pointer; partitionId: uint64;
    errOut: ptr cint): uint64 {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  h.eavt.allocateInPartition(partitionId)

# ═══════════════════════════════════════════════════════════════════════════════
# Declare partition
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_declare_partition*(handle: pointer; name: cstring;
    errOut: ptr cint): uint64 {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  h.eavt.declarePartition($name)

proc nim_query_partition_id_for*(handle: pointer; name: cstring;
    outPid: ptr uint64; errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  let r = h.eavt.partitionIdFor($name)
  if r.isSome:
    outPid[] = r.get
    return 0
  -1

# ═══════════════════════════════════════════════════════════════════════════════
# Admin
# ═══════════════════════════════════════════════════════════════════════════════

proc nim_query_memtable_size*(handle: pointer; errOut: ptr cint): uint64 {.cdecl, exportc, dynlib.} =
  var h = cast[ptr QueryHandle](handle)
  var sz: uint64 = 0
  discard h.kv.memtableSize(h.kv.handle, addr sz, errOut)
  sz

proc nim_query_path*(handle: pointer; outPath: ptr cstring;
    errOut: ptr cint): cint {.cdecl, exportc, dynlib.} =
  outPath[] = "nim".cstring
  0
