# EAVT SQL Reference

The EAVT SQL query language allows querying data stored in Entity-Attribute-Value-Timestamp format using a familiar syntax, without the need for `?`-prefixed variables.

## Concepts

### Datom

Each record in EAVT is a **datom**: a tuple `(entity, attribute, value, transaction)`.

### Aliases

In SQL queries, each `dN` (d1, d2, d3...) represents a **virtual datom**. Conditions grouped under the same alias refer to the same datom pattern.

**Bare alias = entity ID.** `d2` alone means the entity ID of d2, equivalent to `d2.eid`:

```sql
WHERE d1.company.hq = d2 AND d2.city.name = 'London'
```

### Fundamental rule

**With dot = reference to concrete data. Without dot = entity ID (free variable).**

### Attributes

Every attribute has a **namespace** and is referenced with dot notation: `namespace.attr`.

```python
r_ca = list(engine.sql("UPSERT AS D1 SET company.name = 'ACME Corp'"))
company_a = r_ca[0][0]
r_pb = list(engine.sql("UPSERT AS D1 SET person.name = 'John'"))
partner_b = r_pb[0][0]
list(engine.sql("UPSERT AS D1 = eid('company.name', 'ACME Corp') SET company.partner = %1", partner_b))
```

Attributes are referenced via 3 parts: `d1.namespace.attr`:

```python
engine.sql("SELECT d1.company.name WHERE d1.eid = %1", 1000)
```

## General syntax

```
SELECT [HISTORY] <projection> WHERE <conditions>
```

## Projection (SELECT)

| Expression | Type | Return |
|------------|------|--------|
| `dN.ns.attr` | attribute value | Value of attribute `ns.attr` in datom N |
| `dN.eid` | entity ID | Entity integer ID (uint64) |
| `dN.tx` | transaction entity ID | Tx entity ID `(3 << 44) \| t` — can join with `dM.eid` for transaction metadata |
| `dN.attr` | attribute (wildcard) | Attribute name (for any attribute) |
| `dN.val` | value (wildcard) | Any value |
| `N` | integer literal | Literal value (useful for `SELECT 1`) |
| `'text'` | string literal | String literal value |

Multiple projections separated by comma:

```python
engine.sql("SELECT d1.eid, d1.company.partner, d1.tx WHERE d1.eid = %1", 1000)
```

### Attribute reference in queries

| Syntax | Meaning | Example |
|--------|---------|---------|
| `d1` | entity ID (bare alias) | `d1.company.hq = d2` |
| `d1.ns.attr` | namespaced attribute | `d1.company.name`, `d1.person.name` |
| `d1.eid` | entity ID (explicit) | same as bare `d1` |
| `d1.tx` | tx entity ID | joinable with `dM` for transaction metadata |
| `d1.attr` | wildcard: any attribute | always 2 parts |
| `d1.val` | wildcard: any value | always 2 parts |

**Rule:** bare alias = entity ID. 2 parts = reserved field or wildcard. 3 parts = namespaced attribute.

### Wildcard: `attr` and `val`

`dN.attr` and `dN.val` are reserved fields that allow querying any attribute or value:

```python
engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", 1001)
```

### Existence test: `SELECT 1`

```python
result = list(engine.sql(
    "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
    "company-a", "partner-b"
))
# [(1,)] if the datom exists, [] if not
```

### Temporal query: `SELECT HISTORY`

Returns all versions of matching datoms — both current and retracted — for
temporal auditing. Normal `SELECT` shows only the current (non-retracted)
value; `SELECT HISTORY` shows the full revision history.

```python
list(engine.sql("SELECT HISTORY d1.ns.name WHERE d1.eid = %1", 1000))
# [("Alice",), ("Bob",)]  — Alice was retracted, Bob is current
```

History mode is per-scanner: each scanner opened with `SCANNER_OPEN p3=1`
iterates all versions (including retracted). This enables composed queries
where different scanners use different modes.

## Conditions (WHERE)

Conditions are connected by `AND`. Each condition is a comparison.

### Operators

| Operator | Meaning |
|----------|---------|
| `=` | Equality (filter or join) |
| `>` | Greater than (range) |
| `<` | Less than (range) |
| `>=` | Greater than or equal (range) |
| `<=` | Less than or equal (range) |
| `!=` / `<>` | Not equal (exclusion) |

### `IN` operator

