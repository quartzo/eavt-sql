"""resolver.py — Schema cache, ID allocation.

Port of nim_eavt/resolver.nim. Manages attribute registry, partition counters,
and schema metadata.
"""
from __future__ import annotations

from .types import (
    BOOTSTRAP_SCHEMA,
    BOOTSTRAP_FIRST_USER_ID,
    DB_CARDINALITY_AID,
    DB_CARDINALITY_MANY,
    DB_CARDINALITY_ONE,
    DB_IDENT_AID,
    DB_INDEX_AID,
    DB_IS_COMPONENT_AID,
    DB_NO_HISTORY_AID,
    DB_TX_INSTANT_AID,
    DB_TYPE_BOOLEAN,
    DB_TYPE_INSTANT,
    DB_TYPE_LONG,
    DB_TYPE_REF,
    DB_TYPE_STRING,
    DB_UNIQUE_AID,
    DB_UNIQUE_IDENTITY,
    DB_UNIQUE_VALUE,
    DB_VALUE_TYPE_AID,
    DB_PART_ID_AID,
    FIRST_CUSTOM_PARTITION,
    PARTITION_SHIFT,
    PART_DB,
    PART_TX,
    PART_USER,
    SEQ_MASK,
)


# ═══════════════════════════════════════════════════════════════════════════════
# Entity ID helpers
# ═══════════════════════════════════════════════════════════════════════════════


def partition_of(eid: int) -> int:
    return (eid & 0xFFFFFFFFFFFFFFFF) >> PARTITION_SHIFT


def seq_of(eid: int) -> int:
    return eid & SEQ_MASK


def make_entity_id(partition_id: int, seq: int) -> int:
    return ((partition_id & 0xFFFFFFFFFF) << PARTITION_SHIFT) | (seq & SEQ_MASK)


# ═══════════════════════════════════════════════════════════════════════════════
# Attribute name normalization
# ═══════════════════════════════════════════════════════════════════════════════


def normalize_attr(name: str) -> str:
    if name.startswith(":") and "/" in name:
        return name[1:].replace("/", ".")
    if "." not in name:
        raise ValueError(f"attribute name must include namespace (e.g. 'company.name'), got {name}")
    return name


# ═══════════════════════════════════════════════════════════════════════════════
# Resolver
# ═══════════════════════════════════════════════════════════════════════════════


class PartitionCounter:
    __slots__ = ("next_seq",)

    def __init__(self, next_seq: int = 1):
        self.next_seq = next_seq


