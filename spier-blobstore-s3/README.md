# spier-blobstore-s3

S3-backed BlobStore spier for the DynSpire dynamic plugin architecture.

Stores zstd-compressed blobs on any S3-compatible object store.

## Build

```sh
cargo build --release -p spier-blobstore-s3
```

Produces `libspier_blobstore_s3.so`.

## Config

Reads `[storage.{ctx_name}]` for storage path and `[blobstore.s3]` for S3 options (endpoint, bucket_name, region, access_key, secret_key, prefix, path_style).

## Operations

| Op | Access | Description |
|----|--------|-------------|
| `put` | Exclusive | Upload to S3 under random UUID |
| `put_at` | Exclusive | Upload under given UUID |
| `get` | Concurrent | Download blob by UUID |
| `delete` | Exclusive | Remove blob from S3 |
| `list` | Concurrent | List all blob UUIDs |
| `put_root` | Exclusive | Upload named root |
| `get_root` | Concurrent | Download named root |
| `list_roots` | Concurrent | List root names |
| `delete_root` | Exclusive | Remove named root from S3 |

## S3 Key Layout

```
<prefix>/blobs/aa/bb/aabbccddeeff00112233445566778899
<prefix>/roots/root_index
```

## Dependencies

- `dynspire` — arena, FFI types
- `spier-kvstore` — `BlobStoreEngine` IDL (`idl/blobstore.dspi`)
- `dynspire-codegen` — `impl_blobstore_spier!()` macro, `#[slot_struct]`
- `dynspire-libs` — config
- `reqwest` (blocking, rustls-tls) — HTTP client
- `rusty-s3` — S3 protocol (presigned URLs, list v2)
- `zstd` — blob compression
