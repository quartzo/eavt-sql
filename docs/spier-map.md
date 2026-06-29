# DynSpire Spier & Tower Map

Map of all DynSpire plugins (spiers) in the project.

## IDLs

Defined as `.dspi` DSL files processed by `dynspire-codegen` at build time. Each `.dspi` declares an `interface` that generates a Rust trait, Op enum, IDL hash, type table, and tower client (`Dyn*`).

Storage-layer IDLs live in `spier-kvstore/src/idl/`; upper-layer IDLs live in `dynspire-commons/src/`.

| IDL | Interface | File |
|-----|-----------|------|
| BlobStore | `BlobStoreEngine` | `spier-kvstore/src/idl/blobstore.dspi` |
| Journal | `JournalEngine` | `spier-kvstore/src/idl/journal.dspi` |
| MemTable | `MemTableEngine` | `spier-kvstore/src/idl/memtable.dspi` |
| KVStore | `KVStoreEngine` | `spier-kvstore/src/idl/kvstore.dspi` |
| Transactor | `TransactorEngine` | `dynspire-commons/src/transactor.dspi` |
| Query Engine | `QueryEngine` | `dynspire-commons/src/query_engine.dspi` |
| SQL Parse | `SqlParseEngine` | `dynspire-commons/src/sql_parse.dspi` |
| Datalog | `DatalogEngine` | `dynspire-commons/src/datalog.dspi` |
| Planner | `PlannerEngine` | `dynspire-commons/src/planner.dspi` |
| SQL Frontend | `SqlFrontendEngine` | `dynspire-commons/src/sql_frontend.dspi` |
| Compiler | `CompilerEngine` | `dynspire-commons/src/compiler.dspi` |

## Spier servers (cdylib `.so`)

Each spier is a `cdylib` compiled to `.so`, loaded at runtime via `libloading`. Uses `dynspire-codegen` macros: `impl_*_spier!()` (lifecycle + IDL dispatch), `#[slot_struct]` (opaque pointer transport).

| Spier | IDL | Backend | File |
|-------|-----|---------|------|
| `spier-blobstore-memory` | BlobStore | In-memory `HashMap` | `spier-blobstore-memory/src/lib.rs` |
| `spier-blobstore-file` | BlobStore | Directory + zstd-compressed blobs + atomic writes | `spier-blobstore-file/src/lib.rs` |
| `spier-blobstore-s3` | BlobStore | S3-compatible object store | `spier-blobstore-s3/src/lib.rs` |
| `spier-journal-file` | Journal | Local disk file | `spier-journal-file/src/lib.rs` |
| `spier-memtable` | MemTable | In-memory `SkipMap<Vec<u8>, ()>` per CF | `spier-memtable/src/lib.rs` |
| `spier-kvstore` | KVStore | Pure key-only multi-CF store: MemTable + GenericPageStore + flush (loads blobstore + journal + memtable spiers) | `spier-kvstore/src/lib.rs` |
| `spier-transactor` | Transactor | EAVT engine: save/retract/declare_attr + resolver + constraints (loads spier-kvstore) | `spier-transactor/src/lib.rs` |
| `spier-sql-parse` | SQL Parse | Pure Rust lexer + parser | `spier-sql-parse/src/lib.rs` |
| `spier-datalog` | Datalog | SQL AST → Datalog IR (patterns `[?e ?a ?v ?t ?added]`) | `spier-datalog/src/lib.rs` |
| `spier-planner` | Planner | Datalog IR → Query Plan: cost-based join ordering, index selection (stats from DatalogNumIR, no transactor) | `spier-planner/src/lib.rs` |
| `spier-sql-frontend` | SQL Frontend | Stage 1 compilation: parse + datalog IR (loads spier-sql-parse + spier-datalog). Constructs fake SELECT for UPDATE/DELETE | `spier-sql-frontend/src/lib.rs` |
| `spier-compiler` | Compiler | Stage 2 compilation: plan + codegen (loads spier-planner only). No transactor | `spier-compiler/src/lib.rs` |
| `spier-eavt-query` | Query Engine | VM + triejoin. Orchestrates two-stage compilation: frontend → resolve_ir → compiler (loads spier-sql-frontend + spier-compiler + spier-transactor) | `spier-eavt-query/src/lib.rs` |

## Consumer architecture

```
Host (Python ctypes / gRPC)
  │  QueryEngine IDL
  ▼
spier-eavt-query (.so) — VM, triejoin, orchestration
  │
  ├─ SqlFrontendEngine IDL ──► spier-sql-frontend (.so) — parse + datalog
  │     ├─ SqlParseEngine IDL ──► spier-sql-parse (.so) — lexer + parser
  │     └─ DatalogEngine IDL  ──► spier-datalog  (.so) — AST → DatalogIR
  │
  ├─ (resolve_ir — in-process, uses transactor for schema)
  │
  ├─ CompilerEngine IDL ──► spier-compiler (.so) — plan + codegen
  │     └─ PlannerEngine IDL ──► spier-planner (.so) — join order + index selection
  │           (stats from DatalogNumIR, no transactor)
  │
  └─ TransactorEngine IDL ──► spier-transactor (.so) — save/retract, resolver
        └─ KVStoreEngine IDL ──► spier-kvstore (.so) — put/get/scan, cursors, flush
              ├─ BlobStoreEngine IDL ──► spier-blobstore-{memory|file|s3} (.so)
              ├─ MemTableEngine IDL   ──► spier-memtable (.so)
              └─ JournalEngine IDL    ──► spier-journal-file (.so)
```

Compilation pipeline orchestrated by `spier-eavt-query`:

```
SQL text
  → spier-sql-frontend  (SqlFrontendEngine)  → RustStmt (AST) + DatalogIR
  → resolve_ir          (in-process, commons) → DatalogNumIR  [schema resolution]
  → spier-compiler      (CompilerEngine)      → CompileResultSt { VMProgram, traces }
```

`spier-eavt-query` is the orchestration hub:
1. Calls `frontend.parse(sql)` → `RustStmtSt`
2. Calls `frontend.build_datalog(stmt, params)` → `DatalogIRSt`
3. Calls `resolve_ir(datalog_ir, &transactor)` (pure function in `dynspire-commons`) → `DatalogNumIRSt`
4. Dispatches to `compiler.compile_select(num_ir)` (SELECT) or `compiler.compile_dml_scan(stmt, num_ir, params)` / `compiler.compile_dml_direct(stmt, params)` (DML) → `CompileResultSt`

No `DynSpireTransactor` crosses any spier boundary during compilation. The transactor is used only by `spier-eavt-query` itself (for `resolve_ir` schema resolution). The planner receives cost statistics embedded in `DatalogNumIR` (computed by `resolve_ir`), not via a live transactor connection.

Each spier loads the next via `DynSpireClient::connect()` with IDL hash verification.
