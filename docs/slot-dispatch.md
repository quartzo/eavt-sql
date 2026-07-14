# Python ↔ Rust FFI

The Python layer talks to Rust through **PyO3 bindings** (`cdylib` crates).
There is no slot buffer, no C ABI dispatcher, and no runtime `dlopen`.

## Binding crates

| Crate | Exposes | Python import |
|-------|---------|---------------|
| `spier-sql-parse-py` | `SqlParser` | `spier_sql_parse_py` |
| `spier-transactor-py` | `Engine`, `Journal` | `spier_transactor_py` |
| `spier-eavt-query-py` | `Engine` (query engine) | `spier_eavt_query_py` |

Each binding crate is compiled with `crate-type = ["cdylib"]` and the
`extension-module` PyO3 feature. The resulting `.so` is installed into the
project venv by `maturin` / `uv` and imported directly by Python.

## Transport model

PyO3 converts Rust types to Python automatically. Bulk data crosses the
boundary packed into `Vec<u8>` (see AGENTS.md "Vec<u8> as Lingua Franca").
Live objects (cursors, sessions, compiled programs) cross as a single boxed
pointer wrapped in an `Arc`:

| Rust type | FFI shape | Cleanup |
|-----------|-----------|---------|
| `CursorHandle` | `Arc<RefCell<dyn Cursor>>` | Arc refcount + `Drop` |
| `SessionHandle` | `Arc<RefCell<dyn VMResultStream>>` | Arc refcount + `Drop` |
| `ProgramHandle` | `Arc<VMProgram>` | Arc refcount + `Drop` |

No `u64` handle registries, no explicit `close`/`free` calls. Python's
garbage collector drops the wrapper, the `Arc` decrements, and `Drop`
reclaims the Rust resource.

## GIL release

PyO3 bindings release the GIL around long-running operations (streaming,
compilation) via `py.allow_threads`. The Rust traits carry `Send + Sync`
bounds where required so the engine can run off-GIL.

## Python layer

`src/eavt_sql/` wraps the three binding crates in a small typed API:

- `engine.py` — `EAVTEngine` (uses `spier_eavt_query_py`)
- `sql_parse_client.py` — `SqlParseClient` (uses `spier_sql_parse_py`)
- `query_codec.py` — Value serialization for query params/results
- `types.py` — Datom, Timestamp, ref, etc.
