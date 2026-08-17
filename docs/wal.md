# WAL — Write-Ahead Log (interval durability)

## Overview

With `--backend file --path DIR`, the data server persists every write to a
journal (WAL) before applying it to the MemTable. Writes are handed to a
`WalWriter` living on the server's chronos event loop; disk I/O goes through
**chronos-file** (vendored at `vendor/chronos_file_pkg/`), whose thread-pool
backend runs `pwrite`/`fsync` off the loop.

```
write path (per request, under kv.lock)          event loop               pool
┌──────────────────────────┐   sink(bytes)   ┌─────────────┐  writeAt  ┌─────┐
│ KVStore.put/putKv/batch  │ ───────────────▶│ WalWriter   │ ────────▶ │pread│
│ Write (MemTable apply)   │   memcpy only   │ .buf (group)│  chained  │pwrite│
└──────────────────────────┘                 │ fsync 100ms │ ──fsync──▶│fsync│
                                             └─────────────┘           └─────┘
```

## Durability policy

**Interval fsync (100ms), Redis-everysec style:**

- Appends reach the file via one chained `writeAt` per accumulated group
  (single writer, tracked offset — `AsyncFileBusyError` can never happen on
  the positioned ops).
- `fsync` fires on a 100 ms timer, plus a final drain+fsync on shutdown.
- Semantics: **process crash is always safe** (bytes handed to the sink are
  in the loop's buffer; the journal file itself only ever contains complete
  records, and replay tolerates a torn tail by stopping at the first
  malformed record). **Machine crash loses at most the last ~100 ms** of
  acknowledged writes.

## Journal format (unchanged)

Stream of records, big-endian:

```
[4B klen][cf (1B) + key (klen-1 B)][4B vlen][value (vlen B)]
```

- `vlen = 0xFFFFFFFF` marks a delete.
- Key-only CFs 0-3 (EAVT indexes); CFs ≥ 10 are key-value pairs.

## Replay

At startup, **before** the chronos loop starts serving (synchronous, in
`newKVStore`): records are parsed and applied to the MemTable as a batch.
A torn tail (partial record from a crash mid-write) ends the replay at the
last complete record. The resolver/schema is then bootstrapped from the
replayed `db.*` datoms (`bootstrapResolver`).

## Files

```
DIR/journal/journal   the WAL
DIR/blobs/            PageStore blobs (flush target)
```

## Server flags

```
eavt-sql-server                                        # default: file backend,
                                                       #   data dir $XDG_DATA_HOME/eavt/db
                                                       #   (fallback ~/.local/state/eavt/db)
eavt-sql-server --path /var/lib/eavt                   # file backend, explicit dir
eavt-sql-server --backend s3 --path /wal/dir \
                --s3-endpoint ... --s3-bucket ... \
                --s3-access-key ... --s3-secret-key ... # blobs in S3, WAL local
```

S3 credentials also resolve from `EAVT_S3_ENDPOINT/BUCKET/ACCESS_KEY/SECRET_KEY/REGION/PREFIX/PATH_STYLE`
(flags win over env). With `--backend s3` the local `--path` still hosts the
WAL/journal — blobs are flushed to the bucket.

## Implementation notes

- `KVStore.journalSink` (nim_kvstore/kvstore.nim): when installed, journal
  bytes are handed to the sink **under `kv.lock`** — sinks must only do cheap
  work (the WalWriter sink is a memcpy into its group buffer).
- The WalWriter captures a heap `WalWriter` ref in the sink closure — never
  the async `result` FutureVar (that was a SIGSEGV: the sink runs on the
  write path outside the async frame).
- Journal is opened `fmReadWriteExisting` (no `O_TRUNC`!) — `fmReadWrite`
  would erase the journal on every restart.
- Replay reconstructs ops with the record's own CF (the old replay
  hard-coded cf=0, corrupting every CF but 0 — pre-existing bug, exposed by
  the first file-backend persistence test).
