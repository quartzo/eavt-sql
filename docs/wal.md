# WAL — Segmented Write-Ahead Log (interval durability)

## Overview

With the file backend, the transactor persists every write to a segmented
journal (WAL) before applying it to the MemTable. Writes land in a loop-side
buffer; disk I/O goes through **chronos-file**'s thread pool; `fsync` fires on
a 100 ms timer. The journal is **rotated at flush-capture boundaries** so
records written *during* a flush survive it — see "Why segments" below.

```
write path (loop, under kv.lock)          WAL cycle (loop, 100 ms)
┌────────────────────────────┐            ┌──────────────────────────────┐
│ sink: buf.add(data)        │            │ drain: split buf at seal     │
│ logicalEnd += len          │            │   pre-seal → segment N       │
└────────────────────────────┘            │   post-seal → segment N+1    │
                                          │ fsync current segment        │
flush thread (nim_spawn)                  │ delete sealed segs whose     │
capture (kv.lock): journalSeal() ────────▶│   boundary ≤ walDurableUpTo  │
publish  (kv.lock): walDurableUpTo=seal ──┘
```

## Why segments (not one truncated file)

Records written during a flush tail the same file *after* the captured ones.
Truncating — at 0 or at the capture offset — either loses those records (they
are only in the WAL) or rewrites live bytes with torn-crash regressions.
Segments are append-only and deleted only once their records are durable in
the PageStore. A crash mid-flush leaves all segments; replay applies them in
numeric order (later wins; pre-capture re-applies are idempotent puts).

## Segment files

```
DIR/journal/journal.NNNNN   segments, 5-digit zero-padded, numeric order
DIR/journal/journal         legacy single-file format (pre-rotation) —
                            replayed first if present; no longer written
```

The correspondence seal↔memtable is exact: the sink and `mt.batch` run under
the same `kv.lock` (sink first), and the seal runs at capture under that lock
— every record with logical position < boundary is in the captured roots.

## Durability policy

**Interval fsync (100 ms):** appends reach the segment via one chained
`writeAt` per group; `fsync` on the timer plus at shutdown. **Process crash
is always safe; machine crash loses at most the last ~100 ms.**

## Journal record format (unchanged)

```
[4B klen][cf (1B) + key (klen-1 B)][4B vlen][value (vlen B)]
```

`vlen = 0xFFFFFFFF` marks a delete. A torn tail (crash mid-write) ends that
file's replay at the last complete record.

## Files

```
DIR/journal/journal.NNNNN   the WAL segments
DIR/blobs/                  PageStore blobs (flush target)
```

## Implementation notes

- `KVStore.journalSink` / `KVStore.journalSeal` / `walDurableUpTo`
  (nim_kvstore/kvstore.nim): the hooks the server's WalWriter installs. The
  sink is a memcpy under `kv.lock`; the seal is a counter read.
- `WalWriter` (eavt_transactor_nim/wal.nim): loop-owned buffers; rotation closes
  the sealed segment, records it for deletion, opens the next. Segment
  discovery uses `lastPathPart` — `splitFile` would eat ".00001" as an
  extension and silently find nothing.
- Commit-side tree swaps (`commitMerge*`) take `ps.lock` (loop readers take
  `kv.lock → ps.lock`; the flush thread takes `ps.lock` alone — no cycle):
  closes the torn-read race on `ps.trees` between flush and queries.


## Server flags

```
eavt-sql-transactor                                        # default: file backend,
                                                       #   data dir $XDG_DATA_HOME/eavt/db
                                                       #   (fallback ~/.local/state/eavt/db)
eavt-sql-transactor --path /var/lib/eavt                   # file backend, explicit dir
eavt-sql-transactor --backend s3 --path /wal/dir \
                --s3-endpoint ... --s3-bucket ... \
                --s3-access-key ... --s3-secret-key ... # blobs in S3, WAL local
```

S3 credentials also resolve from `EAVT_S3_ENDPOINT/BUCKET/ACCESS_KEY/SECRET_KEY/REGION/PREFIX/PATH_STYLE`
(flags win over env). With `--backend s3` the local `--path` still hosts the
WAL/journal — blobs are flushed to the bucket.
