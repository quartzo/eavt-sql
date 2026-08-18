# AGENTS.md

## Development Commands

- **Nim tests (compile + run):** `nimble test` — compiles `build/all_tests` and runs it (~492 tests)
- **Re-run tests without recompiling:** `./build/all_tests` — binary already compiled
- **Check which tests failed:** `./build/all_tests 2>&1 | grep FAILED`
- **Count failures:** `./build/all_tests 2>&1 | grep -c FAILED`
- **Module-level tests:** `nim c --mm:orc --threads:on -d:release -d:useMalloc -r nim_eavt/test_eavt.nim` (replace module as needed)
- **Build data server + gateway + REPL:** `nimble dist` → `build/eavt-sql-server`, `build/eavt-sql-gateway`, `build/eavt-sql-cli`
- **Run the stack (data server + gateway):** `nimble dev` (or `scripts/dev.sh`) — Ctrl-C stops both
- **Python benchmarks:** `uv run python tests/bench.py` (requires msgpack)
- **Python deps:** `uv sync --group dev`

### Testing Workflow

Always verify compilation BEFORE checking test results. A missing binary
or compile error will produce misleading output from `grep`.

```bash
# 1. Compile + run full suite, see end of output (includes compile errors + test summary)
nimble test 2>&1 | tail -20

# 2. If it compiled and ran, check specific results:
./build/all_tests 2>&1 | grep FAILED          # which tests failed
./build/all_tests 2>&1 | grep -c FAILED       # how many

# 3. For a single module (compiles + runs, shows full output):
nim c --mm:orc --threads:on -d:release -d:useMalloc -r nim_eavt/test_eavt.nim 2>&1 | tail -40
```

**Never:** `nimble test 2>&1 | grep "\[OK\]" | wc -l` without first seeing compiler
output. This hides compile errors (0 OK = could be 0 tests compiled) and forces
unnecessary recompilation.

### Prerequisites

- **Nim ≥ 2.0.14** — with `--mm:orc --threads:on -d:useMalloc` for everything (atomic ref counting under threads, plus the cycle collector). Storage is acyclic by design, so it also passes under `--mm:atomicArc` if you ever need a cycle-collector-free build.

## Project Structure

```
eavt_server_nim/           # Data server: scheme/schema/admin/kv over UDS (msgpack, chronos loop + blob pool)
eavt_gateway_nim/           # Gateway: compiles SQL→Scheme (chronos, single-thread async), forwards to data server
eavt-repl-nim/              # REPL client (linenoise, tab-separated output; orc, no threads)
py_eavt_client/             # Python UDS client (msgpack; sql/scheme/schema/admin)
vendor/chronos_file_pkg/    # Vendored chronos-file (async file I/O; WAL + async blobstore bridge) — see VENDORED.md
nim_blobstore/async/      # Async blobstore facade (pool bridge over sync trait; file/s3 via same bridge)
nim_kvstore/async/        # Async KVStore twin: flush + GC on the event loop (chronos, blob pool)
nim_sql_parse/              # D.1 — SQL lexer + recursive-descent parser
nim_datalog/                # D.2 — SQL AST → Datalog IR (EAVT patterns)
nim_planner/                # D.3 — Cost-based join ordering (EAVT/AEVT/AVET/VAET)
nim_compiler/               # D.4 — Datalog IR → Scheme S-expressions
nim_sql_frontend/           # Orchestration: parse → compile → SchemeProgram
nim_scheme/                 # S-expr parser + stack VM with yield/resume
nim_query/                  # Scanner, hostfns (22 ops), leapfrog triejoin
nim_eavt/                   # EAVT engine: save/retract + resolver + constraints
nim_kvstore/                # KVStore + MergedCursor (sync + async twin in async/ subdir)
nim_memtable/               # Per-CF COW treap (ARC-managed)
nim_page_store/             # COW B-tree, zstd-compressed pages, LRU cache
nim_blobstore/              # file / S3 backends + journal + async facade (no memory backend)
build/                      # Compiled binaries (gitignored)
tests/                      # Python benchmarks
```

