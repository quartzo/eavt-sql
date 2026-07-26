# AGENTS.md

## Development Commands

- **Nim tests (compile + run):** `nimble test` — compiles `build/all_tests` and runs it (~492 tests)
- **Re-run tests without recompiling:** `./build/all_tests` — binary already compiled
- **Check which tests failed:** `./build/all_tests 2>&1 | grep FAILED`
- **Count failures:** `./build/all_tests 2>&1 | grep -c FAILED`
- **Module-level tests:** `nim c --mm:arc --threads:on -d:release -r nim_eavt/test_eavt.nim` (replace module as needed)
- **Build server + REPL:** `nimble dist` → `build/eavt-sql-server`, `build/eavt-sql-cli`
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
nim c --mm:arc --threads:on -d:release -r nim_eavt/test_eavt.nim 2>&1 | tail -40
```

**Never:** `nimble test 2>&1 | grep "\[OK\]" | wc -l` without first seeing compiler
output. This hides compile errors (0 OK = could be 0 tests compiled) and forces
unnecessary recompilation.

### Prerequisites

- **Nim ≥ 2.0.14** — with `--mm:arc --threads:on` for engine modules, `--mm:orc --threads:on` for server (thread-safe ref counting)

## Project Structure

```
eavt_server_nim/           # UDS server (msgpack, thread-per-connection)
eavt-repl-nim/              # REPL client (linenoise, tab-separated output)
py_eavt_client/             # Python UDS client (msgpack)
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

- **Transport:** Unix Domain Socket (`/run/user/$UID/eavt/eavt.sock`)
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

The persistent treap uses `--mm:arc`, so node lifetime is governed by
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

**NEVER use `{.cast(gcsafe).}:`** — it hides real data races and wastes debugging time.
If the compiler says something is not gcsafe, fix the root cause instead.

**NEVER call `createThread` / instantiate raw `Thread[T]`** — this is a low-level
API that requires manual lifecycle management of the thread handle. If a `Thread[T]`
local goes out of scope before the spawned thread has read its descriptor, the main
thread's `nimZeroMem` (generated by Nim for the new local) zeroes `dataFn` to NULL
while the child reads it in `threadProcWrapDispatch`, producing a SIGSEGV at address
`0x0`. gdb masks this race (timing changes), making it extremely hard to diagnose.
This bug took down `eavt_server_nim/server.nim` on every CLI command.

For DB workloads (CPU/disk-intensive, thread-per-connection in the server), use the
**malebolgia** thread pool (`spawn` / `parallel` / `Await`) instead. It owns thread
handles internally, is built for `--mm:orc`, and lets the engine stay a plain shared
`ref` passed as the spawn argument — no globals, no `cast(gcsafe)`. This matches the
intent of the refactor in commit `e9587f1` ("ConnArg replaces gEng global").
