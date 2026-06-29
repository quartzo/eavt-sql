# EAVT-SQL Virtual Machine Specification

## 1. Overview

The EAVT-SQL Virtual Machine (VM) is a register-based bytecode interpreter
implemented in Rust (`spier-eavt-query`), modeled after SQLite's VDBE. It uses
a two-phase architecture:

1. **Compiler** (`spier-compiler` + `spier-datalog` + `spier-sql-parse`) —
   translates a parsed SQL AST into a `VMProgram` (bytecode).
2. **VM** (`spier-eavt-query`) — executes the bytecode, producing result rows.

### Design Goals

- **Explicit execution plans**: every index seek, depth traversal, range check,
  and type conversion is visible in the bytecode.
- **Cacheable programs**: `VMProgram` is immutable and can be cached for
  prepared statements.
- **Debuggable**: `EXPLAIN` prints a human-readable disassembly (JSON format).
- **Extensible**: new operations are new opcodes.

### Transport

`VMProgram` crosses FFI as a `#[slot_struct]` — 1 boxed pointer. The nested
`Vec<Instruction>`, `Vec<String>`, etc. ride along unserialized. No binary
wire format is needed for Rust→Rust or Python→Rust communication. Python
callers interact via `engine.sql()` which calls `compile_sql` then `run_vm`
through the DynSpire tower.

### Scanner-Centric Architecture (v2)

The VM uses **v2 scanner-centric opcodes** (`ScannerOpen`, `PrefixPush`,
`DepthEnter`) — see sections 6.5 and 2.5 for design principles and compiler
constraints. Legacy v1 opcodes (`CursorDeclare`, `CursorBind`, `DepthOpen`)
are still in the enum for binary compatibility but are no-ops when encountered.

---

## 2. Compilation Pipeline

### 2.1 Compiler Responsibilities

The compiler is responsible for **all** optimization decisions. The VM executes
a fixed plan — it never reconsiders index choice, variable ordering, or join
strategy at runtime.

The pipeline (all in Rust):

1. **Parse** (`spier-sql-parse`) — SQL string → AST (`RustStmt`).
2. **Translate** (`spier-datalog`) — AST → `DatalogIR` (patterns + find_vars +
   range_bounds + history flag).
3. **Plan** (`spier-compiler` planner) — `DatalogIR` → `QueryPlanResult`
   (variable ordering, index choice, join patterns, probes).
4. **Emit bytecode** (`spier-compiler`) — `QueryPlanResult` → `VMProgram`.

### 2.2 Variable Ordering

The planner sorts variables by ascending domain size. The variable with the
**smallest estimated domain** is placed first in the global variable ordering,
minimizing the search space at the outermost depth of the triejoin.

The resulting ordering determines:
- **Depth 0** = most selective variable (fewest distinct values).
- **Depth N-1** = least selective variable.
- **Index choice** = the planner picks the index with the longest bound prefix
  for the given ordering.

### 2.3 Index Selection

Given the variable ordering, each pattern is matched to the best index:

```
Index   Key Order          Best when variables appear in this order
──────   ─────────         ──────────────────────────────────────────
EAVT     e, a, v           entity known → attr known → value free
AEVT     a, e, v           attr known → entity free → value free
AVET     a, v, e           attr known → value known → entity free
VAET     v, a, e           value known → attr known → entity free
```

The compiler picks the index with the **longest bound prefix** — i.e., the
most leading positions that are constants or already-bound variables.

Missing positions between the prefix and the first variable are promoted to
**synthetic skip variables** (`_skip_{pos}_{idx}`) by the planner, not by new
VM opcodes. The number of synthetic variables factors into the cost model.

### 2.4 What Gets Baked Into the Bytecode

| Decision | Made By | Visible in Bytecode |
|----------|---------|-------------------|
| Variable ordering | Planner | `DEPTH_ENTER` order, `depth_var` mapping |
| Index choice | Planner | `SCANNER_OPEN` p2 (CF ID) |
| Bound prefix | Compiler | `PREFIX_PUSH` instructions |
| Range bounds | Compiler | `RANGE_ADD` operands |
| History mode | Compiler | `SCANNER_OPEN` p3 (0 or 1) |
| Projection type conversions | Compiler | `ATTR_NAME`, `RESOLVE_VAL` |

### 2.5 Compiler Constraints (v2 Forward-Only)

With forward-only persistent scanners, the variable ordering (depth assignment)
must be compatible with each scanner's natural iteration order. When a scanner
iterates at depth N, it consumes values in ascending order — these values
cannot be revisited at depth N for a different depth N-1 value.

**Example:** `SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid`

- **Plan A (name-first)**: depth 0=?name, depth 1=?d2. Scanner p0 at depth 1
  iterates partner entities: john, jane. For name="Jane", convergence moves p0
  forward past john to jane. For name="John", p0 needs john again —
  **forward-only prevents this**.
- **Plan B (entity-first)**: depth 0=?d2, depth 1=?name. Scanner p0 at depth 0
  iterates entities: john → jane. Each entity consumed once — **compatible**.

The compiler must prefer plans where scanners iterate at their earliest depth,
avoiding the need to revisit values.

