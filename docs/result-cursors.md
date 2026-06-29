# VM Result Cursors — Unified Streaming via Pull-Based Cursors

**Status:** Implemented (Steps 1-8). The cursor primitive
(`run_vm_cursor` / `SessionHandle` / `session_next_batch`) replaces the
old thread+channel streaming trio. Python streams via pull-based cursor
batches. UPDATE/DELETE yield changed eids (streaming RETURNING). The
old `run_vm_streaming`/`stream_next`/`stream_close`/`StreamSink` are
removed. The gRPC server streams via cursor-pull through a dedicated
thread (`tx.blocking_send` bridge to the tokio async channel).
**Related:** [vm-spec.md](./vm-spec.md), [slot-dispatch.md](./slot-dispatch.md)

## 1. Overview

This document proposes replacing the current push-based thread+channel
streaming with a **pull-based cursor** as the single primitive for consuming
VM execution results — covering `SELECT` rows **and** `UPDATE`/`DELETE`
changed-entity streams.

### Problem with the current design

Today there are **four overlapping entry points** for producing results,
none unified:

| # | Entry point | Layer | Problem |
|---|-------------|-------|---------|
| 1 | `run_vm` (batch) | `QueryEngine` (`query_engine.dspi`) | Materializes the entire result in Rust (`Vec<Vec<Value>>`) then serializes once |
| 2 | `run_vm_streaming` + `stream_next` + `stream_close` | `QueryEngine` (`query_engine.dspi`) | Thread + channel + registry; **buggy and unused from Python** |
| 3 | `scan_datoms` | `QueryEngine` (`query_engine.dspi`) | Bulk EAVT dump for export — not a VM program |
| 4 | `open_cursor_direct` + `cursor_*` | `TransactorEngine` / `KVStoreEngine` | Raw key cursor — no VM, no join, no projection |

`run_vm_streaming` has four concrete defects:

- **Write-lock contention** — `stream_next` takes `inner.write()` on the
  whole `QueryInner` and holds it while blocking on `recv_timeout`
  (`spier-eavt-query/src/lib.rs:194,203`). A single slow stream blocks
  **all** other queries (compile, `run_vm`, other streams).
- **Errors swallowed** — the spawned thread discards the VM `Result`
  (`lib.rs:177`). VM failures during streaming are invisible to the
  consumer.
- **Handle leaks** — no `Drop` cleanup; `close()` does not drain streams.
  An abandoned `stream_id` lingers in the `HashMap` forever.
- **Busy-spin backpressure** — `StreamSink::send_row` loops
  `try_send` + `sleep(1ms)` (`engine/vm.rs:40`) with a 30s auto-terminate
  heuristic measured from the last drain.

The Python layer (`src/eavt_sql/engine.py`) uses **only** `run_vm`
(batch). `EAVTEngine.sql()` is nominally a generator but materializes the
full result in Rust and Python before the first `yield` — it is not
streaming.

### Proposal

Make the **cursor** the single primitive. A VM execution is exposed as a
resumable session whose results are pulled in batches:

```
run_vm_cursor(program, params, limit, as_of) -> SessionHandle   ← THE primitive
session_next_batch(handle, max_rows) -> Vec<u8>                 ← pull rows
# cleanup: automatic (Arc refcount + FFIResource.__del__)
```

- `SELECT` → cursor yields projected rows.
- `UPDATE` / `DELETE` → cursor yields **changed entity IDs** as the
  triejoin scan progresses (streaming `RETURNING`).
- `run_vm` (batch) becomes a thin wrapper: open cursor → drain all → pack.

This reuses the proven `CursorHandle` / `#[slot_struct]` / `FFIResource`
machinery already used for raw key cursors, eliminates the thread+channel
path entirely, and gives Python true streaming with bounded memory.

---

## 2. The Resumable VM

The core change is making the VM suspendable at result-emission points.

### Current execution model

