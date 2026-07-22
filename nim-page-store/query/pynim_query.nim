## pynim_query.nim — nimpy bridge: full QueryEngine for Python.
##
## Replaces spier-eavt-query-py (Rust PyO3).
## Currently delegates to spier_eavt_query_py internally.
##
## Build:
##   nim c --mm:arc --threads:on -d:release --noNimblePath \
##     --path:<nimpy_dir> --app:lib \
##     -o:pynim_query.so nim-page-store/query/pynim_query.nim

import nimpy
import std/[options, strutils, tables]

type
  PyEngineObj = ref object
    inner: PyObject
    engineId: string

var gRustModule {.threadvar.}: PyObject

proc getRustModule(): PyObject =
  if gRustModule.isNil():
    gRustModule = pyImport("spier_eavt_query_py")
  gRustModule

proc createEngine(config: PyObject): PyEngineObj {.exportpy: "new".} =
  let pymod = getRustModule()
  let re = pymod.callMethod("Engine", config)
  PyEngineObj(inner: re, engineId: "0")

template def(fn: untyped; pyName: string; body: untyped) =
  proc fn*(eng: PyEngineObj; args: body) {.exportpy: pyName.}

# Close / path (void and string return)
proc close*(eng: PyEngineObj) {.exportpy: "close".} = discard
proc path*(eng: PyEngineObj): string {.exportpy: "path".} = eng.inner.callMethod("path").to(string)

# DML
proc save*(eng: PyEngineObj; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "save".} =
  discard eng.inner.callMethod("save", e, attr, v, t)
proc retract*(eng: PyEngineObj; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "retract".} =
  discard eng.inner.callMethod("retract", e, attr, v, t)

# Entities
proc allocateEntityId*(eng: PyEngineObj): uint64 {.exportpy: "allocate_entity_id".} =
  eng.inner.callMethod("allocate_entity_id").to(uint64)
proc allocateTx*(eng: PyEngineObj): uint64 {.exportpy: "allocate_tx".} =
  eng.inner.callMethod("allocate_tx").to(uint64)
proc allocateInPartition*(eng: PyEngineObj; partitionId: uint64): uint64 {.exportpy: "allocate_in_partition".} =
  eng.inner.callMethod("allocate_in_partition", partitionId).to(uint64)
proc defaultUserPartition*(eng: PyEngineObj): uint64 {.exportpy: "default_user_partition".} =
  eng.inner.callMethod("default_user_partition").to(uint64)

# Schema
proc declareAttr*(eng: PyEngineObj; name: string; valueType: string; many: bool): uint32 {.exportpy: "declare_attr".} =
  eng.inner.callMethod("declare_attr", name, valueType, many).to(uint32)
proc declareAttrFromSql*(eng: PyEngineObj; attr: string; typeName: string; many: bool; unique: bool) {.exportpy: "declare_attr_from_sql".} =
  discard eng.inner.callMethod("declare_attr_from_sql", attr, typeName, many, unique)
proc lookupAttr*(eng: PyEngineObj; name: string): Option[uint32] {.exportpy: "lookup_attr".} =
  let r = eng.inner.callMethod("lookup_attr", name)
  if r.isNone().to(bool): none[uint32]() else: some(r.to(uint32))
proc attrName*(eng: PyEngineObj; aid: uint32): string {.exportpy: "attr_name".} =
  eng.inner.callMethod("attr_name", aid).to(string)
proc isDeclared*(eng: PyEngineObj; aid: uint32): bool {.exportpy: "is_declared".} =
  eng.inner.callMethod("is_declared", aid).to(bool)
proc valueTypeFor*(eng: PyEngineObj; aid: uint32): Option[uint32] {.exportpy: "value_type_for".} =
  let r = eng.inner.callMethod("value_type_for", aid)
  if r.isNone().to(bool): none[uint32]() else: some(r.to(uint32))
proc isMany*(eng: PyEngineObj; aid: uint32): bool {.exportpy: "is_many".} =
  eng.inner.callMethod("is_many", aid).to(bool)
proc isUniqueAttr*(eng: PyEngineObj; name: string): bool {.exportpy: "is_unique_attr".} =
  eng.inner.callMethod("is_unique_attr", name).to(bool)
proc declarePartition*(eng: PyEngineObj; name: string): uint64 {.exportpy: "declare_partition".} =
  eng.inner.callMethod("declare_partition", name).to(uint64)
