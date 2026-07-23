## pynim_query.nim — nimpy bridge: full QueryEngine for Python.
##
## Replaces spier-eavt-query-py (Rust PyO3).
## Native Nim for storage ops; Rust PyO3 delegate for SQL compilation.
##
## Build:
##   nim c --mm:arc --threads:on -d:release --noNimblePath \
##     --path:nim_blobstore --path:nim_kvstore --path:. --path:<nimpy_dir> \
##     --passL:-lcrypto --passL:-lzstd --app:lib \
##     -o:pynim_query.so nim_kvstore/query/pynim_query.nim

import nimpy
import nimpy/nim_py_marshalling  # newPyNone
import nimpy/py_types             # PPyObject, Py_ssize_t
import std/[options, strutils, tables, dynlib]

import memory/all
import file/all
import s3/all
import journal/all
import nim_memtable/all

import resolver
import kvstore
import abi
import eavt
import keys
import scheme
import engine   # query/engine.nim: QueryStore, QuerySession, StreamingSession
import hostfns  # EngineOps (base for method dispatch)
import codec    # query/codec.nim: wire value codec

# ═══════════════════════════════════════════════════════════════════════════════
# Engine object — holds native Nim store + optional Rust delegate
# ═══════════════════════════════════════════════════════════════════════════════

type
  PyEngine = ref object
    kv: KVStore              # Nim ref — no C-ABI
    eavt: EavtEngine
    store: QueryStore       # VM engine ops over the SAME EavtEngine
    pathStr: string
    rustEngine: PyObject   # nil if no Rust delegate needed

  PyProgram = ref object
    prog: SchemeProgram
    isSelect: bool          # SELECT/UPDATE-scan/DELETE-scan vs DML

  PySession = ref object
    isSelect: bool
    ss: StreamingSession    # select programs (yield/resume)
    qs: QuerySession        # dml programs (batch-once, Rust SchemeSession semantics)
    dmlDone: bool

# ═══════════════════════════════════════════════════════════════════════════════
# Value conversion: Python → Nim string (for EAVT storage)
# ═══════════════════════════════════════════════════════════════════════════════
#
# LANDMINE (nimpy 0.2.1): never `callMethod` (or `.()`) a Python attribute
# that may not exist. callMethodAux re-raises ValueError while CPython's
# error indicator is still set; nimpy's pythonException bridge then calls
# PyErr_NewException with a pending error → NULL → decRef(NULL) → SIGSEGV.
# (Plain getattr failure is safe: raisePythonError does PyErr_Fetch, which
# clears the indicator, so the exception bridge survives.)

proc isPyNone(o: PyObject): bool =
  ## None-check without probing Python attrs (see LANDMINE above).
  var noneObj: PyObject
  pyValueToNim(newPyNone(), noneObj)
  o == noneObj

# ── Binary boundary ──
# nimpy's string→Py conversion ("s#") yields `str` whenever the payload is
# valid UTF-8 — which corrupts binary wire formats by pure chance. And the
# seq[byte]→bytes overload in nim_py_marshalling references a non-existent
# pyLib symbol, so it doesn't compile. Define our own: a real Python `bytes`.
type PyBytesCtor = proc(s: ptr char, len: Py_ssize_t): PPyObject {.cdecl.}
var gPyBytesCtor {.global.}: PyBytesCtor

proc pyBytesFromStringAndSize(s: ptr char, len: Py_ssize_t): PPyObject =
  ## CPython PyBytes_FromStringAndSize, resolved from the host process
  ## (global symbol scope — same trick nimpy uses for libpython).
  if gPyBytesCtor.isNil:
    gPyBytesCtor = cast[PyBytesCtor](loadLib().symAddr("PyBytes_FromStringAndSize"))
    if gPyBytesCtor.isNil:
      raise newException(ValueError, "PyBytes_FromStringAndSize not found")
  gPyBytesCtor(s, len)

proc nimValueToPy*(v: seq[byte]): PPyObject =
  if v.len == 0:
    pyBytesFromStringAndSize(nil, 0)
  else:
    pyBytesFromStringAndSize(cast[ptr char](unsafeAddr v[0]), v.len.Py_ssize_t)