**PREFIX_PUSH constraint**: only constants at the start of idx_order (before
the first variable) can be pushed. Constants after the first variable become
trailing bindings (handled via `RANGE_ADD` with exact bounds). This means v2
prefers indexes where all constants are leading positions.

**VAET index**: `[v, a, e]` is populated only for REF attributes. The current
planner excludes VAET when `v` is a variable (join patterns like
`d1.company.partner = d2.eid`), falling back to EAVT/AEVT. A future improvement
would make the planner schema-aware for VAET — when the attribute is REF and v
is a variable, VAET can serve as the iteration index with v at position 0.

---

## 3. Type System

### 3.1 Value Enum

Every data element in the VM is a `Value` — a tagged enum defined in
`dynspire-commons`:

```rust
pub enum Value {
    Text(String),       // TAG_STR = 2
    Bytes(Vec<u8>),     // TAG_BYTES = 3
    Bool(u8),           // TAG_BOOL = 4
    Int64(i64),         // TAG_INT64 = 12
    Float64(f64),       // TAG_FLOAT64 = 14
    Timestamp(i64),     // tag = -1 (microsecond epoch)
    Unknown(i8, u64),   // catch-all for other tag types
}
```

**No REF types.** Entities are always `Int64`. There is no `REF_STR`,
`REF_UINT64`, or entity-name-to-ID resolution at the VM level.

### 3.2 Tag Ordering

Tags define a total order across types:

```
STR(2) < BYTES(3) < BOOL(4) < ... < INT64(12) < FLOAT64(14)
```

Within the same tag, comparison is by raw value (numeric or lexicographic).

### 3.3 Registers and Variable Slots

Every register is `Option<Value>`. Variables (triejoin bindings) are also
`Option<Value>` in integer-indexed slots. `BindGet` and `BindSet` transfer
`Value`s between registers and variable slots.

---

## 4. VM State

```rust
pub struct VM<'a> {
    prog: &'a VMProgram,
    regs: Vec<Option<Value>>,        // registers (general-purpose)
    vars: Vec<Option<Value>>,        // variable slots (triejoin bindings)
    engine: &'a dyn VMEngine,        // storage backend trait
    ctx: QueryContext,               // as_of_us, current_t
    params: Vec<Value>,              // query parameters
    limit: Option<usize>,
    pc: usize,                       // program counter
    count: usize,                    // rows yielded
    depth_var: HashMap<usize, usize>,       // depth → var_id
    depth_cursors: HashMap<usize, Vec<usize>>,  // depth → [scanner_ids]
    ranges: HashMap<usize, Vec<RangeSpec>>,      // depth → range intervals
    scan_data: Vec<RawDatomView>,    // full-scan buffer
    scan_idx: usize,                 // full-scan cursor
    emit_values: Vec<Value>,         // accumulator for EMIT_VALUE
    probe_positions: HashMap<usize, Value>,  // probe accumulator
    v2_scanners: HashMap<usize, V2Scanner>,  // v2 scanner-centric scanners
    same_var_constraints: HashMap<usize, Vec<(usize, usize)>>,
    t_var_ids: Vec<usize>,
}
```

### VMEngine Trait

The VM calls into storage via the `VMEngine` trait — methods for resolving
attributes, creating scanners, opening raw cursors, collecting active datoms,
probing, saving, retracting, and allocating entities.

---

## 5. Instruction Format

```rust
pub struct Instruction {
    pub op: OpCode,
    pub p1: i32,
    pub p2: i32,
    pub p3: i32,
    pub p4: InstructionData,
}

pub enum InstructionData {
    None,
    Int(i64),
    Float(f64),
    Str(String),
    CursorPlan(CursorPlanData),
    RangeFlags(i32),
}
```

```rust
#[slot_struct]
#[derive(Clone)]
pub struct VMProgram {
    pub instructions: Vec<Instruction>,
    pub num_registers: usize,
    pub num_vars: usize,
    pub var_names: Vec<String>,
    pub depth_var: Vec<(usize, usize)>,
    pub t_var_ids: Vec<usize>,
    pub same_var_constraints: Vec<(i32, Vec<(usize, usize)>)>,
    pub history: bool,  // JSON introspection only; actual flag is SCANNER_OPEN p3
}
```

`VMProgram` crosses FFI as 1 boxed pointer via `#[slot_struct]`. No
serialization needed — the nested `Vec`s travel intact.

---

## 6. Opcode Reference

### 6.1 Opcode Enum

```rust
pub enum OpCode {
    // Control
    Halt = 0,
    Goto = 1,
    // Loading
    Null = 10,
    Param = 14,
    ConstInt = 16,
    ConstStr = 17,
    ConstFloat = 18,
    ConstBool = 19,
    // Resolution
    InternA = 21,
    AttrName = 51,
    ResolveVal = 52,
    // v1 Cursor (legacy — VM treats as no-op)
    CursorDeclare = 62,
    CursorBind = 63,
    CursorClose = 66,
    DepthOpen = 70,
    // Depth
    DepthUp = 71,
    LeapInit = 72,
    LeapNext = 73,
    // Binding
    BindGet = 80,
    BindSet = 81,
    // Range
    RangeAdd = 91,
    // Result
    ResultRow = 100,
    EmitDeclare = 101,
    EmitValue = 102,
    EmitEnd = 103,
    // Probe
    ProbeDeclare = 110,
    ProbeBind = 111,
    ProbeBegin = 112,
    ProbeGetT = 113,
    // Scan
    ScanNext = 121,
    // DML
    ExecInsert = 140,
    ExecAttribute = 141,
    ExecRetract = 143,
    LookupEntity = 144,
    AllocEntP = 145,
    DeclarePartition = 146,
     LoadTxEnt = 147,
     // v2 Scanner-Centric
    ScannerOpen = 200,
    PrefixPush = 201,
    DepthEnter = 202,
    ScannerClose = 203,
}
```

