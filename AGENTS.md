# AGENTS.md

## Development Commands

- **Rust tests:** `cargo test --release`
- **Rust build:** `cargo build --workspace --release`
- **Build PyO3 bindings:** `./build_py.sh` (all) or `./build_py.sh eavt` (one crate)
- **Python tests:** `uv run pytest tests/`
- **Python deps:** `uv sync --group dev` (pure-Python deps only)
- **gRPC server:** `uv run --project py_eavt_client --group dev` (isolated client venv)
- **All Python commands must use `uv run`.**

### PyO3 Binding Workflow

The 4 `spier-*-py` crates are **not managed by uv** — they are installed as
editable packages via `maturin develop`. After changing Rust code that affects
the Python bindings, rebuild with `./build_py.sh` before running tests.

```
uv sync --group dev          # one-time: install pure-Python deps (pytest, moto, etc.)
./build_py.sh                # one-time: install all PyO3 bindings via maturin develop
# After Rust changes:
./build_py.sh eavt           # rebuild only the affected crate (fuzzy match)
uv run pytest tests/         # uv does NOT touch the bindings
```

## Project Structure

```
spier-storage-traits/              # Storage-layer trait abstractions
  blobstore.rs                     # BlobStoreEngine
  journal.rs                       # JournalEngine
  memtable.rs                      # MemTableEngine + MemTableSnapshot
  kvstore.rs                       # KVStoreEngine
  cursor.rs                        # Cursor + CursorHandle
  types.rs                         # CfStats, DbStats, GcFullResult
spier-value/                       # Core Value type + query codecs
  lib.rs                           # Value, ValueType, tag constants
  query_codec.rs                   # encode_values / decode_values / decode_rows
spier-query-ir/                    # VM instruction formats
  opcodes.rs                       # OpCode, Instruction, InstructionData, VMProgram
  spec_kind.rs                     # SpecKind
spier-blobstore-{memory,file,s3}/  # BlobStore backends (implement BlobStoreEngine)
spier-journal-file/                # JournalEngine backend
spier-memtable/                    # MemTableEngine (crossbeam SkipMap per CF)
spier-kvstore/src/                 # KVStoreEngine implementation
spier-transactor/src/              # TransactorEngine implementation (EAVT + resolver)
  eavt.rs                          # EavtEngine { kv: Box<dyn KVStoreEngine>, resolver }
  resolver.rs                      # Schema cache
  resolver_consts.rs               # Bootstrap / partition constants
  keys.rs                          # EAVT key format helpers
  lib.rs                           # TransactorEngine trait + TransactorState::open
spier-scheme/                      # Scheme IR: AST + parser + printer + evaluator (zero deps)
spier-sql-parse/src/               # SQL parser library + SqlParseEngine trait + AST
spier-datalog/src/                 # DatalogEngine trait + DatalogIR + resolve_ir
  ast.rs                           # Datalog IR AST types
  pattern.rs                       # Pattern + INDEX_ORDERS + index_order
  resolve.rs                       # resolve_ir / compute_plan_stats
  stats.rs                         # CompileStats trait
spier-planner/src/                 # PlannerEngine trait + QueryPlanSt
spier-compiler/src/                # CompilerEngine trait + CompileResultSt + scheme_compile (UPSERT→Scheme)
spier-sql-frontend/src/            # SqlFrontendEngine trait
spier-eavt-query/src/              # QueryEngine + VMResultStream + SessionHandle
  engine/                          # vm, scanner, triejoin, opcodes, query_engine_inner, session, scheme
  lib.rs                           # QueryState::open(config) -> impl QueryEngine
spier-sql-parse-py/                # PyO3 bindings for spier-sql-parse
spier-transactor-py/               # PyO3 bindings for spier-transactor
spier-eavt-query-py/               # PyO3 bindings for spier-eavt-query
eavt-cli/src/                      # REPL client (gRPC binary: eavt-repl)
eavt-server/                       # gRPC server (tonic, binary: eavt-server)
src/eavt_sql/                      # Legacy Python package (ctypes FFI replaced by PyO3 per layer)
tests/                             # Python tests (flat)
```

## Architecture

### Storage Backends

The storage backends are pure Rust crates. Backends are selected at construction time
(`spier_kvstore::KVState::open(config)`) rather than loaded as `.so` plugins.

| Backend | Crate | Storage | Use Case |
|---------|-------|---------|----------|
| Memory  | `spier-blobstore-memory` | In-memory `HashMap` | `:memory:` mode |
| File    | `spier-blobstore-file` | Directory with zstd-compressed blobs + journal file | Persistent local |
| S3      | `spier-blobstore-s3` | S3-compatible object store + local journal file | Cloud/distributed |

All backends implement the hand-written `BlobStoreEngine` trait. Journal implements
`JournalEngine`.

### CompileStats Boundary

