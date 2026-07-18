# AGENTS.md

## Development Commands

- **Rust tests:** `cargo test --release`
- **Rust build:** `cargo build --workspace --release`
- **Build PyO3 bindings:** `./build_py.sh` (all) or `./build_py.sh eavt` (one crate)
- **Python tests:** `uv run pytest tests/`
- **Python deps:** `uv sync --group dev` (pure-Python deps only)
- **gRPC server:** `uv run --project py_eavt_client --group dev` (isolated client venv)
- **All Python commands must use `uv run`.**

### Prerequisites

- **Rust** (stable, with cargo)
- **Nim ≥ 2.0.14** — used by `spier-blobstore-nim/build.rs` to compile
  `nim-blobstore/{memory,file,s3,journal}/` into **4 separate static
  libraries**, and by `spier-memtable-nim/build.rs` to compile
  `nim-memtable/` into a **5th static library** (`libnim_memtable.a`). The
  build scripts invoke `nim c` automatically; Nim must be on `PATH`.
- **OpenSSL libcrypto** (`libcrypto.so`, usually via `libssl-dev` / `openssl-libs`)
  — used by the S3 backend for SHA-256 / HMAC-SHA256 in SigV4 signing. Linked
  with `-lcrypto`. No AWS SDK is linked; the rest of the SigV4 protocol is
  hand-rolled over `std/httpclient`.
- **`objcopy`** (GNU binutils or LLVM) — `build.rs` calls
  `objcopy --weaken` on each of the 4 `.a`s so the duplicated Nim runtime
  symbols (system.nim, tables.nim, etc.) don't collide at link time.

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
spier-query-ir/                    # Program IR + range-op constants
  opcodes.rs                       # Program enum (Scheme, SelectScheme), ProgramHandle, SelectSchemeMeta
  spec_kind.rs                     # SpecKind
spier-blobstore-nim/                # Rust wrapper exposing the Nim blobstore via the
                                    # BlobStoreEngine trait. build.rs invokes `nim c` 3×.
  Cargo.toml                        # deps: spier-storage-traits, libc, tempfile (dev)
  build.rs                          # compiles nim-blobstore/{memory,file,s3}/all.nim into
                                    # 3 separate .a files, runs `objcopy --weaken` on each,
                                    # links pthread + libcrypto
  src/lib.rs                        # NimBlobVtable #[repr(C)], NimBlobStore,
                                    # impl BlobStoreEngine, Send+Sync, Drop,
                                    # err_to_string (code → static str, no allocation)
nim-blobstore/                      # Pure-Nim blobstore backends — 3 self-contained dirs
  memory/                           # → libnim_blobstore_memory.a
    abi.nim                         # VTable type, error-code constants, helpers
                                    # (setErr template, allocByteBuf, newUuidBytes,
                                    # parseConfig)
    spinlock.nim                    # Raw pthread_mutex binding (std/locks needs --threads:on)
    backend.nim                     # In-memory HashMap backend
    all.nim                         # Single compilation entry point
  file/                             # → libnim_blobstore_file.a
    abi.nim, spinlock.nim           # backend-local copies (identical to memory/)
    backend.nim                     # Directory backend: hex-sharded blobs (XX/YY/<hex>),
                                    # atomic tmp+rename, zstd compression, root_ prefix,
                                    # read-only guard
    all.nim
   s3/                               # → libnim_blobstore_s3.a
     abi.nim, spinlock.nim           # backend-local copies
     sha256.nim                      # Thin OpenSSL libcrypto wrapper (EVP_Digest + HMAC)
     sigv4.nim                       # SigV4 signing (signAwsRequestV4)
     backend.nim                     # S3 backend: hand-rolled SigV4 over std/httpclient,
                                     # ListObjectsV2 with pagination, naive XML parsing
     all.nim
   journal/                           # → libnim_blobstore_journal.a
     abi.nim, spinlock.nim           # backend-local copies
     backend.nim                     # Sequential file journal at <path>/journal/journal,
                                     # frame [u32 klen][key][u32 vlen][value] (big-endian);
                                     # read re-emits all valid frames
     all.nim                         # exports nim_journal_open / nim_journal_close
 spier-journal-file/                 # JournalEngine adapter: thin Rust wrapper over
                                      # NimJournalStore (spier-blobstore-nim) via C-ABI
                                      # vtable; keeps the JournalFile name + new(config) API
