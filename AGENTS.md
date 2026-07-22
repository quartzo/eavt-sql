# AGENTS.md

## Development Commands

- **Nim tests:** `nimble test` (runs all ~286 unit tests)
- **Query engine tests:** `(cd nim-kvstore && nimble query_test)`
- **Rust tests:** `cargo test --release`
- **Rust build:** `cargo build --workspace --release`
- **Build PyO3 bindings:** `./build_py.sh` (all) or `./build_py.sh eavt` (one crate)
- **Python tests:** `uv run pytest tests/`
- **Python deps:** `uv sync --group dev` (pure-Python deps only)
- **All Python commands must use `uv run`.**

### Prerequisites

- **Nim ≥ 2.0.14** — all Nim code compiles via `nimble` / `nim c` with `--mm:arc --threads:on`.
- **Rust** (stable, with cargo)
- **OpenSSL libcrypto** (`libcrypto.so`, usually via `libssl-dev` / `openssl-libs`)
  — used by the S3 backend for SHA-256 / HMAC-SHA256 in SigV4 signing.
  Linked with `-lcrypto`. No AWS SDK is linked; the rest of the SigV4 protocol is
  hand-rolled over `std/httpclient`.
- **zstd** — linked via `-lzstd`.

### PyO3 Binding Workflow

The PyO3 crates are installed as editable packages via `maturin develop`.
After changing Rust code that affects the Python bindings, rebuild with `./build_py.sh`.

## Project Structure

```
spier-value/                       # Core Value type + query codecs
  lib.rs                           # Value, ValueType, tag constants
  query_codec.rs                   # encode_values / decode_values / decode_rows
spier-query-ir/                    # Program IR + range-op constants
  opcodes.rs                       # Program enum (Scheme, SelectScheme), ProgramHandle, SelectSchemeMeta
  spec_kind.rs                     # SpecKind
spier-scheme/                      # Scheme IR: AST + parser + printer + evaluator (zero deps)
spier-sql-parse/src/               # SQL parser library + SqlParseEngine trait + AST
spier-datalog/src/                 # DatalogEngine trait + DatalogIR + resolve_ir
  ast.rs, pattern.rs, resolve.rs, stats.rs
spier-planner/src/                 # PlannerEngine trait + QueryPlanSt
spier-compiler/src/                # CompilerEngine trait + scheme_compile (UPSERT→Scheme)
spier-sql-frontend/src/            # SqlFrontendEngine trait
spier-eavt-query/src/              # Rust query engine (deprecated — Nim engine replaces it)
  engine/                          # types, scanner, opcodes, query_engine_inner, scheme
  lib.rs                           # QueryState::open(config) -> impl QueryEngine
spier-sql-parse-py/                # PyO3 bindings for spier-sql-parse
spier-eavt-query-py/               # PyO3 bindings (wrapper layer)
eavt-cli/src/                      # REPL client (gRPC binary: eavt-repl)
eavt-server/                       # gRPC server (tonic, binary: eavt-server)
src/eavt_sql/                      # Python package (nimpy bindings)
tests/                             # Python tests (flat)

nim-blobstore/                     # Pure-Nim blobstore backends
  blobstore.nim                    # BlobStore trait (ref object + virtual methods)
  common.nim                       # ByteArr16, compress/decompress
  memory/backend.nim               # In-memory HashMap backend
  file/backend.nim                 # Directory backend: hex-sharded blobs, zstd compression,
                                   # read-only guard
  s3/backend.nim                   # S3: SigV4 signing, ListObjectsV2, local journal
  journal/backend.nim              # Sequential append-only file journal
nim_memtable/                      # Persistent treap (COW) per CF
  backend.nim                      # MemTable, TreapNode, insert, scanAll, collectKeys
  treap_cursor.nim                 # Lazy in-order cursor (stack-based)
nim-kvstore/                       # KVStore + PageStore + EAVT + Query engine
  backend.nim                      # PageStoreInner, B-tree, PageCache (zstd-compressed LRU)
  pages.nim                        # Leaf page serialization (prefix-compressed, varint)
  page_cursor.nim                  # Lazy forward cursor over B-tree leaves
  kvstore.nim                      # KVStore: put/get/scan/flush/GC, MergedCursor
  eavt.nim                         # EAVT engine (save, retract, bootstrap, lookup)
  keys.nim                         # EAVT key format helpers
  resolver.nim                     # Schema cache + entity allocation
  scheme.nim                       # Scheme IR evaluator (SExpr parser + stack-based VM)
  query/                           # Native Nim query engine
    engine.nim                     # QueryStore, QuerySession, StreamingSession
    hostfns.nim                    # 22+ SchemeHostFns + leapfrog triejoin
    scanner.nim                    # V2Scanner with leapfrog triejoin, NimCursor
    types.nim                      # Value comparison, interval merging
    codec.nim                      # Wire value codec (tagged big-endian)
  query/pynim_query.nim            # nimpy bridge for Python
```

