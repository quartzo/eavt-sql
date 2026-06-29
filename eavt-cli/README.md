# eavt-cli

Interactive SQL REPL client for EAVT databases. Binary: `eavt-repl`.

Pure gRPC client — no local engine access. Connects to a running `eavt-server`.

## Usage

```bash
eavt-repl localhost:50051
```

## Dot Commands

| Command | Description |
|---------|-------------|
| `.status` | Database overview (disk, SST, live data, MemTable, WAL) |
| `.tree` | Per-column-family stats |
| `.memtable` | MemTable contents and sizes |
| `.dump [EAVT\|AEVT\|AVET\|VAET]` | Dump active datoms |
| `.flush` | Flush MemTable to disk |
| `.help` | Show available commands |
| `.quit` / `.exit` | Exit the REPL |

## SQL

SQL statements end with `;`. Supports: `SELECT`, `UPSERT`, `UPDATE`, `DELETE`, `ATTRIBUTE`.