`VM::run(sink: Option<&StreamSink>) -> Result<Vec<Vec<Value>>, EngineError>`
(`engine/vm.rs:581`) is a single opcode-dispatch loop. At `ResultRow` /
`EmitEnd` it either pushes to the channel sink or appends to a local
`results: Vec`, then continues until `Halt`.

### Proposed: batched stepping

Add a method that runs the VM until `max_rows` rows have been produced or
the VM halts, then returns. All VM state (`pc`, `regs`, `vars`, scanners,
join convergence, `emit_values`) already lives as fields on the `VM`
struct, so it persists naturally across calls:

```rust
impl VM<'_> {
    /// Run until up to `max_rows` result rows are accumulated in `out`,
    /// or the program halts. Returns `true` if more rows may follow.
    fn run_batch(
        &mut self,
        out: &mut Vec<Vec<Value>>,
        max_rows: usize,
    ) -> Result<bool, EngineError> {
        let mut produced = 0;
        while produced < max_rows {
            match self.dispatch_one()? {
                StepOutcome::Row(row) => { out.push(row); produced += 1; }
                StepOutcome::Continue => {}
                StepOutcome::Halt => return Ok(false),
            }
        }
        Ok(true) // may be more
    }
}
```

The existing `run()` becomes a backward-compatible wrapper that loops
`run_batch` until it returns `false`:

```rust
fn run(&mut self, sink: Option<&StreamSink>) -> Result<Vec<Vec<Value>>, _> {
    let mut results = Vec::new();
    while self.run_batch(&mut results, usize::MAX)? {}
    Ok(results)
}
```

**Why this is safe:** the triejoin is a depth-first enumeration expressed
as a flat GOTO state machine (see vm-spec.md §8.2). The "program counter"
captures the exact position in the enumeration. Suspended state is just
the fields of the VM struct; there is no separate coroutine stack to
save/restore. This is the same model SQLite/DuckDB/Postgres executors use
to yield tuples one at a time.

The only subtlety: `ResultRow`/`EmitEnd` must advance `pc` **past** the
opcode before returning, so the next `run_batch` resumes at the following
instruction (the `LEAP_NEXT` / `GOTO` loop continuation). This is already
how the opcodes behave.

---

## 3. VMSession and Transport

A session owns the resumable VM and packs rows into the wire format:

```rust
pub struct VMSession<'a> {
    vm: VM<'a>,
    num_cols: usize,   // fixed per program (from ResultRow p2 of first emit)
    done: bool,
}

impl VMSession<'_> {
    /// Run the VM, packing up to `max_rows` rows into `out`.
    /// Wire format: [u32 num_cols][encoded values]... repeated.
    /// Returns `false` when the VM has halted (no more rows).
    pub fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize)
        -> Result<bool, EngineError> { ... }
}
```

### Transport

`SessionHandle` mirrors `CursorHandle` exactly (`dynspire-commons/src/transactor/cursor.rs:16`) —
a `#[slot_struct]` wrapping an `Arc<RefCell<dyn …>>`, crossing FFI as 1 boxed
pointer both as a return value and as an input parameter:

```rust
pub trait VMResultStream: Send {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, EngineError>;
}

#[slot_struct]
#[derive(Clone)]
pub struct SessionHandle {
    pub session: Arc<RefCell<dyn VMResultStream>>,
}
```

- **Rust callers** call `session.borrow_mut().next_batch(...)` directly via
  the vtable — zero per-call FFI.
- **Python ctypes callers** receive an `FFIResource` wrapping the pointer
  and pass it back to `session_next_batch` (1 slot in, identical to how
  `cursor_step(cursor: CursorHandle)` works).
- **GC is automatic** — Arc refcount + `FFIResource.__del__` (Python) /
  `Drop` (Rust). No `session_close`, no handle registry, no `u64` IDs.