proc partitionIdFor*(eng: PyEngineObj; name: string): Option[uint64] {.exportpy: "partition_id_for".} =
  let r = eng.inner.callMethod("partition_id_for", name)
  if r.isNone().to(bool): none[uint64]() else: some(r.to(uint64))
proc isUnique*(eng: PyEngineObj; aid: uint32): bool {.exportpy: "is_unique".} =
  eng.inner.callMethod("is_unique", aid).to(bool)
proc lookupEntity*(eng: PyEngineObj; attrName: string; value: PyObject): Option[uint64] {.exportpy: "lookup_entity".} =
  let r = eng.inner.callMethod("lookup_entity", attrName, value)
  if r.isNone().to(bool): none[uint64]() else: some(r.to(uint64))

# Maintenance
proc flush*(eng: PyEngineObj) {.exportpy: "flush".} =
  discard eng.inner.callMethod("flush")
proc internalStatus*(eng: PyEngineObj; target: string): string {.exportpy: "internal_status".} =
  eng.inner.callMethod("internal_status", target).to(string)
proc memtableSize*(eng: PyEngineObj): uint64 {.exportpy: "memtable_size".} =
  eng.inner.callMethod("memtable_size").to(uint64)
proc memtableCount*(eng: PyEngineObj; cf: uint32): uint64 {.exportpy: "memtable_count".} =
  eng.inner.callMethod("memtable_count", cf).to(uint64)
proc journalSize*(eng: PyEngineObj): uint64 {.exportpy: "journal_size".} =
  eng.inner.callMethod("journal_size").to(uint64)
proc cfStats*(eng: PyEngineObj; cf: uint32): string {.exportpy: "cf_stats".} =
  eng.inner.callMethod("cf_stats", cf).to(string)
proc dbStats*(eng: PyEngineObj): string {.exportpy: "db_stats".} =
  eng.inner.callMethod("db_stats").to(string)
proc gcFull*(eng: PyEngineObj; dryRun: bool; nowait: bool): string {.exportpy: "gc_full".} =
  eng.inner.callMethod("gc_full", dryRun, nowait).to(string)

# SQL compilation
proc compileSql*(eng: PyEngineObj; sql: string; params: string): PyObject {.exportpy: "compile_sql".} =
  eng.inner.callMethod("compile_sql", sql, params)
proc explain*(eng: PyEngineObj; sql: string; params: string): string {.exportpy: "explain".} =
  eng.inner.callMethod("explain", sql, params).to(string)
proc compileSqlJson*(eng: PyEngineObj; sql: string; params: string): string {.exportpy: "compile_sql_json".} =
  eng.inner.callMethod("compile_sql_json", sql, params).to(string)

# VM execution
proc runVm*(eng: PyEngineObj; prog: PyObject; params: string; limit: uint64; asOfUs: uint64): string {.exportpy: "run_vm".} =
  eng.inner.callMethod("run_vm", prog, params, limit, asOfUs).to(string)
proc runVmCursor*(eng: PyEngineObj; prog: PyObject; params: string; limit: uint64; asOfUs: uint64): PyObject {.exportpy: "run_vm_cursor".} =
  eng.inner.callMethod("run_vm_cursor", prog, params, limit, asOfUs)
proc sessionNextBatch*(eng: PyEngineObj; session: PyObject; maxRows: uint64): string {.exportpy: "session_next_batch".} =
  eng.inner.callMethod("session_next_batch", session, maxRows).to(string)

# Scheme compilation
proc compileScheme*(eng: PyEngineObj; schemeText: string): PyObject {.exportpy: "compile_scheme".} =
  eng.inner.callMethod("compile_scheme", schemeText)
proc compileSchemeDml*(eng: PyEngineObj; schemeText: string): PyObject {.exportpy: "compile_scheme_dml".} =
  eng.inner.callMethod("compile_scheme_dml", schemeText)
proc compileSchemeDebug*(eng: PyEngineObj; schemeText: string): seq[string] {.exportpy: "compile_scheme_debug".} =
  let rows = eng.inner.callMethod("compile_scheme_debug", schemeText)
  result = @[]
  let n = rows.callMethod("__len__").to(int)
  for i in 0..<n:
    result.add rows[i].to(string)

# Scan
proc scanDatoms*(eng: PyEngineObj; asOfUs: uint64): string {.exportpy: "scan_datoms".} =
  eng.inner.callMethod("scan_datoms", asOfUs).to(string)