## Architecture

### Compiler Pipeline (Pure Nim)

```
SQL text
  → nim_sql_parse    (lexer + parser → AST)
  → nim_datalog      (AST → Datalog IR)
  → nim_planner      (join ordering + index selection)
  → nim_compiler     (Datalog IR → Scheme S-expressions)
  → nim_scheme       (stack VM with yield/resume)
  → nim_query        (scanner, hostfns, leapfrog triejoin)
  → nim_eavt         (save/retract + resolver)
  → nim_kvstore      (MemTable + PageStore + MergedCursor)
```

### Storage Layers

```
BlobStore (Memory / File / S3)
  → PageStore (COW B-tree per CF, zstd-compressed blobs, LRU page cache)
    → KVStore (MemTable + PageStore + journal)
      → EavtEngine (save/retract + bootstrap + resolver)
        → Query Engine (Scheme IR → scanner → streaming results)
```

### Server Protocol

- **Processes:** gateway owns `eavt.sock` (clients connect here); data server
  listens on `eavt-data.sock`. SQL is compiled to Scheme **at the gateway**
  (`docs/scheme-transport.md`); the data server is a pure execution engine.
- **Request types (data server):** `scheme` (tagged-AST program + `mode`
  query|exec + `params`), `schema` (CompileStats snapshot), `admin`, `kv`.
  The gateway additionally accepts `sql` (text + params) and passes the rest
  through verbatim.
- **Position-independence rule:** compiled programs never embed attribute ids;
  attributes resolve by name at execution time (`intern-a`).
- **Transport:** Unix Domain Socket (`$XDG_RUNTIME_DIR/eavt/`)
- **Framing:** 4 bytes big-endian length prefix + MessagePack payload
- **Streaming:** Responses chunked with `{"rows": [...], "more": bool}`
- **Types preserved:** int64, float64, bool, string, bytes via msgpack

### Key Encoding

- **All int64 values sign-flipped** (XOR with `1<<63`) for lexicographic ordering
- **EID, aid, value** in keys: all use `encodeInt` / `decodeInt64` (sign-flip)
- **Suffix** (t + retracted): raw cast, no sign-flip (loses 1 bit to retracted flag)
- **Strings:** 8+1 block encoding (`encodeVariable` / `decodeVariableStr`)
- **Bytes/Blob:** 4-byte length prefix + raw bytes

### MemTable (ARC-driven COW)

The persistent treap uses ARC-family refcounting (`--mm:orc`), so node lifetime is
governed by atomic reference counting. `insert` does path-copying — old versions are shared, not mutated.
Cursors hold a `TreapNode` ref directly. No snapshot registry.

### Flush

Flush runs on the event loop (no thread): the `AsyncFlusher` in
`nim_kvstore/async/kvstore_async.nim` drives it via the blob pool.

1. `kv.flushRoots = kv.mt.hnd.live` — capture current COW roots
2. `kv.mt.clear()` — nil live roots
3. **Chunked drain** (~256 KiB slices, `await sleepAsync(0)` between)
   — the loop keeps serving queries between slices
4. Async commit: each page write awaits the blob pool (zstd + backend in worker)
5. Publish: `kv.flushRoots = @[]`; `kv.walDurableUpTo` set

Single-flight via a Future waiter queue (`AsyncFlusher.waiters`); concurrent
requests collapse. `batchWrite` threshold crossing arms the onFlushRequest
hook → `requestFlushAsync` (the server installs it in `shared_engine.nim`).

Post-flush auto-GC: after every flush the runner does a cheap
`hasOldRootsAsync` check and, when roots/blobs are past the retention
window (`gc_max_age_secs`/`gc_root_count`), a full `gcFullAsync` pass —
the original Rust poller semantics, minus the thread.

### Bootstrap

