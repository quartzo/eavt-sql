# py_eavt

**Python EAVT engine** — an immutable, time-traveling fact database backed by RocksDB.

Every piece of data is an immutable **datom** — a tuple `(entity, attribute, value, transaction)`. Nothing is ever overwritten: updates retract the old value, history is preserved forever.

## Quick Start

```python
from eavt import EavtEngine, QuerySession, prepare

eng = EavtEngine("/tmp/mydb")
eng.bootstrap()

sess = QuerySession(eng)

# Schema
sess.declare_attr("person.name", "string")
sess.declare_attr("person.age", "long")

# Data
eid = sess.alloc_entity()
sess.save(eid, "person.name", "Alice")
sess.save(eid, "person.age", 30)
sess.commit()

# Query
q = prepare(
    session=sess,
    find=["?eid", "?name"],
    where=[("?eid", "person.name", "?name")],
)
for eid, name in q.execute():
    print(eid, name)

eng.close()
```

## EavtEngine

The engine manages storage (RocksDB) and schema (resolver).

```python
eng = EavtEngine("/path/to/db")  # open or create
eng.bootstrap()                   # write system attrs if first run

# Context manager
with EavtEngine("/path/to/db") as eng:
    eng.bootstrap()
    ...
```

**Methods:**

| Method | Description |
|--------|-------------|
| `bootstrap()` | Write system attrs (db.ident, db.valueType, etc.) if not already done |
| `commit(sync=False)` | Flush pending writes to RocksDB |
| `close()` | Commit + release resources |
| `alloc_entity(partition=4)` | Allocate a new entity ID |
| `declare_attr(name, type_name, many, unique, indexed)` | Declare an attribute |
| `save(eid, attr_name, value, tx=None)` | Write a datom |
| `retract(eid, attr_name, value, tx=None)` | Retract a datom |
| `allocate_tx()` | Allocate a transaction entity |
| `lookup_attr(name) -> int` | Attribute name → EID |
| `attr_name(aid) -> str` | Attribute EID → name |
| `value_type_for(aid) -> int` | Attribute EID → type constant |
| `is_many(aid) -> bool` | Is this a many-cardinality attr? |
| `is_unique(aid) -> bool` | Is this a unique attr? |
| `lookup_entity(attr, value) -> int` | Unique attr lookup → entity EID |
| `lookup_value(eid, attr) -> Any` | Entity + attr → current value |
| `scan_datoms(cf) -> Iterator[Datom]` | Scan all datoms in a column family |
| `declare_partition(name) -> int` | Create a named partition |

## Attributes

```python
eng.declare_attr("person.name", "string")        # STRING (default indexed)
eng.declare_attr("person.age", "long")            # LONG
eng.declare_attr("company.partner", "ref")        # REF (entity reference)
eng.declare_attr("tag.x", "ref", many=True)       # REF, many-cardinality
eng.declare_attr("item.price", "long", indexed=False)  # not indexed (no AVET)
```

**Type names:** `"string"`, `"long"`, `"ref"`, `"keyword"`, `"boolean"`, `"instant"`, `"float"`, `"bytes"`, `"blob"`

**Options:**

| Param | Default | Description |
|-------|---------|-------------|
| `many` | `False` | Many-cardinality (multiple values per entity) |
| `unique` | `False` | Unique value (enables lookup_entity) |
| `indexed` | `True` | AVET index (enables value-range queries) |

## Entities

```python
eid = eng.alloc_entity()                    # user partition
eid = eng.alloc_entity(partition=4)         # explicit partition
```

Entity IDs encode partition + sequence: `(partition << 44) | sequence`.

## Data

### Save

```python
eng.save(eid, "person.name", "Alice")
eng.save(eid, "person.age", 30)
eng.save(eid, "company.partner", other_eid)  # REF type
eng.commit()
```

For not-many attributes, `save` automatically retracts the previous value. For many attributes, each `save` adds a new value.

### Retract

```python
eng.retract(eid, "person.name", "Alice")
eng.commit()
```

### Transactions

```python
tx = eng.allocate_tx()
eng.save(eid, "person.name", "Bob", tx=tx)
eng.commit()
```

Without explicit `tx`, each `save` allocates its own transaction.

## Reads

### Lookup