**No `u64` handles anywhere.** Both the program and the session cross as
`#[slot_struct]` boxed pointers. The program part is **already implemented**:
`compile_sql` returns a `ProgramHandle` (`Arc<VMProgram>` via `#[slot_struct]`,
`dynspire-commons/src/query_ir/opcodes.rs`), which eliminates the former
`HashMap<u64, Arc<VMProgram>>` registry, `next_program_id`, and `free_program`
— the caller holds the refcounted program and cleanup is automatic (`Arc` +
`Drop` / `FFIResource.__del__`). `run_vm` / `run_vm_streaming` now take
`ProgramHandle`. This is the same pointer-transport model AGENTS.md mandates
over the `u64`-handle anti-pattern. The `SessionHandle` for cursors (below)
follows the identical pattern, mirroring `CursorHandle`.

---

## 4. Unified IDL Interface

### DONE — program as `ProgramHandle` (replaces `u64` handle + `free_program`)

`compile_sql`, `run_vm`, and `run_vm_streaming` now use `ProgramHandle`
(`#[slot_struct]` wrapping `Arc<VMProgram>`, `opcodes.rs:198`) instead of a
`u64` registry ID. `free_program` and the `programs: HashMap<u64, Arc<VMProgram>>`
registry are removed — cleanup is automatic via `Arc` refcount. `ProgramHandle`
crosses as 1 slot (boxed pointer); passing it as a by-value input parameter is
a cheap `Arc` clone (mirrors `cursor_step(cursor: CursorHandle)`), so it is
safe on every `run_vm` call for prepared statements.

```rust
// ALREADY IMPLEMENTED
fn compile_sql(&self, sql: &str, sql_params: &[u8]) -> Result<ProgramHandle, String>;
fn run_vm(&self, program: ProgramHandle, sql_params: &[u8], limit: u64, as_of_us: u64) -> Result<Vec<u8>, String>;
fn run_vm_streaming(&self, program: ProgramHandle, sql_params: &[u8], limit: u64, as_of_us: u64) -> Result<u64, String>;
// free_program: REMOVED
```

### PROPOSED — cursor methods (replace the streaming trio)

Two new methods on `QueryEngine` replace the streaming trio:

```dspi
// query_engine.dspi
interface QueryEngine {
    // ... compile_sql / run_vm now take ProgramHandle (above) ...

    /// Open a resumable VM execution session. `program` is a ProgramHandle.
    /// Returns a SessionHandle (#[slot_struct]). Pull rows with
    /// session_next_batch. Cleanup is automatic (Arc refcount + FFIResource.__del__).
    fn run_vm_cursor(program: ProgramHandle, sql_params: &[u8], limit: u64, as_of_us: u64)
        -> Result<SessionHandle, String>;

    /// Pull up to max_rows packed rows from a session.
    /// Returns [u32 num_cols][values]... repeated. Empty Vec = done.
    fn session_next_batch(session: SessionHandle, max_rows: u64) -> Result<Vec<u8>, String>;

    // run_vm (batch) is RETAINED as a backward-compatible wrapper.
}
```

`ProgramHandle` and `SessionHandle` both cross as 1 slot (boxed pointer). Passing
them as input parameters works exactly like `cursor_step(cursor: CursorHandle)`
does today (`transactor/idl.rs:146`) — the slot system extracts the pointer.

### `run_vm` becomes a wrapper

```rust
fn run_vm(&self, program: VMProgram, sql_params: &[u8], limit: u64, as_of_us: u64) -> Result<Vec<u8>, String> {
    let session = self.run_vm_cursor(program, sql_params, limit, as_of_us)?;
    let mut buf = Vec::new();
    while self.session_next_batch(session, BATCH_SIZE)?.len() > 0 {
        // append / re-pack into the single-header batch format
    }
    Ok(buf)
}
```

### What gets removed

| Removed | Status |
|---------|--------|
| `run_vm_streaming` | ✅ Removed — replaced by `run_vm_cursor` |
| `stream_next` | ✅ Removed — replaced by `session_next_batch` |
| `stream_close` | ✅ Removed — automatic via Arc refcount / `Drop` |
| `StreamHandle`, stream `HashMap`, `sync_channel` | ✅ Removed — no thread needed |
| `StreamSink` + 30s auto-terminate + busy-spin | ✅ Removed — pull model has no backpressure problem |
| `programs: HashMap<u64, Arc<VMProgram>>`, `next_program_id`, `free_program` | ✅ Removed — program crosses as `ProgramHandle` (`#[slot_struct]`) |