## Architecture

### Storage Backends

All 4 blobstore backends (Memory, File, S3, Journal) and the MemTable
are implemented in **pure Nim** using native Nim types (`ref object` +
virtual methods for BlobStore; `ref object` + COW for MemTable).
There is no C-ABI vtable — backends are selected at construction time
via `newKVStore(config)`.

| Backend | Directory               | Storage                                                | Use Case            |
|---------|-------------------------|--------------------------------------------------------|---------------------|
| Memory  | `nim-blobstore/memory/` | In-memory `HashMap`                                    | `:memory:` mode     |
| File    | `nim-blobstore/file/`   | Directory with zstd-compressed blobs (hex-sharded)     | Persistent local    |
| S3      | `nim-blobstore/s3/`     | S3-compatible object store via hand-rolled SigV4       | Cloud/distributed   |
| Journal | `nim-blobstore/journal/`| Sequential append-only file journal                    | WAL / crash recovery |

### Storage Layers

```
BlobStore (Memory / File / S3)
  → PageStore (COW B-tree per CF, zstd-compressed blobs, LRU page cache)
    → KVStore (single MemTable instance + PageStore)
      │  auto-flush by threshold, journal-based crash recovery
      → EavtEngine (EAVT: save/retract + resolver + eager constraints)
        → Query Engine (Scheme IR evaluation)
          ← Rust: SQL parse → datalog IR → plan → Scheme codegen
```

### MemTable (ARC-driven COW)

The persistent treap uses `--mm:arc`, so node lifetime is governed by
**reference counting**. A `TreapNode` stays alive as long as ANY reference
holds it. `insert` does path-copying — old versions are shared, not mutated.

No snapshot registry. Cursors hold a `TreapNode` ref directly. When the
last ref drops (cursor consumed, KVStore closed), ARC frees the treap.

### Flush

1. `kv.flushRoots = kv.mt.hnd.live` — capture current COW roots
2. `kv.mt.clear()` — nil live roots
3. Scan captured roots → merge with PageStore → commit
4. ARC releases old nodes when flushRoots goes out of scope

### No Transaction Mechanism

Single-writer serial: `resolver: Mutex<Resolver>` locks per-datom, not per-statement.
No `begin_tx`/`commit_tx`/`rollback_tx`. Multi-row UPDATE/DELETE is not atomic.

### Scheme IR Execution

All SQL compiles to Scheme S-expressions. The Rust compiler produces Scheme IR;
the Nim evaluator (`nim-kvstore/scheme.nim`) executes it with yield/resume
semantics. `SessionHandle` wraps a resumable evaluator; callers pull batches
via `session_next_batch(handle, max_rows)`.

### Streaming Scan (MergedCursor)

Lazy heap-merge of 3 sources — no mass materialization:
- `PageStoreCursor` — iterates B-tree leaves one page at a time
- `TreapCursor` — stack-based in-order over treap, 1 key per `next()`
- `MergedCursor` — heap merge of N cursors, O(k) memory (k = number of sources)

### Key Design Points

- **4 column families**: CFs 0-3 (eavt, aevt, avet, vaet indexes)
- **Page format**: `[num_keys u16][varint plen][varint slen][suffix]...`
- **Page cache**: LRU storing zstd-compressed bytes (~3x capacity vs raw)
- **Config**: `flush_threshold` (64MB), `page_cache_size` (64MB), `gc_max_age_secs` (43200)
- **Recovery**: on open, replay journal into MemTable
- **Write path**: `put()` → journal append → MemTable → auto-flush when >= threshold

## Conventions

- Python >= 3.13
- Attribute names: mandatory dot notation (e.g. `company.name`)
- Test files: `test_*.py` in `tests/`, `tests.nim` per Nim module
- Binary formats: big-endian (`>""`)
- **Never remove or weaken failing tests to get "all green".**
