# Scheme Transport — SQL → Scheme at the Gateway

## 1. Overview

Today every client sends raw SQL text (`{"type": "sql"}`) to a single server that
parses, plans, compiles to Scheme, and executes. This document specifies the new
architecture: **SQL is compiled to Scheme in a query server process, and the transactor
becomes a pure Scheme execution engine.**

### Motivation

- The compiled `SchemeProgram` is db-independent (host functions bind the store only
  at execution time), so compilation can live anywhere.
- A single compilation point (query server) serves multiple frontends (Nim REPL, Python
  client) without duplicating the compiler pipeline in each language.
- The transactor shrinks to execution + storage: no `nim_sql_parse`, `nim_datalog`,
  `nim_planner`, `nim_compiler`, `nim_sql_frontend` imports.

### Design Goals

- **AST, not text, on the wire**: programs travel as native msgpack values
  (symbols via ext type) — no S-expression string printing/parsing round-trip,
  no bytes escaping issues, no `[tag, value]` wrapper arrays.
- **Position-independence**: compiled programs never embed attribute ids (aids) as
  integers; attributes resolve by name at execution time.
- **Client transparency**: the REPL keeps sending `{"type": "sql"}` to the same
  socket; the Python client keeps its SQL API and gains a native Scheme API.

---

## 2. Architecture

```
eavt-repl-nim (unchanged)        py_eavt_client (SQL API + new scheme API)
        └──────────── eavt-query.sock ────────────┘
                        │
                        ▼
     eavt-sql-query    (new binary)
       • msgpack, thread-per-connection (nim_spawn)
       • compiles SQL → Scheme in-process (nim_sql_frontend)
       • caches schema snapshot for planning/estimates
       • renders EXPLAIN locally
       • passes through scheme / schema / admin / kv
                        │  eavt-transactor.sock
                        ▼
     eavt-sql-transactor (refactored: pure execution engine)
       • accepts: scheme / schema / admin / kv
       • no SQL parsing, no compiler imports
```

- **Processes are independent**; a dev script starts both (transactor first).
  The query server returns a clear error if the transactor is down.
- **Sockets**: query server owns `eavt-query.sock` (clients see no change); transactor
  listens on `eavt-transactor.sock` and honors `--socket-path`.
- **Connections**: one multiplexed connection between query server and transactor
  carrying all traffic (replication events + forwarded requests). Correlation IDs
  disambiguate responses; `"ev"` frames are the replication stream.
- **Threading**: the query server is a **single-thread chronos event loop** (each client
  callback is an async proc); the transactor is
  thread-per-connection. SQL compilation runs inline on the query server loop (ms-scale).

---

## 3. Wire Protocol

Framing is unchanged: 4-byte big-endian length prefix + msgpack payload; responses
chunked as `{"columns": [...], "rows": [...], "more": bool}` or
`{"error": str, "more": false}`.

### 3.1 Requests accepted by the transactor

| `type` | Fields | Behavior |
|--------|--------|----------|
| `scheme` | `program` (wire AST, §3.3), `mode`: `"query"` \| `"exec"`, `params` (array of wire ASTs, optional) | `query` streams rows via yield/resume; `exec` runs to completion and returns the `(result ...)` payload |
| `schema` | — | Returns the `CompileStats` snapshot as a single msgpack map (see 3.3) |
| `admin` | `command` | Unchanged (`flush`, `flush-sync`, `status`, `memtable`, `dump ...`) |
| `kv` | `op`, `cf`, `key`, `value` | Unchanged |

`type: sql` is **removed** from the data server.

### 3.2 Requests accepted by the query server

| `type` | Fields | Behavior |
|--------|--------|----------|
| `sql` | `sql`, `params` (optional) | Fetches schema snapshot (cached), runs the full compile pipeline; EXPLAIN is rendered locally, everything else is forwarded as `scheme` |
| `scheme` | `program`, `mode`, `params` | Forwarded verbatim |
| `schema` | — | Served from cache (or fetched) |
| `admin` / `kv` | — | Transparent pass-through, including streaming (`dump`, `scan`) |

`type: sql` is **removed** from the transactor.

### 3.3 Program encoding (`program`, `params`) — EDN-like msgpack

A program node is a **native msgpack value**; the only distinction plain
msgpack cannot express (symbol × string) rides on an application ext type:

| SExpr kind | Wire encoding |
|------------|---------------|
| int | msgpack int (int64) |
| float | msgpack float (f64; f32 accepted) |
| str | msgpack str |
| symbol | **ext type `0x05`**, payload = UTF-8 name |
| bool | msgpack bool |
| bytes | msgpack bin |
| void | msgpack nil |
| list | msgpack array of child nodes |

`sResource` never appears in compiled programs (scanners/iterators are created at
execution time); encoders reject it. The decoder is fail-loud: maps inside a
program, unknown ext types and truncated input all raise `WireError`.

### 3.4 Python helpers (`py_eavt_client`)