class Resolver:
    __slots__ = (
        "attrs",
        "attrs_rev",
        "next_aid",
        "partitions",
        "partition_names",
        "next_custom_partition",
        "cardinality",
        "declared",
        "value_types",
        "unique_attrs",
        "indexed_attrs",
        "attr_decl_order",
        "part_decl_order",
    )

    def __init__(self):
        self.attrs: dict[str, int] = {}
        self.attrs_rev: dict[int, str] = {}
        self.next_aid: int = 1
        self.partitions: dict[int, PartitionCounter] = {}
        self.partition_names: dict[str, int] = {}
        self.next_custom_partition: int = FIRST_CUSTOM_PARTITION
        self.cardinality: dict[int, bool] = {}  # aid → is_many
        self.declared: set[int] = set()
        self.value_types: dict[int, int] = {}
        self.unique_attrs: set[int] = set()
        self.indexed_attrs: set[int] = set()
        self.attr_decl_order: list[str] = []
        self.part_decl_order: list[str] = []

        # Bootstrap schema
        for name, aid in BOOTSTRAP_SCHEMA:
            self.attrs[name] = aid
            self.attrs_rev[aid] = name
            self.declared.add(aid)
            if aid >= self.next_aid:
                self.next_aid = aid + 1

        # Default value types for bootstrap attrs
        self.value_types[DB_VALUE_TYPE_AID] = DB_TYPE_REF
        self.value_types[DB_CARDINALITY_AID] = DB_TYPE_REF
        self.value_types[DB_UNIQUE_AID] = DB_TYPE_REF
        self.value_types[DB_IDENT_AID] = DB_TYPE_STRING
        self.value_types[DB_PART_ID_AID] = DB_TYPE_LONG
        self.value_types[DB_TX_INSTANT_AID] = DB_TYPE_INSTANT
        self.indexed_attrs.add(DB_IDENT_AID)

        for name, aid in BOOTSTRAP_SCHEMA:
            if aid not in self.value_types:
                if name in ("db.ident", "db.part/id"):
                    vt = DB_TYPE_STRING
                elif name == "db.txInstant":
                    vt = DB_TYPE_INSTANT
                elif name in ("db.isComponent", "db.index", "db.fulltext", "db.noHistory"):
                    vt = DB_TYPE_BOOLEAN
                elif name.startswith("db.type."):
                    vt = DB_TYPE_LONG
                else:
                    vt = DB_TYPE_REF
                self.value_types[aid] = vt

        # Partitions
        self.partitions[PART_DB] = PartitionCounter(BOOTSTRAP_FIRST_USER_ID)
        self.partition_names["db.part/db"] = PART_DB
        self.partitions[PART_TX] = PartitionCounter(1)
        self.partition_names["db.part/tx"] = PART_TX
        self.partitions[PART_USER] = PartitionCounter(1)
        self.partition_names["db.part/user"] = PART_USER

    # ── Partition management ──

    def allocate_in_partition(self, partition_id: int) -> int:
        if partition_id not in self.partitions:
            raise ValueError(f"unknown partition: {partition_id}")
        seq_val = self.partitions[partition_id].next_seq
        self.partitions[partition_id].next_seq = seq_val + 1
        return make_entity_id(partition_id, seq_val)

    def allocate_entity_id(self) -> int:
        return self.allocate_in_partition(PART_USER)

    def allocate_schema_id(self) -> int:
        return self.allocate_in_partition(PART_DB)

    def partition_id_for(self, name: str) -> int | None:
        return self.partition_names.get(name)

    def declare_partition(self, name: str) -> int:
        if name in self.partition_names:
            return self.partition_names[name]
        p = self.next_custom_partition
        self.next_custom_partition += 1
        self.partitions[p] = PartitionCounter(1)
        self.partition_names[name] = p
        self.part_decl_order.append(name)
        return p

    def register_partition(self, name: str, partition_id: int):
        if name in self.partition_names:
            return
        if partition_id not in self.partitions:
            self.partitions[partition_id] = PartitionCounter(1)
        self.partition_names[name] = partition_id
        if partition_id >= FIRST_CUSTOM_PARTITION and partition_id >= self.next_custom_partition:
            self.next_custom_partition = partition_id + 1

    def default_user_partition(self) -> int:
        return PART_USER

    def known_partitions(self) -> list[int]:
        return list(self.partitions.keys())

    # ── Attribute resolution ──

    def lookup_attr(self, name: str) -> int | None:
        try:
            n = normalize_attr(name)
            return self.attrs.get(n)
        except ValueError:
            return None

    def is_declared(self, aid: int) -> bool:
        return aid in self.declared

    def intern_attr(self, name: str) -> int:
        n = normalize_attr(name)
        if n in self.attrs:
            return self.attrs[n]
        eid = self.allocate_in_partition(PART_DB)
        aid = eid & 0xFFFFFFFF
        self.next_aid = aid + 1
        self.attrs[n] = aid
        self.attrs_rev[aid] = n
        return aid

    def declare_attr(self, name: str, value_type: int, many: bool) -> tuple[int, bool]:
        n = normalize_attr(name)
        if n in self.attrs and self.attrs[n] in self.declared:
            return self.attrs[n], False
        seq_val = self.allocate_in_partition(PART_DB)
        aid = seq_val & 0xFFFFFFFF
        self.next_aid = aid + 1
        self.attrs[n] = aid
        self.attrs_rev[aid] = n
        self.declared.add(aid)
        self.value_types[aid] = value_type
        if many:
            self.cardinality[aid] = True
        self.attr_decl_order.append(n)
        return aid, True

    def value_type_for(self, aid: int) -> int | None:
        return self.value_types.get(aid)

    def attr_name(self, aid: int) -> str:
        return self.attrs_rev.get(aid, str(aid))

    def attr_name_opt(self, aid: int) -> str | None:
        return self.attrs_rev.get(aid)

    # ── Cardinality / uniqueness / indexing ──

    def is_many(self, aid: int) -> bool:
        return aid in self.cardinality

    def set_cardinality(self, aid: int, many: bool):
        if many:
            self.cardinality[aid] = True
        else:
            self.cardinality.pop(aid, None)

    def is_unique(self, aid: int) -> bool:
        return aid in self.unique_attrs

    def set_unique(self, aid: int, unique: bool):
        if unique:
            self.unique_attrs.add(aid)
        else:
            self.unique_attrs.discard(aid)

    def is_indexed(self, aid: int) -> bool:
        return aid in self.unique_attrs or aid in self.indexed_attrs

    def set_indexed(self, aid: int, indexed: bool):
        if indexed:
            self.indexed_attrs.add(aid)
        else:
            self.indexed_attrs.discard(aid)

    # ── Sequence management ──

    def advance_past(self, eid: int):
        p = partition_of(eid)
        s = seq_of(eid)
        if p in self.partitions:
            if s >= self.partitions[p].next_seq:
                self.partitions[p].next_seq = s + 1

    def set_partition_seq(self, partition_id: int, seq: int):
        if partition_id in self.partitions:
            if seq > self.partitions[partition_id].next_seq:
                self.partitions[partition_id].next_seq = seq

    def next_ent_id(self) -> int:
        if PART_DB in self.partitions:
            return self.partitions[PART_DB].next_seq
        return BOOTSTRAP_FIRST_USER_ID

    # ── Batch loading ──

    def load_user_attr(
        self, name: str, eid: int, value_type: int, many: bool, unique: bool, indexed: bool
    ):
        aid = eid & 0xFFFFFFFF
        is_new = aid not in self.declared
        self.attrs[name] = aid
        self.attrs_rev[aid] = name
        self.declared.add(aid)
        self.value_types[aid] = value_type
        if many:
            self.cardinality[aid] = True
        if unique:
            self.unique_attrs.add(aid)
        if indexed:
            self.indexed_attrs.add(aid)
        if is_new:
            # Insert sorted by aid
            ins_pos = len(self.attr_decl_order)
            for i, n in enumerate(self.attr_decl_order):
                if self.attrs.get(n, 0) > aid:
                    ins_pos = i
                    break
            self.attr_decl_order.insert(ins_pos, name)
        p = partition_of(eid)
        if p in self.partitions:
            if seq_of(eid) >= self.partitions[p].next_seq:
                self.partitions[p].next_seq = seq_of(eid) + 1
        if aid >= self.next_aid:
            self.next_aid = aid + 1
