## symtab.nim — symbol/keyword interning for the wire boundary.
##
## Keywords and symbols arrive as msgpack ext payloads (0x06/0x05) and are
## interned ONCE per distinct payload at decode time (Clojure's Keyword.intern
## at the reader).  After capture, identity is a uint32 compare — no strings
## on the hot path.  The reverse table exists for rare error/declare paths.
##
## The table is OWNED by the engine (SymTab ref created with the store and
## passed explicitly) — no global GC state, gcsafe by construction.  Ids are
## per-process: never persisted, never on the wire.

import std/[tables]

type SymId* = distinct uint32

proc `==`*(a, b: SymId): bool {.inline, raises: [].} = uint32(a) == uint32(b)

type SymTab* = ref object
  ## Intern table owned by the engine; single event loop.
  map: Table[string, uint32]
  names: seq[string]           # index = id - 1 (0 reserved: invalid)
  # Well-known ids (interned at construction):
  dbAdd*: SymId
  dbRetract*: SymId
  dbIdent*: SymId
  dbType*: SymId
  dbCardinality*: SymId
  dbUnique*: SymId
  dbCurrentTx*: SymId

proc newSymTab*(): SymTab =
  result = SymTab(map: initTable[string, uint32]())
  let s = result
  proc intern(payload: string): SymId =
    ## First occurrence allocates the string; later hits are probes.
    let existing = s.map.getOrDefault(payload, 0'u32)
    if existing != 0: return SymId(existing)
    let id = uint32(s.names.len + 1)
    s.map[payload] = id
    s.names.add(payload)
    SymId(id)
  s.dbAdd = intern("db/add")
  s.dbRetract = intern("db/retract")
  s.dbIdent = intern("db/ident")
  s.dbType = intern("db/valueType")
  s.dbCardinality = intern("db/cardinality")
  s.dbUnique = intern("db/unique")
  s.dbCurrentTx = intern("db/current-tx")

proc internSym*(tab: SymTab; payload: string): SymId {.raises: [].} =
  ## Intern a keyword/symbol payload (identity for its process lifetime).
  let existing = tab.map.getOrDefault(payload, 0'u32)
  if existing != 0: return SymId(existing)
  let id = uint32(tab.names.len + 1)
  tab.map[payload] = id
  tab.names.add(payload)
  SymId(id)

proc symName*(tab: SymTab; id: SymId): string {.raises: [].} =
  ## Reverse lookup for rare paths (errors, attribute declaration).
  let i = uint32(id)
  if i == 0 or int(i) > tab.names.len: return ""
  tab.names[int(i) - 1]

proc symCount*(tab: SymTab): int {.raises: [].} =
  ## Distinct symbols interned so far (monitoring).
  tab.names.len
