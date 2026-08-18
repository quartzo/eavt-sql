# Replication — Push-Based WAL Streaming to Read-Only Replicas

## Overview

The data server pushes every WAL record to connected replicas in real time.
The gateway hosts a read-only replica engine and executes SELECT/EXPLAIN
queries **locally** against it; DML (UPSERT/ATTRIBUTE/DELETE) and admin/kv
requests forward to the data server. This scales reads (each gateway is an
independent query engine), isolates query load from the write path, and
keeps reads available when the data server is down (stale reads).

```
clients ──eavt.sock──▶ GATEWAY ──multiplexed──▶ DATA SERVER (writer)
                        │  ▲         conn
                        │  └── replication events (wal/seal/root)
                        │  └── response frames (id-tagged)
                        ▼
                   SELECT/EXPLAIN execute locally
                   (QueryStore + VM — same libs as the server)
```

## Protocol

**One multiplexed connection** carries all gateway→server traffic: forwarded
requests from every client AND the replication event stream.  Demultiplexing
is by frame shape (disjoint key sets — no ambiguity):

| Frame has… | Meaning | Routed to |
|-----------|---------|-----------|
| `"ev"` key | Replication event (server-push) | replica engine (`onReplicationEvent`) |
| `"id"` key | Response to a forwarded request | matching pending client transport |

### Correlation IDs

Every forwarded request gets a monotonic `id` injected by the gateway's
`MultiplexedConn`.  The data server echoes `id` in every response frame
(`writeResponseAsync`, `writeErrorAsync`, schema/admin/kv writers).  The
gateway's reader task demultiplexes: `"ev"` frames go to the replica;
`"id"` frames are relayed to the client transport registered in the pending
table; the pending future completes when `more=false`.

Replication events carry `"ev"` only — the reader dispatches them to the
replica's `onReplicationEvent` callback (snapshot/wal/seal/root).

### Snapshot + replication events

The gateway sends `{"type":"replicate"}` once on connection open.  The data
server registers a subscriber, sends the snapshot, spawns the drain task,
and **returns to the read loop** — subsequent request frames are dispatched
pipelined (each spawned as an independent async handler).  Replication
events and response frames write concurrently to the same transport;
chronos `StreamTransport` queues writes as complete vectors — frames are
never interleaved at the byte level.

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
its bytes are already queued server-side.  The gateway sleeps 50 ms after
relaying a DML (server drains subscribers every ~2 ms + UDS latency + reader
task scheduling), so the next statement in the same session sees its own
writes on the local replica.

Schema freshness: the gateway rebuilds compile stats from the replica on
TTL (30 s) or on "attribute resolution failed" (retry with 15 ms grace +
resolver re-bootstrap + engine stats-cache bypass).

## Pipelined server dispatch

The data server reads frames in a tight loop and **spawns** each request
handler (`asyncSpawn processFrame`).  Long-running streaming queries yield
between batches (`nextBatch(100)`) while the loop continues accepting new
frames.  Multiple handlers write concurrently to the same transport —
chronos `StreamTransport` queues writes as complete vectors, so frames are
never interleaved at the byte level.  This gives true parallelism across
concurrent gateway clients on a single connection.

## Consistency & availability

- **Data server down**: SELECT/EXPLAIN keep answering from the last
  replicated state (stale reads); writes fail with "data server
  disconnected".  The `MultiplexedConn` auto-reconnects (1 s backoff),
  re-subscribes, and re-snapshots when the server returns.
- **Transport**: UDS today.  The protocol is transport-agnostic (chronos
  StreamTransport) — TCP replicas are a configuration change, enabling
  large read scale-out.  Blobs in S3 remove the shared-filesystem coupling
  for page reads.
- **Single writer**: enforced by the socket stale-check (second server on
  the same socket refuses to start).  Replicas never write.
- **Head-of-line blocking**: the single reader task relays response frames
  to client transports sequentially.  A slow client can delay other
  clients' responses.  Acceptable for UDS (no real backpressure locally);
  TCP deployments may need per-pending write queues.

## Design notes

- **Single multiplexed connection.**  The gateway opens one `MultiplexedConn`
  at startup.  All client requests (scheme/admin/kv) and the replication
  stream share this connection.  Correlation IDs (`"id"` field) disambiguate
  responses; `"ev"` frames are the replication stream.  No per-client
  downstream connections — the shared conn replaces them entirely.
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
