# Scheme Transport — SQL → Scheme at the Gateway

## 1. Overview

Today every client sends raw SQL text (`{"type": "sql"}`) to a single server that
parses, plans, compiles to Scheme, and executes. This document specifies the new
architecture: **SQL is compiled to Scheme in a gateway process, and the data server
becomes a pure Scheme execution engine.**

### Motivation

- The compiled `SchemeProgram` is db-independent (host functions bind the store only
  at execution time), so compilation can live anywhere.
- A single compilation point (gateway) serves multiple frontends (Nim REPL, Python
  client) without duplicating the compiler pipeline in each language.
- The data server shrinks to execution + storage: no `nim_sql_parse`, `nim_datalog`,
  `nim_planner`, `nim_compiler`, `nim_sql_frontend` imports.

### Design Goals

- **AST, not text, on the wire**: programs travel as tagged msgpack arrays — no
  S-expression string printing/parsing round-trip, no bytes escaping issues.
- **Position-independence**: compiled programs never embed attribute ids (aids) as
  integers; attributes resolve by name at execution time.
- **Client transparency**: the REPL keeps sending `{"type": "sql"}` to the same
  socket; the Python client keeps its SQL API and gains a native Scheme API.

---

## 2. Architecture

```
eavt-repl-nim (unchanged)        py_eavt_client (SQL API + new scheme API)
        └──────────── eavt.sock ────────────┘
                        │
                        ▼
     eavt-sql-gateway  (new binary)
       • msgpack, thread-per-connection (nim_spawn)
       • compiles SQL → Scheme in-process (nim_sql_frontend)
       • caches schema snapshot for planning/estimates
       • renders EXPLAIN locally
       • passes through scheme / schema / admin / kv
                        │  eavt-data.sock
                        ▼
     eavt-sql-server   (refactored: pure execution engine)
       • accepts: scheme / schema / admin / kv
       • no SQL parsing, no compiler imports
```

- **Processes are independent**; a dev script starts both (data server first).
  The gateway returns a clear error if the data server is down.
- **Sockets**: gateway owns `eavt.sock` (clients see no change); data server moves
  to `eavt-data.sock` and honors `--socket-path`.
- **Connections**: one client handler ↔ one dedicated downstream connection to the
  data server. Streaming responses never share a downstream connection (interleaved
  frames would corrupt the protocol).
- **Threading**: the gateway is a **single-thread chronos event loop** (each client
  callback is an async proc owning its downstream connection); the data server is
  thread-per-connection. SQL compilation runs inline on the gateway loop (ms-scale).

---

## 3. Wire Protocol

Framing is unchanged: 4-byte big-endian length prefix + msgpack payload; responses
chunked as `{"columns": [...], "rows": [...], "more": bool}` or
`{"error": str, "more": false}`.

### 3.1 Requests accepted by the data server

| `type` | Fields | Behavior |
|--------|--------|----------|
| `scheme` | `program` (tagged AST), `mode`: `"query"` \| `"exec"`, `params` (array of tagged ASTs, optional) | `query` streams rows via yield/resume; `exec` runs to completion and returns the `(result ...)` payload |
| `schema` | — | Returns the `CompileStats` snapshot as a single msgpack map (see 3.3) |
| `admin` | `command` | Unchanged (`flush`, `flush-sync`, `status`, `memtable`, `dump ...`) |
| `kv` | `op`, `cf`, `key`, `value` | Unchanged |

`type: sql` is **removed** from the data server.

### 3.2 Requests accepted by the gateway

| `type` | Fields | Behavior |
|--------|--------|----------|
| `sql` | `sql`, `params` (optional) | Fetches schema snapshot (cached), runs the full compile pipeline; EXPLAIN is rendered locally, everything else is forwarded as `scheme` |
| `scheme` | `program`, `mode`, `params` | Forwarded verbatim |
| `schema` | — | Served from cache (or fetched) |
| `admin` / `kv` | — | Transparent pass-through, including streaming (`dump`, `scan`) |

### 3.3 Tagged AST encoding (`program`, `params`)

A program node is a 2-element array `[tag, value]` (lists are `[7, [children...]]`).
This preserves the symbol × string distinction that plain JSON cannot express, and
carries bytes as an array of ints — no hex, no textual round-trip.

| Tag | Kind | Value encoding |
|-----|------|----------------|
| `0` | int | JSON number (int64) |
| `1` | float | JSON number (float64) |
| `2` | str | JSON string |
| `3` | symbol | JSON string |
| `4` | bool | JSON bool |
| `5` | bytes | array of ints (0–255) |
| `6` | void | `null` |
| `7` | list | array of child nodes |

`sResource` never appears in compiled programs (scanners/iterators are created at
execution time); encoders reject it.

### 3.4 Python helpers (`py_eavt_client`)

`to_wire(v)` converts Python values to the tagged form (int → `[0, i]`,
float → `[1, f]`, `str` → `[2, s]`, `Sym` → `[3, s]`, `bool` → `[4, b]`,
`bytes` → `[5, [...]]`, `None` → `[6, null]`, list/tuple → `[7, [...]`).
Plain `str` is a Scheme **string**; wrap variable/function names in
`Sym("name")` to get a **symbol**. `EavtClient.scheme(program, *params)` and
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

## 5. Schema Snapshot Semantics at the Gateway

- Fetched on demand, cached with a short TTL (~30s).
- Used for two things only: rejecting unknown attribute names at compile time
  ("attribute resolution failed") and feeding the planner's cardinality estimates.
- On "attribute resolution failed" the gateway refetches once and recompiles —
  covers the case of an attribute declared moments ago through another connection.

---

## 6. Implementation Phases

| Phase | Scope | Acceptance |
|-------|-------|------------|
| F0 | Tagged AST codec (`nim_scheme/wire.nim`); `bvResolvedAttr` → `intern-a`; unknown-attr error | round-trip tests incl. bytes/sym≠str; compiled program executes correctly with different aid assignments; `nimble test` green |
| F1 | Data server: remove `rkSql`, add `rkScheme`/`rkSchema`; wire `params` through to the hostfn; drop compiler imports; `eavt-data.sock` | server tests: scheme query/exec, typed params, schema snapshot |
| F2 | Extract EXPLAIN renderer → `nim_sql_frontend/explain.nim` | EXPLAIN output byte-identical to current |
| F3 | Gateway package (`eavt_gateway_nim/`) | e2e: SQL select, EXPLAIN, writes, multi-batch streaming (>100 rows), late-declared attribute, data server down → clear error |
| F4 | Python client: `scheme(program_ast, *params)`, `schema()` | bench.py unchanged behavior via SQL API |
| F5 | `nimble dist` builds gateway; dev script starts both; full `nimble test` | all green |

---

## 7. Related Documents

- `docs/scheme-ir.md` — SExpr type system, evaluator, host functions
- `docs/sql-reference.md` — SQL surface accepted by the compiler
