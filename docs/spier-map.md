# Spier & Crate Map

Map of all crates in the project and how they depend on each other.

## Trait locations

Traits now live in their natural crates. The only shared abstraction crate
is `spier-storage-traits`, because BlobStore, Journal, MemTable and KVStore
each have multiple implementations.

| Trait | Crate | File |
|-------|-------|------|
| BlobStore | `BlobStoreEngine` | `spier-storage-traits/src/blobstore.rs` |
| Journal | `JournalEngine` | `spier-storage-traits/src/journal.rs` |
| MemTable | `MemTableEngine` | `spier-storage-traits/src/memtable.rs` |
| KVStore | `KVStoreEngine` | `spier-storage-traits/src/kvstore.rs` |
| Cursor | `Cursor` / `CursorHandle` | `spier-storage-traits/src/cursor.rs` |
| Transactor | `TransactorEngine` | `spier-transactor/src/lib.rs` |
| Query Engine | `QueryEngine` | `spier-eavt-query/src/lib.rs` |
| SQL Parse | `SqlParseEngine` | `spier-sql-parse/src/lib.rs` |
| Datalog | `DatalogEngine` | `spier-datalog/src/lib.rs` |
| Planner | `PlannerEngine` | `spier-planner/src/lib.rs` |
| SQL Frontend | `SqlFrontendEngine` | `spier-sql-frontend/src/lib.rs` |
| Compiler | `CompilerEngine` | `spier-compiler/src/lib.rs` |
| CompileStats | `CompileStats` | `spier-datalog/src/stats.rs` |

## Crates

Each crate is a Rust library (`rlib`), except the PyO3 bindings (`cdylib`)
and the gRPC binaries. Crates depend on each other directly through `Cargo.toml`
paths. There is no runtime `dlopen`, no C ABI slot buffer, and no code
generation step.

| Crate | Responsibility | Depends on |
|-------|----------------|------------|
| `spier-storage-traits` | Storage-layer trait abstractions + `CfStats`/`DbStats`/`GcFullResult` | — |
| `spier-value` | Core `Value`/`ValueType` + tags + `query_codec` | chrono |
| `spier-query-ir` | VM opcodes, `Instruction`, `VMProgram`, `SpecKind` | `spier-value` |
| `spier-blobstore-memory` | In-memory `BlobStoreEngine` | `spier-storage-traits` |
| `spier-blobstore-file` | File-backed `BlobStoreEngine` (zstd pages) | `spier-storage-traits` |
| `spier-blobstore-s3` | S3-backed `BlobStoreEngine` | `spier-storage-traits` |
| `spier-journal-file` | File-backed `JournalEngine` | `spier-storage-traits` |
| `spier-memtable` | `MemTableEngine` (crossbeam SkipMap per CF) | `spier-storage-traits` |
| `spier-kvstore` | `KVStoreEngine` (MemTable + PageStore + flush + GC) | `spier-storage-traits` + backends |
| `spier-transactor` | EAVT engine: save/retract + resolver + constraints | `spier-kvstore`, `spier-storage-traits`, `spier-value` |
| `spier-sql-parse` | SQL lexer + parser | serde |
| `spier-datalog` | SQL AST → Datalog IR + `resolve_ir` + `CompileStats` | `spier-sql-parse`, `spier-value` |
| `spier-planner` | Cost-based join ordering + index selection | `spier-datalog`, `spier-query-ir`, `spier-value` |
| `spier-compiler` | Plan → VM bytecode | `spier-datalog`, `spier-planner`, `spier-query-ir`, `spier-sql-parse`, `spier-value` |
| `spier-sql-frontend` | Stage 1: parse + datalog IR | `spier-sql-parse`, `spier-datalog` |
| `spier-eavt-query` | Orchestrates pipeline + runs the triejoin VM | all of the above |
| `spier-sql-parse-py` | PyO3 bindings for `spier-sql-parse` | pyo3, `spier-sql-parse` |
| `spier-transactor-py` | PyO3 bindings for `spier-transactor` | pyo3, `spier-transactor`, `spier-journal-file`, `spier-storage-traits`, `spier-value` |
| `spier-eavt-query-py` | PyO3 bindings for `spier-eavt-query` | pyo3, `spier-eavt-query`, `spier-query-ir`, `spier-transactor`, `spier-value` |
| `eavt-cli` | gRPC REPL client (`eavt-repl` binary) | tonic, clap, rustyline |
| `eavt-server` | gRPC server (`eavt-server` binary) | tonic, `spier-eavt-query`, `spier-storage-traits`, `spier-value` |

## Consumer architecture

```
Host (Python PyO3 / gRPC)
  │  QueryEngine trait
  ▼
spier-eavt-query — VM, triejoin, orchestration
  │
  ├─ SqlFrontendEngine trait ──► spier-sql-frontend — parse + datalog
  │     ├─ SqlParseEngine trait ──► spier-sql-parse — lexer + parser
  │     └─ DatalogEngine trait  ──► spier-datalog  — AST → DatalogIR
  │
  ├─ (resolve_ir — in-process, uses CompileStats adapter over the transactor)
  │
  ├─ CompilerEngine trait ──► spier-compiler — plan + codegen
  │     └─ PlannerEngine trait ──► spier-planner — join order + index selection
  │           (stats from DatalogNumIR, no transactor)
  │
  └─ TransactorEngine trait ──► spier-transactor — save/retract, resolver
        └─ KVStoreEngine trait ──► spier-kvstore — put/get/scan, cursors, flush
              ├─ BlobStoreEngine trait ──► spier-blobstore-{memory|file|s3}
              ├─ MemTableEngine trait   ──► spier-memtable
              └─ JournalEngine trait    ──► spier-journal-file
```

Compilation pipeline orchestrated by `spier-eavt-query`:

```
SQL text
  → spier-sql-frontend  (SqlFrontendEngine)  → RustStmt (AST) + DatalogIR
  → resolve_ir          (spier-datalog)       → DatalogIR with resolved attrs
  → compute_plan_stats  (spier-datalog)       → PlanStats
  → spier-compiler      (CompilerEngine)      → CompileResultSt { VMProgram, traces }
```

`spier-eavt-query` is the orchestration hub:

1. Calls `frontend.parse(sql)` → `RustStmtSt`
2. Calls `frontend.build_datalog(stmt, params)` → `DatalogIRSt`
3. Calls `resolve_ir(datalog_ir, &tx_stats)` (pure function in `spier-datalog`)
   → `DatalogIR` with resolved attribute IDs
4. Calls `compute_plan_stats(&resolved, &tx_stats)` → `PlanStats`
5. Dispatches to `compiler.compile_select(num_ir)` (SELECT) or
   `compiler.compile_dml_scan(stmt, num_ir, params)` /
   `compiler.compile_dml_direct(stmt, params)` (DML) → `CompileResultSt`

No `TransactorEngine` crosses any crate boundary during compilation. The
transactor is used only by `spier-eavt-query` itself (for schema resolution
via the local `TxStats` adapter that implements `CompileStats`). The planner
receives cost statistics embedded in `DatalogNumIR`, not via a live
transactor connection.