`scan_datoms` (bulk export) and `open_cursor_direct` (raw key cursor) stay
as-is — they serve different purposes and are not VM-result paths.

---

## 5. DML: Streaming Changed Entities (RETURNING)

### Current DML behavior

`UPDATE` compiles to a triejoin scan with `ExecInsert` in the leaf
(`spier-compiler/src/compiler.rs:1160`). Today the leaf emits **no** per-row
result; a single `ResultRow(count)` fires once after the whole loop
(`compiler.rs:1221`). The caller only learns "how many SET values per row",
not which entities changed.

`DELETE` scan (`compile_rust_delete_scan`) is structurally identical, with
`ExecRetract` in the leaf.

### Proposed: yield changed eids in the leaf

The leaf already has `r_ent` (the matched entity, read via `BindGet` at
`compiler.rs:1183`). Adding one `ResultRow` inside the leaf closure makes
the cursor stream the changed entity ID per match:

```
════ UPDATE LEAF (inside triejoin skeleton) ════
  BIND_GET      r_ent  var_id        ← matched entity
  CONST_STR     r_attr "company.name"
  CONST_STR     r_val  "ACME Corp"
  EXEC_INSERT   r_ent  r_attr  r_val  -1
  ...more SET clauses...
  RESULT_ROW    r_ent  1             ← yield changed eid  [NEW]
```

With the resumable VM, this becomes: each triejoin match → `ExecInsert`
block → `ResultRow(eid)` → **cursor suspends and returns the eid** →
resume → next match. `DELETE` is identical with `ExecRetract`.

### Granularity

The leaf can emit at two granularities, chosen by the compiler:

| Mode | What the leaf emits | Cursor yields | Use case |
|------|---------------------|---------------|----------|
| **Per-entity** | one `ResultRow(eid)` after all SETs | distinct changed eids | `RETURNING eid` |
| **Per-datom** | `ResultRow(eid, attr, op)` per `ExecInsert`/`ExecRetract` | full change log | CDC / audit |

