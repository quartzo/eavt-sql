"""engine.py — EAVT engine with RocksDB storage (via rocksdict).

Port of nim_eavt/eavt.nim. Coordinates Resolver + RocksDB for
entity-attribute-value-time operations.

Write model: writes accumulate in an in-memory pending buffer and are
flushed to RocksDB by an explicit `commit()` (single cross-CF WriteBatch).
There is no rollback and a single pending window: `commit()` flushes
everything accumulated, `close()` commits. Reads merge the pending buffer
with the committed keys (read-your-writes); a concurrent process can never
open the same RocksDB path (exclusive file lock).
"""
from __future__ import annotations

import bisect
import time
from typing import Iterator

import rocksdict as rdb
from sortedcontainers import SortedSet

from . import keys
from .perf_counter import Timer
from .resolver import Resolver, partition_of, seq_of
from .types import (
    BOOTSTRAP_SCHEMA,
    DB_CARDINALITY_AID,
    DB_CARDINALITY_MANY,
    DB_IDENT_AID,
    DB_TX_INSTANT_AID,
    DB_TYPE_STRING,
    DB_UNIQUE_AID,
    DB_UNIQUE_IDENTITY,
    DB_VALUE_TYPE_AID,
    EncodeMode,
    PART_DB,
    PART_TX,
    PART_USER,
    value_type_to_encode_mode,
    value_type_from_name,
)


# ═══════════════════════════════════════════════════════════════════════════════
# Column family names
# ═══════════════════════════════════════════════════════════════════════════════

CF_NAMES = ["eavt", "aevt", "avet", "vaet"]


def _open_db(path: str):
    """Open RocksDB with 4 EAVT column families."""
    opts = rdb.Options()
    opts.create_if_missing(True)
    opts.create_missing_column_families(True)

    # Header / block compression tuning: fewer restart points (less full-key
    # rewriting between keys), larger blocks (better zstd ratio), filter+index
    # kept in block cache instead of rewritten per block.
    bbo = rdb.BlockBasedOptions()
    bbo.set_block_restart_interval(128)
    bbo.set_block_size(64 * 1024)
    bbo.set_cache_index_and_filter_blocks(True)
    opts.set_block_based_table_factory(bbo)

    opts.set_compression_type(rdb.DBCompressionType.zstd())
    opts.set_compression_options(-14, 3, 0, 0)
    opts.set_bottommost_compression_type(rdb.DBCompressionType.zstd())
    opts.set_write_buffer_size(64 * 1024 * 1024)
    opts.set_max_write_buffer_number(2)
    opts.set_arena_block_size(64 * 1024)
    opts.set_bytes_per_sync(1 << 20)
    opts.set_wal_bytes_per_sync(1 << 20)

    cf_opts = {name: opts for name in CF_NAMES}
    db = rdb.Rdict(path, options=opts, column_families=cf_opts)
    # Rdict per CF (for dict-like access + iterators)
    cfs = {name: db.get_column_family(name) for name in CF_NAMES}
    # ColumnFamily handles (for WriteBatch.put)
    cf_handles = {name: db.get_column_family_handle(name) for name in CF_NAMES}
    return db, cfs, cf_handles


# ═══════════════════════════════════════════════════════════════════════════════
# Datom
# ═══════════════════════════════════════════════════════════════════════════════


class Datom:
    __slots__ = ("e", "a", "attr_name", "value", "t", "retracted")

    def __init__(self, e, a, attr_name, value, t, retracted):
        self.e = e
        self.a = a
        self.attr_name = attr_name
        self.value = value
        self.t = t
        self.retracted = retracted

    def __repr__(self):
        op = "-" if self.retracted else "+"
        return f"[{op} {self.e} {self.attr_name} {self.value!r} tx={self.t}]"


# ═══════════════════════════════════════════════════════════════════════════════
# PendingMergeIter
# ═══════════════════════════════════════════════════════════════════════════════