proc nimValueToPy*[T](v: Option[T]): PPyObject =
  ## nimpy's default Option conversion produces a {'has','val'} dict, which
  ## breaks the Python API contract (callers expect the value or None).
  if v.isSome: nimValueToPy(v.get)
  else: newPyNone()

proc pyToStorage(v: PyObject): string =
  ## Convert Python value to string for EAVT storage.
  if isPyNone(v): return ""
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
  var pairs = newSeq[(string, string)]()
  if not isPyNone(config):
    # Iterate the dict directly (yields keys). Do NOT route through
    # pyBuiltins(): PyEval_GetBuiltins returns a *dict*, and dicts have no
    # "list" method → callMethod fails → SIGSEGV (see LANDMINE above).
    for k in config:
      let ks = k.to(string)
      pairs.add (ks, config[k].to(string))

  let n = pairs.len
  var keysA = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  var valsA = cast[CStringArr](allocShared0(n * sizeof(cstring)))
  for i, (k, v) in pairs:
    keysA[i] = k.cstring
    valsA[i] = v.cstring
  var err: cint
  let kv = newKVStore(keysA, valsA, n.cint, addr err)
  deallocShared(keysA)
  deallocShared(valsA)

  if kv == nil:
    raise newException(ValueError, "failed to open KVStore")

  let eavtEng = newEavtEngine(kv)
  eavtEng.bootstrapResolver()

  PyEngine(
    kv: kv, eavt: eavtEng,
    store: newQueryStore(kv),
    pathStr: "db",
    rustEngine: nil,
  )

# ═══════════════════════════════════════════════════════════════════════════════
# Native Nim — storage ops (no Rust delegate)
# ═══════════════════════════════════════════════════════════════════════════════

proc close*(eng: PyEngine) {.exportpy: "close".} =
  eng.kv.close()

proc path*(eng: PyEngine): string {.exportpy: "path".} = eng.pathStr

proc flush*(eng: PyEngine) {.exportpy: "flush".} =
  eng.kv.flush()

# ── DML ──

proc save*(eng: PyEngine; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "save".} =
  let valStr = pyToStorage(v)
  discard eng.eavt.eavtSave(e, attr, valStr, t)

proc retract*(eng: PyEngine; e: uint64; attr: string; v: PyObject; t: uint64) {.exportpy: "retract".} =
  let valStr = pyToStorage(v)
  eng.eavt.eavtRetract(e, attr, valStr, t)

# ── Entities ──

proc allocateEntityId*(eng: PyEngine): int64 {.exportpy: "allocate_entity_id".} =
  eng.eavt.allocateInPartition(PartUser)

proc allocateTx*(eng: PyEngine): uint64 {.exportpy: "allocate_tx".} = 0

proc allocateInPartition*(eng: PyEngine; partitionId: uint64): int64 {.exportpy: "allocate_in_partition".} =
  eng.eavt.allocateInPartition(partitionId)

proc defaultUserPartition*(eng: PyEngine): uint64 {.exportpy: "default_user_partition".} = PartUser

# ── Schema ──

proc vtToName(vt: uint32): string =
  case vt
  of DbTypeRef: "REF"
  of DbTypeLong: "LONG"
  of DbTypeKeyword: "KEYWORD"
  of DbTypeBoolean: "BOOLEAN"
  of DbTypeInstant: "INSTANT"
  of DbTypeBytes: "BYTES"
  of DbTypeBlob: "BLOB"
  of DbTypeFloat: "FLOAT"
  else: "STRING"

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

proc valueTypeFor*(eng: PyEngine; aid: uint32): Option[string] {.exportpy: "value_type_for".} =
  let r = eng.eavt.valueTypeFor(aid)
  if r.isNone: return none[string]()
  some(vtToName(r.get))

proc isMany*(eng: PyEngine; aid: uint32): bool {.exportpy: "is_many".} =
  eng.eavt.isMany(aid)

proc isUniqueAttr*(eng: PyEngine; name: string): bool {.exportpy: "is_unique_attr".} =
  let aid = eng.eavt.lookupAttr(name)
  aid.isSome and eng.eavt.isUnique(aid.get)

proc declarePartition*(eng: PyEngine; name: string): uint64 {.exportpy: "declare_partition".} =
  eng.eavt.declarePartition(name)