### 6.2 Control Flow

#### `HALT`
Stop execution.

#### `GOTO addr`
Unconditional jump. `p1` = target address.

### 6.3 Register Loading

#### `NULL dst`
Set register to `None`. `p1` = destination register.

#### `PARAM dst param_idx`
Load a parameter into a register as `Value`. `p1` = dst, `p2` = 1-based param index.

#### `CONST_INT dst value`
Load a constant integer. `p1` = dst, `p4` = `Int(value)`.

#### `CONST_STR dst value`
Load a constant string. `p1` = dst, `p4` = `Str(value)`.

#### `CONST_FLOAT dst value`
Load a constant float. `p1` = dst, `p4` = `Float(value)`.

#### `CONST_BOOL dst value`
Load a constant boolean. `p1` = dst, `p4` = `Int(0|1)`.

### 6.4 Resolution and Projection

#### `INTERN_A dst attr_name`
Look up (or create) the integer attribute ID for the given attribute name.
`p1` = dst, `p4` = attribute name string (e.g., `"company.partner"`).

#### `ATTR_NAME dst`
Convert an attribute ID to its name string. `p1` = register.
`Register[p1]: Value(Int64, attr_id) → Value(Text, attr_name)`

#### `RESOLVE_VAL dst`
General-purpose resolution: if the Value is a `Timestamp`, converts to ISO
string. Otherwise, no-op. `p1` = register.

### 6.5 Scanner-Centric Opcodes (v2)

The v2 architecture is built on seven principles:

1. **One scanner per clause** — opened at start, persists until end
2. **Fixed prefix populated by PUSH** — constant values from the clause, in index order
3. **DEPTH_ENTER reads current key** — positions cursor for scanners that start at this depth, reads from `current_active_key` for scanners that serve parent depths
4. **LEAP_NEXT moves cursor** — advance_to_active + reads new key
5. **DEPTH_UP does not destroy scanner** — returns to previous depth only
6. **Forward-only within each depth entry** — cursor always ascending, never backtracks
7. **Degree of freedom preservation** — each depth entry must have its full range available

Legacy v1 opcodes (`CursorDeclare`, `CursorBind`, `DepthOpen`) are still in the
enum for binary compatibility but are no-ops.

#### `SCANNER_OPEN sid cf_id history`
Declare a scanner over an index.

```
p1: scanner ID
p2: column family ID (0=EAVT, 1=AEVT, 2=AVET, 3=VAET)
p3: history flag (0=normal, 1=history mode — iterates all versions)
```

When `p3=1`, the scanner appends `"t"` to its idx_order and calls
`set_history_mode()`. History mode iterates all key versions (both current
and retracted) without filtering.

#### `PREFIX_PUSH sid src`
Append bytes from a register into the scanner's prefix. Each push fills the
next position in index order. The scanner opens on the first `DEPTH_ENTER`.

```
p1: scanner ID
p2: source register
```

The register value is encoded to bytes according to its type and the index
position. For example, for AEVT `[a, e, v]`:
- 1st push → position `a` (attr_id as u32 big-endian)
- 2nd push → position `e` (entity as u64 big-endian)
- 3rd push → position `v` (value encoded according to type)

More pushes → fewer keys the cursor loads when opened.

Only constants at the **start** of idx_order (before the first variable) can be
pushed. Constants after the first variable become trailing bindings, handled
via `RANGE_ADD` with exact bounds. This constrains index choice: v2 prefers
indexes where all constants are leading positions.

#### `DEPTH_ENTER depth sid`
Activate a scanner at a given depth. The scanner reads the value at the next
free position of the current key.

```
p1: depth (0-based)
p2: scanner ID
```

Behavior depends on scanner state:
- **First entry** (scanner not open): opens cursor with accumulated prefix,
  advance_to_active, reads value at next free position.
- **Scanner starts at this depth** (no parent depth binding): positions cursor
  at prefix start, advance_to_active. This establishes the degree of freedom
  for this depth — the full range under the prefix is available.