Tests membership in a set of values:

```sql
d1.item.score IN (10, 20, 30)
d1.item.score IN (%1, %2, %3)
```

`IN` is compiled to point intervals — each value becomes a `[X, X]` range.
The TrieIterator skips non-matching values efficiently.

### Condition types

**Filter by literal parameter:**
```
d1.eid = %1
d1.company.price > %2
```

**Filter by reference parameter (auto-coerced for REF attributes):**
```
d1.company.hq = %1
```

**Join between datoms:**
```
d1.company.partner = d2.eid
```

The join `d1.company.partner = d2.eid` means: the value of attribute `company.partner` in datom d1 equals the entity of datom d2. The planner creates an internal shared variable between the two patterns.

**Self-join (same alias):**
```
d1.company.partner = d1.eid
```

The value of `company.partner` equals the entity of the same datom.

**Multiple attributes on the same alias:**

When the same alias appears with different attributes, the planner generates multiple internal patterns with an implicit join on entity:

```
WHERE d1.eid = d2.eid AND d2.company.hq = %1
```

d1 and d2 share the same entity via `d1.eid = d2.eid`.

## Parameters

Positional parameters are referenced by `%N` (1-indexed):

| Syntax | Type | Python argument |
|--------|------|-----------------|
| `%1` | literal | `"ACME"`, `42`, `3.14` |

Values are auto-coerced based on the attribute's declared type. No explicit wrappers needed. Using `ref()` raises a `ParseError`.

```python
engine.sql(
    "SELECT d1.eid WHERE d1.company.hq = %1 AND d1.company.price > %2",
    1001,          # %1 → auto-coerced to ref for REF attribute company.hq
    1000,          # %2 → literal 1000
)
```

## Attribute format

### Internal (dot notation)

The internal EAVT format uses dot notation for attributes: `namespace.attribute`.

```python
engine.sql("UPSERT AS D1 SET company.name = 'ACME'")        # dot notation
```

### Required

Every attribute must have a namespace. Attributes without a namespace are rejected:

```python
engine.sql("UPSERT AS D1 SET name = 'ACME'")       # ERROR: missing namespace
engine.sql("UPSERT AS D1 SET company.name = 'ACME'")  # OK
```

## API

### `engine.sql(query, *params, as_of=None, tz=None, limit=None)`

Executes a SQL query and returns a generator of tuples.

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | `str` | SQL string |
| `*params` | positional | Values for `%1`, `%2`, ... |
| `as_of` | `datetime \| str \| int \| None` | Temporal point (int = `t` value or tx entity ID) |
| `tz` | `tzinfo \| None` | Timezone for timestamps |
| `limit` | `int \| None` | Maximum number of results |

```python
for row in engine.sql("SELECT d1.company.name WHERE d1.eid = %1", 1000):
    print(row)
```

### `engine.sql1(query, *params, as_of=None, tz=None)`

Returns the first tuple or `None`. Equivalent to `next(engine.sql(..., limit=1), None)`.

```python
name = engine.sql1("SELECT d1.company.name WHERE d1.eid = %1", 1000)
```

### `EXPLAIN` (via `engine.sql`)

Returns the query plan traces and compiled VM bytecode.

```python
rows = list(engine.sql("EXPLAIN SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid", 1000))
print("\n".join(row[0] for row in rows))
```

Output includes:
- **Plan traces**: all evaluated variable orderings with cost breakdowns
- **Disassembly**: compiled VM bytecode (opcode listing)

## Examples

### Simple query

Find partners of a company:

```python
list(engine.sql("SELECT d1.company.partner WHERE d1.eid = %1", 1000))
# [(1001,), (1002,)]
```

### Join

Find partner names of a company:

```python
list(engine.sql(
    "SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid",
    1000
))
# [("John Smith",), ("Jane Doe",)]
```

### Multi-attribute

Companies with partners and a specific HQ:

```python
list(engine.sql(
    "SELECT d1.eid, d1.company.partner WHERE d1.eid = d2.eid AND d2.company.hq = %1",
    1001
))
```

### Ref filter

Entities with a specific HQ:

```python
list(engine.sql("SELECT d1.eid WHERE d1.company.hq = %1", 1001))
# [(1000,), (1002,), (1003,)]
```

### Entity ID

Find entity ID:

```python
list(engine.sql("SELECT d1.eid WHERE d1.company.partner = %1", 1001))
# [(1000,)]
```

### Range filter

Entities with price greater than 1000:

```python
list(engine.sql("SELECT d1.company.name WHERE d1.company.price > %1", 1000))
```

Range with both bounds:

```python
list(engine.sql("SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2", 30, 70))
```

Range with join:

```python
list(engine.sql(
    "SELECT d2.person.name WHERE d1.item.score > %1 AND d1.eid = d2.eid",
    70
))
```

### Not-equal filter

Exclude specific values:

```python
list(engine.sql("SELECT d1.item.score WHERE d1.item.score != %1", 50))
list(engine.sql("SELECT d1.item.score WHERE d1.item.score <> %1", 50))
```

Not-equal with range:

```python
list(engine.sql(
    "SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2 AND d1.item.score != %3",
    30, 70, 50
))
```

### IN filter

Match a set of values:

```python
list(engine.sql("SELECT d1.item.score WHERE d1.item.score IN (10, 30, 50)"))
list(engine.sql("SELECT d1.item.score WHERE d1.item.score IN (%1, %2, %3)", 10, 30, 50))
```

### Wildcard

Dump all attributes/values of an entity:

```python
list(engine.sql("SELECT d1.attr, d1.val WHERE d1.eid = %1", 1001))
# [("company.name", "ACME Corp"), ("company.hq", "New York"), ...]
```

### Existence

Check if a datom exists:

```python
list(engine.sql(
    "SELECT 1 WHERE d1.eid = %1 AND d1.company.partner = %2",
    1000, 1001
))
# [(1,)]  → exists
```

### Transaction entity

Find partner with transaction entity ID:

```python
list(engine.sql(
    "SELECT d1.company.partner, d1.tx WHERE d1.eid = %1", 1000))
# [(1001, 52776558134250)]  — tx entity ID = (3 << 44) | t
```

Join transaction metadata (Datomic style):

```python
list(engine.sql(
    "SELECT d1.company.name, d2.db.txInstant "
    "WHERE d1.company.name = 'ACME' AND d1.tx = d2.eid"))
# [("ACME", datetime(2026, 5, 27, 19, 6, 40, 10249, tzinfo=timezone.utc))]
```

The `d1.tx = d2.eid` join connects data datoms to their transaction entity, allowing access to transaction metadata like `db.txInstant`.

### Self-join

Entities that reference themselves as partner:

```python
list(engine.sql(
    "SELECT d2.person.name WHERE d1.company.partner = d1.eid AND d1.eid = d2.eid"
))
```

### History (temporal)

All versions of an attribute, including retracted values:

```python
list(engine.sql("SELECT HISTORY d1.company.name WHERE d1.eid = %1", 1000))
# [("ACME Corp",), ("ACME Inc",)]  — name changed from ACME Corp to ACME Inc
```

### 3-pattern chain

Chained join: partner → hq → city name:

```python
list(engine.sql(
    "SELECT d3.person.name WHERE d1.company.partner = d2.eid AND d2.company.hq = d3.eid"
))
```

### With as_of

Temporal query (by transaction number):

```python
list(engine.sql(
    "SELECT d1.company.partner WHERE d1.eid = %1",
    1000,
    as_of=1005
))
```

Or by datetime string:

```python
list(engine.sql(
    "SELECT d1.company.partner WHERE d1.eid = %1",
    1000,
    as_of="2025-06-15T12:00:01+00:00"
))
```

## Schema

### `ATTRIBUTE`

Declares an attribute with its value type, cardinality, and optional uniqueness constraint. Every attribute must be declared before use in `UPSERT` or `DELETE`.

```
ATTRIBUTE ns.attr TYPE [ONE|MANY] [UNIQUE]
```

**TYPE** is required and must be one of:

| Type | Description | Accepted values |
|------|-------------|-----------------|
| `STRING` | Text | `'hello'` |
| `LONG` | 64-bit integer | `42` |
| `REF` | Entity reference | integer entity ID (auto-coerced) |
| `BOOLEAN` | True/false | `true`, `false` |
| `FLOAT` | 64-bit float | `3.14` |
| `INSTANT` | Timestamp | microsecond value, ISO string, or `datetime` |
| `BYTES` | Binary data | pass `bytes` Python value via `%N` |
| `KEYWORD` | Keyword/string | `'ns/name'` |

