# dynspire-commons

Shared protocol definitions for all DynSpire spiers. Upper-layer IDLs live here as `.dspi` files; storage-layer IDLs (blobstore, journal, memtable, kvstore) live in `spier-kvstore/src/idl/`.

```
src/
  lib.rs                    # trace_vm(), trace_cursor() — EAVT_TRACE env var (cached AtomicBool)
  transactor.dspi           # TransactorEngine IDL
  query_engine.dspi         # QueryEngine IDL
  sql_parse.dspi            # SqlParseEngine IDL
  datalog.dspi              # DatalogEngine IDL
  planner.dspi              # PlannerEngine IDL
  sql_frontend.dspi         # SqlFrontendEngine IDL (stage 1: parse + datalog)
  compiler.dspi             # CompilerEngine IDL (stage 2: plan + codegen)
  shared_types.dspi         # Value/ValueType (included by transactor + query_engine)
  opaque_types.dspi         # CursorHandle, DynSpireTransactor, VMProgram, CompileResultSt, etc.
  value.rs                  # Value type + tag constants
  kvstore/                  # inline module — generated HOST code for DynSpireKVStore (used by transactor)
  compiler/                 # CompileResultSt + CompileStats trait (pure Rust, not an IDL) + tower extensions
  query_ir/
    opcodes.rs              # OpCode, Instruction, VMProgram (#[slot_struct]), to_json()
    spec_kind.rs            # SpecKind (triejoin variable binding)
  transactor/
    keys.rs                 # Key encoding (EAVT 4-column key format)
    cursor.rs               # Cursor trait (is_valid, step, seek, reopen, ...)
    query_codec.rs          # Value serialization for query params/results
    resolver_consts.rs      # Schema constants (DB_TYPE_*, partition bits)
    types.rs                # CfStats, DbStats parsing
  sql_parse/
    ast.rs                  # SQL AST types (RustStmt, RustSelectStmt, etc.)
  datalog/
    ast.rs                  # Datalog AST types (DatalogIR, DatalogNumIR, ResolvedAttr, etc.)
    resolve.rs              # resolve_ir() + compute_stats() — schema resolution using &DynSpireTransactor
  planner/
    ast.rs                  # Planner AST types
```

## What lives here

- **`.dspi` IDLs** — `dynspire-codegen` processes these at build time, generating Rust traits, tower clients (`Dyn*`), Op enums, IDL hashes, and type tables. Both spier implementations and consumers depend on the same generated trait.
- **Codegen-generated tower clients** — `DynSpireTransactor`, `DynSpireKVStore`, etc. All use `Arc<DynSpireClient>` internally. No handwritten tower code.
- **Shared types** — types that cross the FFI boundary (`Value`, `VMProgram`) or are used by both spier and consumer (AST types, `OpCode`, `SpecKind`).
- **Stateless utilities** — pure functions (key encoding, value serialization) with no I/O or side effects.

## Domains

| Domain | IDL | Generated tower | Shared types | Utils |
|--------|-----|-----------------|-------------|-------|
| KVStore (HOST only) | `KVStoreEngine` | `DynSpireKVStore` | — | — |
| Transactor | `TransactorEngine` | `DynSpireTransactor` | `Value`, `ValueType` | keys, cursor, query_codec, resolver_consts, types |
| Query Engine | `QueryEngine` | `DynSpireQuery` | — | — |
| SQL Parse | `SqlParseEngine` | `DynSpireSqlParse` | `RustStmt` + AST types | — |
| Datalog | `DatalogEngine` | `DynSpireDatalog` | DatalogIR types | — |
| Planner | `PlannerEngine` | `DynSpirePlanner` | Planner types | — |
| SQL Frontend | `SqlFrontendEngine` | `DynSpireSqlFrontend` | — | — |
| Compiler | `CompilerEngine` | `DynSpireCompiler` | `VMProgram`, `OpCode`, `SpecKind`, `CompileResultSt` | `CompileStats` trait (pure Rust) |

> Storage IDLs (BlobStore, Journal, MemTable, KVStore SPIER side) are in `spier-kvstore/src/idl/`.

## Features

- `serde` — enables `Serialize`/`Deserialize` derives on AST types (used by `spier-sql-parse` for `parse_json`)