`spier_datalog::CompileStats` is the small schema/cardinality abstraction used by
`spier_datalog::resolve_ir` and `spier_datalog::compute_plan_stats`. The query engine
implements it via the local `TxStats` adapter (`spier-eavt-query/src/lib.rs`) over
`dyn TransactorEngine`, so `spier-datalog` and `spier-planner` never depend on storage or
transactor crates directly. Isolated planner tests use a fixed `CompileStats` mock in
`spier-planner/src/lib.rs` to exercise index choice without touching storage or the
transactor.

### Storage Layers

```
BlobStore (Memory / File / S3)
  → GenericPageStore (BTreeMap index per CF, root blob with UUID references)
    → KVStore (single MemTable instance + GenericPageStore, snapshot flush)
      │  background poller: auto-flush by threshold + auto-GC by age
      → Transactor/EavtEngine (EAVT: save/retract + resolver + eager constraints)
        → Query Engine (orchestrates two-stage compilation + VM)
          → SQL Frontend (parse + datalog IR)
          → resolve_ir (uses CompileStats, not TransactorEngine, for schema/cardinality)
          → Compiler (plan + codegen)
            → VM (triejoin, leapfrog, scanner, streaming via thread + bounded queue)
```

### Trait-Based Boundaries

Traits now live in their natural crates: storage abstractions are in
`spier-storage-traits`; `TransactorEngine` is in `spier-transactor`; `QueryEngine` is in
`spier-eavt-query`; `SqlParseEngine` is in `spier-sql-parse`; `DatalogEngine` is in
`spier-datalog`; `PlannerEngine` is in `spier-planner`; `CompilerEngine` is in
`spier-compiler`; `SqlFrontendEngine` is in `spier-sql-frontend`. The only shared
abstraction crate is `spier-storage-traits`, because BlobStore, Journal, MemTable and
KVStore each have multiple implementations.

Crates depend on each other directly through `Cargo.toml` paths. There is no runtime
`dlopen`, no C ABI slot buffer, and no code generation step.

### Vec<u8> as Lingua Franca

Bulk data that crosses to **Python**, or that needs an explicit on-disk/blob format, is
packed into `Vec<u8>`.

**Packed formats:**
- Keys: `[u32 klen][key]...` repeated (no count — receiver iterates until buffer end)
- Journal KV: `[u32 klen][key][u32 vlen][value]...` repeated
- Batch writes: `[u8 cf][u32 klen][key]...` repeated
- VM results (non-streaming): `[u32 num_cols][u32 total_values][encoded values]`
- VM results (streaming): each row is `[u32 num_cols][encoded values]` per channel message

### MemTable Snapshot

MemTableEngine uses `crossbeam_skiplist::SkipMap<Vec<u8>, ()>` per CF, each held in an
`Arc<SkipMap>` so snapshots are O(1) Arc clones. Unlike `imbl::OrdMap` (persistent /
structural sharing), the SkipMap is **mutable through `&`** — a snapshot only freezes once
the live MemTable swaps in a fresh empty map (see Flush below). All reads require a
`MemTableSnapshot`. Reads are lock-free; `scan_prefix` / `scan_prefix_reverse` materialize
matching keys into a packed `Vec<u8>`.

Writes (`put`, `batch_write`, `drain`, `clear`) take no snapshot; reads
(`scan_prefix`, `scan_prefix_reverse`, `contains`) all require snapshot parameter.

### Flush (Snapshot + Clear)

Single MemTable instance lives for the transactor's entire lifetime — no instance swapping.

1. `flush_snap = mt.snapshot()` — O(1) Arc clone of each CF's SkipMap
2. `mt.clear()` — O(1) per CF (swap in a fresh empty `Arc<SkipMap>`); old snapshots keep the pre-clear SkipMap alive via Arc
3. Flush scans `flush_snap` → merge with PageStore → commit
4. Reads during flush see: active mt + flush_snap + PageStore

### No Transaction Mechanism

There is no `begin_tx`/`commit_tx`/`rollback_tx`. The system is single-writer serial in the
**pairwise** sense: no two `save_at_t` calls execute concurrently. But "single-writer serial"
does **not** mean a long statement holds the lock for its whole duration — see granularity below.

**Write lock granularity:**

- The only write lock is `resolver: Mutex<Resolver>` (`spier-transactor/src/eavt.rs`). It is
  **global in space** but **per-datom in time**.
- Every write method acquires `resolver.lock()` at entry and releases it at the function's
  return, i.e. for **one datom**, not for a whole SQL statement.
- UNIQUE constraints are validated **eagerly and atomically per-datom** inside the same lock.

**Consequences for long statements (UPDATE / DELETE scans):**

A multi-row UPDATE/DELETE compiles to a triejoin scan interleaved with `ExecInsert` /
`ExecRetract` opcodes. The **scan phase holds no resolver lock**. Each
`ExecInsert`/`ExecRetract` takes the resolver mutex **for that one datom**, then releases it.
Therefore a multi-datom UPDATE/DELETE is **not atomic**. Statement-level atomicity would
require adding a transaction mechanism.

