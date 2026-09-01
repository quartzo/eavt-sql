# Tx Protocol — EDN Transactions between Query Server and Transactor

## Status

Draft — implementation pending (phases F0–F4 below). This document specifies
the Datomic-style transaction protocol that will replace compiled Scheme
programs as the write path between the query server and the transactor.
Reading it before `docs/scheme-transport.md` is not required, but §3 of that
document (msgpack framing, EDN-like value encoding) is the substrate this
protocol builds on.

## 1. Overview

Today every write that reaches the transactor travels as a compiled Scheme
program: `(set! X (alloc-entity 4))`, `(when X ...)` chains, `(save X "attr" v)`,
and a `(result X N)` return convention. The transactor is a VM host; transaction
semantics (entity allocation, upsert-by-unique, value chaining) are encoded as
*programs*.

This document specifies the replacement: **a `tx` request type whose payload is
tx-data as data** — EDN vectors in the Datomic tradition — interpreted natively
by the transactor, without the Scheme VM in the write path.

```
[:db/add -1 :person/name "álvia"]
[:db/add -1 :person/employer -2]
[:db/add -2 :company/name "Acme"]
```

### Motivations

- **Transaction semantics as data, not program.** Tempid resolution, lookup
  refs and atomicity belong to a transaction processor, not to stack-machine
  idioms. The query-server compiler stops manipulating `set!`/`when`/`alloc-entity`.
- **Resolution in-tx against the source of truth.** Lookup refs and upserts by
  unique attribute must consult the authoritative store *inside the
  transaction*. Only the transactor can do that atomically; resolving on the
  replica would reintroduce stale reads by design (see §2).
- **Observable protocol.** A tx frame is data: logs, WAL and debug output show
  exactly what was written. No `(param N)` placeholders, no `(result X N)`
  convention; the response is a structured tx-report.
- **Substrate for Datalog.** Step 2 of the roadmap replaces the SQL surface
  with Datalog. With tx-data in place, the query server never compiles writes
  to Scheme again; `scheme` Q→T survives only as Python passthrough and dies
  with `translate.nim` in step 2.

### Non-goals (step 1)

- `:db/retractEntity` (VAET cascade), `:db.fn` / transaction functions, rules,
  aggregates, `:db.tempid` in partitions other than user (no `:db.part/tx`
  tempids — use `:db/current-tx` for tx metadata, §6).
- Any change to the query path: SELECT/EXPLAIN/HISTORY keep running on the
  replica exactly as today.

## 2. Consistency model

The architecture separates long-lived read work from authoritative writes:

- **Queries** (triejoin, HISTORY, EXPLAIN) run on the query server's replica
  and are *designed* for replica operation with eventual consistency. This is
  by design, not a limitation to fix.
- **Unit writes** (single entities, upserts by unique attribute) are atomic in
  the transactor: lookup refs and tempids resolve in-tx against the
  authoritative store, all datoms share one `t`.
- **Bulk UPDATE/DELETE** are best-effort, two-phase: the query server's replica
  finds matching eids (its own time), then sends per-batch transactions of
  concrete eids to the transactor. Selection may be stale under concurrent
  writes — this is accepted, documented behavior. Each batch is atomically
  consistent; the multi-batch whole is not.

Rationale: long-running triejoin operations are designed for replica
operation where consistency is not required; updates and deletes operate on
their own time with best-effort semantics, counting on no large changes
happening underneath. The protocol does not pretend to give bulk operations
strong atomicity — that is what unit transactions (and future tx-embedded
queries, if ever) are for.

## 3. Wire format

Framing is unchanged from `scheme-transport.md` §3: 4-byte big-endian length
prefix + msgpack payload; a single multiplexed connection carries all traffic.

### 3.1 Request

```
{"type": "tx", "txdata": [op, op, ...]}
```

- `txdata` is a msgpack **array of vectors** (EDN vectors encoded as msgpack
  arrays). Each op is a vector whose first element is a keyword.
- Values inside ops follow the same encoding as scheme program values
  (`scheme-transport.md` §3.3): native msgpack types, symbols as ext `0x05`,
  **keywords as ext `0x06`**, strings as str, ints as int64, floats as f64,
  bytes as bin, nil as void. There is no `params` field and no `(param N)`
  placeholder — client-supplied values are substituted at compile time (§5.4).

### 3.2 Response (tx-report)

```
{"tempids": {-1: 70368744177664, -2: 70368744177665}, "tx": 549755813888, "more": false}
```

- `tempids`: msgpack map from the original **negative int64** tempid to the
  resolved eid (int keys are native msgpack — no stringification). Omitted
  when the tx has no tempids.
- `tx`: the tx entity id (`:db.part/tx`) that all datoms in this transaction
  carry as their `t`.

### 3.3 Errors

Failures abort the transaction **before any datom is applied** and return a
single error frame:

```
{"error": "tx: lookup ref [:person/email \"missing@x\"] did not match any entity", "more": false}
```

