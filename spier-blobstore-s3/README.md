# spier-blobstore-s3

S3-backed BlobStore backend implementing `spier_storage_traits::BlobStoreEngine`.

Stores zstd-compressed blobs on any S3-compatible object store.

## Build

```sh
cargo build --release -p spier-blobstore-s3
```

Produces `libspier_blobstore_s3.rlib` (linked into the workspace, not a plugin).

## Config

Reads S3 options from the `HashMap<String, String>` config passed to `S3BlobStore::new`: `endpoint`, `bucket_name`, `region`, `access_key`, `secret_key`, `prefix`, `path_style`.

## Operations

Implements the `BlobStoreEngine` trait (`spier-storage-traits/src/blobstore.rs`):

`put`, `put_at`, `get`, `delete`, `list`, `put_root`, `get_root`, `list_roots`, `delete_root`.

## S3 Key Layout

```
<prefix>/blobs/aa/bb/aabbccddeeff00112233445566778899
<prefix>/roots/root_index
```

## Dependencies

- `spier-storage-traits` — `BlobStoreEngine` trait
- `uuid` — UUID generation
- `ureq` (tls) — HTTP client
- `rusty-s3` — S3 protocol (presigned URLs, list v2)