spier-memtable-nim/                # NimMemTableStore: Nim-backed MemTableEngine (persistent
                                    # treap, COW snapshots, opaque-cursor FFI) — compiles
                                    # nim-memtable/ into libnim_memtable.a
spier-memtable/                    # MemTableEngine adapter over NimMemTableStore (Arc-shared);
                                    # exposes open_scan_source -> MemTableCursor
nim-memtable/                      # Pure-Nim memtable backend — persistent treap per CF
                                    # (path-copying COW), snapshot version registry,
                                    # per-handle cursor table. Exports nim_memtable_open/close.
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
  engine/                          # types, scanner, opcodes, query_engine_inner, scheme
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

The three blobstore backends (Memory, File, S3) plus the sequential **Journal**
are implemented in **Nim** and exposed to Rust via a hand-written C-ABI vtable in
`spier-blobstore-nim`. The build script (`spier-blobstore-nim/build.rs`) invokes
`nim c` **4 times** to compile `nim-blobstore/{memory,file,s3,journal}/all.nim`
into **4 separate static libraries**
(`libnim_blobstore_{memory,file,s3,journal}.a`), all linked into the Rust crate.
Backends are selected at construction time
(`spier_kvstore::KVState::open(config)`) rather than loaded as `.so` plugins.

| Backend | Directory               | Storage                                                | Use Case            |
|---------|-------------------------|--------------------------------------------------------|---------------------|
| Memory  | `nim-blobstore/memory/` | In-memory `HashMap`                                    | `:memory:` mode     |
| File    | `nim-blobstore/file/`   | Directory with zstd-compressed blobs (hex-sharded)     | Persistent local    |
| S3      | `nim-blobstore/s3/`     | S3-compatible object store via hand-rolled SigV4 (OpenSSL libcrypto + `std/httpclient`) + local journal file | Cloud/distributed |
| Journal | `nim-blobstore/journal/`| Sequential append-only file journal (`<path>/journal/journal`) | WAL / crash recovery |

Each backend directory is **self-contained** — it owns local copies of
`abi.nim` and `spinlock.nim` so the 4 `.a`s have no cross-archive symbol
references (other than libc / libpthread / libcrypto). The blobstore backends
implement the hand-written `BlobStoreEngine` trait (Rust side) by forwarding to
the Nim functions exported in the C-ABI `VTable`; the journal backend implements
`JournalEngine` via `NimJournalStore` (also in `spier-blobstore-nim`), and
`spier-journal-file` is a thin Rust adapter that re-exports the same
`JournalFile` + `new(config)` API over it.

#### FFI error protocol (POSIX-style)

Every C-ABI function returns `c_int` (`0` = success, `-1` = failure) and
takes `errOut: ptr cint`. On failure, `errOut` receives one of 9 numeric
codes defined in each `abi.nim`:

```
ErrOk=0  ErrInvalidHandle=1  ErrInvalidArg=2  ErrIo=3  ErrReadOnly=4
ErrNoMem=5  ErrNotFound=6  ErrConflict=7  ErrConfig=8
```

