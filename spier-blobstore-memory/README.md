# spier-blobstore-memory

In-memory BlobStore backend implementing `spier_storage_traits::BlobStoreEngine`.

Stores blobs and roots in `HashMap`/`BTreeMap` — all in-process, no persistence. Use for testing, caching layers, or ephemeral workloads (`:memory:` mode).

## Build

```sh
cargo build --release -p spier-blobstore-memory
```

Produces `libspier_blobstore_memory.rlib` (linked into the workspace, not a plugin).

## Config

No config needed. Ignores `[storage.{ctx_name}]`.

## Operations

Implements the `BlobStoreEngine` trait (`spier-storage-traits/src/blobstore.rs`):

`put`, `put_at`, `get`, `delete`, `list`, `put_root`, `get_root`, `list_roots`, `delete_root`.

## Dependencies

- `spier-storage-traits` — `BlobStoreEngine` trait
- `uuid` — UUID generation