proc partitionIdFor*(eng: PyEngine; name: string): Option[uint64] {.exportpy: "partition_id_for".} =
  eng.eavt.partitionIdFor(name)

proc isUnique*(eng: PyEngine; aid: uint32): bool {.exportpy: "is_unique".} =
  eng.eavt.isUnique(aid)

proc lookupEntity*(eng: PyEngine; attrName: string; value: PyObject): Option[uint64] {.exportpy: "lookup_entity".} =
  let vstr = pyToStorage(value)
  EngineOps(eng.store).lookupEntity(attrName, SExpr(kind: sStr, sval: vstr))

# ── Admin ──

proc internalStatus*(eng: PyEngine; target: string): string {.exportpy: "internal_status".} = "{}"

proc memtableSize*(eng: PyEngine): uint64 {.exportpy: "memtable_size".} =
  eng.kv.memtableSize()

proc memtableCount*(eng: PyEngine; cf: uint32): uint64 {.exportpy: "memtable_count".} = 0
proc journalSize*(eng: PyEngine): uint64 {.exportpy: "journal_size".} = 0
proc cfStats*(eng: PyEngine; cf: uint32): string {.exportpy: "cf_stats".} = ""
proc dbStats*(eng: PyEngine): string {.exportpy: "db_stats".} = ""
proc gcFull*(eng: PyEngine; dryRun: bool; nowait: bool): string {.exportpy: "gc_full".} = ""

proc scanDatoms*(eng: PyEngine; asOfUs: uint64): seq[byte] {.exportpy: "scan_datoms".} =
  let scanRes = eng.eavt.scan(0'u32, @[])
  result = @[]
  for k in scanRes:
    for b in k: result.add b

# ═══════════════════════════════════════════════════════════════════════════════
# SQL / VM — Scheme text boundary.
#
# Rust keeps ONLY SQL→Scheme compilation (compile_sql_json / explain). The
# compiled program crosses as Scheme source text; everything else — parsing,
# evaluation, scanning, sessions — is native Nim (query/engine.nim).
# ═══════════════════════════════════════════════════════════════════════════════

proc ensureRust(eng: PyEngine): PyObject =
  if eng.rustEngine == nil:
    try:
      let pymod = getRustModule()
      eng.rustEngine = pymod.callMethod("Engine", pyDict())
    except:
      discard
  eng.rustEngine

proc syncSchemaToRust(eng: PyEngine) =
  ## Replay the Nim resolver's declarations into the Rust compiler engine.
  ## Both resolvers assign ids from the same bootstrap constants, so
  ## replaying in declaration order yields IDENTICAL aid/partition ids —
  ## which the compiled Scheme bakes in as numeric literals.
  let re = ensureRust(eng)
  if re == nil: return
  for name in eng.eavt.resolver.partDeclOrder:
    discard re.callMethod("declare_partition", name)
  for name in eng.eavt.resolver.attrDeclOrder:
    let aid = eng.eavt.lookupAttr(name)
    if aid.isNone: continue
    let vt = eng.eavt.valueTypeFor(aid.get).get(DbTypeString)
    let many = eng.eavt.isMany(aid.get)
    discard re.callMethod("declare_attr_from_sql", name, vtToName(vt), many, false)

proc explain*(eng: PyEngine; sql: string; params: PyObject): string {.exportpy: "explain".} =
  syncSchemaToRust(eng)
  let re = ensureRust(eng)
  re.callMethod("explain", sql, params).to(string)

proc compileSqlJson*(eng: PyEngine; sql: string; params: PyObject): string {.exportpy: "compile_sql_json".} =
  syncSchemaToRust(eng)
  let re = ensureRust(eng)
  re.callMethod("compile_sql_json", sql, params).to(string)

# ── Program parsing (native) ──

proc astUsesResultRow(e: SExpr): bool =
  ## The compiler emits `(result-row ...)` only for SelectScheme programs
  ## (SELECT / UPDATE-scan / DELETE-scan). This distinguishes them from DML
  ## (Program::Scheme: UPSERT, ATTRIBUTE, PARTITION, direct DELETE) without
  ## needing Rust's SelectSchemeMeta (which is unused at execution time).
  if e.kind != sList: return false
  if e.items.len > 0 and e.items[0].kind == sSymbol and
     e.items[0].symval == "result-row":
    return true
  for it in e.items:
    if astUsesResultRow(it): return true
  false

proc parseProgramText(schemeText: string): PyProgram =
  let body = scheme.parse(schemeText)
  PyProgram(prog: SchemeProgram(body: body), isSelect: astUsesResultRow(body))

proc compileScheme*(eng: PyEngine; schemeText: string): PyProgram {.exportpy: "compile_scheme".} =
  parseProgramText(schemeText)

proc compileSchemeDml*(eng: PyEngine; schemeText: string): PyProgram {.exportpy: "compile_scheme_dml".} =
  parseProgramText(schemeText)

proc compileSql*(eng: PyEngine; sql: string; params: PyObject): PyProgram {.exportpy: "compile_sql".} =
  syncSchemaToRust(eng)
  let re = ensureRust(eng)
  let schemeText = re.callMethod("compile_sql_json", sql, params).to(string)
  parseProgramText(schemeText)

# ── Sessions (native) ──

proc paramsFromPy(params: PyObject): seq[SExpr] =
  ## Python bytes → seq[SExpr] via the wire codec (query_codec compatible).
  if isPyNone(params): return @[]
  let s = params.to(string)  # pyStringToNim handles PyBytes
  var b = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr b[0], unsafeAddr s[0], s.len)
  codec.decodeParams(b)