**Cardinality** defaults to `ONE` if omitted.

```python
engine.sql("ATTRIBUTE company.name STRING ONE")
engine.sql("ATTRIBUTE company.partner REF MANY")
engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE")
engine.sql("ATTRIBUTE company.tags STRING MANY")
```

- `ONE`: single value per entity (overwrites on `UPSERT`)
- `MANY`: multiple values per entity (accumulates on `UPSERT`)
- `UNIQUE`: enforces that no two entities share the same value for this attribute

> **Value size limit:** `STRING` and `BYTES` values are capped at **1 MB** (raw payload). Larger values are rejected at write time.

#### Idempotency

Calling `ATTRIBUTE` multiple times for the same attribute:
- **Same type + same cardinality**: no-op (idempotent)
- **Same type + different cardinality**: updates cardinality
- **Different type**: raises `ValueError`

```python
engine.sql("ATTRIBUTE company.name STRING ONE")
engine.sql("ATTRIBUTE company.name STRING MANY")     # OK: cardinality updated
engine.sql("ATTRIBUTE company.name LONG ONE")         # ERROR: type mismatch
```

#### Type validation & auto-coercion

`UPSERT` validates that values match the declared type. Auto-coercion is applied:

- `Int64` → `Bool` for BOOLEAN attributes

```python
engine.sql("ATTRIBUTE company.age LONG ONE")
engine.sql("UPSERT AS D1 SET company.age = 42")       # OK
engine.sql("UPSERT AS D1 SET company.age = 'hello'")  # ValueError: type mismatch

engine.sql("ATTRIBUTE company.partner REF MANY")
engine.sql("UPSERT AS D1 SET company.partner = %1", 1001)  # OK: Int64 used directly as entity ref
```

#### Uniqueness

`UNIQUE` prevents duplicate values across entities:

```python
engine.sql("ATTRIBUTE company.email STRING ONE UNIQUE")
engine.sql("UPSERT AS D1 SET company.email = 'a@co.com'")  # OK
engine.sql("UPSERT AS D1 SET company.email = 'a@co.com'")  # ValueError: unique constraint violation
engine.sql("UPSERT AS D1 SET company.email = 'b@co.com'")  # OK: different value
```

Updating a unique attribute on the same entity is allowed:

```python
eid = list(engine.sql("UPSERT AS D1 SET company.email = 'old@co.com'"))[0][0]
engine.sql("UPSERT AS D1 = %1 SET company.email = 'new@co.com'", eid)  # OK: same entity
```

#### Schema introspection

Schema attributes (`db.ident`, `db.valueType`, `db.cardinality`, `db.unique`) are queryable via SQL:

```python
# Find the entity ID of a declared attribute
list(engine.sql("SELECT d1.eid WHERE d1.db.ident = 'company.email'"))

# Find all STRING attributes (20 is the entity ID for db.type.string)
list(engine.sql("SELECT d1.eid WHERE d1.db.valueType = 20"))

# Find all attributes with cardinality MANY
list(engine.sql("SELECT d1.eid WHERE d1.db.cardinality = 36"))

# Find all unique attributes
list(engine.sql("SELECT d1.eid WHERE d1.db.unique = 37"))
```

## Mutations (UPSERT, UPDATE, DELETE)

Two mutation commands cover different semantics:

| Command | Alias resolution | Matches | Behavior |
|---------|-----------------|---------|----------|
| `UPSERT` | New entity, eid(), or explicit eid | 0..1 | Creates new entity or updates existing |
| `UPDATE` | WHERE with joins | 0..N | Updates all matched entities |

### Alias convention

- **`d<n>` bare** (e.g. `d2`) = entity ID — equivalent to `d2.eid`
- **`d<n>.ns.attr`** = attribute value
- Alias is **optional** for single-entity operations
- `TX` is a reserved alias for the current transaction entity

### `UPSERT`

Creates a new entity or updates an existing one. Exactly 0 or 1 result.

#### Syntax

```
UPSERT [AS <alias>] [= eid(<attr>, <val>) | = %N] SET <attr> = <value>, ...
```

#### Create new (no alias)

```python
rows = list(engine.sql("UPSERT SET company.name = %1", "ACME Corp"))
eid = rows[0][0]
```

#### Multi-entity with cross-references