Rust maps codes to static strings via `match` (`err_to_string` in
`spier-blobstore-nim/src/lib.rs`). **No string allocation crosses the FFI
boundary**, so there is no `free_str` export and no `freeStr` field in the
vtable. The vtable's `free_buf` / `free_strs` are still needed for the *data*
buffers returned by `get` / `list` / `get_root` / `list_roots` (those are
allocated on Nim's shared heap).

#### Nim build flags

```
nim c --app:staticlib --noMain --mm:arc --threads:off -d:release --panics:on \
      --noNimblePath --passC:-fPIC --passL:-fPIC \
      [--passL:-lcrypto for s3] \
      --out:libnim_blobstore_<backend>.a nim-blobstore/<backend>/all.nim
```

`--threads:off` is critical: `--threads:on` (with `--tlsEmulation:on`) caused
SIGSEGV when Rust foreign threads entered Nim code. Because `--threads:off`
makes `std/locks` unavailable, each backend's `spinlock.nim` provides a raw
`pthread_mutex_t` binding instead.

#### Linking 3 self-contained archives

Each `.a` embeds its own copy of the Nim runtime (`system.nim`, `tables.nim`,
etc.). When linked into one Rust binary, the strong runtime symbols collide.
`build.rs` runs `objcopy --weaken` on each archive after `nim c`, turning all
defined globals into weak symbols so the linker silently picks the first
definition. Backend-specific exports (`nim_blob_<name>_open` / `_close`) are
unaffected — they remain strong and unique per archive.

#### Allocator boundary

Under `--mm:arc`, Nim uses its own allocator (not libc `malloc`). Any **data
buffer** returned from Nim to Rust must be released by Nim — Rust uses the
vtable's `free_buf` for byte buffers and `free_strs` for `char**` arrays.
**Never** call `libc::free` on Nim-owned memory. Error strings never cross
the boundary (numeric codes only — see above).

#### S3 backend status

The S3 backend is validated end-to-end against moto
(`tests/test_config_s3_moto.py` — 3 tests covering put/get, scan+flush, and
cursor iteration). SigV4 vectors in `s3/sha256.nim` (OpenSSL libcrypto) were
verified against the official RFC 4231 / FIPS test vectors. Real-world S3
endpoints (AWS, MinIO) should work but are not exercised in CI.

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
        → Query Engine (orchestrates two-stage compilation + Scheme IR evaluation)
          → SQL Frontend (parse + datalog IR)
          → resolve_ir (uses CompileStats, not TransactorEngine, for schema/cardinality)
          → Compiler (plan + Scheme codegen)
            → Scheme IR (stack-based evaluator with yield/resume, streaming via SchemeSession)
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

MemTableEngine is backed by a **Nim persistent treap** (path-copying COW) per CF
(`nim-memtable/`). Snapshots are O(1): `snapshot()` records the current per-CF
roots in a versioned registry and returns an opaque `u64` id wrapped in
`MemTableSnapshot { data: Arc<NimSnap(u64)> }`. `clear()` swaps the live roots
for empty ones; old snapshot roots stay alive (shared nodes, no copy) as long
as a snapshot id references them. The `MemTableSnapshot.data: Arc<dyn Any>` is
downcast to `NimSnap` on each read to recover the id.

**Rust never holds a reference to the ordered structure.** The forward scan
path (`scan_sources` → `ChunkedMemTableSource`) holds only an opaque `u64`
cursor id (`MemTableCursor`); each `advance`/`seek`/`skip_group` forwards to
the Nim cursor FFI, which yields **one key per `cursor_next`** — zero mass
materialization. The cursor holds an `Arc<NimMemTableStore>` so it stays
self-contained (the Nim handle outlives the cursor even if the parent
`MemTable` is dropped first). The reverse scan path and the flush path still
materialize via `scan_prefix`/`scan_prefix_reverse` (returning packed
`[u32 klen][key]...`) — reverse is already materialized in the merge layer,
and flush is rare (64 MB threshold).

Writes (`put`, `batch_write`, `clear`) take no snapshot; reads
(`scan_prefix`, `scan_prefix_reverse`, `contains`, `count_prefix`) all require
a snapshot parameter.

### Flush (Snapshot + Clear)

Single MemTable instance lives for the transactor's entire lifetime — no instance swapping.

1. `flush_snap = mt.snapshot()` — O(1): record current treap roots in the snapshot registry, return id
2. `mt.clear()` — O(1) per CF (swap live root for `nil`); old snapshot roots stay alive via the registry (COW, shared nodes)
3. Flush scans `flush_snap` via `scan_prefix` (materialized, rare) → merge with PageStore → commit
4. Reads during flush see: active mt + flush_snap + PageStore

### MemTable GC (ARC-driven)

The persistent treap lives inside Nim under `--mm:arc`, so node lifetime is governed by **reference counting** (ARC, deterministic, no cycles since it's a tree). A `TreapNode` stays alive as long as ANY root — live or any in-use snapshot — references it; `insert` does path-copying so old versions are shared, not mutated. The trigger for collection is the Rust → FFI → Nim `Drop` chain:

- `MemTableSnapshot.data: Arc<NimSnap>` where `NimSnap { id, store: Arc<NimMemTableStore> }`.
- `impl Drop for NimSnap` calls `((*vt).snapshot_free)(handle, id)` on the Nim side.
- `snapshotFreeImpl` clears the snapshot registry entry (`roots = @[]`, `inUse = false`) and **returns the slot to a free-list** so the registry does NOT grow monotonically across the process lifetime.
- ARC then decrements the released `TreapNode` refs; any node no longer reachable from a live root or another in-use snapshot has its refcount hit 0 and is freed.

Without that `Drop` the old COW versions would leak forever (the "immutable reference" lives inside Nim; Rust signals release via the Drop → `snapshot_free` FFI call). Cursors follow the same pattern: `MemTableCursor::drop` → `cursor_free` → slot returned to the cursor free-list.

`closeMemTable` manually clears `live` / `snaps` / `cursors` (and the free-lists) BEFORE the raw `deallocShared(handle)`: ARC does NOT run finalizers on a raw free, so without this the whole treap and every retained snapshot/cursor would leak on store close.

GC tests (`spier-memtable-nim`) use a `debug_count_nodes` FFI (counts UNIQUE node addresses reachable from any live or in-use-snapshot root via a `HashSet` of pointer addresses) to assert: (a) snapshot drop collects old COW nodes, (b) shared nodes between snapshot and live are not double-counted, (c) 1000 snapshot/drop cycles leak zero nodes.

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

### Scheme IR Execution (Pull-Based Cursor)

Programs are executed through the stack-based Scheme evaluator with yield/resume
semantics. For SELECT/UPDATE/DELETE, the triejoin skeleton produces result rows
via `result-row` forms; the evaluator yields after each row.

A `SessionHandle` (`Arc<RefCell<dyn VMResultStream>>`) wraps a `SchemeSession` or
`SelectSchemeSession` that owns the resumable evaluator. The caller pulls batches via
`session_next_batch(handle, max_rows) -> Vec<u8>`. `execute` (batch) remains as a
convenience wrapper. DML (UPDATE/DELETE) emits `(result-row eid)` inside the triejoin
leaf — the cursor streams changed eids.

The evaluator per-forms a single step (`EvalStep`) then yields (`YieldState::Return`
or `YieldState::Suspend`). `next_batch` resumes from the suspension point until
`max_rows` rows are produced or the program completes.

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

### Scheme IR (Unified Compilation Target)

All SQL statements compile to Scheme S-expressions — there is no VM bytecode.
The full reference is at `docs/scheme-ir.md`.

Key points:
- `spier-scheme` crate: zero-dep AST + parser + printer + stack-based evaluator with yield/resume
- 10 special forms: `let*`, `let`, `when`, `if`, `begin`, `set!`, `dbg`, `trace`, `log`, `assert`
- `Program::Scheme(SchemeProgram)` — UPSERT, ATTRIBUTE, PARTITION, direct DELETE
- `Program::SelectScheme(SchemeProgram, SelectSchemeMeta)` — SELECT, UPDATE, DELETE with scan
- Host functions per operation type: `SchemeHostFns` (7 functions for DML) and `SelectSchemeHostFns` (18 functions for scanning)
- EXPLAIN and `compile_sql_json` show S-expressions for all statement types
- `SchemeSession` and `SelectSchemeSession` implement `VMResultStream` for cursor-based execution
- `EvalStep` + `YieldState` streaming model: evaluate one step, yield row, resume from suspension
- Nullable alias guard: `(when alias ...)` wraps result when entity refs use `eid()`

## Conventions

- Python >= 3.13
- Attribute names: mandatory dot notation (e.g. `company.name`), EDN (`:ns/name`) accepted as input convenience
- Comments when appropriate — explain intent, not mechanics
- Test files: `test_*.py` in `tests/`
- Binary formats: big-endian struct (`">..."`)
- **Never remove or weaken failing tests to get "all green".** Use `pytest.mark.xfail` with a reason to document known bugs.