class PendingMergeIter:
    """Merged iterator: RocksDB iterator + pending (uncommitted) keys.

    Presents the same interface as rocksdict's RdictIter (valid/key/next/
    seek/seek_to_first/seek_to_last) so it can be consumed anywhere a raw
    iterator is used (RocksCursor, scan_prefix, scan_datoms). Sorted k-way
    merge of the committed keys and the pending buffer, dedup on equal keys
    (pending shadows committed).
    """

    __slots__ = ("_it", "_pending", "_p_idx", "_cur", "_valid")

    def __init__(self, it, pending):
        self._it = it
        # Materialize the sorted SortedSet once: O(K) at open, O(1) per step.
        self._pending = list(pending)
        self._p_idx = 0
        self._cur: bytes | None = None
        self._valid = False

    def _recompute(self):
        raw = self._it.key() if self._it.valid() else None
        pend = self._pending[self._p_idx] if self._p_idx < len(self._pending) else None
        if raw is None and pend is None:
            self._cur = None
            self._valid = False
            return
        if pend is None or (raw is not None and raw < pend):
            self._cur = raw
        elif raw is None or pend < raw:
            self._cur = pend
        else:
            self._cur = raw
        self._valid = True

    def valid(self) -> bool:
        return self._valid

    def key(self) -> bytes:
        return self._cur

    def next(self):
        cur = self._cur
        raw = self._it.key() if self._it.valid() else None
        pend = self._pending[self._p_idx] if self._p_idx < len(self._pending) else None
        if raw is not None and raw == cur:
            self._it.next()
        if pend is not None and pend == cur:
            self._p_idx += 1
        self._recompute()

    def seek(self, target: bytes):
        self._it.seek(target)
        self._p_idx = bisect.bisect_left(self._pending, target)
        self._recompute()

    def seek_to_first(self):
        self._it.seek_to_first()
        self._p_idx = 0
        self._recompute()

    def seek_to_last(self):
        self._it.seek_to_last()
        if self._pending:
            self._p_idx = len(self._pending) - 1
        else:
            self._p_idx = 0
        raw = self._it.key() if self._it.valid() else None
        pend = self._pending[self._p_idx] if self._p_idx < len(self._pending) else None
        if raw is None and pend is None:
            self._cur = None
            self._valid = False
        elif pend is None or (raw is not None and raw > pend):
            self._cur = raw
            self._valid = True
        elif raw is None or pend > raw:
            self._cur = pend
            self._valid = True
        else:
            self._cur = raw
            self._valid = True


# ═══════════════════════════════════════════════════════════════════════════════
# EavtEngine
# ═══════════════════════════════════════════════════════════════════════════════


_MAX_FRESH = 100


