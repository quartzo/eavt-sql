# spier-journal-file

File-backed journal backend implementing `spier_storage_traits::JournalEngine`. Stores entries as a sequential binary file with length-prefixed key-value pairs.

## Build

```sh
cargo build --release -p spier-journal-file
```

Produces `libspier_journal_file.rlib` (linked into the workspace, not a plugin).

## Config

Reads `path` from the `HashMap<String, String>` config passed to `JournalFile::new`. Derives journal path as `{path}/journal`. Creates the directory if it doesn't exist.

## Operations

Implements the `JournalEngine` trait (`spier-storage-traits/src/journal.rs`):

- `journal_append` — append `[u32 klen][key][u32 vlen][value]` to `base/journal`
- `journal_read` — parse and return all entries from `base/journal`
- `journal_truncate` — delete `base/journal`

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

- `spier-storage-traits` — `JournalEngine` trait