`to_wire(v)` converts Python values to the wire form — values travel as
native msgpack types (int → int, float → float, str → str, bool → bool,
bytes → bin, None → nil, list/tuple → array); `Sym("name")` becomes
`msgpack.ExtType(0x05, name)` to mark a **symbol**. Plain `str` is a Scheme
**string**. On decode, ext `0x05` is unwrapped back to `Sym` (via the
unpacker's `ext_hook`). `EavtClient.scheme(program, *params)` and
`EavtClient.schema()` speak this protocol.

### 3.5 Schema snapshot format

`CompileStats` is all scalars, serialized as one msgpack map:

```
{
  "attrIds":       { "company.name": 27, ... },
  "indexEstimates": { "EAVT:": 12345.0, ... },
  "partitionIds":  { "main": 4, ... },
  "refAttrs":      [ "company.ceo", ... ],
  "indexedAttrs":  [ "user.email", ... ]
}
```

`indexedAttrs` (unique ∨ indexed) drives AVET eligibility: the planner only
assigns the AVET index to patterns whose attribute is in this set. Value
filters on non-indexed attributes fall back to AEVT with a trailing range
filter — correct results, slower path.

---

## 4. Position-Independence Rule

**Compiled programs must never embed attribute ids as integer literals.** Aids are
allocation-ordered and change as attributes are declared; a program carrying a stale
aid would silently read/write the wrong attribute.

- The triejoin path already emits `(intern-a "attr.name")` for the `a` slot; DML
  (`save`/`retract`), `lookup-entity`, `lookup-value`, and `declare-attr` carry
  attribute names as strings.
- The remaining baked-int path (`bvResolvedAttr` → `newInt(raId)` in the fully-bound
  lookup probe) changes to emit `(intern-a "name")` as well.
- `intern-a` on an unknown attribute **raises** an evaluation error instead of
  returning void — a wrong name must fail loudly, not silently scan nothing.

Consequence: schema staleness can only degrade **plan quality** (stale index
estimates → worse join order), never **correctness**. No schema hash validation,
no `schema_changed` retry, no forced cache invalidation on writes.

---

## 5. Schema Snapshot Semantics at the Query Server

- Fetched on demand, cached with a short TTL (~30s).
- Used for two things only: rejecting unknown attribute names at compile time
  ("attribute resolution failed") and feeding the planner's cardinality estimates.
- On "attribute resolution failed" the query server refetches once and recompiles —
  covers the case of an attribute declared moments ago through another connection.

---

## 6. Scheme Protocol Contract

The `scheme` request type carries compiled Scheme programs from the query server
to the transactor.  The transactor is a **pure execution engine** — it never
parses SQL, plans joins, or selects indexes.  The query server handles all
compilation.

### Programs the query server sends

| Operation | Scheme program | Notes |
|-----------|---------------|-------|
| UPSERT | `(save (alloc-entity N) "attr" (param M))` | Entity allocated at execution time |
| UPSERT by lookup | `(lookup-entity "attr" val)` + `(save eid "attr" val)` | Entity found by unique attribute |
| Mixed UPDATE | `(save 101 "attr" (param 1))` — concrete eids | Query server scans replica, batches eids |
| Mixed DELETE | `(retract 101 "attr" "val")` — concrete eids | Query server scans replica, batches eids |
| ATTRIBUTE | `(declare-attr "name" "STRING" false)` | Schema declaration |
| PARTITION | `(declare-partition "name")` | Partition declaration |

### Programs the query server NEVER sends

| Opcode | Why |
|--------|-----|
| `scanner-open` | Triejoin runs on the query server's replica |
| `scanner-push` / `scanner-pop` | Index prefix narrowing — replica only |
| `scanner-iterate-init` / `scanner-iterate-next` | Leapfrog join — replica only |
| `while` (scanner loop) | Join iteration — replica only |

The transactor's VM supports these opcodes (shared codebase with the query
server), but they are **dead code** in the transactor — never invoked by any
program the query server sends.

### Why not a simpler protocol?

The `scheme` protocol supports **batched operations with entity allocation and
value chaining** in a single atomic request:

```scheme
(begin
  (set! D1 (alloc-entity 4))
  (set! D2 (alloc-entity 4))
  (save D1 "ref" D2)     ; D1 references D2 — value is the entity allocated above
  (save D2 "name" "alice")
  (result D1 2))
```

Replacing `scheme` with individual `save`/`retract` requests would lose:
- **Atomicity**: all-or-nothing execution
- **Batch allocation**: multiple entity IDs in one round-trip
- **Value chaining**: one entity's value is another entity allocated in the same batch

The `scheme` protocol preserves these properties while remaining simple enough
that the transactor never needs the planner, datalog, or SQL parser.

---

## 7. Implementation Phases

| Phase | Scope | Acceptance |
|-------|-------|------------|
| F0 | Tagged AST codec (`nim_scheme/wire.nim`); `bvResolvedAttr` → `intern-a`; unknown-attr error | round-trip tests incl. bytes/sym≠str; compiled program executes correctly with different aid assignments; `nimble test` green |
| F1 | Transactor: remove `rkSql`, add `rkScheme`/`rkSchema`; wire `params` through to the hostfn; drop compiler imports; `eavt-transactor.sock` | transactor tests: scheme query/exec, typed params, schema snapshot |
| F2 | Extract EXPLAIN renderer → `nim_sql_frontend/explain.nim` | EXPLAIN output byte-identical to current |
| F3 | Query server package (`eavt_query_nim/`) | e2e: SQL select, EXPLAIN, writes, multi-batch streaming (>100 rows), late-declared attribute, transactor down → clear error |
| F4 | Python client: `scheme(program_ast, *params)`, `schema()` | bench.py unchanged behavior via SQL API |
| F5 | `nimble dist` builds transactor + query server; dev script starts both; full `nimble test` | all green |

---

## 8. Related Documents

- `docs/scheme-ir.md` — SExpr type system, evaluator, host functions
- `docs/sql-reference.md` — SQL surface accepted by the compiler