class EavtEngine:
    """EAVT engine backed by RocksDB with 4 column families."""

    def __init__(self, path: str):
        self.path = path
        self.db, self.cf, self.cf_handles = _open_db(path)
        self.resolver = Resolver()
        self._pending: dict[int, SortedSet] = {}
        self._fresh: dict[int, set[int]] = {}       # eid → set of used attr_ids
        self._fresh_order: list[int] = []            # FIFO for eviction

    def close(self):
        """Commit pending entries and release all resources."""
        self.commit()
        for cf in self.cf.values():
            del cf
        for h in self.cf_handles.values():
            del h
        self.cf.clear()
        self.cf_handles.clear()
        self.db.close()
        del self.db

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    # ── Pending (uncommitted) buffer ──

    def _pending_add(self, cf: int, key: bytes) -> None:
        ss = self._pending.get(cf)
        if ss is None:
            ss = SortedSet()
            self._pending[cf] = ss
        ss.add(key)

    def _pending_remove(self, cf: int, key: bytes) -> None:
        ss = self._pending.get(cf)
        if ss is not None:
            ss.discard(key)

    def _pending_keys(self, cf: int) -> SortedSet | None:
        return self._pending.get(cf)

    # ── Commit ──

    def commit(self, sync: bool = False) -> None:
        """Flush all pending entries to RocksDB in a single cross-CF WriteBatch.

        One WriteBatch for all column families (a single group commit instead
        of one WriteBatch per CF). `sync=True` forces an fsync of the WAL.
        The pending buffer is cleared after a successful write.
        """
        batch = rdb.WriteBatch()
        for cf in range(len(CF_NAMES)):
            cf_handle = self.cf_handles[CF_NAMES[cf]]
            ss = self._pending.get(cf)
            if not ss:
                continue
            for k in ss:
                batch.put(k, b"", cf_handle)
        if batch.is_empty():
            return
        opts = rdb.WriteOptions()
        opts.sync = sync
        self.db.write(batch, opts)
        self._pending.clear()

    # ── Batch write helper ──

    def _batch_write(self, entries: list[keys.EavtEntry]):
        if not entries:
            return
        for e in entries:
            self._pending_add(e.cf, e.key)

    # ── Scan prefix ──

    def _merged_active_key(self, cf: int, prefix: bytes, bound: bytes) -> bytes | None:
        """Return the last active (non-retracted) key matching `prefix`.

        Walks the merged committed+pending stream backward from the range's
        last key, skipping trailing retracts. The active value of a not-many
        attribute is the highest non-retracted key, and a save() always ends
        with an assert, so it is found in O(log K) with no backward walk.
        `bound` must be a key greater than every key matching `prefix` (e.g.
        the same eid with attr+1).
        """
        ss = self._pending_keys(cf)
        pid: int | None = None
        if ss:
            j = bisect.bisect_left(ss, bound)
            if j > 0 and ss[j - 1].startswith(prefix):
                pid = j - 1

        it = self.cf[CF_NAMES[cf]].iter()
        it.seek_for_prev(bound)
        ckey: bytes | None = it.key() if it.valid() and it.key().startswith(prefix) else None

        while ckey is not None or pid is not None:
            if ckey is not None and pid is not None and ckey == ss[pid]:
                pick = ckey
                it.prev()
                ckey = it.key() if it.valid() and it.key().startswith(prefix) else None
                pid -= 1
                if pid < 0:
                    pid = None
            elif pid is None or (ckey is not None and ckey > ss[pid]):
                pick = ckey
                it.prev()
                ckey = it.key() if it.valid() and it.key().startswith(prefix) else None
            else:
                pick = ss[pid]
                pid -= 1
                if pid < 0:
                    pid = None
            if len(pick) < 20:
                continue
            if (pick[-1] & 1) == 0:
                return pick
        return None

    def scan_prefix(self, cf: int, prefix: bytes) -> list[bytes]:
        """Scan all keys in CF with given prefix (committed + pending)."""
        cf_db = self.cf[CF_NAMES[cf]]
        it = cf_db.iter()
        it.seek(prefix)
        result = []
        while it.valid():
            key = it.key()
            if not key.startswith(prefix):
                break
            result.append(key)
            it.next()
        pending = self._pending_keys(cf)
        if not pending:
            return result
        return self._merge_sorted_with_pending(result, pending, prefix)

    @staticmethod
    def _merge_sorted_with_pending(
        committed: list[bytes], pending: SortedSet, prefix: bytes
    ) -> list[bytes]:
        """Linear merge of sorted committed + pending keys matching prefix, dedup.

        Keys matching `prefix` are a contiguous range in the sorted pending set
        starting at bisect_left(prefix). The matching slice is collected once
        (O(P·log K), typically P == 1 for not-many scans) then merged in a
        single O(1)-per-key pass over both lists.
        """
        j = bisect.bisect_left(pending, prefix)
        n = len(pending)
        pmatch: list[bytes] = []
        while j < n and pending[j].startswith(prefix):
            pmatch.append(pending[j])
            j += 1
        if not pmatch:
            return committed
        out: list[bytes] = []
        i = 0
        k = 0
        len_c = len(committed)
        len_p = len(pmatch)
        while i < len_c or k < len_p:
            if i >= len_c:
                out.extend(pmatch[k:])
                break
            if k >= len_p:
                out.extend(committed[i:])
                break
            ck = committed[i]
            pk = pmatch[k]
            if ck == pk:
                out.append(ck)
                i += 1
                k += 1
            elif pk < ck:
                out.append(pk)
                k += 1
            else:
                out.append(ck)
                i += 1
        return out

    # ── Bootstrap ──

    def bootstrap(self):
        """Bootstrap system attrs if needed, then load user schema."""
        self._bootstrap_system_attrs()
        self._bootstrap_resolver()
        self._seed_partition_counters()

    def _bootstrap_system_attrs(self):
        """Write EAVT datoms for all built-in schema attributes if not already done."""
        # Check if already bootstrapped by looking for db.ident entity in AEVT
        cf_aevt = self.cf["aevt"]
        probe_prefix = b"\x00\x00\x00\x01"  # DB_IDENT_AID = 1
        it = cf_aevt.iter()
        it.seek(probe_prefix)
        while it.valid():
            key = it.key()
            if not key.startswith(probe_prefix):
                break
            if len(key) >= 12:
                e = keys.decode_eid(keys.be_uint64(key, 4))
                if e == 1:  # DB_IDENT_AID entity itself
                    return  # already bootstrapped
            it.next()

        tx = self.resolver.allocate_in_partition(PART_TX)
        entries: list[keys.EavtEntry] = []

        for name, aid in BOOTSTRAP_SCHEMA:
            e = aid
            # Determine value type for this bootstrap attr
            if name in ("db.ident", "db.part/id"):
                vt = 20  # DB_TYPE_STRING
            elif name == "db.txInstant":
                vt = 25  # DB_TYPE_INSTANT
            elif name in ("db.isComponent", "db.index", "db.fulltext", "db.noHistory"):
                vt = 24  # DB_TYPE_BOOLEAN
            else:
                vt = 21  # DB_TYPE_REF

            card_id = 35  # DB_CARDINALITY_ONE
            unique_id = 0
            if name == "db.unique.value":
                unique_id = 37
            elif name == "db.unique.identity":
                unique_id = 38

            # db.ident
            entries.extend(
                keys.build_eavt_entries(
                    e, DB_IDENT_AID,
                    keys.encode_value(name, EncodeMode.VARIABLE, 0),
                    tx, False, EncodeMode.VARIABLE, True,
                )
            )
            # db.valueType
            entries.extend(
                keys.build_eavt_entries(
                    e, DB_VALUE_TYPE_AID,
                    keys.encode_value("", EncodeMode.REF, vt),
                    tx, False, EncodeMode.REF, True,
                )
            )
            # db.cardinality
            entries.extend(
                keys.build_eavt_entries(
                    e, DB_CARDINALITY_AID,
                    keys.encode_value("", EncodeMode.REF, card_id),
                    tx, False, EncodeMode.REF, True,
                )
            )
            if unique_id:
                entries.extend(
                    keys.build_eavt_entries(
                        e, DB_UNIQUE_AID,
                        keys.encode_value("", EncodeMode.REF, unique_id),
                        tx, False, EncodeMode.REF, True,
                    )
                )

        self._batch_write(entries)

    def _bootstrap_resolver(self):
        """Load user attribute schema from db.* datoms."""
        ident_map: dict[int, str] = {}
        vt_map: dict[int, int] = {}
        card_map: dict[int, bool] = {}
        unique_set: set[int] = set()

        # Scan AEVT for db.ident (aid=1)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x01"):
            if len(k) < 24:
                continue
            if keys.be_uint32(k, 0) != 1:
                continue
            if (k[-1] & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            if e < 100:  # BOOTSTRAP_FIRST_USER_ID
                continue
            name, _ = keys.read_next(k, 12, DB_TYPE_STRING)
            if name:
                ident_map[e] = name

        # Scan AEVT for db.valueType (aid=3)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x03"):
            if len(k) < 28:
                continue
            if keys.be_uint32(k, 0) != 3:
                continue
            if (k[-1] & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            vt_map[e] = keys.decode_int64(keys.be_uint64(k, 12))

        # Scan AEVT for db.cardinality (aid=2)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x02"):
            if len(k) < 28:
                continue
            if keys.be_uint32(k, 0) != 2:
                continue
            if (k[-1] & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            card_map[e] = keys.decode_int64(keys.be_uint64(k, 12)) == 36

        # Scan AEVT for db.unique (aid=5)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x05"):
            if len(k) < 20:
                continue
            if keys.be_uint32(k, 0) != 5:
                continue
            if (k[-1] & 1) == 1:
                continue
            unique_set.add(keys.decode_eid(keys.be_uint64(k, 4)))

        for e, name in ident_map.items():
            vt = vt_map.get(e, 20)
            many = card_map.get(e, False)
            unique = e in unique_set
            self.resolver.load_user_attr(name, e, vt, many, unique, False)

    def _seed_partition_counters(self):
        """Walk EAVT (CF 0) to find the highest eid per partition."""
        targets = self.resolver.known_partitions()
        covered: set[int] = set()
        cf_eavt = self.cf["eavt"]
        it = cf_eavt.iter()
        it.seek_to_first()
        while it.valid():
            key = it.key()
            if len(key) < 8:
                it.next()
                continue
            if (key[-1] & 1) == 1:
                it.next()
                continue
            e = keys.decode_eid(keys.be_uint64(key, 0))
            p = partition_of(e)
            if p in targets:
                self.resolver.advance_past(e)
                covered.add(p)
            if len(covered) >= len(targets):
                break
            it.next()

    # ── Save a datom ──

    def save(self, eid: int, attr_name: str, value, tx: int | None = None) -> int:
        """Save a datom. For not-many attrs, retracts existing active datoms first."""
        with Timer("save.total"):
            if tx is None:
                with Timer("save.allocate_tx"):
                    tx = self.allocate_tx()
            attr_id = self.resolver.intern_attr(attr_name)
            vt = self.resolver.value_type_for(attr_id) or 20
            many = self.resolver.is_many(attr_id)
            mode = value_type_to_encode_mode(vt)
            indexed = self.resolver.is_indexed(attr_id)

            with Timer("save.encode"):
                encodable = self._to_encodable(value, mode)
                if mode == EncodeMode.REF:
                    ref_eid = int(value) if isinstance(value, (int, float)) else int(str(value))
                    encoded = keys.encode_value(encodable, mode, ref_eid)
                else:
                    encoded = keys.encode_value(encodable, mode, 0)

            if not many:
                fresh_attrs = self._fresh.get(eid)
                if fresh_attrs is not None and attr_id not in fresh_attrs:
                    fresh_attrs.add(attr_id)
                else:
                    e_prefix = keys.encode_eid(eid) + keys._attr_bytes(attr_id)
                    bound = keys.encode_eid(eid) + keys._attr_bytes(attr_id + 1)
                    with Timer("save.retract_scan"):
                        active_key = self._merged_active_key(0, e_prefix, bound)
                    if active_key is not None and active_key[12 : len(active_key) - keys._SUFFIX_SIZE] != encoded:
                        ret_entries = keys.build_eavt_entries(
                            eid, attr_id, active_key[12 : len(active_key) - keys._SUFFIX_SIZE], tx, True, mode, indexed
                        )
                        self._batch_write(ret_entries)
                    # Re-asserting a value that has a pending retract at the same tx
                    for re in keys.build_eavt_entries(eid, attr_id, encoded, tx, True, mode, indexed):
                        self._pending_remove(re.cf, re.key)

            with Timer("save.build_entries"):
                entries = keys.build_eavt_entries(eid, attr_id, encoded, tx, False, mode, indexed)
            with Timer("save.batch_write"):
                self._batch_write(entries)
            return eid

    def retract(self, eid: int, attr_name: str, value, tx: int | None = None):
        """Write retraction entries for a datom."""
        if tx is None:
            tx = self.allocate_tx()
        attr_id = self.resolver.intern_attr(attr_name)
        vt = self.resolver.value_type_for(attr_id) or 20
        mode = value_type_to_encode_mode(vt)
        indexed = self.resolver.is_indexed(attr_id)

        encodable = self._to_encodable(value, mode)
        if mode == EncodeMode.REF:
            ref_eid = int(value) if isinstance(value, (int, float)) else int(str(value))
            encoded = keys.encode_value(encodable, mode, ref_eid)
        else:
            encoded = keys.encode_value(encodable, mode, 0)
        entries = keys.build_eavt_entries(eid, attr_id, encoded, tx, True, mode, indexed)
        self._batch_write(entries)

    @staticmethod
    def _to_encodable(value, mode: EncodeMode):
        """Convert a Python value to the type expected by encode_value."""
        if mode in (EncodeMode.BLOCK, EncodeMode.BLOB):
            if isinstance(value, bytes):
                return value
            return str(value).encode("utf-8")
        if isinstance(value, bool):
            return value  # encode_value handles bool directly
        return value

    # ── Tx allocation ──

    def allocate_tx(self) -> int:
        """Allocate a fresh tx entity and write its db.txInstant datom."""
        tx_eid = self.resolver.allocate_in_partition(PART_TX)
        now_us = int(time.time() * 1_000_000)
        encoded = keys.encode_value(str(now_us), EncodeMode.FIXED, 0)
        entries = keys.build_eavt_entries(
            tx_eid, DB_TX_INSTANT_AID, encoded, tx_eid, False, EncodeMode.FIXED, False
        )
        self._batch_write(entries)
        return tx_eid

    # ── Declare attribute ──

    def declare_attr(
        self, name: str, type_name: str, many: bool = False,
        unique: bool = False, indexed: bool = True, tx: int | None = None,
    ) -> tuple[int, bool]:
        """Declare an attribute with its type, persisting as db.* datoms.

        `indexed=True` (default) maintains the AVET/VAET column families so the
        attribute can be range-scanned by the query engine. Set to False for
        attributes that are only ever looked up by entity.
        """
        vt = value_type_from_name(type_name)
        aid, is_new = self.resolver.declare_attr(name, vt, many)
        if unique:
            self.resolver.set_unique(aid, True)
        if indexed:
            self.resolver.set_indexed(aid, True)
        if is_new and tx is None:
            tx = self.resolver.allocate_in_partition(PART_TX)
        if is_new:
            e = aid
            entries: list[keys.EavtEntry] = []
            entries.extend(keys.build_eavt_entries(
                e, DB_IDENT_AID, keys.encode_value(name, EncodeMode.VARIABLE, 0),
                tx, False, EncodeMode.VARIABLE, True,
            ))
            entries.extend(keys.build_eavt_entries(
                e, DB_VALUE_TYPE_AID, keys.encode_value(str(vt), EncodeMode.FIXED, 0),
                tx, False, EncodeMode.FIXED, True,
            ))
            card_id = 36 if many else 35
            entries.extend(keys.build_eavt_entries(
                e, DB_CARDINALITY_AID, keys.encode_value(str(card_id), EncodeMode.FIXED, 0),
                tx, False, EncodeMode.FIXED, True,
            ))
            if unique:
                entries.extend(keys.build_eavt_entries(
                    e, DB_UNIQUE_AID,
                    keys.encode_value(str(DB_UNIQUE_IDENTITY), EncodeMode.FIXED, 0),
                    tx, False, EncodeMode.FIXED, True,
                ))
            self._batch_write(entries)
        return aid, is_new

    # ── Declare partition ──

    def declare_partition(self, name: str) -> int:
        return self.resolver.declare_partition(name)

    # ── Entity allocation ──

    def alloc_entity(self, partition: int = PART_USER) -> int:
        eid = self.resolver.allocate_in_partition(partition)
        self._fresh[eid] = set()
        self._fresh_order.append(eid)
        if len(self._fresh_order) > _MAX_FRESH:
            old = self._fresh_order.pop(0)
            del self._fresh[old]
        return eid

    # ── Lookup ──

    def lookup_attr(self, name: str) -> int | None:
        return self.resolver.lookup_attr(name)

    def attr_name(self, aid: int) -> str:
        return self.resolver.attr_name(aid)

    def value_type_for(self, aid: int) -> int | None:
        return self.resolver.value_type_for(aid)

    def is_many(self, aid: int) -> bool:
        return self.resolver.is_many(aid)

    def is_unique(self, aid: int) -> bool:
        return self.resolver.is_unique(aid)

    def lookup_entity(self, attr_name: str, value) -> int | None:
        """Unique-attr lookup via AVET index."""
        aid_opt = self.lookup_attr(attr_name)
        if aid_opt is None:
            return None
        aid = aid_opt
        vt = self.value_type_for(aid) or 20
        mode = value_type_to_encode_mode(vt)
        encodable = self._to_encodable(value, mode)
        encoded = keys.encode_value(encodable, mode, 0)
        prefix = keys._attr_bytes(aid) + encoded
        scan_res = self.scan_prefix(2, prefix)  # AVET
        if not scan_res:
            return None
        k = scan_res[0]
        if len(k) < 20:
            return None
        if (k[-1] & 1) == 1:
            return None
        return keys.decode_eid(keys.be_uint64(k, len(k) - keys._SUFFIX_SIZE - 8))

    def lookup_value(self, eid: int, attr_name: str):
        """Lookup the current active value for an entity+attribute."""
        aid_opt = self.lookup_attr(attr_name)
        if aid_opt is None:
            return None
        aid = aid_opt
        prefix = keys.encode_eid(eid) + keys._attr_bytes(aid)
        scan_res = self.scan_prefix(0, prefix)  # EAVT
        retracted_group: bytes = b""
        for j in range(len(scan_res) - 1, -1, -1):
            k = scan_res[j]
            if len(k) < 20:
                continue
            group = k[: len(k) - keys._SUFFIX_SIZE]
            if (k[-1] & 1) == 1:
                retracted_group = group
                continue
            if group == retracted_group:
                continue
            vt = self.value_type_for(aid) or 20
            val, _ = keys.read_next(k, 12, vt)
            return val
        return None

    # ── Scan datoms ──

    def scan_datoms(self, cf: int) -> Iterator[Datom]:
        """Decode all datoms from a column family (committed + pending)."""
        it = self.open_iterator(cf)
        it.seek_to_first()
        while it.valid():
            key = it.key()
            if len(key) < 20:
                it.next()
                continue

            suffix_raw = keys.be_uint64(key, len(key) - keys._SUFFIX_SIZE)
            t = keys.decode_int64(suffix_raw)
            retracted = (key[-1] & 1) != 0

            if cf == 0:  # EAVT
                eid = keys.decode_eid(keys.be_uint64(key, 0))
                aid = keys.be_uint32(key, 8)
                v_start, v_end = 12, len(key) - keys._SUFFIX_SIZE
            elif cf == 1:  # AEVT
                aid = keys.be_uint32(key, 0)
                eid = keys.decode_eid(keys.be_uint64(key, 4))
                v_start, v_end = 12, len(key) - keys._SUFFIX_SIZE
            elif cf == 2:  # AVET
                aid = keys.be_uint32(key, 0)
                v_start = 4
                v_end = len(key) - keys._SUFFIX_SIZE - 8
                eid = keys.decode_eid(keys.be_uint64(key, len(key) - keys._SUFFIX_SIZE - 8))
            elif cf == 3:  # VAET: [value][attr 4B][eid 8B][suffix 9B]
                v_start = 0
                v_end = len(key) - keys._SUFFIX_SIZE - 12
                aid = keys.be_uint32(key, v_end)
                eid = keys.decode_eid(keys.be_uint64(key, v_end + 4))
            else:
                it.next()
                continue

            if v_end <= v_start:
                it.next()
                continue

            vt = self.value_type_for(aid) or 20
            val, _ = keys.read_next(key, v_start, vt)
            aname = self.attr_name(aid)

            yield Datom(e=eid, a=aid, attr_name=aname, value=val, t=t, retracted=retracted)
            it.next()

    # ── Open raw iterator (for scanner) ──

    def open_iterator(self, cf: int):
        """Open a merged iterator (RocksDB + pending) for a column family.

        Returns the raw RocksDB iterator when there is nothing pending (zero
        overhead fast path), otherwise a PendingMergeIter.
        """
        raw = self.cf[CF_NAMES[cf]].iter()
        pending = self._pending_keys(cf)
        if not pending:
            return raw
        return PendingMergeIter(raw, pending)
