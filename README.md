# eavt-sql

**An immutable, time-traveling fact database — with a SQL dialect.**

eavt-sql borrows [Datomic](https://www.datomic.com/)'s immutable, indexed, entity-attribute-value model and brings it to a familiar SQL interface. No Datalog — just `SELECT`, `UPSERT`, `UPDATE`, and `DELETE` over dot-notation attributes with implicit joins.

Every piece of data is an immutable **fact** — a *datom* `(entity, attribute, value, transaction)`. Nothing is ever overwritten: updates retract the old value, history is preserved forever, and you can query the database **as of any point in time**.

## Quick Start

Requires Nim ≥ 2.0.14 and Python ≥ 3.13 for benchmarks. Zero Rust toolchain.

```bash
# Build server + CLI
nimble dist                    # → build/eavt-sql-server, build/eavt-sql-cli

# Run all tests (492 Nim tests)
nimble test                    # → build/all_tests

# Start the server
./build/eavt-sql-server        # listens on /run/user/$UID/eavt/eavt.sock
```

## Server + CLI (Unix Domain Socket + MessagePack)

```bash
# Server
./build/eavt-sql-server

# REPL (Tab-separated output, linenoise history, dot-commands)
./build/eavt-sql-cli
```

**Dot commands:** `.help` `.flush` `.status` `.tree` `.memtable` `.dump [EAVT|AEVT|AVET|VAET]` `.quit`

**Protocol:** MessagePack over UDS (big-endian length-prefix framing). Types preserved across the wire:
int64, float64, bool, string, bytes. Python client in `py_eavt_client/`.

## SQL Dialect

Attributes are namespaced and read with dots. Each `dN` in a query is a **virtual datom**; the same alias joining multiple conditions means "the same entity".

```sql
-- Join two patterns — d1 and d2 share an entity through d1.company.hq = d2
SELECT d1.company.name, d2.city.name WHERE d1.company.hq = d2 AND d2.city.name = 'NYC'

-- Range + not-equal + IN
SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2 AND d1.item.score != %3
SELECT d1.item.score WHERE d1.item.score IN (10, 30, 50)

-- Wildcards: dump every attribute/value of an entity
SELECT d1.attr, d1.val WHERE d1.eid = %1

-- Transaction metadata, Datomic-style
SELECT d1.company.name, d2.db.txInstant WHERE d1.company.name = 'ACME' AND d1.tx = d2

-- History: every revision, including retracted values
SELECT HISTORY d1.company.name WHERE d1.eid = %1
```

## Immutability

| Operation | What happens |
|-----------|-------------|
| `UPSERT` | Asserts a fact. `ONE` cardinality retracts the prior value (both kept). |
| `UPDATE` | Join scan: asserts new facts / retracts old ones per matched entity. |
| `DELETE` | Retracts matching facts — **no physical deletion**. |
| `SELECT` | Reads only the current (non-retracted) state. |
| `SELECT HISTORY` | Reads every revision, including retracted values. |

## Schema

```sql
ATTRIBUTE company.partner REF MANY
ATTRIBUTE company.name STRING ONE UNIQUE
ATTRIBUTE company.revenue FLOAT ONE
ATTRIBUTE company.active BOOLEAN ONE
```

| Param | Effect |
|-------|--------|
| `TYPE` (required) | STRING, LONG, REF, BOOLEAN, FLOAT, INSTANT, BYTES, KEYWORD |
| `ONE` (default) | one value per `(E, A)` — replacement semantics |
| `MANY` | values accumulate for the same `(E, A)` |
| `UNIQUE` | no two entities share a value for this attribute |

## Indexes

| Index | Key order | Best for |
|-------|-----------|----------|
| EAVT | `e, a, v` | everything for an entity |
| AEVT | `a, e, v` | who has a given attribute |
| AVET | `a, v, e` | value → entity lookups |
| VAET | `v, a, e` | reverse ref lookups (refs only) |

Auto-selected by a cost-based planner with branch-and-bound search.

## Architecture

```
SQL text
  │
  ▼
nim-sql-parse        (D.1) lexer + parser → AST
  │
  ▼
nim-datalog          (D.2) AST → Datalog IR (EAVT patterns)
  │
  ▼
nim-planner          (D.3) join ordering + index selection (cost-based DFS)
  │
  ▼
nim-compiler         (D.4) Datalog IR → Scheme S-expressions
  │
  ▼
nim-scheme           Stack-based VM with yield/resume (streaming queries)
  │
  ▼
nim-query            Host functions: scanner-open, scanner-iterate, save, retract
  │
  ▼
nim-eavt             EAVT engine: resolver, allocation, uniqueness constraints
  │
  ▼
nim-kvstore          KVStore: put/get/scan/flush/GC + MergedCursor
  │
  ├── nim-memtable   COW treap (ARC-managed), one per CF
  └── nim-page-store COW B-tree, zstd-compressed pages, LRU cache
  │
  ▼
nim-blobstore        memory / file / S3 backends
```

All layers are **pure Nim** — no C ABI, no vtable indirection, no Rust.

| Module | Lines | Role |
|--------|-------|------|
| `nim_sql_parse` | 780 | SQL lexer + recursive-descent parser |
| `nim_datalog` | 603 | SQL AST → Datalog patterns + resolve |
| `nim_planner` | 774 | Cost-based join ordering (EAVT/AEVT/AVET/VAET) |
| `nim_compiler` | 580 | Datalog IR → Scheme codegen |
| `nim_sql_frontend` | 143 | Orchestration: parse → compile → Scheme program |
| `nim_scheme` | 579 | S-expr parser + stack VM with yield/resume |
| `nim_query` | ~2,000 | Scanner, hostfns (22 ops), leapfrog triejoin |
| `nim_eavt` | 285 | EAVT engine: save/retract + resolver + constraints |
| `nim_kvstore` | 319 | KVStore + PageStore + MergedCursor |
| `nim_memtable` | ~400 | Per-CF COW treap |
| `nim_page_store` | 721 | COW B-tree, LRU cache (zstd-compressed) |
| `nim_blobstore` | ~800 | memory / file / S3 backends |

## Storage Backends

| Backend | Storage | Use case |
|---------|---------|----------|
| Memory | In-memory `HashMap` | `:memory:` mode |
| File | Directory + zstd-compressed blobs | Persistent local |
| S3 | S3-compatible object store + local journal | Cloud / distributed |

## Python Client

```python
from eavt_client.client import EavtClient

client = EavtClient()  # connects to local UDS server
rows = client.execute("ATTRIBUTE company.name STRING ONE")
rows = client.execute("UPSERT SET company.name = 'ACME'")
rows = client.execute("SELECT d1.company.name WHERE d1.company.name = 'ACME'")
client.admin("flush")
client.close()
```

## Benchmarks

```bash
./build/eavt-sql-server &
uv run python tests/bench.py
```

See `tests/bench*.py` — insert/query/flush latency, join performance, compile vs execution cost.

## Project Layout

```
eavt_server_nim/       # UDS server (msgpack, thread-per-connection)
eavt-repl-nim/          # REPL client (linenoise, tab-separated output)
py_eavt_client/         # Python client (msgpack over UDS)
nim_sql_parse/          # D.1 — SQL lexer + parser
nim_datalog/            # D.2 — AST → Datalog IR
nim_planner/            # D.3 — join ordering + index selection
nim_compiler/           # D.4 — Scheme codegen
nim_sql_frontend/       # Orchestration: parse → compile
nim_scheme/             # S-expr parser + VM
nim_query/              # Scanner, hostfns, leapfrog triejoin
nim_eavt/               # EAVT engine
nim_kvstore/            # KVStore + PageStore
nim_memtable/           # COW treap per CF
nim_page_store/         # COW B-tree + LRU cache
nim_blobstore/          # memory / file / S3 backends
build/                  # compiled binaries (gitignored)
tests/                  # Python benchmarks
docs/                   # SQL reference, architecture notes
```

## License

[MIT](./LICENSE)
