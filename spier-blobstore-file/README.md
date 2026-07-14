# spier-blobstore-file

File-backed BlobStore backend implementing `spier_storage_traits::BlobStoreEngine`.

Stores zstd-compressed blobs in a 2-level hex-prefix directory structure (`aa/bb/aabbccdd...`). Roots are stored as named files.

## Build

```sh
cargo build --release -p spier-blobstore-file
```

Produces `libspier_blobstore_file.rlib` (linked into the workspace, not a plugin).

## Config

Reads `path` and `read_only` from the `HashMap<String, String>` config passed to `FileBlobStore::new`. Derives blob path as `{path}/blobs`.

## Operations

Implements the `BlobStoreEngine` trait (`spier-storage-traits/src/blobstore.rs`):

`put`, `put_at`, `get`, `delete`, `list`, `put_root`, `get_root`, `list_roots`, `delete_root`.

## Directory Layout

```
base/blobs/
├── aa/
│   └── bb/
│       └── aabbccddeeff00112233445566778899
└── root_index
```

## Write Atomicity

All file writes use temp+rename to prevent partial writes on crash.

## Dependencies

- `spier-storage-traits` — `BlobStoreEngine` trait
- `uuid` — UUID generation
