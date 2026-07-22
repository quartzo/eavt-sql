## pynim_query.nim — nimpy bridge: full QueryEngine for Python.
##
## Replaces spier-eavt-query-py (Rust PyO3).
## Native Nim for storage ops; Rust PyO3 delegate for SQL compilation.
##
## Build:
##   nim c --mm:arc --threads:on -d:release --noNimblePath \
##     --path:nim-blobstore --path:nim-page-store --path:. --path:<nimpy_dir> \
##     --passL:-lcrypto --passL:-lzstd --app:lib \
##     -o:pynim_query.so nim-page-store/query/pynim_query.nim

import nimpy
import std/[options, strutils, tables]

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all

import resolver
import transactor
import abi
import eavt
import keys
import scheme

# ═══════════════════════════════════════════════════════════════════════════════
# Engine object — holds native Nim store + optional Rust delegate
# ═══════════════════════════════════════════════════════════════════════════════

type
  PyEngine = ref object
    kv: NimKVStoreVtablePtr
    eavt: EavtEngine
    pathStr: string
    rustEngine: PyObject   # nil if no Rust delegate needed

# ═══════════════════════════════════════════════════════════════════════════════
# Value conversion: Python → Nim string (for EAVT storage)
# ═══════════════════════════════════════════════════════════════════════════════

proc pyToStorage(v: PyObject): string =
  ## Convert Python value to string for EAVT storage.
  if v.isNone().to(bool): return ""
  # Try numeric first, then string
  var valInt: int64
  var valFloat: float64
  try:
    valInt = v.to(int64)
    return $valInt
  except: discard
  try:
    valFloat = v.to(float64)
    return $valFloat
  except: discard
  result = v.to(string)

# ═══════════════════════════════════════════════════════════════════════════════
# Open engine
# ═══════════════════════════════════════════════════════════════════════════════

var gRustModule {.threadvar.}: PyObject

proc getRustModule(): PyObject =
  if gRustModule.isNil():
    gRustModule = pyImport("spier_eavt_query_py")
  gRustModule

proc createEngine(config: PyObject): PyEngine {.exportpy: "new".} =
  # Parse Python dict → Nim Table, then → CStringArr for openKvStore
  var pairs: seq[(string, string)] = @[]
  if not config.isNone().to(bool):
    let dictKeys = config.callMethod("keys")
    let numKeys = dictKeys.callMethod("__len__").to(int).int
    for i in 0..<numKeys:
      let k = dictKeys[i].to(string)
      let v = config.callMethod("get", k, "").to(string)
      pairs.add (k, v)

  let n = pairs.len
  var keys = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var vals = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  for i, (k, v) in pairs:
    keys[i] = k.cstring
    vals[i] = v.cstring
  var err: cint
  let kvHandle = openKvStore(keys, vals, n.cint, addr err)
  deallocShared(keys)
  deallocShared(vals)

  if kvHandle == nil:
    raise newException(ValueError, "failed to open KVStore")

  let eavtEng = newEavtEngine(kvHandle)
  eavtEng.bootstrapResolver()

  # Lazy Rust engine — nil until first SQL compilation
  PyEngine(
    kv: kvHandle, eavt: eavtEng,
    pathStr: "db",
    rustEngine: nil,
  )

# ═══════════════════════════════════════════════════════════════════════════════
# Native Nim — storage ops (no Rust delegate)
# ═══════════════════════════════════════════════════════════════════════════════

proc close*(eng: PyEngine) {.exportpy: "close".} =
  discard eng.kv.close(eng.kv.handle, nil)

proc path*(eng: PyEngine): string {.exportpy: "path".} = eng.pathStr

proc flush*(eng: PyEngine) {.exportpy: "flush".} =
  discard eng.kv.flush(eng.kv.handle, nil)

# ── DML ──

proc save*(eng: PyEngine; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "save".} =
  let valStr = pyToStorage(v)
  discard eng.eavt.eavtSave(e, attr, valStr, t)

proc retract*(eng: PyEngine; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "retract".} =
  let valStr = pyToStorage(v)
  eng.eavt.eavtRetract(e, attr, valStr, t)

# ── Entities ──

proc allocateEntityId*(eng: PyEngine): uint64 {.exportpy: "allocate_entity_id".} =
  eng.eavt.allocateInPartition(PartUser)

proc allocateTx*(eng: PyEngine): uint64 {.exportpy: "allocate_tx".} = 0

proc allocateInPartition*(eng: PyEngine; partitionId: uint64): uint64 {.exportpy: "allocate_in_partition".} =
  eng.eavt.allocateInPartition(partitionId)

proc defaultUserPartition*(eng: PyEngine): uint64 {.exportpy: "default_user_partition".} = PartUser

# ── Schema ──

proc parseValueType(name: string): uint32 =
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

proc declareAttr*(eng: PyEngine; name: string; valueType: string; many: bool): uint32 {.exportpy: "declare_attr".} =
  let vt = parseValueType(valueType)
  eng.eavt.eavtDeclareAttr(name, vt, many)[0]

proc declareAttrFromSql*(eng: PyEngine; attr: string; typeName: string;
    many: bool; unique: bool) {.exportpy: "declare_attr_from_sql".} =
  let vt = parseValueType(typeName)
  discard eng.eavt.eavtDeclareAttr(attr, vt, many)

proc lookupAttr*(eng: PyEngine; name: string): Option[uint32] {.exportpy: "lookup_attr".} =
  eng.eavt.lookupAttr(name)

proc attrName*(eng: PyEngine; aid: uint32): string {.exportpy: "attr_name".} =
  eng.eavt.attrName(aid)

