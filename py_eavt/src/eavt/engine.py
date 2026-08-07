"""engine.py — EAVT engine with RocksDB storage (via rocksdict).

Port of nim_eavt/eavt.nim. Coordinates Resolver + RocksDB for
entity-attribute-value-time operations.
"""
from __future__ import annotations

import time
from typing import Iterator

import rocksdict as rdb

from . import keys
from .resolver import Resolver, partition_of, seq_of
from .types import (
    BOOTSTRAP_SCHEMA,
    DB_CARDINALITY_AID,
    DB_CARDINALITY_MANY,
    DB_IDENT_AID,
    DB_TX_INSTANT_AID,
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
# EavtEngine
# ═══════════════════════════════════════════════════════════════════════════════


class EavtEngine:
    """EAVT engine backed by RocksDB with 4 column families."""

    def __init__(self, path: str):
        self.path = path
        self.db, self.cf, self.cf_handles = _open_db(path)
        self.resolver = Resolver()

    def close(self):
        """Flush and release all resources."""
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

    # ── Batch write helper ──

    def _batch_write(self, entries: list[keys.EavtEntry]):
        if not entries:
            return
        # Group entries by CF for efficient batch writes
        by_cf: dict[int, rdb.WriteBatch] = {}
        for e in entries:
            if e.cf not in by_cf:
                by_cf[e.cf] = rdb.WriteBatch()
            cf_handle = self.cf_handles[CF_NAMES[e.cf]]
            by_cf[e.cf].put(e.key, b"", cf_handle)
        for cf_id, batch in by_cf.items():
            self.db.write(batch)

    # ── Scan prefix ──

    def scan_prefix(self, cf: int, prefix: bytes) -> list[bytes]:
        """Scan all keys in CF with given prefix."""
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
        return result

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
            sf = keys.be_uint64(k, len(k) - 8)
            if (sf & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            if e < 100:  # BOOTSTRAP_FIRST_USER_ID
                continue
            name = keys.decode_variable_str(k, 12)
            if name:
                ident_map[e] = name

        # Scan AEVT for db.valueType (aid=3)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x03"):
            if len(k) < 28:
                continue
            if keys.be_uint32(k, 0) != 3:
                continue
            sf = keys.be_uint64(k, len(k) - 8)
            if (sf & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            vt_map[e] = keys.decode_int64(keys.be_uint64(k, 12))

        # Scan AEVT for db.cardinality (aid=2)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x02"):
            if len(k) < 28:
                continue
            if keys.be_uint32(k, 0) != 2:
                continue
            sf = keys.be_uint64(k, len(k) - 8)
            if (sf & 1) == 1:
                continue
            e = keys.decode_eid(keys.be_uint64(k, 4))
            card_map[e] = keys.decode_int64(keys.be_uint64(k, 12)) == 36

        # Scan AEVT for db.unique (aid=5)
        for k in self.scan_prefix(1, b"\x00\x00\x00\x05"):
            if len(k) < 20:
                continue
            if keys.be_uint32(k, 0) != 5:
                continue
            sf = keys.be_uint64(k, len(k) - 8)
            if (sf & 1) == 1:
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
            sf = keys.be_uint64(key, len(key) - 8)
            if (sf & 1) == 1:
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
        if tx is None:
            tx = self.allocate_tx()
        attr_id = self.resolver.intern_attr(attr_name)
        vt = self.resolver.value_type_for(attr_id) or 20
        many = self.resolver.is_many(attr_id)
        mode = value_type_to_encode_mode(vt)
        indexed = self.resolver.is_indexed(attr_id)

        val_str = self._value_to_str(value)
        if mode == EncodeMode.REF:
            ref_eid = int(value) if isinstance(value, (int, float)) else int(val_str)
            encoded = keys.encode_value(val_str, mode, ref_eid)
        else:
            encoded = keys.encode_value(val_str, mode, 0)

        if not many:
            e_prefix = keys.encode_eid(eid) + keys._attr_bytes(attr_id)
            for ek in self.scan_prefix(0, e_prefix):
                if len(ek) < 20:
                    continue
                esf = keys.be_uint64(ek, len(ek) - 8)
                if (esf & 1) != 0:
                    continue
                ret_entries = keys.build_eavt_entries(
                    eid, attr_id, ek[12 : len(ek) - 8], tx, True, mode, indexed
                )
                self._batch_write(ret_entries)

        entries = keys.build_eavt_entries(eid, attr_id, encoded, tx, False, mode, indexed)
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

        val_str = self._value_to_str(value)
        if mode == EncodeMode.REF:
            ref_eid = int(value) if isinstance(value, (int, float)) else int(val_str)
            encoded = keys.encode_value(val_str, mode, ref_eid)
        else:
            encoded = keys.encode_value(val_str, mode, 0)
        entries = keys.build_eavt_entries(eid, attr_id, encoded, tx, True, mode, indexed)
        self._batch_write(entries)

    @staticmethod
    def _value_to_str(value) -> str:
        if isinstance(value, bool):
            return "1" if value else "0"
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return str(value)

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
        return self.resolver.allocate_in_partition(partition)

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
        val_str = self._value_to_str(value)
        encoded = keys.encode_value(val_str, mode, 0)
        prefix = keys._attr_bytes(aid) + encoded
        scan_res = self.scan_prefix(2, prefix)  # AVET
        if not scan_res:
            return None
        k = scan_res[0]
        if len(k) < 20:
            return None
        sf = keys.be_uint64(k, len(k) - 8)
        if (sf & 1) == 1:
            return None
        return keys.decode_eid(keys.be_uint64(k, len(k) - 16))

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
            sf = keys.be_uint64(k, len(k) - 8)
            group = k[: len(k) - 8]
            if (sf & 1) == 1:
                retracted_group = group
                continue
            if group == retracted_group:
                continue
            vt = self.value_type_for(aid) or 20
            return keys.decode_stored_value(k[12 : len(k) - 8], vt)
        return None

    # ── Scan datoms ──

    def scan_datoms(self, cf: int) -> Iterator[Datom]:
        """Decode all datoms from a column family."""
        cf_db = self.cf[CF_NAMES[cf]]
        it = cf_db.iter()
        it.seek_to_first()
        while it.valid():
            key = it.key()
            if len(key) < 20:
                it.next()
                continue

            suffix_raw = keys.be_uint64(key, len(key) - 8)
            t, retracted = keys.decode_suffix(suffix_raw)

            if cf == 0:  # EAVT
                eid = keys.decode_eid(keys.be_uint64(key, 0))
                aid = keys.be_uint32(key, 8)
                v_start, v_end = 12, len(key) - 8
            elif cf == 1:  # AEVT
                aid = keys.be_uint32(key, 0)
                eid = keys.decode_eid(keys.be_uint64(key, 4))
                v_start, v_end = 12, len(key) - 8
            elif cf == 2:  # AVET
                aid = keys.be_uint32(key, 0)
                v_start = 4
                v_end = len(key) - 16
                eid = keys.decode_eid(keys.be_uint64(key, len(key) - 16))
            elif cf == 3:  # VAET: [value][attr 4B][eid 8B][suffix 8B]
                v_start = 0
                # Value length varies by type; attr starts after value.
                # For ref: 8 bytes; for variable: need to find end.
                # We know suffix is last 8 bytes, eid is 8 bytes before suffix,
                # attr is 4 bytes before eid. So attr starts at len(key)-20.
                # But value length varies, so we need to find v_end.
                # The attr is always at len(key)-20 relative to end of value.
                # Actually: suffix=8, eid=8, attr=4 → total tail = 20
                # So v_end = len(key) - 20 is correct.
                v_end = len(key) - 20
                aid = keys.be_uint32(key, v_end)
                eid = keys.decode_eid(keys.be_uint64(key, v_end + 4))
            else:
                it.next()
                continue

            if v_end <= v_start:
                it.next()
                continue

            raw_value = key[v_start:v_end]
            vt = self.value_type_for(aid) or 20
            val = keys.decode_stored_value(raw_value, vt)
            aname = self.attr_name(aid)

            yield Datom(e=eid, a=aid, attr_name=aname, value=val, t=t, retracted=retracted)
            it.next()

    # ── Open raw iterator (for scanner) ──

    def open_iterator(self, cf: int):
        """Open a raw RocksDB iterator for a column family."""
        return self.cf[CF_NAMES[cf]].iter()