```python
# Unique attr → entity
eid = eng.lookup_entity("user.email", "alice@example.com")

# Entity + attr → current value
name = eng.lookup_value(eid, "person.name")
```

### Scan datoms

```python
# Scan all datoms in EAVT (cf=0)
for datom in eng.scan_datoms(0):
    print(datom.e, datom.attr_name, datom.value, datom.t, datom.retracted)

# Datom fields: e, a, attr_name, value, t, retracted
```

### Raw key scan

```python
# Scan raw keys in a column family
aid = eng.lookup_attr("person.name")
prefix = aid.to_bytes(4, "big")
for key in eng.scan_prefix(1, prefix):  # AEVT
    ...
```

**Column families:** 0=EAVT, 1=AEVT, 2=AVET, 3=VAET

## QuerySession

Wraps the engine with a transaction and scanner infrastructure.

```python
sess = QuerySession(eng)             # auto-allocates tx
sess = QuerySession(eng, tx=tx)      # explicit tx
sess = QuerySession(eng, as_of_tx=tx)  # read snapshot at tx
```

**Data methods (delegate to engine with session tx):**

```python
sess.save(eid, "person.name", "Alice")
sess.retract(eid, "person.name", "Alice")
sess.commit(sync=False)
sess.alloc_entity()
sess.declare_attr("person.name", "string")
```

**Lookup methods:**

```python
sess.lookup_entity("user.email", "alice@example.com")
sess.lookup_value(eid, "person.name")
sess.intern_a("person.name")  # → aid
sess.attr_name(100)           # → "person.name"
```

## Query API (Datalog)

Prepared queries: plan once, execute many times.

```python
from eavt import prepare

q = prepare(
    session=sess,
    find=["?eid", "?name"],           # output variables, binding order
    where=[
        ("?eid", "person.name", "?name"),  # clause: (e, a, v)
        ("?eid", "person.age", "?age"),
    ],
    ranges={"?age": (">=", 18)},      # range filter
)

# Execute
for eid, name, age in q.execute():
    print(eid, name, age)

# Explain plan
print(q.explain())
```

### Clause format

Tuples of 3-5 elements: `(e, a, v[, t[, added]])`.

| Position | Types |
|----------|-------|
| `e` | `int`, `"?var"`, `"_"` |
| `a` | `"attr.name"` (resolved to EID), `int`, `"?var"`, `"_"` |
| `v` | `int`, `float`, `str`, `bytes`, `bool`, `"?var"`, `"_"` |
| `t` | `int`, `"?var"`, `"_"` |
| `added` | `bool`, `"?var"`, `"_"` |

### Rules

- All variables in `where` must appear in `find`
- Variables in `find` define binding order (the planner validates feasibility)
- Attribute strings are resolved to EIDs at prepare time
- Wildcards `"_"` can't appear before a variable in the index order

### Indexes

Each clause picks the best index:

| Index | Order | Best for |
|-------|-------|----------|
| EAVT | `[e, a, v, t, added]` | Entity lookup |
| AEVT | `[a, e, v, t, added]` | Attribute scan |
| AVET | `[a, v, e, t, added]` | Value lookup (indexed attrs) |
| VAET | `[v, a, e, t, added]` | Reverse lookup (REF attrs) |

### Trailing constants

Constants at positions after the variable in the index create validation depths:

```python
# Validates that item.price = 20 for each entity
q = prepare(sess, ["?eid"], [("?eid", "item.price", 20)])
```

### Repeated variables

Same variable appearing multiple times in a clause:

```python
# Self-referential: company.partner points to self
q = prepare(sess, ["?eid"], [("?eid", "company.partner", "?eid")])
```

## Write Model

Writes accumulate in an in-memory pending buffer (sorted sets per column family). `commit()` flushes everything to RocksDB in a single cross-CF WriteBatch. Reads merge the pending buffer with committed keys (read-your-writes).

```python
eng.save(eid, "attr", "val")  # goes to pending buffer
eng.commit()                   # flush to RocksDB
```

## Architecture

```
RocksDB (4 column families: EAVT, AEVT, AVET, VAET)
  ↑
KVStore (pending buffer + committed keys)
  ↑
EavtEngine (save/retract + schema + resolver)
  ↑
QuerySession (transaction + scanner infrastructure)
  ↑
prepare() → QueryPlan (leapfrog triejoin)
  ↑
execute() → yield result tuples
```
