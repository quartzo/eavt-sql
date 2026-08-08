from __future__ import annotations

from enum import IntEnum

# ═══════════════════════════════════════════════════════════════════════════════
# Encode modes
# ═══════════════════════════════════════════════════════════════════════════════


class EncodeMode(IntEnum):
    REF = 0
    VARIABLE = 1    # null-terminated (STRING, KEYWORD)
    BLOCK = 2       # 8+1 block encoding (BYTES)
    BLOB = 3        # 4B length + raw
    FIXED = 4       # 8-byte fixed (LONG, FLOAT, BOOLEAN, INSTANT)


# ═══════════════════════════════════════════════════════════════════════════════
# db.type constants
# ═══════════════════════════════════════════════════════════════════════════════

DB_TYPE_STRING = 20
DB_TYPE_REF = 21
DB_TYPE_LONG = 22
DB_TYPE_KEYWORD = 23
DB_TYPE_BOOLEAN = 24
DB_TYPE_INSTANT = 25
DB_TYPE_BYTES = 26
DB_TYPE_FLOAT = 27
DB_TYPE_BLOB = 28

# ═══════════════════════════════════════════════════════════════════════════════
# db.cardinality / db.unique constants
# ═══════════════════════════════════════════════════════════════════════════════

DB_CARDINALITY_ONE = 35
DB_CARDINALITY_MANY = 36
DB_UNIQUE_VALUE = 37
DB_UNIQUE_IDENTITY = 38

# ═══════════════════════════════════════════════════════════════════════════════
# Bootstrap schema attribute IDs
# ═══════════════════════════════════════════════════════════════════════════════

DB_IDENT_AID = 1
DB_CARDINALITY_AID = 2
DB_VALUE_TYPE_AID = 3
DB_IS_COMPONENT_AID = 4
DB_UNIQUE_AID = 5
DB_INDEX_AID = 6
DB_FULLTEXT_AID = 7
DB_NO_HISTORY_AID = 8
DB_TX_INSTANT_AID = 9
DB_PART_ID_AID = 39

# ═══════════════════════════════════════════════════════════════════════════════
# Partitions
# ═══════════════════════════════════════════════════════════════════════════════

PART_DB = 0
PART_TX = 3
PART_USER = 4

FIRST_CUSTOM_PARTITION = 64
PARTITION_SHIFT = 44
SEQ_MASK = 0xFFFFFFFFFFF

BOOTSTRAP_FIRST_USER_ID = 100

# ═══════════════════════════════════════════════════════════════════════════════
# Bootstrap schema: (name, aid)
# ═══════════════════════════════════════════════════════════════════════════════

BOOTSTRAP_SCHEMA: list[tuple[str, int]] = [
    ("db.ident", 1),
    ("db.cardinality", 2),
    ("db.valueType", 3),
    ("db.isComponent", 4),
    ("db.unique", 5),
    ("db.index", 6),
    ("db.fulltext", 7),
    ("db.noHistory", 8),
    ("db.txInstant", 9),
    ("db.type.string", 20),
    ("db.type.ref", 21),
    ("db.type.long", 22),
    ("db.type.keyword", 23),
    ("db.type.boolean", 24),
    ("db.type.instant", 25),
    ("db.type.bytes", 26),
    ("db.type.float", 27),
    ("db.type.blob", 28),
    ("db.cardinality.one", 35),
    ("db.cardinality.many", 36),
    ("db.unique.value", 37),
    ("db.unique.identity", 38),
    ("db.part/id", 39),
    ("db.part/db", 40),
    ("db.part/tx", 41),
    ("db.part/user", 42),
]


# ═══════════════════════════════════════════════════════════════════════════════
# Value type helpers
# ═══════════════════════════════════════════════════════════════════════════════


def value_type_to_encode_mode(vt: int) -> EncodeMode:
    if vt == DB_TYPE_REF:
        return EncodeMode.REF
    if vt in (DB_TYPE_STRING, DB_TYPE_KEYWORD):
        return EncodeMode.VARIABLE
    if vt == DB_TYPE_BYTES:
        return EncodeMode.BLOCK
    if vt == DB_TYPE_BLOB:
        return EncodeMode.BLOB
    return EncodeMode.FIXED


def value_type_from_name(name: str) -> int:
    n = name.removeprefix(":db.type/").lower()
    return {
        "ref": DB_TYPE_REF,
        "string": DB_TYPE_STRING,
        "keyword": DB_TYPE_KEYWORD,
        "boolean": DB_TYPE_BOOLEAN,
        "long": DB_TYPE_LONG,
        "instant": DB_TYPE_INSTANT,
        "float": DB_TYPE_FLOAT,
        "bytes": DB_TYPE_BYTES,
        "blob": DB_TYPE_BLOB,
    }.get(n, DB_TYPE_STRING)


# ═══════════════════════════════════════════════════════════════════════════════
# Index helpers
# ═══════════════════════════════════════════════════════════════════════════════


def cf_name_to_id(name: str) -> int:
    return {"eavt": 0, "aevt": 1, "avet": 2, "vaet": 3}.get(name.lower(), 0)


def cf_for_index(index: str) -> str:
    return index.lower() if index.lower() in ("eavt", "aevt", "avet", "vaet") else "eavt"


def index_order(index: str) -> list[str]:
    return {
        "eavt": ["e", "a", "v"],
        "aevt": ["a", "e", "v"],
        "avet": ["a", "v", "e"],
        "vaet": ["v", "a", "e"],
    }.get(index.lower(), ["e", "a", "v"])


# ═══════════════════════════════════════════════════════════════════════════════
# Range types
# ═══════════════════════════════════════════════════════════════════════════════

RANGE_OP_EQ = 0
RANGE_OP_NEQ = 1
RANGE_OP_GT = 2
RANGE_OP_GTE = 3
RANGE_OP_LT = 4
RANGE_OP_LTE = 5
RANGE_OP_IN = 6

RANGE_LO_OPEN = 1
RANGE_HI_OPEN = 2


class RangeSpec:
    __slots__ = ("lo", "hi", "flags")

    def __init__(self, lo=None, hi=None, flags: int = 0):
        self.lo = lo
        self.hi = hi
        self.flags = flags
