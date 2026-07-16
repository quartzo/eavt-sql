# Result Cursors — Unified Streaming via Pull-Based Cursors

**Status:** Implemented. The cursor primitive (`open_cursor` / `SessionHandle` /
`session_next_batch`) uses the Scheme IR stack-based evaluator with
yield/resume (§2). Python streams via pull-based cursor batches. UPDATE/DELETE
yield changed eids (streaming RETURNING). The old VM bytecode and the legacy
`run_vm_streaming`/`stream_next`/`stream_close` are removed.

## 1. Overview

All results (SELECT rows, UPDATE/DELETE changed entities, UPSERT results) are
streamed through a single pull-based cursor primitive. The cursor is backed by
the **stack-based Scheme evaluator** with `eval_with_yield` — the evaluator runs
until it hits a `(result-row ...)` form, yields the row, and suspends. The next
`session_next_batch` call resumes the evaluator from the suspension point.

The old VM bytecode (`VM`, `run_batch`, `VMProgram`, `OpCode`) has been
completely removed. The Scheme IR evaluator achieves the same resumability
without a program counter — the evaluation stack stored in `YieldState`
captures the suspended state naturally.

## 2. The Resumable Evaluator

The core mechanism is the **stack-based Scheme evaluator** (`run_eval` in
`spier-scheme/src/eval.rs`). It uses explicit frame types (Eval, Apply,
DepthRunBody, etc.) instead of a Rust call stack. This allows the evaluator
to pause mid-execution and resume later.

### YieldState

```rust
pub struct YieldState {
    pub(crate) stack: Vec<Frame>,
    pub depth_runs: Vec<DepthRunFrame>,
    started: bool,
}
```

When `result-row` fires, the host function returns `EvalStep::Yield(row_sexpr)`.
The evaluator preserves the stack in `YieldState` and returns control to the
caller (`SelectSchemeSession::next_batch`). On the next `next_batch` call,
`eval_with_yield` is called again with the same `YieldState` — the loop picks
up the top frame from the stack and resumes exactly where it left off.

### Pull Model

```
open_cursor(program, params) → SessionHandle
session_next_batch(handle, max_rows) → [u32 ncols][values]...

SELECT → cursor yields projected rows
UPDATE/DELETE → cursor yields changed entity IDs
# cleanup: automatic (Arc refcount + Drop)
```

`execute` (batch) becomes a thin wrapper: open cursor → drain all → pack.

## 3. SelectSchemeSession and Transport

`SelectSchemeSession` owns the evaluator state across calls:

```rust
pub struct SelectSchemeSession {
    program: SchemeProgram,
    env: Environment,
    host: SelectSchemeHostFns,
    state: YieldState,
    done: bool,
}
```

`SessionHandle` wraps `Arc<RefCell<dyn VMResultStream>>`, crossing FFI as
1 boxed pointer. `VMResultStream::next_batch` pulls rows from the session.

Wire format per row: `[u32 num_cols][encoded values]` — repeated.

## 4. DML: Streaming Changed Entities

UPDATE/DELETE scan via Scheme IR works the same as SELECT — the triejoin
leaf emits `(result-row (bind-get eid))` after `(save ...)` or `(retract ...)`.
The cursor streams the changed entity ID per match.

## 5. Python Integration

Python wraps `session_next_batch` as a streaming generator:

```python
def sql(self, query, *params, limit=None, as_of=None):
    prog = self._handle.compile_sql(stripped, params_bytes)
    session = self._handle.open_cursor(prog, params_bytes, limit_val, as_of_val)
    while True:
        batch = self._handle.session_next_batch(session, 1024)
        if not batch: break
        for row in decode_rows(batch):
            yield row
```

Bounded memory (1024 rows per FFI hop), automatic cleanup via Arc + Drop.

## 6. gRPC Integration

The gRPC server holds the `SessionHandle` server-side, pulls batches, and
forwards each as a streaming `SqlRow` RPC message. True server-streaming with
bounded server memory.