Error cases: lookup-ref miss (§5.3), unknown attribute, unknown keyword op or
value-type/cardinality keyword, `:db/retract` on `:db/current-tx` (§6),
malformed op vector, non-vector `txdata`.

## 4. Operations

| Op | Syntax | Semantics |
|----|--------|-----------|
| add | `[:db/add e :attr v]` | Assert datom `(e, attr, v)` at this tx. `e` may be an eid (positive int), a tempid (negative int64), a lookup ref, or `:db/current-tx`. |
| retract | `[:db/retract e :attr v]` | Retract the matching datom. `e` must resolve to an existing eid (tempid not allowed); **error** on `:db/current-tx`. |
| schema | `[:db/add eid :db/ident :ns/name]` + `:db/valueType` / `:db/cardinality` / `:db/unique` datoms for the same eid | Interpreted as an attribute declaration (§7), not raw datoms. |
| partition | — | All tempids resolve in `:db.part/user` (id 4). `:db.part/tx` and `:db.part/db` are engine-managed; user tx-data cannot allocate there. |

The `v` slot accepts scalars (str/int/float/bool/bytes/nil), a keyword (ref to
a keyword-namespaced entity, e.g. an enum `:status/active` — stored as its
interned keyword string), or a tempid / lookup ref (entity reference on
`:db.type/ref` attributes only: negative int = tempid, vector = lookup ref;
a string is never a valid ref value, so it errors). `:db/retract` requires a
concrete scalar value (no refs, no tempids) in v1.

## 5. Tempids, lookup refs, and value substitution

### 5.1 Tempids

A **negative int64** in the `e` slot (or in the `v` slot of a `:db.type/ref`
attribute) is a tempid — Datomic's convention (`(d/tempid :db.part/users)`
returns negative longs; clients hand-write `-1`, `-2`, ...). Real eids are
always positive (partition id shifted left), so the sign is an unambiguous
marker: no collision with existing entities, no schema lookaside needed to
classify the `e` slot, and no wire overhead (native int64).

- If any `:db/add` for that tempid carries an attribute declared
  `:db.unique/identity`, resolution is **upsert**: look up the entity by that
  unique value; allocate only when the lookup misses. (Lookup miss during
  upsert resolution is *not* an error — it allocates.)
- Otherwise the tempid allocates a fresh entity via `allocateInPartition(4)`.
- Tempid chaining is native: `[:db/add -1 :person/employer -2]` references
  the entity allocated for `-2` in the same tx.
- Datomic's partition-qualified tempids (`:db.tempid/:db.part/users`) are not
  needed in v1: user data has exactly one target partition (`:db.part/user`).
  Tx-partition tempids (`:db.tempid/:db.part/tx`) are replaced by the
  explicit `:db/current-tx` keyword (§6).
- Resolution order: schema ops first (§7), then a single pass resolving
  tempids (unique lookups before fresh allocations), then all ops apply with
  one `t`.

### 5.2 `:db/current-tx`

The keyword `:db/current-tx` in the `e` slot resolves to the tx entity
allocated by this very transaction (§6). All ops in the tx, including tx
metadata, share the same `t`.

### 5.3 Lookup refs

A vector in the `e` slot — `[:person/email "a@b.c"]` — is a lookup ref: the
attribute must be `:db.unique/identity` (or `:db.unique/value`). Resolution
happens **in the transactor, inside the tx**, against the authoritative store.

A lookup ref that matches no entity is an **error** (Datomic-strict). Note:
this deliberately changes SQL UPSERT-by-lookup semantics, which currently
skips the write silently (`(when X ...)` guarding). Documented behavioral
change; no production data relies on the skip.

### 5.4 No `params` in the protocol

The `scheme` protocol carries `(param N)` placeholders because compiled
programs may be re-executed across batches. Tx requests are built fresh per
batch by the query server and never re-executed, so the indirection buys
nothing: client-supplied values (SQL `%N` params) are substituted into tx-data
at compile time. The transactor's tx interpreter has no concept of params.
(Query-path params — Python `scheme()` passthrough and the future Datalog
`:in` — are unaffected and keep working.)

## 6. Tx entity and user tx metadata

- The engine allocates the tx entity in `:db.part/tx` and writes its
  `:db/txInstant` datom (micros) once, before applying ops — this is today's
  `allocateTAndWriteTx` (eavt.nim), now invoked by the tx interpreter.
- `:db/current-tx` in the `e` slot attaches user data to the tx entity:

```
[:db/add :db/current-tx :audit/user "fabio"]
[:db/add :db/current-tx :audit/reason "initial import"]
```

- Metadata attributes are ordinary attributes (STRING etc.) and must be
  declared (same-tx schema declaration works, §7).
- Every datom's `t` links it to its tx entity, so joins from data to tx
  metadata are native: `[?e :person/name ?v ?tx] [?tx :audit/reason ?r]`.
- `:db/retract` targeting `:db/current-tx` (or any resolved tx entity) is an
  error in v1: tx datoms are immutable.