### VM Result Streaming (Pull-Based Cursor)

The VM is resumable: `VM::run_batch(out, max_rows) -> bool` runs until `max_rows`
rows are produced or the program halts. `run()` loops `run_batch` to completion.

A `SessionHandle` (`Arc<RefCell<dyn VMResultStream>>`) wraps a `VMSession` that owns the
resumable VM. The caller pulls batches via `session_next_batch(handle, max_rows) -> Vec<u8>`.
`run_vm` (batch) remains as a convenience wrapper. DML (UPDATE/DELETE) emits
`ResultRow(r_ent)` inside the triejoin leaf — the cursor streams changed eids.

### Cursor Transport

`open_cursor_direct` returns a `CursorHandle` (`Arc<RefCell<dyn Cursor>>`). Callers call
`step()`/`seek()`/`skip_group()` directly via the `Cursor` trait vtable. Cleanup is automatic
via Arc refcount + `Drop`; there is no `cursor_close`.

`cursor_current_key` checks `is_valid()` first — it returns `false` when the cursor is
exhausted (the underlying `MergedInner` does not clear `cur_key` when invalidated).

### Key Design Points

- **4 column families**: CFs 0-3 all key-only (eavt, aevt, avet, vaet indexes)
- **Page format**: `[num_keys u16][varint plen][varint slen][suffix]...` — prefix compression with varint sizes (7-bit, MSB=continuation), binary split at 256KB raw key data
- **GenericPageStore**: each CF is a `BTreeMap<key_bytes, blob_uuid>`. Root blob stores CF index UUIDs + dead blob groups for GC.
- **BlobStore**: data compressed with zstd, atomic writes via temp+rename (file backend). Blobs stored in 2-level hex prefix directory structure.
- **GC**: old blobs tracked as dead groups with timestamps. `gc()` removes roots older than `gc_max_age_secs` (default 43200s = 12h) **or** beyond `gc_max_root_count` newest roots (default 10). Background poller checks `has_gc_candidates()` before running full scan.
- **Write path**: `put()` → journal append → MemTable → auto-flush when >= `flush_threshold`
- **Non-blocking ops**: explicit `flush()` and `gc_full()` use `try_lock` — return `Busy` if another operation holds the lock, never block.
- **Background poller**: thread in `KVState`, spawned on open, stopped on drop. Polls every `poll_interval_secs` (default 300): checks memtable size → flush if exceeded, then checks `has_gc_candidates()` → GC if eligible. All non-blocking.
- **Config**: `poll_interval_secs` (300), `flush_threshold` (67108864 = 64MB), `page_cache_size` (67108864 = 64MB), `gc_max_age_secs` (43200), `gc_max_root_count` (10) — parsed from `config: HashMap<String,String>`.
- **Read path**: MemTable snapshot → flush_snap → GenericPageStore point lookup
- **Scan path**: `scan_sources` merges PageStore + flush_snap + active MemTable snapshot into heap-merged sources
- **Scanner reuse**: `TrieIterator::up()` drops the scanner; `open_with_engine()` creates a new one each time via `create_scanner`. No cursor-level reuse — `scan_sources` is the dominant cost regardless.
- **EAVT_TRACE**: env var `EAVT_TRACE=vm,cursor` (or `all`/`1`) enables execution tracing. Cached `AtomicBool`.
- **Recovery**: on open, replay journal into MemTable
- **S3 mode**: blobs on S3, journal file on local disk
- **Python layer**: PyO3 bindings per layer (`spier-sql-parse-py`, `spier-transactor-py`, `spier-eavt-query-py`). The Python package `src/eavt_sql/` wraps these bindings in a typed API.

### Scheme IR (UPSERT path)

UPSERT compiles to Scheme S-expressions instead of VM bytecode. The full
reference is at `docs/scheme-ir.md`.

Key points:
- `spier-scheme` crate: zero-dep AST + parser + printer + tree-walking evaluator
- 10 special forms: `let*`, `let`, `when`, `if`, `begin`, `set!`, `dbg`, `trace`, `log`, `assert`
- 7 host functions: `alloc-entity`, `tx-entity`, `param`, `lookup-entity`, `lookup-value`, `save`, `result`
- `CompiledProgram::Scheme(SchemeProgram)` coexists with `CompiledProgram::Vm`
- EXPLAIN and `compile_sql_json` show S-expressions for UPSERT
- `SchemeSession` implements `VMResultStream` for cursor-based execution
- Nullable alias guard: `(when alias ...)` wraps result when entity refs use `eid()`

## Conventions

- Python >= 3.13
- Attribute names: mandatory dot notation (e.g. `company.name`), EDN (`:ns/name`) accepted as input convenience
- Comments when appropriate — explain intent, not mechanics
- Test files: `test_*.py` in `tests/`
- Binary formats: big-endian struct (`">..."`)
- **Never remove or weaken failing tests to get "all green".** Use `pytest.mark.xfail` with a reason to document known bugs.
