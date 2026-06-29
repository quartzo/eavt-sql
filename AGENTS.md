# AGENTS.md

## Development Commands

- **Tests:** `uv run pytest tests/ -v`
- **Rust tests:** `cargo test --release`
- **Dependencies:** `uv sync --group dev`
- **gRPC client deps:** `uv sync --project py_eavt_client --group dev` (isolated venv, not in workspace)
- **gRPC client tests:** `uv run --project py_eavt_client pytest py_eavt_client/tests/ -v`
- **Regenerate Python gRPC stubs:** `uv run --project py_eavt_client python -m grpc_tools.protoc -I proto --python_out=py_eavt_client/src/eavt_client --grpc_python_out=py_eavt_client/src/eavt_client proto/eavt.proto` then fix import: `sed -i 's/^import eavt_pb2/from eavt_client import eavt_pb2/' py_eavt_client/src/eavt_client/eavt_pb2_grpc.py`
- All Python commands must use `uv run` (e.g. `uv run python -c ...`)

## Project Structure

```
spier-kvstore/src/        # Pure key-only KV store spier (MemTable + PageStore + flush)
  idl/                    # Storage-layer .dspi IDLs (blobstore, journal, memtable, kvstore, storage_opaque)
spier-transactor/src/     # EAVT engine spier (save/retract/declare_attr + resolver + constraints, loads spier-kvstore)
  eavt.rs                # EavtEngine { kv: DynSpireKvStore, resolver }
  resolver.rs            # Schema cache
  keys.rs                # EAVT key format helpers
spier-eavt-query/src/     # EAVT query engine (VM, triejoin, scanner, streaming). Orchestrates two-stage compilation
  engine/                # vm (ResultRow, run_batch), scanner, triejoin, opcodes, dynspire_engine, session
spier-sql-frontend/src/   # SQL frontend spier: stage 1 — parse + datalog IR (loads spier-sql-parse + spier-datalog)
spier-compiler/src/       # Compiler spier: stage 2 — plan + codegen (loads spier-planner only, no transactor)
spier-sql-parse/src/      # SQL parser spier (lexer + parser + FFI dispatch)
dynspire-commons/src/     # Shared protocol — .dspi IDLs (codegen-generated traits + tower clients) + types + utils
  transactor.dspi         # TransactorEngine IDL
  query_engine.dspi       # QueryEngine IDL
  sql_parse.dspi          # SqlParseEngine IDL
  datalog.dspi            # DatalogEngine IDL
  planner.dspi            # PlannerEngine IDL
  sql_frontend.dspi       # SqlFrontendEngine IDL (stage 1: parse + datalog)
  compiler.dspi           # CompilerEngine IDL (stage 2: plan + codegen)
  shared_types.dspi       # Value/ValueType (included by transactor + query_engine)
  opaque_types.dspi       # CursorHandle, DynSpireTransactor, VMProgram, CompileResultSt, etc.
  kvstore/                # (inline module — generated HOST code for DynSpireKvStore, used by transactor)
  compiler/               # CompileResultSt + CompileStats trait (pure Rust, not an IDL) + tower extensions
  query_ir/               # OpCode, Instruction, VMProgram (#[slot_struct], to_json), SpecKind
  transactor/             # cursor, keys, query_codec, resolver_consts, types + tower extensions
  sql_parse/              # AST types + tower extensions
  datalog/                # AST types + resolve.rs (resolve_ir, compute_stats) + tower extensions
  planner/                # AST types + tower extensions
  value.rs                # Value type + tag constants
  lib.rs                 # trace_vm(), trace_cursor() — EAVT_TRACE env var (cached AtomicBool)
eavt-cli/src/            # REPL client (gRPC, binary: eavt-repl)
eavt-server/             # gRPC server (tonic, proto, binary: eavt-server)
dynspire-libs/src/       # Shared constants (CF names, flush threshold)
src/eavt_sql/            # Python package
  __init__.py            # Re-exports Rust classes + constants
  _ffi.py                # load_spier: loads codegen-emitted typed ctypes clients (no dynspire dep, no schema introspection)
  engine.py              # EAVT engine (uses _Storage protocol)
  sql_parse_client.py    # SqlParseClient (spier-sql-parse via FFI)
  query_codec.py         # Value serialization for query params/results
  types.py               # Datom, Timestamp, ref, etc.
tests/                   # Python tests (flat)
  helpers.py             # unpack_keys, unpack_kv for packed Vec<u8> formats
spier-sql-parse/tests/   # Python tests for spier-sql-parse FFI
spier-memtable/          # MemTable spier (crossbeam SkipMap per CF, key-only, Arc-swap snapshots)
spier-kvstore/           # Pure KV store spier (MemTable + PageStore + flush, loads blobstore/journal/memtable)
```