proc isDeclared*(eng: PyEngine; aid: uint32): bool {.exportpy: "is_declared".} =
  eng.eavt.isDeclared(aid)

proc valueTypeFor*(eng: PyEngine; aid: uint32): Option[uint32] {.exportpy: "value_type_for".} =
  eng.eavt.valueTypeFor(aid)

proc isMany*(eng: PyEngine; aid: uint32): bool {.exportpy: "is_many".} =
  eng.eavt.isMany(aid)

proc isUniqueAttr*(eng: PyEngine; name: string): bool {.exportpy: "is_unique_attr".} = false

proc declarePartition*(eng: PyEngine; name: string): uint64 {.exportpy: "declare_partition".} =
  eng.eavt.declarePartition(name)

proc partitionIdFor*(eng: PyEngine; name: string): Option[uint64] {.exportpy: "partition_id_for".} =
  eng.eavt.partitionIdFor(name)

proc isUnique*(eng: PyEngine; aid: uint32): bool {.exportpy: "is_unique".} = false

proc lookupEntity*(eng: PyEngine; attrName: string; value: PyObject): Option[uint64] {.exportpy: "lookup_entity".} =
  let vstr = pyToStorage(value)
  let vt = eng.eavt.lookupAttr(attrName)
  if vt.isNone: return none[uint64]()
  let aid = vt.get
  let mode = valueTypeToEncodeMode(aid)
  let encoded = encodeValue(vstr, mode, 0)
  var prefix: seq[byte] = @[]
  let aBytes = cast[array[4, byte]](aid)
  for i in 0..3: prefix.add aBytes[i]
  prefix.add encoded
  let scanRes = eng.eavt.scan(1'u32, prefix)
  if scanRes.len > 0: some(beUint64(scanRes[0], 4))
  else: none[uint64]()

# ── Admin ──

proc internalStatus*(eng: PyEngine; target: string): string {.exportpy: "internal_status".} = "{}"

proc memtableSize*(eng: PyEngine): uint64 {.exportpy: "memtable_size".} =
  var sz: uint64 = 0; var err: cint
  discard eng.kv.memtableSize(eng.kv.handle, addr sz, addr err)
  sz

proc memtableCount*(eng: PyEngine; cf: uint32): uint64 {.exportpy: "memtable_count".} = 0
proc journalSize*(eng: PyEngine): uint64 {.exportpy: "journal_size".} = 0
proc cfStats*(eng: PyEngine; cf: uint32): string {.exportpy: "cf_stats".} = ""
proc dbStats*(eng: PyEngine): string {.exportpy: "db_stats".} = ""
proc gcFull*(eng: PyEngine; dryRun: bool; nowait: bool): string {.exportpy: "gc_full".} = ""

proc scanDatoms*(eng: PyEngine; asOfUs: uint64): string {.exportpy: "scan_datoms".} =
  let scanRes = eng.eavt.scan(0'u32, @[])
  result = ""
  for k in scanRes:
    for b in k: result.add char(b)

# ═══════════════════════════════════════════════════════════════════════════════
# SQL / VM — delegate to Rust PyO3 (compiler not yet ported)
# ═══════════════════════════════════════════════════════════════════════════════

proc ensureRust(eng: PyEngine): PyObject =
  if eng.rustEngine == nil:
    try:
      let pymod = getRustModule()
      eng.rustEngine = pymod.callMethod("Engine", pyDict())
    except:
      discard
  eng.rustEngine

proc compileSql*(eng: PyEngine; sql: string; params: string): PyObject {.exportpy: "compile_sql".} =
  let re = ensureRust(eng)
  re.callMethod("compile_sql", sql, params)

proc explain*(eng: PyEngine; sql: string; params: string): string {.exportpy: "explain".} =
  let re = ensureRust(eng)
  re.callMethod("explain", sql, params).to(string)

proc compileSqlJson*(eng: PyEngine; sql: string; params: string): string {.exportpy: "compile_sql_json".} =
  let re = ensureRust(eng)
  re.callMethod("compile_sql_json", sql, params).to(string)

proc runVm*(eng: PyEngine; prog: PyObject; params: string;
    limit: uint64; asOfUs: uint64): string {.exportpy: "run_vm".} =
  let re = ensureRust(eng)
  re.callMethod("run_vm", prog, params, limit, asOfUs).to(string)

proc runVmCursor*(eng: PyEngine; prog: PyObject; params: string;
    limit: uint64; asOfUs: uint64): PyObject {.exportpy: "run_vm_cursor".} =
  let re = ensureRust(eng)
  re.callMethod("run_vm_cursor", prog, params, limit, asOfUs)

proc sessionNextBatch*(eng: PyEngine; session: PyObject; maxRows: uint64): string {.exportpy: "session_next_batch".} =
  let re = ensureRust(eng)
  re.callMethod("session_next_batch", session, maxRows).to(string)

proc compileScheme*(eng: PyEngine; schemeText: string): PyObject {.exportpy: "compile_scheme".} =
  let re = ensureRust(eng)
  re.callMethod("compile_scheme", schemeText)

proc compileSchemeDml*(eng: PyEngine; schemeText: string): PyObject {.exportpy: "compile_scheme_dml".} =
  let re = ensureRust(eng)
  re.callMethod("compile_scheme_dml", schemeText)

proc compileSchemeDebug*(eng: PyEngine; schemeText: string): seq[string] {.exportpy: "compile_scheme_debug".} =
  let re = ensureRust(eng)
  let rows = re.callMethod("compile_scheme_debug", schemeText)
  result = @[]
  let n = rows.callMethod("__len__").to(int)
  for i in 0..<n: result.add rows[i].to(string)
