# Replication — Push-Based WAL Streaming to Read-Only Replicas

## Overview

The data server pushes every WAL record to connected replicas in real time.
The gateway hosts a read-only replica engine and executes SELECT/EXPLAIN
queries **locally** against it; DML (UPSERT/ATTRIBUTE/DELETE) and admin/kv
requests forward to the data server. This scales reads (each gateway is an
independent query engine), isolates query load from the write path, and
keeps reads available when the data server is down (stale reads).

```
clients ──eavt.sock──▶ GATEWAY ──sql(DML/admin/kv)──▶ DATA SERVER (writer)
                        │  ▲
                        │  └── replication stream (WAL bytes, seal, root)
                        ▼
                   SELECT/EXPLAIN execute locally
                   (QueryStore + VM — same libs as the server)
```

## Protocol

One-way stream on a dedicated downstream connection (same 4-byte-BE length +
msgpack framing as all EAVT messages). The gateway sends
`{"type":"replicate"}`; the data server responds with a snapshot, then pushes
events keyed by `"ev"`:

| Event | Payload | Meaning |
|-------|---------|---------|
| `snapshot` | `sealed: [paths]`, `openTail: [bytes]`, `root`, `blobDir` | Initial state: replica reads sealed segment files from the shared filesystem, applies the open tail to its live treap, loads the root into its PageStore |
| `wal` | `data: [bytes]` | Journal records — applied to the replica's live treap |
| `seal` | `idx` | Segment rotation: live treap → flushRoots (pending), fresh live treap takes over |
| `root` | `name` | Flush published: replica loads the new root, discards the pending treap |

Sealed segments are **immutable files on the shared filesystem** — the
snapshot lists their paths and the replica reads them itself (no MBs over
the wire; co-located by design since page reads on cache-miss already
require the shared dir or S3). Only the volatile open tail travels as bytes.

## Replica state (exact mirror of the server)

| Server | Replica | Synced by |
|--------|---------|-----------|
| `ps.trees` (root) | same, via `loadRoot` from blobstore | `root` event |
| `flushRoots` (pending treap) | sealed segments replayed | `seal`/snapshot |
| `mt.live` (live treap) | WAL stream applied | `wal` events |

Queries on the replica merge all three, exactly like the server. COW treaps
make interleaving safe on the single event loop.

## Read-your-writes

The WAL sink broadcasts bytes to subscribers **under kv.lock, before the DML
response is written** — so by the time the gateway relays a DML response,
its bytes are already queued server-side. The gateway sleeps 10 ms after
relaying a DML (server drains subscribers every ~2 ms + UDS latency), so the
next statement in the same session sees its own writes on the local replica.

Schema freshness: the gateway rebuilds compile stats from the replica on
TTL (30 s) or on "attribute resolution failed" (retry with 15 ms grace +
resolver re-bootstrap + engine stats-cache bypass).

## Consistency & availability

- **Data server down**: SELECT/EXPLAIN keep answering from the last
  replicated state (stale reads); writes fail with a clear error. The
  replication loop auto-reconnects (1 s) and re-snapshots when the server
  returns.
- **Transport**: UDS today. The protocol is transport-agnostic (chronos
  StreamTransport) — TCP replicas are a configuration change, enabling
  large read scale-out. Blobs in S3 remove the shared-filesystem coupling
  for page reads.
- **Single writer**: enforced by the socket stale-check (second server on
  the same socket refuses to start). Replicas never write.

## Design notes

- **Two gateway→server connections (per role, not per party).** The plan
  called for multiplexing the replication stream onto "the existing
  connection" — but no such single connection exists: forwarding
  connections are per-client-session and ephemeral, while the replication
  subscription is gateway-global and must outlive every client. And the
  wire protocol has no correlation IDs: unsolicited `wal` frames arriving
  between a forwarded DML and its response would be indistinguishable to
  the verbatim relay (`relayFrames` relays everything until `more=false`).
  So the subscription is a dedicated long-lived connection opened at
  gateway startup. True multiplexing would require adding correlation IDs
  to the protocol — a larger redesign with no current benefit.
- v2 (replica reads sealed WAL directly from disk instead of receiving the
  open tail over the wire) was considered and **rejected**: slower,
  WAL-lifecycle state management on the server (pin/ack for segment
  deletion), and it ties the replica physically to the WAL directory.
- No explicit slow-replica buffer cap: the kernel's UDS/TCP send buffers +
  epoll write-readiness provide natural backpressure; a dead replica is
  cleaned up by the socket error callback.
- SELECTs do not allocate tx entities (dummy tx) — neither on the server
  nor the replica: query-mode programs are read-only by construction, so a
  per-SELECT txInstant datom was pure WAL/memtable/replication pollution.