## Architecture

### Storage Backends

The Transactor uses DynSpire spier plugins (`.so` loaded at runtime) with three pluggable backends:

| Backend | Spier | Storage | Use Case |
|---------|-------|---------|----------|
| Memory  | `spier-blobstore-memory` | In-memory `HashMap` | `:memory:` mode |
| File    | `spier-blobstore-file` | Directory with zstd-compressed blobs + journal file | Persistent local |
| S3      | `spier-blobstore-s3` | S3-compatible object store + local journal file | Cloud/distributed |

All backends implement the `BlobStoreEngine` IDL. Journal is a separate IDL (`JournalEngine`).

### Storage Layers

```
BlobStore (Memory / File / S3)
  → GenericPageStore (BTreeMap index per CF, root blob with UUID references)
    → KVStore (single MemTable instance + GenericPageStore, snapshot flush)
      │  background poller: auto-flush by threshold + auto-GC by age
      → Transactor/EavtEngine (EAVT: save/retract + resolver + eager constraints, loads spier-kvstore via tower)
        → Query Engine (orchestrates two-stage compilation + VM)
          → SQL Frontend (parse + datalog IR, loads spier-sql-parse + spier-datalog)
          → resolve_ir (in-process, uses transactor for schema resolution)
          → Compiler (plan + codegen, loads spier-planner only)
            → VM (triejoin, leapfrog, scanner, streaming via thread + bounded queue)
```

### DynSpire is In-Process, Not RPC — Read This First

> **Mental model warning (especially for LLMs):** terms like "IDL", "tower client",
> "dispatch", "host/spier" *look* like RPC. They are **not**. A spier is a `.so` loaded via
> `dlopen` into **the same process and same address space** as the host. A method call is a
> **C ABI call over a flat `u64[]` slot buffer** — no network, no IPC, no wire format, no
> serialization layer. Host and spier share one heap, and **pointers are valid across the
> boundary**.

Consequences that hold here but **do not hold under an RPC mental model**:

- **Live objects cross as opaque pointers (1 slot) via `#[slot_struct]`.** The struct is
  `Box::into_raw`'d on the sender side and stays *live* — not serialized. Both sides alias
  the same memory. State machines, locks, `Arc`, inner references all travel intact.
- **Borrows are zero-copy.** `&[u8]` / `&str` pass `(ptr, len)` pointing at the caller's
  memory; the spier reads it directly. `&mut Vec<u8>` passes a raw pointer to the caller's
  `Vec`; the spier pushes into it and the host sees the writes **immediately** on return.
- **The IDL hash gates binary/ABI compatibility between two `.so` files** compiled against
  the same trait — it is not message-schema versioning (not protobuf/gRPC/Avro).
- **Trait objects dispatch directly via vtable.** A `Box<dyn Trait>` where `Trait` is
  defined in `dynspire-commons` crosses as 1 slot via `#[slot_struct]`. The receiver calls
  methods directly — in-process vtable dispatch, **not** a per-call FFI hop. Both sides
  link the same `dynspire-commons`, so the vtable layout is consistent.

Concrete examples in this repo (all are pointer transport, not serialization):

