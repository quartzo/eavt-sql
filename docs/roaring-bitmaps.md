# Roaring Bitmaps — Derived Index Design

## 1. Goal

Roaring bitmaps are a **derived inverted index** for efficient faceted filtering
over a large, fixed entity population (~30M companies). The workload: start from
the full universe and apply bitmap arithmetic (state, is-headquarters, has-site,
sector, ...) to reduce it before enrichment. Bitmaps are regenerable from the
EAVT data, read-heavy, and best-effort consistent.

Roaring is **not** part of the EAVT engine's semantics. The EAVT data is
authoritative; bitmaps are a projection of it.

## 2. When Roaring Beats the EAVT Indexes

The existing indexes (EAVT/AEVT/AVET/VAET) + leapfrog triejoin handle set
intersection well when each attribute is moderately selective and the number of
joined clauses is small. Roaring wins in a different regime:

| Workload | EAVT + triejoin | Roaring bitmap |
|----------|-----------------|----------------|
| Few joins, moderate selectivity | Excellent | No advantage |
| Many boolean/categorical filters (dozens) | Cost grows with joins × result set | `AND` is O(n/64) bitops |
| Cardinality estimation (count without materializing) | Must scan | O(n/64) popcount |
| Dense boolean/categorical dimensions | datom per entity per value | one roaring set per value |

For faceted filtering, the reduction (intersect of N dimensions) is roaring's
textbook case. The triejoin is the wrong tool for multi-dimensional boolean
algebra — forcing N scanners into leapfrog convergence is slower than native
roaring `AND`.

**Decision factor:** adopt roaring only when the faceted-filter workload is real.
For general-purpose EAVT queries the triejoin is already optimal.

## 3. Architecture

Two stores, one authoritative, one derived:

```
BlobStore (Memory / File / S3)          ← shared content-addressed substrate
   ├─ KVStore-A (EAVT)                  ← key-only CFs 0–3, MemTable, as-of
   │     └─ Transactor                   ← EAVT semantics (save/retract/constraints)
   └─ KVStore-B (bitmap)                ← value-bearing CF, no MemTable
         └─ bitmap derivation + query   ← roaring store, maintained post-commit or batch
```

KVStore-A holds the authoritative datoms (`estado="SP"` is a real fact, queryable
normally). KVStore-B holds the derived roaring index. Both are the **same
KVStore codebase** with different configuration — see §6.

The query layer composes them: the bitmap reduces the entity set (native
roaring), then EAVT enriches the result (triejoin). Each store stays true to its
domain; they meet at the value level (entity ID sets), not by entangling engines.

## 4. Schema Declaration

Bitmap dimensions are declared as real EAVT attributes with a `BITMAP` modifier:

```
ATTRIBUTE bitmap.estado_federacao STRING BITMAP
ATTRIBUTE bitmap.tem_site BOOL BITMAP
ATTRIBUTE empresa.tags STRING MANY BITMAP
```

This declares:
- a **real EAVT attribute** (authoritative datom, queryable via normal EAVT:
  `SELECT d1.bitmap.estado WHERE d1.eid = %1` → `"SP"`)
- **plus** a derived roaring index — one bitmap per distinct value
  (`estado_federacao="SP"` → set of entities in SP)

The `BITMAP` modifier is **orthogonal** to type, cardinality, and uniqueness:
- `STRING BITMAP` → one roaring bitmap per categorical value
- `BOOL BITMAP` → roaring for `true` (and `false`, if useful)
- `STRING MANY BITMAP` → tags: one roaring bitmap per tag
- composes with `ONE`/`MANY`/`UNIQUE`

The forward datoms are the source of truth; the roaring bitmaps are a second
derived inverted index that earns its keep on multi-facet AND queries (where the
AVET index via leapfrog loses). `BITMAP` is opt-in — only on attributes that
participate in faceted filtering, not all attributes.

## 5. Bit Allocation

### Bit position = seq, within a dedicated partition

Entity IDs are partitioned (`resolver_consts.rs`): `eid = (partition << 44) | seq`.
The `seq` (low 44 bits) is a dense, monotonically-allocated index within a
partition.

```
bit_position = seq_of(eid) = eid & 0xFFFFFFFFFFF
block_id     = seq >> 16
bit_in_block = seq & 0xFFFF
```

