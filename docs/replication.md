# Replication — Push-Based WAL Streaming to Read-Only Replicas

## Overview

The transactor pushes every WAL record to connected replicas in real time.
The query server hosts a read-only replica engine and executes SELECT/EXPLAIN
queries **locally** against it; DML (UPSERT/ATTRIBUTE/DELETE) and admin/kv
requests route to the transactor. This scales reads (each query server is an
independent query engine), isolates query load from the write path, and
keeps reads available when the transactor is down (stale reads).

```
clients ──eavt-query.sock──▶ QUERY SERVER ──multiplexed──▶ TRANSACTOR (writer)
                              │  ▲             conn
                              │  └── replication events (wal/seal/root)
                              │  └── response frames (id-tagged)
                              ▼
                         SELECT/EXPLAIN execute locally
                         (QueryStore + VM — same libs as the transactor)
```

## Protocol

**One multiplexed connection** carries all query server→transactor traffic:
forwarded requests from every client AND the replication event stream.
Demultiplexing is by frame shape (disjoint key sets — no ambiguity):

| Frame has… | Meaning | Routed to |
|-----------|---------|-----------|
| `"ev"` key | Replication event (transactor-push) | replica engine (`onReplicationEvent`) |
| `"id"` key | Response to a forwarded request | matching pending client transport |

### Correlation IDs

Every forwarded request gets a monotonic `id` injected by the query server's
`MultiplexedConn`.  The transactor echoes `id` in every response frame
(`writeResponseAsync`, `writeErrorAsync`, schema/admin/kv writers).  The
query server's reader task demultiplexes: `"ev"` frames go to the replica;
`"id"` frames are relayed to the client transport registered in the pending
table; the pending future completes when `more=false`.

Replication events carry `"ev"` only — the reader dispatches them to the
replica's `onReplicationEvent` callback (snapshot/wal/seal/root).

### Snapshot + replication events

The query server sends `{"type":"replicate"}` once on connection open.  The
transactor registers a subscriber and sends the snapshot directly (outside
the queue); after that, every frame to the transport goes through the
subscriber's single output queue, drained by a single-flight task woken on
each enqueue.  Subsequent request frames are dispatched pipelined (each
spawned as an independent async handler); handler responses are **enqueued**
(not written directly) so that wal records generated during execution always
precede the response on the wire.

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

## Replica state (exact mirror of the transactor)

| Transactor | Replica | Synced by |
|--------|---------|-----------|
| `ps.trees` (root) | same, via `loadRoot` from blobstore | `root` event |
| `flushRoots` (pending treap) | sealed segments replayed | `seal`/snapshot |
| `mt.live` (live treap) | WAL stream applied | `wal` events |

Queries on the replica merge all three, exactly like the transactor. COW treaps
make interleaving safe on the single event loop.

## Read-your-writes

**Guaranteed by single-queue ordering, not by sleeps.** Every frame written
to a replication transport — wal/seal/root events AND response frames — flows
through the subscriber's single output queue (`Subscriber.queue`).  The WAL
sink runs during request execution (broadcast → `s.buf`); the handler enqueues
its response only afterwards, and `enqueueResponse` flushes `s.buf` into the
queue first.  The transactor therefore writes the request's wal frame(s)
**before** the response on the same transport, and the query server's reader
applies them in arrival order: by the time the ack is relayed to the client,
the replica's treap already holds the writes.  There is no guard sleep and
no cross-task race: the drain is a single-flight task (`pump`) woken on every
enqueue — no polling.

Backpressure: the subscriber keeps an exact byte accounting of pending
frames.  When the backlog exceeds 64 MiB the subscriber is presumed unable
to keep up and is **closed** (logError + transport close) — the query server
reconnects after 1 s and receives a fresh snapshot.  A query server whose
replica cannot keep up fails loudly instead of growing memory without bound.