| What crosses FFI | How | Where |
|------------------|-----|-------|
| `MemTableSnapshot` (live `Arc<dyn Any>` over `Vec<Arc<SkipMap>>`) | 1 slot, `#[slot_struct]` — snapshot stays refcounted & live; reads alias it | `spier-kvstore/src/idl/storage_opaque.dspi` |
| `DynSpireTransactor` (whole client handle, `Arc<DynSpireClient>`) | 1 slot, `#[slot_struct]` | `dynspire-commons/src/transactor.dspi` |
| `VMProgram` (`Vec<Instruction>` + `Vec<String>` + nested Vecs) | 1 slot, `#[slot_struct]` — **no flattening**, the whole tree moves as one pointer | `dynspire-commons/src/query_ir/opcodes.rs:185` |
| Live cursor | `CursorHandle` (`Arc<RefCell<dyn Cursor>>`) via `#[slot_struct]` — Rust callers call `step()`/`seek()`/`skip_group()` via vtable with zero per-call FFI. Python callers receive a generated `CursorHandle` (`OpaqueHandle`) from `open_cursor_direct` and pass it to `cursor_*` typed methods (same 1-slot wire format). GC via Arc refcount + `OpaqueHandle.__del__` (Python) / `Drop` (Rust) — no `cursor_close` | `dynspire-commons/src/transactor/cursor.rs` |
| `RustStmt` (enum — can't be `#[slot_struct]` directly) | Wrapped in `RustStmtSt { stmt: RustStmt }` (`#[slot_struct]`) — crosses as 1 boxed pointer, caller extracts `.stmt` | `dynspire-commons/src/sql_parse/mod.rs` |
| Bulk key batches | `&mut Vec<u8>` out-param — spier writes directly into caller's allocation, visible on return | `cursor_current_key` |

**Don't / Do** (common LLM mistakes):

- ❌ "Serialize this struct to bytes / msgpack / JSON to send it across FFI."
  → ✅ Make it a `#[slot_struct]`. It crosses as 1 boxed pointer. The nested `Vec<String>`,
    `Vec<Instruction>`, etc. ride along *unserialized*.
- ❌ "Enums can't cross FFI — serialize them to JSON / a discriminant int."
  → ✅ Wrap the enum in a struct: `RustStmtSt { stmt: RustStmt }` annotated with
    `#[slot_struct]`. The struct crosses as 1 boxed pointer; the caller extracts `.stmt`.
    Never write manual `impl SlotReturn`/`SlotReceive` with `Box::into_raw`/`from_raw`.
- ❌ "We can't return a stateful object (cursor / iterator / snapshot) — RPC can't transport that."
  → ✅ Yes you can. `#[slot_struct]` the whole object — it crosses as 1 boxed pointer.
    No need for `u64` handles or a server-side `HashMap<id, object>`.
- ❌ "Stateful objects must use `u64` handles — you can't call methods on a received object across FFI."
  → ✅ If a trait is defined in `dynspire-commons`, any spier can receive `Arc<RefCell<dyn Trait>>`
    via `#[slot_struct]` and call methods directly (in-process vtable dispatch, zero per-call
    FFI). GC is automatic via Arc refcount + `OpaqueHandle.__del__` (Python) / `Drop` (Rust).
    The `u64` handle pattern is an **unnecessary indirection** — `#[slot_struct]` already
    transports as 1 slot (boxed pointer).
- ❌ "Add a length prefix / framing because data crosses a process boundary."
  → ✅ `&[u8]` and `Vec<T>` already carry `(ptr, len)` — that *is* the framing. Extra
    prefixes are only needed when you deliberately pack heterogeneous records into one
    buffer (see "Vec<u8> as Lingua Franca" below).
- ❌ "`Vec<Vec<u8>>` can't cross FFI, so flatten it."
  → ✅ It *can* cross for Rust→Rust (`Vec<T: Clone>` input = `(ptr, len)`, spier clones the
    slice). It can't be constructed by Python. Flattening in this repo is a Python-compat /
    explicit-format choice, **not** an FFI limitation.

The packed `Vec<u8>` formats in the next section exist for two reasons only: **Python
callers** (which can't lay out Rust memory) and **explicit opaque blob formats** (journal,
SST pages). They are *not* the general transport — `#[slot_struct]` pointer transport is.

**Two transport modes — IDL interface dispatch vs `#[slot_struct]`:**

- IDL interface dispatch (C ABI slot dispatch via `dynspire-codegen`) is the *verified*
  contract — the IDL hash gates compatibility between two `.so` files compiled against the
  same `.dspi` interface. Use when you need a checked ABI boundary.
- `#[slot_struct]` pointer transport is the *direct* contract — the receiver gets a live
  object and can call methods on it via vtable (if a shared trait exists in
  `dynspire-commons`) or hold it opaque. Use when both sides link the same crate and you
  want zero per-call dispatch overhead.

**Multi-hop dispatch is avoidable.** When spier A loads spier B via a `Dyn*` tower client,
and spier C needs B's objects, C should receive them directly (as `#[slot_struct]`) rather
than relaying through A — each spier boundary in the chain adds an FFI dispatch hop. A
chain like query → transactor → kvstore incurs two hops per call; if the transactor
returned the kvstore's cursor as `Arc<RefCell<dyn Cursor>>` (via `#[slot_struct]`), the query engine would call methods
directly with zero FFI per step/seek/skip_group.

### Vec<u8> as Lingua Franca

Bulk data that crosses to **Python**, or that needs an explicit on-disk/blob format, is
packed into `Vec<u8>` — 2 slots (`[ptr, len]`) regardless of data volume. (Rust→Rust can
pass `Vec<T: Clone>` directly as `(ptr, len)` — see the section above. Python callers can't
construct Rust memory layouts, so they serialize to `&[u8]` instead.)

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
the live MemTable swaps in a fresh empty map (see Flush below): between `snapshot()` and
`clear()`, writes to the live map are visible to the snapshot too. All reads require a
`MemTableSnapshot`. The snapshot type is `#[slot_struct]` with `Arc<dyn Any + Send + Sync>`
— opaque to dynspire-commons, refcount-managed (no explicit drop). Reads are lock-free;
`scan_prefix` / `scan_prefix_reverse` materialize matching keys into a packed `Vec<u8>`.

**IDL:** writes (`put`, `batch_write`, `drain`, `clear`) take no snapshot; reads
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

**Write lock granularity — read this before reasoning about concurrency:**

- The only write lock is `resolver: Mutex<Resolver>` (`spier-transactor/src/eavt.rs:155`). It is
  **global in space** (one mutex, not per-record / per-entity / per-attribute) but **per-datom
  in time**.
- Every write method — `save_at_t` (`eavt.rs:453`), `retract_at_t` (`eavt.rs:497`),
  `declare_attr_with_t` (`eavt.rs:535`) — acquires `resolver.lock()` at entry and releases it at
  the function's return, i.e. for **one datom**, not for a whole SQL statement.
- UNIQUE constraints are validated **eagerly and atomically per-datom**: `save_at_t` calls
  `check_unique_constraint` (`eavt.rs:473`) **inside** the same lock acquisition as the write, so
  there is no check-then-act (TOCTOU) race between concurrent writers.

**Consequences for long statements (UPDATE / DELETE scans):**

- A multi-row UPDATE/DELETE compiles to a triejoin scan interleaved with `ExecInsert` /
  `ExecRetract` opcodes (see "Architecture"). The **scan phase holds no resolver lock** — reads
  go through the KVStore `RwLock<StoreInner>` read path only (`spier-kvstore/src/store.rs:226`).
- Each `ExecInsert`/`ExecRetract` crosses into `save_at_t`/`retract_at_t` and takes the resolver
  mutex **for that one datom**, then releases it. Between datoms, other writers can interleave.
- Therefore a multi-datom UPDATE/DELETE is **not atomic**: concurrent writers may observe or
  mutate state between individual datom writes. This is intentional under the single-writer-serial
  model. Statement-level atomicity would require adding a transaction mechanism.

### VM Result Streaming (Pull-Based Cursor)

The VM is resumable: `VM::run_batch(out, max_rows) -> bool` runs until `max_rows`
rows are produced or the program halts. `run()` loops `run_batch` to completion.

A `SessionHandle` (`#[slot_struct]`, `Arc<RefCell<dyn VMResultStream>>`) wraps a
`VMSession` that owns the resumable VM. The caller pulls batches via
`session_next_batch(handle, max_rows) -> Vec<u8>`. Wire format: `[u32 ncols][values]...`
per row, repeated. Empty Vec = done. Cleanup is automatic (Arc refcount + `Drop`).

**IDL:** `run_vm_cursor(program, ...) -> SessionHandle`, `session_next_batch(session, max_rows) -> Vec<u8>`.
`run_vm` (batch) remains as a convenience wrapper. DML (UPDATE/DELETE) emits
`ResultRow(r_ent)` inside the triejoin leaf — the cursor streams changed eids.

### Cursor Transport

`open_cursor_direct` returns a `CursorHandle` (`Arc<RefCell<dyn Cursor>>`) via
`#[slot_struct]` pointer transport. Rust callers receive the `CursorHandle` and
call `step()`/`seek()`/`skip_group()` directly via the `Cursor` trait vtable —
zero per-call FFI.

Python ctypes callers receive an `FFIResource` wrapping the boxed pointer. The
`cursor_*` methods (`cursor_step`, `cursor_current_key`, `cursor_seek`,
`cursor_skip_group`, `cursor_update_end`, `cursor_valid`) take `CursorHandle` —
Python passes the `FFIResource` and the slot system extracts the pointer (1 slot,
identical wire format to `u64`). No `cursor_close` — cleanup is automatic via
`FFIResource.__del__` (Python) or `Drop` (Rust, Arc refcount).

`cursor_current_key` checks `is_valid()` first — returns `false` when the cursor is
exhausted (the underlying `MergedInner` does not clear `cur_key` when invalidated).

### Key Design Points

- **4 column families**: CFs 0-3 all key-only (eavt, aevt, avet, vaet indexes)
- **Page format**: `[num_keys u16][varint plen][varint slen][suffix]...` — prefix compression with varint sizes (7-bit, MSB=continuation), binary split at 256KB raw key data
- **GenericPageStore**: each CF is a `BTreeMap<key_bytes, blob_uuid>`. Root blob stores CF index UUIDs + dead blob groups for GC.
- **BlobStore**: data compressed with zstd, atomic writes via temp+rename (file backend). Blobs stored in 2-level hex prefix directory structure.
- **GC**: old blobs tracked as dead groups with timestamps. `gc()` removes roots older than `gc_max_age_secs` (default 43200s = 12h) **or** beyond `gc_max_root_count` newest roots (default 10). Background poller checks `has_gc_candidates()` before running full scan.
- **Write path**: `put()` → journal append → MemTable → auto-flush when >= `flush_threshold`
- **Non-blocking ops**: explicit `flush()` and `gc_full()` use `try_lock` — return `Busy` if another operation holds the lock, never block.
- **Background poller**: thread in TransactorState, spawned on `init()`, stopped on `close()`. Polls every `poll_interval_secs` (default 300): checks memtable size → flush if exceeded, then checks `has_gc_candidates()` → GC if eligible. All non-blocking.
- **Config**: `poll_interval_secs` (300), `flush_threshold` (67108864 = 64MB), `page_cache_size` (67108864 = 64MB), `gc_max_age_secs` (43200), `gc_max_root_count` (10) — parsed from init `config: HashMap<String,String>`, forwarded end-to-end through query → transactor → kvstore layers
- **Read path**: MemTable snapshot → flush_snap → GenericPageStore point lookup
- **Scan path**: `scan_sources` merges PageStore + flush_snap + active MemTable snapshot into heap-merged sources
- **Scanner reuse**: `TrieIterator::up()` drops the scanner; `open_with_engine()` creates a new one each time via `create_scanner`. No cursor-level reuse — `scan_sources` is the dominant cost regardless.
- **EAVT_TRACE**: env var `EAVT_TRACE=vm,cursor` (or `all`/`1`) enables execution tracing. Cached `AtomicBool` — one env read, zero overhead when disabled.
- **Recovery**: on open, replay journal into MemTable
- **S3 mode**: blobs on S3, journal file on local disk
- **Python layer**: engine.py (EAVT semantics), sql_parse_client.py, query_codec.py, types.py
- **FFI**: `src/eavt_sql/_ffi.py` loads code-generated typed ctypes clients — each spier's `build.rs` emits `<crate>/generated/<spier>.py` via `dynspire-codegen`'s `build_python()`. The generated module is self-contained (stdlib `ctypes`/`struct` only); the IDL hash, `dynspire_free` type indices, slot layout, and type classes (`Value`, `ValueType`, `CursorHandle`, ...) are baked in at build time. `load_spier(name)` resolves `lib<name>.so` + the generated `.py` and returns a `SpierLib`; `create_handle(config)` returns the typed client — call methods directly (`h.put(cf, key)`), no dict dispatch, no runtime schema reflection. Cursor outvec methods (e.g. `cursor_current_key`) return `(value, [outvecs])`. Opaque handles (`CursorHandle`/`SessionHandle`/`ProgramHandle`) are `OpaqueHandle` instances, GC'd via `__del__` → `dynspire_free`.

## Conventions

- Python >= 3.13
- Attribute names: mandatory dot notation (e.g. `company.name`), EDN (`:ns/name`) accepted as input convenience
- Comments when appropriate — explain intent, not mechanics
- Test files: `test_*.py` in `tests/`
- Binary formats: big-endian struct (`">..."`)
- **Never remove or weaken failing tests to get "all green".** Use `pytest.mark.xfail` with a reason to document known bugs.