- **Scanner serves parent depth** (has binding at depth < current): reads from
  `current_active_key` (already updated by parent's LEAP_NEXT). Zero cursor ops.

Each depth entry must preserve its degree of freedom. A scanner that starts at
this depth needs its full prefix range available. A scanner that serves a
parent depth inherits the parent's cursor position.

Multiple `DEPTH_ENTER` with the same depth but different scanner IDs accumulate
active scanners for leapfrog convergence.

#### `DEPTH_UP depth sid`
Deactivate a scanner at a depth. Does NOT destroy the scanner — only returns
the triejoin state to the previous depth.

#### `SCANNER_CLOSE sid`
Close and release a scanner.

### 6.6 Leapfrog Convergence

#### `LEAP_INIT depth fail_addr`
Initialize leapfrog convergence at the given depth. Intersects active scanners.
On failure, jump to `fail_addr`.
Side effect: `vars[depth_var[depth]] = converged value`.

#### `LEAP_NEXT depth fail_addr`
Advance the leapfrog at the given depth. The scanner with the minimum value
advances. On exhaustion, jump to `fail_addr`.

### 6.7 Binding Transfer

#### `BIND_GET dst var_id`
Copy a Value from a variable slot to a register. `p1` = dst, `p2` = var_id.

#### `BIND_SET var_id src`
Copy a Value from a register to a variable slot. `p1` = var_id, `p2` = src.

### 6.8 Range Filtering

#### `RANGE_ADD depth lo_reg hi_reg flags`
Add a range interval for the given depth.

```
p1: depth (0-based)
p2: lo register index (-1 for unbounded / -∞)
p3: hi register index (-1 for unbounded / +∞)
p4: RangeFlags (0=closed, 1=lo_open, 2=hi_open, 3=both_open)
```

Interval flags:
- `0` = `[lo, hi]` — both endpoints closed (inclusive)
- `1` = `(lo, hi]` — lo open (exclusive)
- `2` = `[lo, hi)` — hi open (exclusive)
- `3` = `(lo, hi)` — both open (exclusive)

### 6.9 Result Emission

#### `RESULT_ROW start count`
Emit a result row composed of `count` consecutive registers starting at `start`.
`p1` = first register, `p2` = number of registers.

If any register is `None`, the row is silently dropped.

#### `EMIT_DECLARE`
Initialize an empty accumulator for literal values.

#### `EMIT_VALUE src`
Append the value from a register to the emit accumulator. `p1` = source register.

#### `EMIT_END`
Yield the accumulated values as a tuple, then check the limit.

### 6.10 Probe (Lookup)

#### `PROBE_DECLARE`
Initialize an empty probe accumulator.

#### `PROBE_BIND position src`
Bind one position in the probe pattern. `p1` = position (0=e, 1=a, 2=v, 3=t),
`p2` = source register.

#### `PROBE_BEGIN fail_addr`
Execute the probe. Opens a scan on the index with the bound prefix, checks if
any non-retracted datom matches. If not found, jumps to `fail_addr`.

#### `PROBE_GET_T dst`
After a successful probe, extract the transaction `t` value into a register.
`p1` = destination register.

### 6.11 Full Scan

#### `SCAN_NEXT fail_addr`
Advance the full scan to the next active (non-retracted) datom. If exhausted,
jump to `fail_addr`. `p1` = fail address.

### 6.12 DML Opcodes

#### `EXEC_INSERT e_reg a_reg v_reg p4=ts_reg`
Save one datom. `p1` = entity register, `p2` = attribute register (string name),
`p3` = value register, `p4` = timestamp register index (`-1` = no timestamp).

#### `EXEC_RETRACT e_reg a_reg v_reg p4=ts_reg`
Retract one datom. Same operand layout as `EXEC_INSERT`.

#### `EXEC_ATTRIBUTE attr_reg cardinality`
Register an attribute's cardinality. `p1` = attribute register (string name),
`p2` = 0 (one) or 1 (many).

#### `ALLOC_ENT_P dst partition_id`
Allocate a fresh entity ID in the given partition. `p1` = result register,
`p2` = partition ID.

#### `LOOKUP_ENTITY dst`
Lookup entity by unique attribute. Used by UPSERT `eid()`.

#### `LOAD_TX_ENT dst`
Load the current transaction entity ID into a register. `p1` = dst.

#### `DECLARE_PARTITION name`
Declare a partition. `p4` = partition name string.

---

## 7. Triejoin Fundamentals

### 7.1 What is a Trie?

Each column family (EAVT, AEVT, AVET, VAET) stores datoms sorted as a
**trie** — a tree where each level corresponds to one position in the key.

For example, the EAVT column family sorts by `(e, a, v)`:

```
EAVT trie:
  ├─ entity 7
  │   ├─ attr 5 (company.partner)
  │   │   ├─ value "partner-a"
  │   │   └─ value "partner-b"
  │   └─ attr 8 (person.name)
  │       └─ value "John Smith"
  ├─ entity 42
  │   ├─ attr 5 (company.partner)
  │   │   └─ value "partner-c"
  │   └─ attr 3 (company.name)
  │       └─ value "ACME Corp"
  └─ entity 99
      └─ ...
```

A **scanner** is an iterator positioned at one level of this trie. Given a
bound prefix (e.g., entity=42, attr=5), the scanner can enumerate all values
at the next level.

### 7.2 Index Terminology

| Term | Definition |
|------|-----------|
| **Column family** | One sorted copy of all datoms, keyed in a specific order: EAVT, AEVT, AVET, or VAET. |
| **Key order** | The position order in the sorted index (e.g., EAVT → e, a, v). |
| **Bound prefix** | Leading positions that are constants or already-resolved variables. A longer prefix means fewer keys to scan. |
| **Depth** | A level in the triejoin, corresponding to one variable. Depth 0 = most selective variable. |
| **Scanner** | One iterator over one index for one clause. A scanner participates at one or more depths. |
| **Leapfrog convergence** | Finding the intersection of multiple iterators at the same depth. All scanners at the same depth must agree on the variable value. |
| **Same-variable constraint** | When two positions in a pattern refer to the same variable (e.g., `e = v`). |

### 7.3 How the Leapfrog Triejoin Works

The triejoin is a **depth-first enumeration** over sorted tries. At each depth,
all scanners sharing that variable must **converge** — find a value where all
scanners agree.

#### Step-by-step example

Query: Find all persons who work at companies that have a specific partner.

```sql
SELECT d2.person.name
WHERE d1.company.partner = d2.eid AND d2.eid = %1
-- params: (42,)
```

This produces two patterns:
- s0: `(42, "company.partner", ?v_partner)` on EAVT — finds partners of entity 42.
- s1: `(?v_partner, "person.name", ?v_name)` on EAVT — finds names of those partners.

Variables: `?v_partner` (depth 0), `?v_name` (depth 1).

**Depth 0** — both scanners participate:

```
s0 values at depth 0: [7, 15, 23]     (partners of entity 42)
s1 values at depth 0: [3, 7, 12, 15]  (entities with person.name)

Leapfrog convergence:
  1. s0.key=7, s1.key=3 → s1 seeks to 7 → s1.key=7
  2. All equal → converged at 7
  3. vars[0] = 7
```

**Depth 1** — only s1 participates:

```
s1 values at depth 1 (under entity 7): ["John Smith"]
  → vars[1] = "John Smith"
  → yield ("John Smith",)
```

**Advance at depth 1** — exhausted, backtrack to depth 0:

```
s0 advances to 15, s1 seeks to 15 → converged at 15
s1 values at depth 1 (under entity 15): ["Jane Doe"]
  → yield ("Jane Doe",)
```

**Advance at depth 0** — s0 to 23, s1 seeks past 15 → exhausted. Done.

Result: `("John Smith",), ("Jane Doe",)`.

### 7.4 Scanner Lifecycle (v2)

In v2, scanners are **persistent** — opened once at the start and kept alive
throughout the query. This eliminates the per-depth scanner recreation that
v1 suffered from.

1. `SCANNER_OPEN` — declares a scanner with an index and optional history flag.
2. `PREFIX_PUSH` — fills constant positions from the clause.
3. `DEPTH_ENTER` — activates the scanner at a depth (opens cursor on first call).
4. `LEAP_INIT` / `LEAP_NEXT` — convergence and advancement.
5. `DEPTH_UP` — deactivates at a depth (scanner stays alive).
6. `SCANNER_CLOSE` — releases the scanner at query end.

### 7.5 Next Free Position

The scanner knows its index layout (e.g., AVET = `[a, v, e]`). It tracks how
many positions are already filled:

1. Positions filled by `PREFIX_PUSH` (constants from the clause)
2. Positions filled by bindings from parent depths (variables already resolved)

The **next free position** is what `DEPTH_ENTER` reads and `LEAP_NEXT`
iterates:

```
AVET = [a,    v,    e,    tx]
        ↑     ↑     ↑
        push  d=0   d=1

PREFIX_PUSH a=bench.name   → fills position a
DEPTH_ENTER d=0            → iterates position v (next free)
DEPTH_ENTER d=1            → reads position e from same key (next free)
LEAP_NEXT   d=1            → advance past [a, v, e] → next e
DEPTH_UP    d=1
LEAP_NEXT   d=0            → advance past [a, v] → next v (new key)
```

Each scanner independently calculates its next free position based on its index
layout, how many PREFIX_PUSHes it received, and which depth it is being used at.

### 7.6 Key State Continuity Between Depths

When depth N reads a key and binds a variable, the **same key** contains the
value for depth N+1. No cursor movement is needed:

```
Current key: [bench.name, "Acme", entity_42, tx_5, ¬retracted]
              \________/ \_____/ \________/ \________________/
               push(a)   d=0(v)  d=1(e)       suffix

d=0: reads bytes at offset v → ?v_name = "Acme"
d=1: reads bytes at offset e → ?e = entity_42     ← SAME key, zero cursor op
```

The cursor only moves on `LEAP_NEXT` or when a newly-entered scanner needs to
seek to a specific value (leapfrog convergence).

---

## 8. Triejoin Execution Model

### 8.1 The Algorithm

The Leapfrog Triejoin is a depth-first enumeration over sorted tries (indexes).

Given a global variable ordering `[var_0, var_1, ..., var_N-1]`:

1. **Depth 0**: Enter scanners, converge. Bind `var_0`.
2. **Depth 1**: Enter scanners (using `var_0` binding), converge. Bind `var_1`.
3. ...
4. **Depth N-1**: Enter scanners, converge. Bind `var_N-1`.
5. **Yield** result row.
6. **Advance** at depth N-1. If exhausted, **backtrack** to N-2, advance there.
7. When backtracking to depth K, **re-enter** depths K+1 through N-1.

### 8.2 Bytecode Pattern (v2)

```
════ SETUP ════
  PARAM, INTERN_A, CONST_INT, CONST_STR, CONST_FLOAT ...
  RANGE_ADD for each range interval

════ SCANNER SETUP ════
  SCANNER_OPEN  sid=0  cf=AVET  history=0
  PREFIX_PUSH   sid=0  R_attr_value       ← position a
  # v and e remain free

  SCANNER_OPEN  sid=1  cf=AVET
  PREFIX_PUSH   sid=1  R_attr_name        ← position a
  # v and e remain free

════ DEPTH 0 ════
addr_d0:
  DEPTH_ENTER   d=0  sid=1               ← scanner 1: iterate v
  LEAP_INIT     d=0  addr_done

════ DEPTH 1 ════
addr_d1:
  DEPTH_ENTER   d=1  sid=1               ← scanner 1: reads e from current key
  DEPTH_ENTER   d=1  sid=0               ← scanner 0: seeks to entity, iterates e
  LEAP_INIT     d=1  addr_back_d0

════ DEPTH 2 ════
addr_d2:
  DEPTH_ENTER   d=2  sid=0               ← scanner 0: reads v from current key
  LEAP_INIT     d=2  addr_back_d1

════ RESULT ════
  BIND_GET      r_result  var_id
  RESOLVE_VAL   r_result
  RESULT_ROW    r_result  1

════ LOOP DEPTH 2 ════
addr_loop_d2:
  LEAP_NEXT     d=2  addr_back_d1
  BIND_GET / RESULT_ROW ...
  GOTO          addr_loop_d2

════ BACKTRACK ════
addr_back_d1:
  DEPTH_UP      d=2  sid=0
  LEAP_NEXT     d=1  addr_back_d0
  GOTO          addr_d2

addr_back_d0:
  DEPTH_UP      d=1  sid=0
  DEPTH_UP      d=1  sid=1
  LEAP_NEXT     d=0  addr_done
  GOTO          addr_d1

addr_done:
  SCANNER_CLOSE sid=0
  SCANNER_CLOSE sid=1
  HALT
```

### 8.3 The Backtracking Structure

When `LEAP_NEXT` or `LEAP_INIT` fails at depth D, the VM:

1. Calls `DEPTH_UP` at depth D (deactivates those scanners).
2. Tries `LEAP_NEXT` at depth D-1.
3. If that succeeds, re-enters depths D, D+1, ... via `GOTO addr_dD`.

This is the recursive algorithm expressed as a flat state machine with GOTO.

---

## 9. Query Pattern Examples

### 9.1 Simple Attribute Lookup

```sql
SELECT d1.company.name WHERE d1.eid = %1
-- params: (1000,)
```

**Compiled plan**: Single scanner on EAVT, entity bound, attr bound, 1 depth.

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   PARAM         r0  1            r0 = Value(Int64, 1000)
  1   INTERN_A      r1  "company.name"  r1 = Value(Int64, 5)
  2   SCANNER_OPEN  sid=0  cf=0  p3=0  EAVT
  3   PREFIX_PUSH   sid=0  r0          push entity ID
  4   PREFIX_PUSH   sid=0  r1          push attr ID
  5   DEPTH_ENTER   d=0  sid=0         prefix: [1000, 5]
  6   LEAP_INIT     d=0  13            vars[0] = Value(Text, "ACME Corp")
  7   BIND_GET      r2  0             r2 = Value(Text, "ACME Corp")
  8   RESOLVE_VAL   r2                no-op
  9   RESULT_ROW    r2  1             yield ("ACME Corp",)
 10   LEAP_NEXT     d=0  13
 11   BIND_GET      r2  0
 12   RESOLVE_VAL   r2
 13   RESULT_ROW    r2  1
 14   GOTO          10
 13   SCANNER_CLOSE sid=0
 14   HALT
```

### 9.2 Two-Pattern Join (Chain)

```sql
SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid
-- params: (1000,)
```

**Variables**: var0=`_e_d1`, var1=`_v_d1_partner` (= d2.eid), var2=`_v_d2_name`

**Scanners**:
- s0: EAVT, pattern (?_e_d1, "company.partner", ?_v_partner)
- s1: EAVT, pattern (?_v_partner, "person.name", ?_v_name)

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   PARAM         r0  1            r0 = Value(Int64, 1000)
  1   INTERN_A      r1  "company.partner"
  2   INTERN_A      r2  "person.name"
  3   SCANNER_OPEN  sid=0  cf=0       EAVT
  4   PREFIX_PUSH   sid=0  r0         push entity
  5   PREFIX_PUSH   sid=0  r1         push attr
  6   SCANNER_OPEN  sid=1  cf=0       EAVT
  7   PREFIX_PUSH   sid=1  r2         push attr
  8   DEPTH_ENTER   d=0  sid=0
  9   LEAP_INIT     d=0  26           vars[0] = partner entity
 10   DEPTH_ENTER   d=1  sid=0
 11   DEPTH_ENTER   d=1  sid=1
 12   LEAP_INIT     d=1  23           vars[1] = Value(Int64, 7)
 13   DEPTH_ENTER   d=2  sid=1
 14   LEAP_INIT     d=2  20           vars[2] = Value(Text, "John Smith")
 15   BIND_GET      r3  2
 16   RESOLVE_VAL   r3
 17   RESULT_ROW    r3  1
 18   LEAP_NEXT     d=2  20
 19   GOTO          15
 20   DEPTH_UP      d=2  sid=1
 21   LEAP_NEXT     d=1  23
 22   GOTO          13
 23   DEPTH_UP      d=1  sid=1
 24   DEPTH_UP      d=1  sid=0
 25   LEAP_NEXT     d=0  26
 26   GOTO          10
 27   SCANNER_CLOSE sid=0
 28   SCANNER_CLOSE sid=1
 29   HALT
```

### 9.3 Range Query

```sql
SELECT d1.item.score WHERE d1.item.score >= %1 AND d1.item.score <= %2
-- params: (30, 70)
```

**Range**: converted to interval `[Value(Int64, 30), Value(Int64, 70)]`

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   PARAM         r0  1            r0 = Value(Int64, 30)
  1   PARAM         r1  2            r1 = Value(Int64, 70)
  2   RANGE_ADD     0  r0  r1  0     depth=0, interval [30, 70]
  3   INTERN_A      r2  "item.score"
  4   SCANNER_OPEN  sid=0  cf=1       AEVT
  5   PREFIX_PUSH   sid=0  r2         push attr
  6   DEPTH_ENTER   d=0  sid=0
  7   LEAP_INIT     d=0  14
  8   BIND_GET      r3  0
  9   RESOLVE_VAL   r3
 10   RESULT_ROW    r3  1
 11   LEAP_NEXT     d=0  14
 12   GOTO          8
 13   SCANNER_CLOSE sid=0
 14   HALT
```

Range enforcement happens inside the scanner via range-aware seeking.

### 9.4 SELECT HISTORY (Temporal)

```sql
SELECT HISTORY d1.ns.name WHERE d1.eid = %1
-- params: (1000,)
```

The compiler emits `SCANNER_OPEN` with `p3=1`:

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   PARAM         r0  1            r0 = Value(Int64, 1000)
  1   INTERN_A      r1  "ns.name"
  2   SCANNER_OPEN  sid=0  cf=0  p3=1  EAVT, history mode
  3   PREFIX_PUSH   sid=0  r0
  4   PREFIX_PUSH   sid=0  r1
  5   DEPTH_ENTER   d=0  sid=0       idx_order = [e, a, v, t]
  6   LEAP_INIT     d=0  ...         iterates ALL versions (incl. retracted)
  ...
```

In history mode, the scanner iterates each key individually at the `"t"`
position without filtering retracted datoms.

**Scanner internals:**
- `advance_to_active_at` delegates to `advance_history_each` at the `"t"`
  position — iterates each key individually (no value grouping, no retraction
  filter).
- Non-`"t"` positions group by value but do NOT filter retracted datoms.
- `extract_raw` at the `"added"` position returns `1 - retracted` (1 for
  asserted, 0 for retracted).

**Key suffix format:** `(t, retracted)` encoded as `!((t << 1) | retracted)`
— inverted for descending sort (newest first). `decode_suffix(suffix)` returns
`(t: u64, retracted: bool)`.

**Per-scanner design:** history mode is per-scanner (via `SCANNER_OPEN` p3),
not a global program flag. This enables composition: a normal SELECT can feed
into a HISTORY SELECT within the same program, with each scanner using the
appropriate mode.

### 9.5 v1 vs v2 Comparison

| Aspect | v1 (legacy, no-op) | v2 (current) |
|--------|-------------|---------------|
| Scanner creation | `CURSOR_DECLARE` + `CURSOR_BIND` | `SCANNER_OPEN` + `PREFIX_PUSH` |
| Scanner lifecycle | Created/destroyed per DEPTH_OPEN | Created once, persists |
| DEPTH_OPEN/ENTER | Creates new scanner via FFI | Reads current key, zero FFI |
| DEPTH_UP | Destroys scanner | Keeps scanner alive |
| Extraction position | Fixed per scanner | Dynamic per depth (next free position) |
| Cursor movement | Every depth entry | Only LEAP_NEXT |
| FFI calls | O(depths × entities) | O(1) per clause + O(entities) seeks |

**Measured impact** for `SELECT name WHERE value >= 25 AND value < 75` with
5000 entities:

| Metric | v1 (legacy) | v2 (current) |
|--------|-------------|---------------|
| Scanner creations | 15001 | 2 |
| FFI calls (scan_sources) | 15001 | 2 |
| Total query time | ~1700ms | ~30ms |

---

## 10. DML Statements

### 10.1 UPSERT

```sql
UPSERT SET company.name = 'ACME Corp'
```

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   ALLOC_ENT_P    r0  <partition>  allocate entity
  1   CONST_STR      r1  "company.name"
  2   CONST_STR      r2  "ACME Corp"
  3   EXEC_INSERT    r0  r1  r2  -1   save(entity, attr, value, no ts)
  4   CONST_INT      r3  1            count = 1
  5   RESULT_ROW     r0  2            yield (entity, count)
  6   HALT
```

### 10.2 DELETE

```sql
DELETE WHERE d1.eid = %1 AND d1.ns.name = 'Alice'
```

Uses the triejoin engine to find matching datoms, then emits `EXEC_RETRACT`
for each match.

### 10.3 ATTRIBUTE

```sql
ATTRIBUTE company.name STRING ONE
```

```
addr  opcode                         annotation
────  ─────────────────────────────  ──────────────────────────────────
  0   CONST_STR      r0  "company.name"
  1   EXEC_ATTRIBUTE r0  0            cardinality=ONE
  2   RESULT_ROW     r0  2
  3   HALT
```

---

## 11. EXPLAIN

Running `EXPLAIN SELECT ...` calls the compiler and returns the query plan
traces and compiled VM bytecode as JSON.

```python
rows = list(engine.sql("EXPLAIN SELECT d2.person.name WHERE d1.eid = %1 AND d1.company.partner = d2.eid", 1000))
print("\n".join(row[0] for row in rows))
```

The JSON output includes:
- **Plan traces**: all evaluated variable orderings with cost breakdowns.
- **Instructions**: each instruction as `{"op":"ScannerOpen","p1":0,"p2":0,"p3":0,"p4":null}`.
- **Program metadata**: `num_registers`, `num_vars`, `var_names`, `depth_var`,
  `t_var_ids`, `history`.

---

## 12. Opcode Summary Table

| Category | Opcode | Number | Description |
|----------|--------|--------|-------------|
| **Control** | `Halt` | 0 | Stop execution |
| | `Goto` | 1 | Unconditional jump |
| **Loading** | `Null` | 10 | Set register to None |
| | `Param` | 14 | Load parameter as Value |
| | `ConstInt` | 16 | Load constant integer |
| | `ConstStr` | 17 | Load constant string |
| | `ConstFloat` | 18 | Load constant float |
| | `ConstBool` | 19 | Load constant boolean |
| **Resolution** | `InternA` | 21 | Attr name → ID |
| | `AttrName` | 51 | Attr ID → name string |
| | `ResolveVal` | 52 | Generic value resolution |
| **v1 Cursor (legacy)** | `CursorDeclare` | 62 | No-op (v2 replaces) |
| | `CursorBind` | 63 | No-op (v2 replaces) |
| | `CursorClose` | 66 | No-op (v2 replaces) |
| | `DepthOpen` | 70 | No-op (v2 replaces) |
| **Depth** | `DepthUp` | 71 | Deactivate scanner at depth |
| | `LeapInit` | 72 | Initialize convergence |
| | `LeapNext` | 73 | Advance + converge |
| **Binding** | `BindGet` | 80 | Variable → register |
| | `BindSet` | 81 | Register → variable |
| **Filter** | `RangeAdd` | 91 | Add range interval |
| **Result** | `ResultRow` | 100 | Emit row from registers |
| | `EmitDeclare` | 101 | Initialize emit accumulator |
| | `EmitValue` | 102 | Append to emit accumulator |
| | `EmitEnd` | 103 | Yield accumulated values |
| **Probe** | `ProbeDeclare` | 110 | Initialize probe |
| | `ProbeBind` | 111 | Bind probe position |
| | `ProbeBegin` | 112 | Execute probe |
| | `ProbeGetT` | 113 | Extract probe transaction t |
| **Scan** | `ScanNext` | 121 | Advance full scan |
| **DML** | `ExecInsert` | 140 | Save one datom |
| | `ExecAttribute` | 141 | Register attribute cardinality |
| | `ExecRetract` | 143 | Retract one datom |
| | `LookupEntity` | 144 | Lookup by unique attr |
| | `AllocEntP` | 145 | Allocate entity in partition |
| | `DeclarePartition` | 146 | Declare named partition |
| | `LoadTxEnt` | 147 | Load transaction entity ID |
| **v2 Scanner** | `ScannerOpen` | 200 | Open scanner (p3=history flag) |
| | `PrefixPush` | 201 | Push constant into scanner prefix |
| | `DepthEnter` | 202 | Activate scanner at depth |
| | `ScannerClose` | 203 | Close scanner |

### Removed Opcodes

These opcodes existed in the original Python VM but have been removed from the
Rust implementation:

| Opcode | Reason |
|--------|--------|
| `RESOLVE_E` | Entities are always integers — no name-to-ID resolution at VM level |
| `MAKE_REF` | No REF types in the Value enum |
| `ENTITY_NAME` | Removed — entities are plain integers |
| `FORMAT_TS` | Removed — timestamp formatting handled by Python layer |
| `RAW_INT` | Removed — use `BindGet` with `Int64` values directly |
| `BIND_TS` | Removed |
| `SCAN_OPEN` | Removed — `ScanNext` opens implicitly |
| `SCAN_EXTRACT` | Removed |
| `OPEN_SCAN_DECLARE` | Removed — v2 scanners handle all scan patterns |
| `OPEN_SCAN_SPEC` | Removed |
| `OPEN_SCAN_VAR_ID` | Removed |
| `OPEN_SCAN_BEGIN` | Removed |
| `OPEN_SCAN_NEXT` | Removed |