Schema freshness: when a wal frame carries schema datoms (db.ident /
db.valueType / db.cardinality / db.unique — cf 1, aid in the first 4 key
bytes), the replica re-bootstraps its resolver immediately (the treap update
alone does not touch the in-memory resolver) and marks `schemaDirty`, which
bypasses the gateway stats TTL (30 s) on the next snapshot fetch.  This is
what makes `lookup-entity`/`eid()` usable on the replica right after
`ATTRIBUTE ... UNIQUE`: the resolver sees the UNIQUE flag before the ack.

The compile path also rebuilds stats on "attribute resolution failed"
(retry with 15 ms grace + resolver re-bootstrap + engine stats-cache bypass).

### Snapshot

The snapshot (sealed segment paths + open-tail bytes + root + blobDir) is
sent as a **direct write at subscribe time, outside the queue** — it never
counts against the backlog and cannot trigger the stall discard.  The
subscriber is registered before the open tail is captured, so records
broadcast in between land in both the snapshot's openTail and the subscriber
buf; the replica re-applies them as idempotent puts.

## Pipelined transactor dispatch

The transactor reads frames in a tight loop and **spawns** each request
handler (`asyncSpawn processFrame`).  Long-running streaming queries yield
between batches (`nextBatch(100)`) while the loop continues accepting new
frames.  Multiple handlers write concurrently to the same transport —
chronos `StreamTransport` queues writes as complete vectors, so frames are
never interleaved at the byte level.  This gives true parallelism across
concurrent query server clients on a single connection.

## Mixed operations (UPDATE/DELETE with WHERE)

UPDATE/DELETE with WHERE are split into two phases:

1. **Query server**: compiles a fake SELECT (project eid, same WHERE conditions),
   executes it on the local replica to find matching entity IDs.
2. **Query server**: constructs batched concrete save/retract calls
   (`save 101 "attr" val`, `retract 102 "attr" val`, ...) and sends them as a
   single scheme request to the transactor.

The triejoin runs on the query server's replica; the transactor only does direct
writes — no scanning needed for these operations.

## Consistency & availability

- **Transactor down**: SELECT/EXPLAIN keep answering from the last
  replicated state (stale reads); writes fail with "data server
  disconnected".  The `MultiplexedConn` auto-reconnects (1 s backoff),
  re-subscribes, and re-snapshots when the transactor returns.
- **Transport**: UDS today.  The protocol is transport-agnostic (chronos
  StreamTransport) — TCP replicas are a configuration change, enabling
  large read scale-out.  Blobs in S3 remove the shared-filesystem coupling
  for page reads.
- **Single writer**: enforced by the socket stale-check (second transactor on
  the same socket refuses to start).  Replicas never write.
- **Head-of-line blocking**: the single reader task relays response frames
  to client transports sequentially.  A slow client can delay other
  clients' responses.  Acceptable for UDS (no real backpressure locally);
  TCP deployments may need per-pending write queues.

## Design notes

- **Single multiplexed connection.**  The query server opens one `MultiplexedConn`
  at startup.  All client requests (scheme/admin/kv) and the replication
  stream share this connection.  Correlation IDs (`"id"` field) disambiguate
  responses; `"ev"` frames are the replication stream.  No per-client
  downstream connections — the shared conn replaces them entirely.
- v2 (replica reads sealed WAL directly from disk instead of receiving the
  open tail over the wire) was considered and **rejected**: slower,
  WAL-lifecycle state management on the transactor (pin/ack for segment
  deletion), and it ties the replica physically to the WAL directory.
- No explicit slow-replica buffer cap: the kernel's UDS/TCP send buffers +
  epoll write-readiness provide natural backpressure; a dead replica is
  cleaned up by the socket error callback.
- SELECTs do not allocate tx entities (dummy tx) — neither on the transactor
  nor the replica: query-mode programs are read-only by construction, so a
  per-SELECT txInstant datom was pure WAL/memtable/replication pollution.
