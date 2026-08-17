# AGENTS.md

## Development Commands

- **Nim tests (compile + run):** `nimble test` — compiles `build/all_tests` and runs it (~492 tests)
- **Re-run tests without recompiling:** `./build/all_tests` — binary already compiled
- **Check which tests failed:** `./build/all_tests 2>&1 | grep FAILED`
- **Count failures:** `./build/all_tests 2>&1 | grep -c FAILED`
- **Module-level tests:** `nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r nim_eavt/test_eavt.nim` (replace module as needed)
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
nim c --mm:atomicArc --threads:on -d:release -d:useMalloc -r nim_eavt/test_eavt.nim 2>&1 | tail -40
```

**Never:** `nimble test 2>&1 | grep "\[OK\]" | wc -l` without first seeing compiler
output. This hides compile errors (0 OK = could be 0 tests compiled) and forces
unnecessary recompilation.

### Prerequisites

- **Nim ≥ 2.0.14** — with `--mm:atomicArc --threads:on -d:useMalloc` for all modules (atomic ref counting, thread-safe)

## Project Structure

```
eavt_server_nim/           # Data server: scheme/schema/admin/kv over UDS (msgpack, thread-per-connection)
eavt_gateway_nim/           # Gateway: compiles SQL→Scheme (chronos, single-thread async), forwards to data server
eavt-repl-nim/              # REPL client (linenoise, tab-separated output; orc, no threads)
py_eavt_client/             # Python UDS client (msgpack; sql/scheme/schema/admin)
nim_sql_parse/              # D.1 — SQL lexer + recursive-descent parser
nim_datalog/                # D.2 — SQL AST → Datalog IR (EAVT patterns)
nim_planner/                # D.3 — Cost-based join ordering (EAVT/AEVT/AVET/VAET)
nim_compiler/               # D.4 — Datalog IR → Scheme S-expressions
nim_sql_frontend/           # Orchestration: parse → compile → SchemeProgram
nim_scheme/                 # S-expr parser + stack VM with yield/resume
nim_query/                  # Scanner, hostfns (22 ops), leapfrog triejoin
nim_eavt/                   # EAVT engine: save/retract + resolver + constraints
nim_kvstore/                # KVStore + MergedCursor
nim_memtable/               # Per-CF COW treap (ARC-managed)
nim_page_store/             # COW B-tree, zstd-compressed pages, LRU cache
nim_blobstore/              # memory / file / S3 backends + journal
nim_spawn/                  # pool-less fire-and-forget spawn (server + flush)
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

The persistent treap uses `--mm:atomicArc`, so node lifetime is governed by
reference counting. `insert` does path-copying — old versions are shared, not mutated.
Cursors hold a `TreapNode` ref directly. No snapshot registry.

### Flush

1. `kv.flushRoots = kv.mt.hnd.live` — capture current COW roots
2. `kv.mt.clear()` — nil live roots
3. Scan captured roots → merge with PageStore → commit

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
| data server | thread-per-connection via `nim_spawn` + background flush thread | `--mm:atomicArc --threads:on` |
| gateway | **single-thread** chronos event loop (no `nim_spawn`, no locks) | `--mm:orc --threads:off` |
| REPL CLI | single-thread blocking I/O | `--mm:orc --threads:off` |

**NEVER call `createThread` / instantiate raw `Thread[T]`** — this is a low-level
API that requires manual lifecycle management of the thread handle. If a `Thread[T]`
local goes out of scope before the spawned thread has read its descriptor, the main
thread's `nimZeroMem` (generated by Nim for the new local) zeroes `dataFn` to NULL
while the child reads it in `threadProcWrapDispatch`, producing a SIGSEGV at address
`0x0`. gdb masks this race (timing changes), making it extremely hard to diagnose.
This bug took down `eavt_server_nim/server.nim` on every CLI command.

For DB workloads (thread-per-connection server, background flush) use **`nim_spawn`**
(`spawn` / `initSpawn`) instead. It is a small pool-less, fire-and-forget spawn
implemented in this repo: each `spawn(fn)` launches a fresh Nim thread that runs `fn`
and exits — no fixed concurrency limit, no `awaitAll`/join, no backpressure channel.
Thread handles live in a fixed-size global array (stable addresses, dodging the
createThread-on-stack race above) and are reaped on each `spawn`. Built for
`--mm:atomicArc` (workers are Nim-native, atomic ref counting — no cycle collector needed)
collector).

**Closure-capture rule when spawning in a loop:** a closure that reads a loop or
body-local variable shares the frame slot — spawned threads read it *late* and get
duplicated values (observed t=1,2,3,3 with t=0 never running). `let` does not help.
Use the factory pattern: `proc makeWorker(fd: T): proc() {.gcsafe.} = result = proc()
= serve(fd)` — parameters captured by a *returned* closure are heap-allocated per call.

**Async (chronos) is for the gateway only.** The data server stays thread-per-connection
(shared engine + flush thread); the gateway is one chronos event loop where each client
callback owns its downstream connection. Compilations run inline on the loop (ms-scale).

`malebolgia` is **optional** — keep it available only for structured, CPU-bound,
finite parallelism (where its `awaitAll` barrier and bounded pool are a feature).
Do not use it for the server's connection loop or for flush.

**`{.cast(gcsafe).}` is forbidden in application code** — it hides real data races
and wastes debugging time. If the compiler says something is not gcsafe, fix the
root cause. The one explicit carve-out is `nim_spawn/spawn.nim` itself: its handle
table is GC'ed (`ref` closure carriers), so the access procs cannot be auto-proven
gcsafe; every access is serialised by `gLock`, and the casts there are a real
guarantee rather than a suppression. This module is the only place cast(gcsafe)
is permitted.