On first startup, `bootstrapSystemAttrs()` writes 26 system attributes (db.ident,
db.cardinality, db.valueType, etc.) with full metadata to the MemTable.
Re-bootstrap is prevented by scanning for existing `db.ident` datom (aid=1).

## Conventions

- Nim module names: snake_case (`nim_sql_parse`, `nim_blobstore`)
- Config: `Table[string, string]` (no CStringArr, no C-ABI)
- Journal: `ref object` with direct methods (no vtable, no cdecl)
- Binary output: `build/` directory (gitignored)
- Attribute names: mandatory dot notation (`company.name`)
- Binary formats: big-endian

### Threading Rules

**Threading model per process:**

| Process | Model | Flags |
|---------|-------|-------|
| data server | **single chronos event loop** (queries/exec inline, VM yield/resume between batches) + blob pool (2-4 POD workers for zstd + blob I/O) + chronos_file pool (WAL) | `--mm:orc --threads:on` |
| gateway | **single chronos event loop** (no threads of its own) | `--mm:orc --threads:off` |
| REPL CLI | single-thread blocking I/O | `--mm:orc --threads:off` |

`chronos-file` (vendored at `vendor/chronos_file_pkg/`, see VENDORED.md) provides
the async file I/O the data server's segmented WAL uses: writes go through its
thread-pool backend (`writeAt`), fsync on a 100ms timer (interval durability —
process crash is always safe, machine crash loses at most ~100ms; see `docs/wal.md`).
The segmented WAL **rotates at flush-capture boundaries** so records written during a
flush survive it. Everything runs `--mm:orc` — suite and all three binaries.
(Storage is acyclic by design; `atomicArc` also passed, kept as a property note,
not an exercised configuration.)

`nim_blobstore/async/` is the async facade over the sync `BlobStore` trait:
a pool of 2-4 worker threads bridges `putPage`/`getPage`/`putRoot`/`getRoot`
operations (zstd compress/decompress inside the worker) off the event loop;
completion crosses to the loop via `ThreadSignalPtr` (eventfd) — only the loop
completes Futures. GC payloads (`seq[byte]` pages, result `seq`s) are owned by
the loop (in-flight table keeps them alive until the future settles); workers see
raw pointers only. The sync trait stays for the main test suite —
`all_tests` does not import the async module (same orc flags, separate binary).

`nim_kvstore/async/` is the async twin of `kvstore` (flush/GC on the loop):
flush/GC run on the event loop, all blob I/O through the pool, every GC ref
loop-owned. The server wires it in `shared_engine.nim` via `onFlushRequest`
(threshold crossing) and admin commands (`flush`, `flush-sync`, `gc`, `gc-dry`).

**`{.cast(gcsafe).}` is forbidden in application code** — it hides real data races
and wastes debugging time. If the compiler says something is not gcsafe, fix the
root cause.

**NEVER call `createThread` / instantiate raw `Thread[T]` in production code.**
The `Thread[T]` lifecycle requires manual management: if a local goes out of scope
before the spawned thread reads its descriptor, `nimZeroMem` zeroes `dataFn` while
the child reads it → SIGSEGV at address 0x0 (gdb masks the timing, making it
extremely hard to diagnose). Test-local threads joined before scope exit are the
sole exception — see below.

**Test-local threads (concurrency tests):** for bounded, structured test
parallelism (e.g. concurrent putters in `test_kvstore.nim`, `test_eavt.nim`),
use raw `Thread[T]` with a POD arg object and `joinThread` before scope exit.
This avoids the createThread-on-stack race (AGENTS.md: the join happens while
the handle is still alive, so `nimZeroMem` can never race the child's descriptor
read) and, unlike a global thread table, args are destroyed deterministically on
the main thread. See `test_kvstore.nim` `PutterArg`/`runThreads` and
`test_eavt.nim` `EavtJob`/`runJobs` for the pattern.

`malebolgia` is **optional** — keep it available only for structured, CPU-bound,
finite parallelism (where its `awaitAll` barrier and bounded pool are a feature).
Do not use it for the server's connection loop or for flush.