proc newSessionFor(eng: PyEngine; prog: PyProgram; params: PyObject;
                   asOfUs: uint64): QuerySession =
  let ps = paramsFromPy(params)
  let t = eng.eavt.allocateTAndWriteTx()
  let asOfTx = eng.eavt.resolveAsOfTx(asOfUs)
  newQuerySession(eng.store, prog.prog, ps, t, asOfTx)

proc packDmlResult(res: SExpr): seq[byte] =
  ## Rust SchemeSession semantics: pack `(result v...)` as one row;
  ## anything else yields a zero-col row (skipped by decode_rows).
  result = @[]
  if res.kind == sList and res.items.len >= 2 and
     res.items[0].kind == sSymbol and res.items[0].symval == "result":
    codec.encodeRow(result, res.items[1..^1])
  else:
    codec.encodeRow(result, [])

proc runVm*(eng: PyEngine; prog: PyProgram; params: PyObject;
    limit: uint64; asOfUs: uint64): seq[byte] {.exportpy: "run_vm".} =
  ## Batch execution (Rust execute()): DML → single result row; SELECT →
  ## drain the streaming session fully (next_batch with usize::MAX).
  let qs = newSessionFor(eng, prog, params, asOfUs)
  result = @[]
  if prog.isSelect:
    let ss = newStreamingSession(qs)
    var more = true
    while more:
      let (rows, m) = ss.nextBatch(1024)
      for row in rows: codec.encodeRow(result, row)
      more = m
  else:
    result = packDmlResult(qs.executeProgram())

proc runVmCursor*(eng: PyEngine; prog: PyProgram; params: PyObject;
    limit: uint64; asOfUs: uint64): PySession {.exportpy: "run_vm_cursor".} =
  let qs = newSessionFor(eng, prog, params, asOfUs)
  if prog.isSelect:
    PySession(isSelect: true, ss: newStreamingSession(qs))
  else:
    PySession(isSelect: false, qs: qs, dmlDone: false)

proc sessionNextBatch*(eng: PyEngine; session: PySession; maxRows: uint64): seq[byte] {.exportpy: "session_next_batch".} =
  result = @[]
  if session.isSelect:
    let mr = if maxRows > uint64(int32.high): int32.high.int else: maxRows.int
    let (rows, _) = session.ss.nextBatch(mr)
    for row in rows: codec.encodeRow(result, row)
  else:
    if session.dmlDone: return
    session.dmlDone = true
    result = packDmlResult(session.qs.executeProgram())

proc compileSchemeDebug*(eng: PyEngine; schemeText: string): seq[string] {.exportpy: "compile_scheme_debug".} =
  let re = ensureRust(eng)
  let rows = re.callMethod("compile_scheme_debug", schemeText)
  result = @[]
  let n = rows.callMethod("__len__").to(int)
  for i in 0..<n: result.add rows[i].to(string)