## 7. Schema as data

Attributes are declared with datoms, the Datomic way. The interpreter groups,
per eid, the following attributes and calls `eavtDeclareAttr` once:

| Keyword | Meaning |
|---------|---------|
| `:db/ident` | attribute name — the keyword's name (e.g. `:person/name` → `person/name`), stored in canonical slash form (§8) |
| `:db/valueType` | `:db.type/string`, `:db.type/long`, `:db.type/float`, `:db.type/boolean`, `:db.type/bytes`, `:db.type/keyword`, `:db.type/ref`, `:db.type/instant` |
| `:db/cardinality` | `:db.cardinality/one` (default) or `:db.cardinality/many` |
| `:db/unique` | `:db.unique/identity` or `:db.unique/value` (both imply indexed) |

```
[[:db/add "sch" :db/ident :person/email]
 [:db/add "sch" :db/valueType :db.type/string]
 [:db/add "sch" :db/cardinality :db.cardinality/one]
 [:db/add "sch" :db/unique :db.unique/identity]
 [:db/add -1 :person/name "álvia"]]    ; same-tx usage is allowed
```

Sequencing: schema ops within a tx execute before data ops, so an attribute
can be declared and used in the same transaction. (The legacy `declare-attr`
scheme opcode remains for the SQL path during the transition.)

## 8. Storage canonical names

- The canonical stored form of an attribute name is `ns/name` — **slash, no
  leading colon** (e.g. `person/name`, `db/ident`). The EDN keyword
  `:person/name` maps to the string `person/name` at resolution time; wire and
  storage never embed the leading colon.
- The SQL legacy path normalizes dot notation (`person.name`) to slash form at
  the compile boundary (`a.b` → `a/b`) during the transition; SQL is removed
  in step 2.
- The 26 bootstrap system attributes are renamed accordingly (`db/ident`,
  `db/cardinality`, `db/valueType`, ...). Dev databases are recreated; there
  is no production data and no migration.

## 9. Compatibility and lifecycle

- The transactor keeps accepting `scheme` requests unchanged — the Python
  client's `scheme()` API is forwarded verbatim by the query server and dies
  in step 2 with the SQL compiler. New write traffic from the query server
  uses `tx` only.
- Correspondence with today's Scheme write programs (for review; not a frozen
  spec):

| Today (Scheme) | Tx protocol (EDN) |
|---|---|
| `(set! X (alloc-entity 4))` + `(save X "attr" v)` | `[:db/add -1 :attr v]` |
| `(set! X (lookup-entity "attr" val))` + guarded saves | `[:db/add [:attr val] :attr v]` (lookup ref; miss → error, was skip) |
| `(save eid "attr" (param M))` | `[:db/add eid :attr M-value]` (params substituted at compile time) |
| `(retract eid "attr" v)` | `[:db/retract eid :attr v]` |
| `(declare-attr "name" "STRING" many unique)` | `:db/ident` + `:db/valueType` + `:db/cardinality` + `:db/unique` datoms (§7) |
| `(declare-partition "name")` | engine-managed partitions; user declarations not needed in v1 |
| `(result X N)` | tx-report `{tempids, tx}` (§3.2) |

## 10. Implementation phases

| Phase | Scope | Acceptance |
|-------|-------|------------|
| F0 | `SExpr` keyword kind + wire ext `0x06`; `nim_edn` reader (keywords, symbols, vectors, scalars, `_`) | round-trip tests incl. sym≠kw≠str; byte-level Python `ExtType(6,...)` |
| F1 | Tx interpreter in transactor (`type: tx`); tempid/lookup-ref/schema-as-data/`:db/current-tx`; tx-report response | suite: chaining, upsert-by-unique, schema-in-same-tx, lookup-miss aborts everything |
| F2 | Query server compiles SQL writes → tx-data; mixed update/delete batching on `:db/add`/`:db/retract`; UPSERT rows rebuilt from tempids | SQL e2e results unchanged; Python `scheme()` passthrough still green |
| F3 | Canonical slash naming: bootstrap `db/*`, SQL boundary `.`→`/` normalization | dev DB recreated; schema snapshot shows `ns/name` |
| F4 | Docs finalized, golden tests SQL↔EDN (same final datoms via both paths), bench sanity | all green |

### Implementation notes / open risks

- Attribute declared and used in the same tx: if `intern-a`-style resolution
  cannot see same-`t` declarations, the interpreter sequences schema ops first
  (already specified, §7).
- REPL/clients observe the lookup-miss behavior change (skip → error); call
  sites must be updated with the F2 acceptance run.
- Bulk two-phase semantics are unchanged from today and must be documented in
  EXPLAIN/help text (§2).

## 11. Related documents

- `docs/scheme-transport.md` — msgpack framing, EDN-like value encoding (§3.3),
  the `scheme` protocol this replaces for writes
- `docs/scheme-ir.md` — SExpr type system and VM (query path)
- `AGENTS.md` — storage key encoding, threading model, exception rules
