# eavt-sql

**An immutable, time-traveling fact database — with a SQL dialect instead of Datalog.**

eavt-sql borrows [Datomic](https://www.datomic.com/)'s immutable, indexed, entity-attribute-value model and brings it to a familiar SQL interface. No `?`-variables, no Datalog — just `SELECT`, `UPSERT`, `UPDATE`, and `DELETE` over dot-notation attributes with implicit joins.

Every piece of data is an immutable **fact** — a *datom* `(entity, attribute, value, transaction)`. Nothing is ever overwritten or physically deleted: updates retract the old value, history is preserved forever, and you can query the database **as of any point in time**.

```python
from eavt_sql.engine import EAVTEngine

engine = EAVTEngine(":memory:")

# Declare a schema (entities are attribute bags — no fixed tables/columns)
list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
list(engine.sql("ATTRIBUTE company.hq REF ONE"))
list(engine.sql("ATTRIBUTE city.name STRING ONE UNIQUE"))

# Create entities — each UPSERT returns [(entity_id, values_inserted)]
acme = list(engine.sql("UPSERT AS D1 SET company.name = 'ACME'"))[0][0]
nyc  = list(engine.sql("UPSERT AS D1 SET city.name = 'New York'"))[0][0]

# Link them by unique attribute via an AVET point lookup
list(engine.sql("UPSERT AS D1 = eid('company.name', 'ACME') SET company.hq = %1", nyc))

# Implicit join: d1.company.hq = d2 — the planner picks the index & join order
list(engine.sql("SELECT d1.company.name, d2.city.name WHERE d1.company.hq = d2 AND d2.city.name = 'New York'"))
# → [('ACME', 'New York')]

# Update is also a join; the old value is retracted, not destroyed
list(engine.sql("UPDATE AS D1 SET company.name = 'ACME Corp' WHERE d1.company.hq = d2 AND d2.city.name = 'New York'"))

# Query the full revision history — retracted values are still there
list(engine.sql("SELECT HISTORY d1.company.name WHERE d1.eid = %1", acme))
# → [('ACME',), ('ACME Corp',)]
```

## Why?

Datomic showed that an **append-only, immutable** database is a better fit for systems that must audit, reason about, and rewind state — but it requires learning Datalog. eavt-sql keeps the model and gives you SQL:

- **Immutable by default** — writes never destroy data. Retract a fact and the old value stays queryable forever.
- **Time travel** — re-run any query as of a past transaction or timestamp (`as_of=...`), or `SELECT HISTORY` to see every revision.
- **A real SQL dialect** — `SELECT`/`UPSERT`/`UPDATE`/`DELETE`/`ATTRIBUTE` with `WHERE`, joins, ranges, and `IN`. Attributes use dot notation (`d1.company.name`); joins are implicit (`d1.company.hq = d2`), so you never write `JOIN ... ON`.
- **Schemaless entities** — an entity is a bag of attribute facts. Add attributes at any time; no migrations to reshape a table.
- **Automatic query planning** — a cost-based planner with branch-and-bound search picks the join order and selects among four indexes (EAVT / AEVT / AVET / VAET). You describe *what* to join; the engine decides *how*.
- **Native Rust core, thin Python API** — all storage and query execution are Rust; Python is a small typed client.

## A SQL dialect for facts

Attributes are namespaced and read with dots. Each `dN` in a query is a **virtual datom**; the same alias joining multiple conditions means "the same entity".

```python
# Join two patterns — d1 and d2 share an entity through d1.company.hq = d2
engine.sql("SELECT d1.company.name, d2.city.name WHERE d1.company.hq = d2 AND d2.city.name = 'NYC'")

# Range + not-equal + IN
engine.sql("SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2 AND d1.item.score != %3", 30, 70, 50)
engine.sql("SELECT d1.item.score WHERE d1.item.score IN (10, 30, 50)")

# Wildcards: dump every attribute/value of an entity
engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", eid)
# → [('company.name', 'ACME Corp'), ('company.hq', 1002), ...]

# Transaction metadata, Datomic-style
engine.sql("SELECT d1.company.name, d2.db.txInstant WHERE d1.company.name = 'ACME' AND d1.tx = d2")
```

Full syntax: **[SQL Reference](./docs/sql-reference.md)**.

## Immutable by default, queryable at any time

| Operation | What happens on disk |
|-----------|----------------------|
| `UPSERT` | Asserts a new fact. `ONE` cardinality also retracts the prior value (both kept in history). |
| `UPDATE` | A join scan that asserts new facts / retracts old ones per matched entity. |
| `DELETE` | Retracts matching facts — **no physical deletion**. |
| `SELECT` | Reads only the current (non-retracted) state. |
| `SELECT HISTORY` | Reads every revision, including retracted values. |
| `as_of=t` | Reads the state as of a transaction number or timestamp. |

```python
engine.export_jsonl("data.jsonl.gz", history=True)   # full history, portable
```

## Everything is a plugin

The entire engine is split into **well-isolated modules, each compiled to its own shared library (`.so`) and loaded at runtime via [DynSpire](https://github.com/quartzo/dynspire)**. A `.dspi` interface file is the contract between any two plugins; `dynspire-codegen` turns it into Rust traits, typed clients, and a versioning hash checked at load time. Swap the storage backend, the planner, or the parser without touching the others.

```
SQL text
  │
  ▼
spier-sql-frontend ──► spier-sql-parse   (lexer + parser → AST)
  │                  └► spier-datalog     (AST → Datalog IR)
  ▼
resolve_ir  ──► spier-transactor          (schema resolution)
  ▼
spier-compiler ──► spier-planner          (cost-based join ordering + index pick)
  ▼
VM program ──► spier-eavt-query           (leapfrog triejoin VM, streaming)
                  │
                  ▼
              spier-kvstore ──► spier-memtable            (crossbeam write buffer)
                             └► spier-blobstore-{memory|file|s3}   (page storage)
                             └► spier-journal-file        (write-ahead log)
```

| Plugin (`.so`) | Responsibility |
|----------------|----------------|
| `spier-sql-parse` | Pure-Rust SQL lexer + parser |
| `spier-datalog` | SQL AST → Datalog IR (patterns `[?e ?a ?v ?t ?added]`) |
| `spier-sql-frontend` | Stage-1 compile: parse + datalog IR |
| `spier-planner` | Stage-2a: cost-based join ordering + index selection (stats only, no transactor) |
| `spier-compiler` | Stage-2b: plan → VM bytecode |
| `spier-eavt-query` | Orchestrates the pipeline; runs the triejoin VM |
| `spier-transactor` | EAVT semantics: save / retract / declare_attr + resolver + UNIQUE constraints |
| `spier-kvstore` | Key-only multi-CF store: MemTable + PageStore + flush + GC |
| `spier-memtable` | Per-CF `SkipMap` write buffer, O(1) snapshots |
| `spier-blobstore-memory` / `-file` / `-s3` | Pluggable page storage backends |
| `spier-journal-file` | Local write-ahead journal (not needed for `:memory:`) |

> **[Spier & Tower Map](./docs/spier-map.md)** — which plugin consumes which, and the IDL behind each boundary.

## Storage backends

```python
engine = EAVTEngine(":memory:")            # volatile — file backend in an ephemeral temp dir
engine = EAVTEngine("./my_db")             # persistent (spier-blobstore-file, zstd-compressed pages)
engine = EAVTEngine("s3://bucket/prefix")  # S3-compatible object store (spier-blobstore-s3)
```

| Backend | Storage | Use case |
|---------|---------|----------|
| Memory | In-memory `HashMap` | Server `:memory:` mode (gRPC); selectable via `backend` config in Rust |
| File | Directory + zstd-compressed blobs + WAL | Persistent local; also backs Python's `:memory:` (temp dir) |
| S3 | S3-compatible object store + local WAL | Cloud / distributed |

Attribute declarations persist to disk and reload on reopen.

## Quick Start

Requires Python 3.13+, [uv](https://docs.astral.sh/uv/), and a Rust toolchain.

```bash
cargo build --release     # compile the spier .so plugins (Python loads these)
uv sync --group dev       # install Python deps
uv run pytest tests/ -v   # run the suite (Rust tests: cargo test --release)
```

## gRPC server & REPL

```bash
eavt-server path/to/db            # file storage
eavt-server :memory:              # in-memory
eavt-server s3://bucket/prefix    # S3

eavt-repl localhost:50051         # connect the REPL client
# Dot commands: .status .tree .memtable .dump .flush .help .quit
# SQL: SELECT, UPSERT, UPDATE, DELETE, ATTRIBUTE ...
```

## Schema

```python
engine.sql("ATTRIBUTE company.partner REF MANY")
engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE")
engine.sql("ATTRIBUTE company.revenue FLOAT ONE")
engine.sql("ATTRIBUTE company.active BOOLEAN ONE")
```

| Param | Effect |
|-------|--------|
| `TYPE` (required) | STRING, LONG, REF, BOOLEAN, FLOAT, INSTANT, BYTES, KEYWORD |
| `ONE` (default) | one value per `(E, A)` — replacement semantics |
| `MANY` | values accumulate for the same `(E, A)` |
| `UNIQUE` | no two entities share a value for this attribute |

Values are auto-coerced by declared type. Schema attributes (`db.ident`, `db.valueType`, …) are themselves queryable via SQL.

## Indexes

| Index | Key order | Best for |
|-------|-----------|----------|
| EAVT | `e, a, v` | everything for an entity |
| AEVT | `a, e, v` | who has a given attribute |
| AVET | `a, v, e` | value → entity lookups |
| VAET | `v, a, e` | reverse ref lookups (refs only) |

All four are key-only and prefix-compressed (varint sizes, 256 KB page splits). The planner selects among them automatically.

## Architecture & design notes

- **Two-stage compilation**: stage 1 (frontend: parse + datalog IR) and stage 2 (compiler: plan + codegen) are decoupled — the compiler never touches the transactor, it consumes cost stats embedded in the resolved IR.
- **Leapfrog triejoin VM**: resumable, pull-based cursors stream results in bounded batches; `EXPLAIN` dumps every candidate join ordering with costs plus the compiled bytecode.
- **MemTable swap-flush**: on threshold, the live write buffer is frozen and a fresh one takes over; flush reads frozen data non-destructively, so reads stay consistent during flush.
- **Single-writer, per-datom locking**: one `Mutex<Resolver>` serializes writes, held only for one datom — not a whole statement. UNIQUE checks run inside the same lock (no TOCTOU). Non-blocking `flush()`/`gc_full()` return `Busy` rather than blocking; a background poller auto-flushes by size and GCs by age.
- **In-process FFI, not RPC**: DynSpire plugins share one address space. Live objects (cursors, snapshots, VM programs) cross the boundary as a single boxed pointer (`#[slot_struct]`) — zero per-call serialization.

### Project layout

```
dynspire-commons/       # Shared protocol: .dspi IDLs + types + codegen clients + utils
dynspire-libs/          # Shared constants (CF names, flush threshold)
spier-sql-parse/        # SQL parser plugin (lexer + parser)
spier-sql-frontend/     # Stage-1 plugin: parse + datalog IR
spier-datalog/          # AST → Datalog IR plugin
spier-planner/          # Cost-based join ordering plugin
spier-compiler/         # Stage-2 plugin: plan + codegen
spier-eavt-query/       # Query engine plugin: VM, triejoin (orchestrates the pipeline)
spier-transactor/       # EAVT engine plugin: save/retract + resolver + constraints
spier-kvstore/          # KV store plugin (MemTable + PageStore + flush); storage .dspi IDLs in src/idl/
spier-memtable/         # MemTable plugin (crossbeam SkipMap per CF)
spier-blobstore-memory/ # In-memory BlobStore plugin
spier-blobstore-file/   # File-backed BlobStore plugin
spier-blobstore-s3/     # S3-backed BlobStore plugin
spier-journal-file/     # File-backed Journal plugin
eavt-cli/               # eavt-repl: REPL client (gRPC)
eavt-server/            # gRPC server (tonic)
src/eavt_sql/           # Python package
  __init__.py           # Re-exports Rust classes + constants
  engine.py             # EAVTEngine
  _ffi.py               # load_spier: loads codegen-emitted typed ctypes clients
  sql_parse_client.py   # SqlParseClient (spier-sql-parse via FFI)
  query_codec.py        # Value serialization for query params/results
  types.py              # Datom, Timestamp, ref, etc.
tests/                  # All tests
```

### Dependencies

- `orjson >= 3.10` — JSON serialization
- No external database — the storage engine is native Rust

## License

[MIT](./LICENSE)
