# spier-journal-file

File-backed journal spier for DynSpire. Implements the `JournalEngine` IDL — stores entries as a sequential binary file with length-prefixed key-value pairs.

## Build

```sh
cargo build --release -p spier-journal-file
```

Produces `libspier_journal_file.so`.

## Config

Reads `[storage.{ctx_name}]` from DynSpire config at init. Derives journal path as `{path}/journal`. Creates the directory if it doesn't exist.

## Operations

| Op | Access | Description |
|----|--------|-------------|
| `journal_append` | Exclusive | Append `[u32 klen][key][u32 vlen][value]` to `base/journal` |
| `journal_read` | Concurrent | Parse and return all entries from `base/journal` |
| `journal_truncate` | Exclusive | Delete `base/journal` |

## File Format

```
base/journal    (sequential binary, append-only)
```

Each entry:

```
[klen: u32 BE][key: bytes][vlen: u32 BE][value: bytes]
```

Truncated entries at the end of the file (partial writes from a crash) are silently ignored on read.

## Dependencies

- `dynspire` — arena, FFI types
- `spier-kvstore` — `JournalEngine` IDL (`idl/journal.dspi`)
- `dynspire-codegen` — `impl_journal_spier!()` macro, `#[slot_struct]`
- `dynspire-libs` — config