Bitmap-participating entities are allocated in a **dedicated partition**
(e.g. `PART_COMPANY`), so their `seq`s are consecutive (0..30M for 30M
companies). Non-bitmap entities (people, addresses, transactions, schema) live in
other partitions and never touch this bit space.

### Why consecutive matters: roaring container efficiency

Roaring partitions the key space into 16-bit blocks, each stored as one of:
- **Run container** (consecutive runs) — RLE-like, near-zero size for ranges
- **Bitset container** — 8 KB fixed, used when ≥ 4096 set bits per block
- **Array container** — sparse, stores sorted values

Consecutive allocation (dedicated partition) gives:
- **Superset bitmaps** (all companies, seq 0..30M) → run containers → ~bytes
- **Faceted bitmaps** (estado=SP, ~10M scattered within 0..30M) → bitset
  containers over the **minimum range** (458 blocks, not 916 if interleaved with
  non-companies)

Interleaving bitmap entities with non-bitmap entities in the same partition
roughly doubles the block count and prevents run containers — a real cost, not
just "unset bits are free."

### eid reconstructible by arithmetic

Because `bit_position = seq_of(eid)`, the eid is reconstructible from a bit
position by pure arithmetic:

```
eid = (PART_COMPANY << 44) | bit_position
```

This is the key property: enriching a bitmap result (set of bit positions →
eids) costs zero lookups. The alternative (a separate dense numbering / "magic
seq attribute") breaks this — it requires a `seq → eid` reverse lookup on every
enrichment. Avoid it unless entity participation is genuinely unknowable at
allocation time (not the case for companies, which are known at creation).

### Block sizing

| | 65536 (2^16) | 262144 (2^18) |
|---|---|---|
| Blocks for 30M | ~458 | ~115 |
| Max bitmap size | ~8 KB | ~33 KB |
| Roaring container alignment | 1 container | 4 containers |

2^16 aligns exactly with one roaring container — one bitmap = one container,
most efficient serialization.

## 6. Storage — Separate KVStore Context

### Same codebase, different configuration

The bitmap store is a **second KVStore instance** (same code), configured
differently from the EAVT store:

| | KVStore-A (EAVT) | KVStore-B (bitmap) |
|---|---|---|
| CF value | `None` (key-only) | `Some(roaring_bytes)` (value-bearing) |
| MemTable | yes | no (batch/direct write) |
| tx / MVCC / as-of | yes | no |
| flush | snapshot + merge | not needed (no MemTable) |
| journal | yes | optional (bitmap is rebuildable) |
| GC | yes | reused (same dead-blob machinery) |
| page codec | key-only `[num_keys][prefix-compressed keys, varint sizes]` | key-value (keys still prefix-compressed; values are roaring bytes) |

The index (`BTreeMap<key, blob_uuid>`) and GC are identical; only the page codec
differs (carries values). Keys remain sorted, so prefix compression still applies
— consecutive `(partition, attr_id, value, block_id)` keys share prefixes and
compress just like EAVT keys. Roaring bytes compress internally (roaring format)
plus zstd at the blob level.

### Key layout

```
key   = (partition: u20, attr_id: u32, encoded_value, block_id: u32)
value = serialized roaring bitmap for that (attr, value, block)
```

The partition in the key prevents cross-universe collision. Different application
populations = different partitions = independent bit spaces (no "bitmap context"
concept needed — partitions already provide this).

### Why no transaction mechanism in bitmap store

The bitmap is a **derived projection** — the authoritative datom (`estado="SP"`)
lives in KVStore-A (EAVT). Derived indexes are intentionally eventually-consistent
to avoid cross-store coordination overhead:

1. EAVT write: `save_at_t` writes directly to MemTable (eager constraint validation)
2. **Post-commit derivation hook** updates the bitmap (simple puts to KVStore-B)

Because derivation runs **after** the EAVT write, a crash between write and bitmap
update leaves the bitmap stale — but it is rebuildable. This is the standard model
for derived indexes (search-engine indexing of a DB, read replicas, materialized views).

Reversing this (strict consistency) would require two-phase commit across both
stores — heavy overhead for a gain (immediate read-of-just-written-derived-index)
that faceted filtering rarely needs.

### Future: KVStore as a generic store

Making KVStore value-aware + configurable (MemTable optional per instance)
naturally pushes transactional semantics **up to the Transactor**, leaving KVStore
as a pure sorted store. Then KVStore-A and KVStore-B are literally the same binary
with different config, and EAVT semantics live where they belong. Not a prerequisite
for the bitmap store today, but the clean end state.

## 7. Query

The query model has two phases, kept strictly separate:

### Phase 1 — Reduction (native roaring, isolated from triejoin)

The intersect of multiple bitmap dimensions is roaring-native `AND`, computed
**inside** the `BITMAP(...)` expression. The triejoin never sees multi-bitmap
algebra — that was the anti-pattern (forcing set-algebra into leapfrog
convergence).

### Phase 2 — Enrichment (single bitmap scanner joins EAVT via leapfrog)

The reduced bitmap (one roaring set) participates as a **single BitmapScanner**
at the entity depth. It iterates entity IDs in ascending order; the leapfrog
converges it with EAVT projection scanners. This is the legitimate use of a
bitmap in the triejoin: **one** already-reduced bitmap joining with EAVT, not
multi-bitmap algebra.

### SQL syntax

```sql
SELECT d1.company.name, d1.company.revenue
WHERE d1.eid IN BITMAP(estado_federacao="SP", matriz=true, tem_site=true)
```

`BITMAP(attr=val, ...)` is a set-returning expression that:
1. resolves each facet to its roaring bitmap (via the `BITMAP`-typed declarations)
2. evaluates the intersect natively (roaring `AND`) → one reduced bitmap
3. `d1.eid IN <reduced bitmap>` drives the EAVT scan as a BitmapScanner

Facet values can be parameters:

```sql
WHERE d1.eid IN BITMAP(estado_federacao=%1, matriz=%2)
-- params: ("SP", true)
```

It composes with regular EAVT predicates — the bitmap is just another scanner
source at the entity depth:

```sql
SELECT d1.company.name
WHERE d1.eid IN BITMAP(estado_federacao="SP", matriz=true)
  AND d1.company.revenue > %1
```

Here the BitmapScanner (entity depth) and the revenue scanner converge via
leapfrog on the entity variable.

### Result count without enrichment

Counting matching entities needs no EAVT at all — it's a roaring popcount on the
reduced bitmap, instant. This is common in the faceted-filtering workload and a
key reason not to route the reduction through SQL's triejoin.

### Cursor trait fit

The `BitmapScanner` implements the existing `Cursor` contract
(`dynspire-commons/src/transactor/cursor.rs`): `is_valid` / `current_key` /
`step` / `seek` / `skip_group`. It iterates entity IDs (8-byte big-endian, the
reduced set) in ascending order — roaring's native iteration is sorted, so it
slots into the v2 forward-only scanner constraint with no special handling. The
planner treats the `IN BITMAP(...)` clause like any entity-binding clause when
ordering variables.

## 8. Maintenance

- Bitmaps are **derived** → regenerable from EAVT. Loss is recoverable by rebuild.
- **Post-commit derivation hook:** on EAVT commit, set/clear the affected bits
  (one bit per written datom). Runs only after successful commit, so rollbacks
  never dirty the bitmap.
- **Batch rebuild (alternative):** periodically scan EAVT, recompute all roaring
  bitmaps, overwrite. Simpler, accepts a staleness window.
- Update = overwrite in-place (`put(key, new_bytes)`); the old blob becomes a
  dead group for the reused GC.
- On corruption: drop the bitmap CF and regenerate from EAVT.

## 9. Open Questions

- **Partition-in-SQL:** bitmap entities must allocate in a dedicated partition
  (`PART_COMPANY`). How UPSERT indicates the allocation partition is a
  general (non-roaring) SQL design item; this doc depends on it but does not
  define it.
- **Maintenance policy:** synchronous post-commit hook vs batch rebuild. Policy
  choice; both are viable.
- **Cross-partition queries:** if a dimension spans two partitions, keep
  per-partition bitmaps and union at query time (roaring `OR`). Rare; deferred.
- **Extended facet syntax:** `BITMAP(estado="SP" OR estado="RJ")` → union;
  `BITMAP(NOT tem_site=true)` → complement. Roaring supports both; start with
  AND of equality facets, extend later.
- **KVStore refactor:** KVStore as a generic configurable sorted store,
  transactional semantics handled by the Transactor. Clean end state; not a
  prerequisite.