Per-entity is the natural default (the caller cares about "which entities
changed"); per-datom is a richer changelog. Both are just different leaf
emission — no new opcodes, no VM changes.

### Honesty about non-atomicity

Because writes take the resolver lock **per-datom** and there is no
transaction mechanism (see AGENTS.md "No Transaction Mechanism"), a
multi-datom `UPDATE`/`DELETE` is not atomic. The cursor makes this
**observable**: it yields exactly the eids that were persisted, in scan
order. If execution fails at eid #50 (e.g. UNIQUE violation), the cursor
yields 49 eids then errors — those 49 are committed, with no rollback.

This is not a new failure mode; it is the existing per-datom semantics,
made visible. If statement-level atomicity is ever added, the changed-eid
stream is precisely the log a transaction would need to track for
rollback.

---

## 6. Python Integration

Python wraps `session_next_batch` as a true streaming generator:

```python
def sql(self, query, *params, limit=None, as_of=None):
    prog = self._handle.call("compile_sql", {"sql": query, "sql_params": ...})  # boxed VMProgram
    session = self._handle.call(
        "run_vm_cursor",
        {"program": prog, "sql_params": ..., "limit": limit_val, "as_of_us": as_of_val},
    )
    try:
        while True:
            batch = self._handle.call("session_next_batch", {"session": session, "max_rows": 1024})
            if not batch:
                return
            for row in decode_rows(batch):   # [u32 ncols][vals] repeated
                yield row
    finally:
        del session   # FFIResource.__del__ → Arc dec (no explicit close)
        # prog stays owned by the caller; reuse for PreparedStatement
```

- **Bounded memory** — at most `max_rows` (e.g. 1024) rows buffered per
  FFI hop. Contrast with the current path, which materializes the entire
  result in Rust + Python.
- **Amortized FFI** — one slot-dispatch per batch, not per row.
- **Errors propagate** — a VM failure raises inside `session_next_batch`
  (no silent swallowing).
- **No lifecycle burden** — `del session` drops the `FFIResource`; the
  `Arc<VMSession>` decrements; `Drop` frees the VM. No `stream_close`,
  no leak if the caller abandons the generator.

`PreparedStatement.execute` follows the same pattern with a cached program.

---

## 7. gRPC Implications

The cursor is an **in-process pointer** (`SessionHandle` via `#[slot_struct]`)
— it cannot cross the network to a gRPC client. So for gRPC, the cursor is a
**server-side primitive**: the server holds the `SessionHandle`, pulls batches,
and forwards each as a streaming RPC message.

### Done: true server-streaming backed by the cursor

The `Sql` RPC (`returns (stream SqlRow)`, `proto/eavt.proto:6`) now uses
cursor-pull instead of batch-then-replay. The server compiles the SQL
synchronously (so compile errors surface as gRPC `Status`), then spawns a
dedicated OS thread that opens the cursor, pulls batches, and forwards rows:

```
gRPC Sql (server-streaming):
  prog = compile_sql(...)                         // synchronous — errors → Status
  spawn thread {
    session = run_vm_cursor(prog, ...)            // session is !Send, stays here
    loop {
      batch = session_next_batch(session, 1024)   // pull from cursor
      if empty: break
      for row in decode_rows(batch):
        tx.blocking_send(Ok(SqlRow { ... }))      // sync→async bridge
    }
  }
  return ReceiverStream(rx)
```

This yields **bounded server memory** (only 1024 rows buffered at a time),
**low time-to-first-byte** (first batch sent as soon as the VM produces it),
and **natural backpressure** (tokio channel + cursor pull rate).

### Why a dedicated thread (not `spawn_blocking`)

`SessionHandle` wraps `Arc<RefCell<dyn VMResultStream>>`. `RefCell` is `!Sync`,
so `Arc<RefCell<…>>` is `!Send` — the session cannot cross thread boundaries.
`tokio::task::spawn_blocking` requires the closure to be `Send + 'static`, so
the session cannot be moved into it.

The solution: create the session **inside** a dedicated `std::thread::spawn`
closure. The thread captures `Arc<DynSpireQueryClient>` (which is `Send +
Sync` — `DynSpireClient` has `unsafe impl Send + Sync`) and the compiled
`ProgramHandle` (also `Send` — wraps `Arc<VMProgram>`). The session is created
on the thread, lives on the thread, and drops on the thread. Results are
forwarded to the tokio async runtime via `tx.blocking_send` (designed for
exactly this sync→async bridge pattern).

### The async/sync boundary belongs at the gRPC layer

Tonic is **async**; the VM's `next_batch` is **synchronous**. **This sync/async
bridge lives in the gRPC layer, where it belongs — not inside the query spier.**

This is the strongest argument for removing the thread from the spier: the
spier stays purely synchronous, and each consumer manages its own bridge.
Python (sync ctypes) needs no bridge at all; the gRPC server uses a dedicated
thread; a future async Rust embedder would do the same. The old
`run_vm_streaming` thread+channel was trying (badly) to solve a problem that
is the consumer's, not the engine's — and it pulled that complexity into the
spier along with its four defects (§1).

### Unification extends to the RPC surface

Because `UPDATE`/`DELETE` now emit `ResultRow(eid)` exactly like `SELECT`
(§5), a **single `Sql` server-streaming RPC serves all three**: SELECT
projected rows, and UPDATE/DELETE changed-eids, over the wire. The
non-streaming `Execute` RPC is the batch analog, using `run_vm` (batch).

### Proto: no change needed

`SqlRow { repeated Value values }` (`proto:22`) is generic enough to carry
any emitted row: a SELECT projection, an `(eid,)` changed-id, or a per-datom
`(eid, attr, op)` changelog. The `Dump` RPC (stream of `DatomRow`, backed by
`scan_datoms`) is a separate raw-EAVT path and is untouched. So the cursor
change is **server-internal** — the wire contract is forward-compatible.

---

## 8. Interface Unification Summary

```
                    ┌─────────────────────────────────┐
                    │  run_vm_cursor  →  SessionHandle │   ← THE primitive
                    └────────────┬────────────────────┘
                                 │
          ┌──────────────────────┼────────────────────────┐
          ▼                      ▼                        ▼
   SELECT program         UPDATE program           DELETE program
   yields projected       yields changed eids      yields removed eids
   rows                   (RETURNING)              (RETURNING)
          │                      │                        │
          └──────────────────────┴────────────────────────┘
                                 │
                          session_next_batch
                                 │
                 ┌────────────────┴────────────────┐
                 ▼                                 ▼
           Python generator                Rust drain-to-batch
           (streaming, bounded)            (= run_vm wrapper)

    Server-side (in-process pointer does not cross network):
      gRPC server holds SessionHandle → next_batch → forward as
      stream SqlRow (true server-streaming via spawn_blocking, §7)
```

One cursor primitive serves every statement type **and** every consumer
(Python FFI, Rust direct, gRPC server). The cursor does not know whether the
program is read-only or has side effects — it just runs the VM to the next
emission point and suspends.

---

## 9. Implementation Plan (ordered)

Each step is independently testable and keeps the system working.

### Step 1 — Resumable VM (no API change)
Refactor `VM::run` into `VM::run_batch(&mut self, out, max_rows) -> bool`
(see §2). Keep `run()` as a wrapper. Verify with existing tests — behavior
is identical, only the loop boundary moves. *Files:* `spier-eavt-query/src/engine/vm.rs`.

### Step 2 — ✅ DONE: VMSession + transport
`VM` now owns `Arc<VMProgram>` and `Arc<dyn VMEngine + Send + Sync>` (no lifetime
parameter), enabling it to live inside a `'static` session object. `VMSession`
wraps `VM` and implements `VMResultStream`. `SessionHandle` (`#[slot_struct]`,
mirroring `CursorHandle`) wraps `Arc<RefCell<dyn VMResultStream>>`. The IDL
methods `run_vm_cursor` and `session_next_batch` are implemented in the
`QueryEngine` trait and `QueryState` impl. The gRPC query client dispatches
both via slot dispatch.
*Files:* `spier-eavt-query/src/engine/vm.rs`, `spier-eavt-query/src/engine/session.rs`,
`spier-eavt-query/src/engine/dynspire_engine.rs`, `spier-eavt-query/src/lib.rs`,
`dynspire-commons/src/query_engine.dspi`, `eavt-server/src/main.rs`.

### Step 3 — ✅ DONE: program as slot_struct
`compile_sql` now returns `ProgramHandle` (`Arc<VMProgram>` via `#[slot_struct]`),
and `run_vm` / `run_vm_streaming` take `ProgramHandle`. The
`programs: HashMap<u64, Arc<VMProgram>>` registry, `next_program_id`, and
`free_program` are removed (cleanup via `Arc` refcount). The remaining cursor
methods (`run_vm_cursor` + `session_next_batch`) are still PROPOSED — add them
to the `QueryEngine` trait when implementing the cursor primitive.
*Files:* `dynspire-commons/src/query_engine.dspi`, `dynspire-commons/src/query_ir/opcodes.rs`, `spier-eavt-query/src/lib.rs`, `eavt-server/src/main.rs`, `src/eavt_sql/engine.py`.

### Step 4 — ✅ DONE: Python streaming path
`EAVTEngine.sql()` and `PreparedStatement.execute()` now use `run_vm_cursor` +
`session_next_batch` (batch size 1024) instead of `run_vm` (batch). Results
stream with bounded memory. Cleanup is automatic via `FFIResource.__del__`.
Added `decode_rows()` to `query_codec.py` for the per-row wire format.
*Files:* `src/eavt_sql/engine.py`, `src/eavt_sql/query_codec.py`.

### Step 5 — ✅ DONE: DML changed-eid emission
UPDATE leaf emits `ResultRow(r_ent, 1)` inside the triejoin leaf — the cursor
streams changed entity IDs per matched row. DELETE leaf emits `ResultRow(r_ent)`
instead of `ResultRow(count)`. DELETE scan no longer uses `star=true` wildcard
projection (was causing duplicate leaf invocations). Direct DELETE path also
yields eid.
*Files:* `spier-compiler/src/compiler.rs`.

### Step 6 — ✅ DONE: gRPC server true server-streaming
Rewired the `Sql` RPC (`eavt-server/src/main.rs`) from batch-then-replay
to cursor-pull (see §7): compile synchronously, then spawn a dedicated OS
thread that opens `run_vm_cursor`, pulls batches via `session_next_batch`,
decodes rows via `query_codec::decode_rows`, and forwards each row via
`tx.blocking_send` (sync→async channel bridge). The session is created and
consumed entirely within the thread because `SessionHandle` is `!Send`
(wraps `Arc<RefCell<dyn VMResultStream>>`). The `Execute` RPC keeps using
`run_vm` (batch analog). The proto is unchanged. Added
`query_codec::decode_rows` (Rust) for the cursor batch wire format.
*Files:* `eavt-server/src/main.rs`, `dynspire-commons/src/transactor/query_codec.rs`.

### Step 7 — ✅ DONE: Remove old streaming
Deleted `run_vm_streaming` / `stream_next` / `stream_close` from the IDL,
`QueryState`, and `DynSpireQueryClient`. Removed `StreamSink`, `StreamHandle`,
`streams` HashMap, `sync_channel`, thread spawning, and the `sink` parameter
from `VM::run` / `VM::run_batch`. The pull-based cursor is the sole streaming
mechanism. Net: -216 lines.
*Files:* `dynspire-commons/src/query_engine.dspi`, `spier-eavt-query/src/lib.rs`,
`spier-eavt-query/src/engine/vm.rs`, `spier-eavt-query/src/engine/dynspire_engine.rs`,
`spier-eavt-query/src/engine/session.rs`.

### Step 8 — ✅ DONE: Docs
Updated vm-spec.md (resumable VM section), AGENTS.md (streaming section),
this document's status.

---

## 10. Tradeoffs and Risks

### Why pull-based over thread+channel

| Concern | Thread+channel (current) | Pull-based cursor (proposed) |
|---------|--------------------------|------------------------------|
| Contention | `stream_next` write-locks whole engine while blocking | No global lock; each `next_batch` runs inline |
| Errors | Swallowed in thread | Propagate normally |
| Lifecycle | Manual `stream_close`, handle leaks | Automatic (Arc + `__del__`) |
| Backpressure | Busy-spin + 30s heuristic | Caller-controlled batch size |
| Infrastructure | Thread + channel + registry | None new (reuses cursor machinery) |

The only thing the thread buys is overlapping VM computation with consumer
processing. But the VM (triejoin scan) is the expensive part, and the
cursor naturally overlaps: Python processes batch K while the VM has already
produced and is ready for the next pull.

### Resumability complexity

The VM must preserve all state across `run_batch` calls. Since state is
already struct fields, this is a loop-boundary refactor, not a rewrite.
The risk area is the triejoin convergence state (`v2_scanners`, depth
bookkeeping) — these must survive suspension cleanly. Existing tests (v2
scanner tests, range tests, join tests) cover this once `run()` is
re-expressed over `run_batch`.

### FFI overhead

Each `session_next_batch` is one slot-dispatch. For N result rows with
batch size K, that's N/K FFI hops. K=1024 makes this negligible for all
but pathological cases. The batch size is caller-controlled, so Python can
tune it (smaller for low-latency first-row, larger for throughput).

### Backward compatibility

`run_vm` (batch) stays, reimplemented as a cursor drain. Existing callers
(Python `sql()` until rewired, gRPC server) keep working unchanged until
they migrate. The old streaming trio is removed only after the cursor path
is proven.
