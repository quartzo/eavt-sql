# spier-blobstore-file

File-backed BlobStore spier for the DynSpire dynamic plugin architecture.

Stores zstd-compressed blobs in a 2-level hex-prefix directory structure (`aa/bb/aabbccdd...`). Roots are stored as named files.

## Build

```sh
cargo build --release -p spier-blobstore-file
```

Produces `libspier_blobstore_file.so`.

## Config

Reads `[storage.{ctx_name}]` from DynSpire config at init. Derives blob path as `{path}/blobs`. Supports `read_only` option.

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

- `dynspire` — arena, FFI types
- `spier-kvstore` — `BlobStoreEngine` IDL (`idl/blobstore.dspi`)
- `dynspire-codegen` — `impl_blobstore_spier!()` macro, `#[slot_struct]`
- `dynspire-libs` — config, discovery
- `zstd` — blob compression