```python
engine.sql('''
    UPSERT AS D1 SET company.name = %1,
           AS D2 SET person.name = %2, person.employer = d1
''', "ACME Corp", "John Smith")
```

Entity IDs for all aliases are allocated first, then values are set — forward references work.

#### Self-reference

```python
engine.sql("UPSERT AS D1 SET company.partner = d1")
```

#### Long chain

```python
engine.sql('''
    UPSERT AS D1 SET company.name = 'ACME',
           AS D2 SET person.name = 'John', person.employer = d1,
           AS D3 SET city.name = 'NY', city.resident = d2
''')
```

#### Lookup by unique attribute (`eid()`)

```python
engine.sql("UPSERT AS D1 = eid('empresa.cnpj', %1) SET empresa.active = true", "12345678000199")
```

The attribute in `eid()` must be declared `UNIQUE`. If no entity is found, the operation is a no-op.

#### Point lookup functions: `eid()` and `val()`

`eid()` performs AVET index point lookups (O(log n)) for entity resolution:

**`eid(attr, value)` → entity ID** (AVET lookup)

Used in entity binding position (`AS D1 = eid(...)`) and as a SET value for REF attributes.

```python
# Entity binding — find entity by unique attr
engine.sql("UPSERT AS D1 = eid('company.name', 'ACME') SET company.active = true")

# As SET value (REF attribute)
engine.sql("UPSERT AS D1 SET company.ceo = eid('person.name', 'Alice')")

# Unquoted attr name (dotted ident, same as everywhere else)
engine.sql("UPSERT AS D1 = eid(company.name, 'ACME') SET company.active = true")

# With params
engine.sql("UPSERT AS D1 = eid(%1, %2) SET company.active = true", "company.name", "ACME")
```

**`val(entity, attr)` → value** (EAVT lookup)

Resolves an attribute value given an entity ID. Used in SET values — avoids a separate SELECT to read a value.

```python
# Copy a value from another entity
engine.sql("UPSERT AS D1 SET order.total = val(eid('item.codigo', 'ABC'), 'item.preco')")

# With a param entity ID
engine.sql("UPSERT AS D1 SET order.total = val(%1, 'item.preco')", item_eid)

# Unquoted attr name
engine.sql("UPSERT AS D1 SET order.total = val(eid(item.codigo, 'ABC'), item.preco)")
```

Both `eid()` and `val()` accept quoted strings (`'attr.name'`), unquoted dotted idents (`attr.name`), and params (`%N`) for all attr arguments. The `eid()` entity argument in `val()` can be a `%param`, alias ref (`d1`), or a nested `eid()` call.

| Function | Lookup | Index | Returns |
|----------|--------|-------|---------|
| `eid(attr, val)` | attr + value → entity | AVET | entity ID |
| `val(entity, attr)` | entity + attr → value | EAVT | attribute value |

#### Lookup as value reference

```python
engine.sql('''
    UPSERT AS D1 SET company.name = 'ACME', company.hq = d2,
           AS D2 WHERE city.name = 'Tokyo'
''')
```

#### Annotate transaction

```python
engine.sql('''
    UPSERT AS D1 SET company.name = 'ACME',
           AS TX SET tx.user = 'alice'
''')
```

`TX` is a reserved alias — no creation, no WHERE. Always refers to the current transaction.

### Mutation rules

| Rule | Detail |
|------|--------|
| `AS <alias> SET ...` | Creates new entity, auto-allocated |
| `AS <alias> = eid(<attr>, <val>) SET ...` | Point lookup by unique attribute via AVET index |
| `AS <alias> WHERE <conditions> SET ...` | Composite WHERE with joins (UPDATE only) |
| `AS TX SET ...` | Annotate current transaction entity |
| `AS <alias> = %N SET ...` | Explicit entity ID, no allocation |
| `AS <alias> = eid(...)` (no SET) | Lookup-only reference, usable as value |
| `SET <ref-attr> = eid(<attr>, <val>)` | Resolve REF value via AVET point lookup |
| `SET <attr> = val(<entity>, <attr>)` | Resolve attribute value via EAVT point lookup |
| `d<n>` (lowercase, bare) | Entity ID of alias `D<n>` |
| `d<n>.ns.attr` | Attribute value |
| `eid()` requires UNIQUE attribute | Non-unique attributes are rejected at runtime |
| Alias optional for single entity | `UPSERT SET ...` = `UPSERT AS D1 SET ...` |

