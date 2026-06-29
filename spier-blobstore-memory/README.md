# spier-blobstore-memory

In-memory BlobStore spier for the DynSpire dynamic plugin architecture.

Stores blobs and roots in `HashMap`/`BTreeMap` — all in-process, no persistence. Use for testing, caching layers, or ephemeral workloads (`:memory:` mode).

## Build

```sh
cargo build --release -p spier-blobstore-memory
```

Produces `libspier_blobstore_memory.so`.

## Config

No config needed. Ignores `[storage.{ctx_name}]`.

## Operations

| Op | Access | Description |
|----|--------|-------------|
| `put` | Exclusive | Store under random UUID |
| `put_at` | Exclusive | Store under given UUID |
| `get` | Concurrent | Return blob by UUID |
| `delete` | Exclusive | Remove blob by UUID |
| `list` | Concurrent | Return all stored UUIDs |
| `put_root` | Exclusive | Store named root |
| `get_root` | Concurrent | Return named root |
| `list_roots` | Concurrent | Return all root names |
| `delete_root` | Exclusive | Remove named root |

## Dependencies

- `dynspire` — arena, FFI types
- `spier-kvstore` — `BlobStoreEngine` IDL (`idl/blobstore.dspi`)
- `dynspire-codegen` — `impl_blobstore_spier!()` macro, `#[slot_struct]`
- `zstd` — blob compression