### Mutation results

```python
# UPSERT — create new
result = list(engine.sql("UPSERT SET company.name = %1", "ACME"))
# [(1000, 1)]  — auto-generated entity 1000, 1 value inserted

# Multi-entity UPSERT
result = list(engine.sql("UPSERT AS D1 SET company.name = %1, AS D2 SET person.name = %2", "ACME", "John"))
# [(1000, 2)]  — first alias entity, total values across all clauses

# UPSERT lookup
engine.sql("UPSERT AS D1 = eid('empresa.cnpj', %1) SET empresa.active = true", "12345678000199")
# [(1000, 1)]  — found existing company, added active = true

# UPDATE with join
engine.sql("UPDATE SET company.active = true WHERE company.hq = d2 AND d2.city.name = 'London'")
# [(3,)]  — 3 entities updated
```

### `DELETE WHERE`

Retracts all datoms matching the WHERE conditions. Uses the same query engine as SELECT and UPDATE.

```
DELETE WHERE <conditions>
```

```python
engine.sql('DELETE WHERE company.hq = d2 AND d2.city.name = %1', 'London')
```

### SqlResult

All mutation operations return a `SqlResult`:

```python
@dataclass
class SqlResult:
    kind: str              # "select", "insert", "update", "delete"
    columns: list[str]     # column names
    rows: list[tuple]      # data rows (empty for mutations)
    count: int             # rows returned or affected
```

| Operation | kind | rows | count |
|-----------|------|------|-------|
| SELECT | `"select"` | projected data | number of rows |
| UPSERT | `"insert"` | `[("OK", entity, n), ...]` | number of entities |
| UPDATE | `"update"` | `[("OK", n)]` | n entities updated |
| DELETE | `"delete"` | `[("DELETED", n)]` | n retracted |

## EXPLAIN

Shows the query plan and compiled VM bytecode without running the query.

```
EXPLAIN SELECT ...
EXPLAIN UPSERT ...
EXPLAIN ATTRIBUTE ...
```

```python
rows = list(engine.sql("EXPLAIN SELECT d1.company.name WHERE d1.eid = %1", 1000))
print("\n".join(row[0] for row in rows))
```

For SELECT, shows plan traces (evaluated orderings with cost) followed by bytecode disassembly.
For non-SELECT statements, returns a descriptive message.

## Roadmap (future)

- `ORDER BY` — result ordering
- `GROUP BY` / `COUNT` — aggregations
- Replace SELECT bytecode with plan interpreter

## REPL (Interactive)

The `eavt-admin repl` command starts an interactive SQL shell:

```
$ eavt-admin repl path/to/db
eavt-sql repl: path/to/db
Type .help for commands, .quit to exit

eavt-sql> SELECT d1.company.name WHERE d1.eid = %1;
Acme Corp

eavt-sql> .status
Database:      path/to/db
Disk usage:    1.2 MB
SST size:      856 KB
...

eavt-sql> .dump
e1	company.name	ACME Corp	2025-06-15T12:00:00.123456

eavt-sql> .quit
```

### Rules

- **SQL statements** require a trailing `;` (semicolon)
- **Dot commands** (`.status`, `.dump`, etc.) do **not** require a semicolon
- **Multiline** — press Enter without `;` to continue a SQL statement
- **Multiple statements** — separate with `;` on one line or across lines
- **Tab-separated output** — SQL results shown as `\t`-separated columns, one row per line
- **Error recovery** — errors are printed but don't exit the REPL

### Dot commands

| Command | Description |
|---------|-------------|
| `.quit` / `.exit` | Exit the REPL |
| `.help` | Show available commands |
| `.flush` | Flush MemTable to PageStore |
| `.dump [INDEX]` | Dump active datoms (EAVT/AEVT/AVET/VAET, default: EAVT) |
| `.status` | Database overview (disk, SST, WAL, MemTable) |
| `.tree` | Per-column-family stats |
| `.free` | Disk usage summary |
| `.memtable` | MemTable contents and sizes |

Dot commands that access the store (`.status`, `.tree`, etc.) require a file-based database.

### Prompts

- `eavt-sql> ` — primary prompt (new statement)
- `       -> ` — continuation prompt (statement incomplete, no `;` yet)

### History

Command history is saved to `~/.eavt_sql_history` (last 500 entries).
