# Scheme IR Reference

## 1. Overview

The Scheme IR is an S-expression-based intermediate representation used to compile
and execute all SQL statements. It is the unified compilation target — there is no
VM bytecode path.

### Design Goals

- **Inspectability**: programs are human-readable S-expressions, not opaque bytecode.
- **Debuggability**: `EXPLAIN` and `compile_sql_json` show the full program as text.
- **Serializability**: programs can be round-tripped through `parse`/`write_scheme`.
- **Extensibility**: host functions bridge Scheme to the transactor without changing the evaluator.
- **Unified**: all SQL statements (UPSERT, SELECT, UPDATE, DELETE, ATTRIBUTE, PARTITION) compile to Scheme.

### Crate Structure

| Crate | Role | Dependencies |
|-------|------|-------------|
| `spier-scheme` | AST, parser, printer, evaluator, HostFns trait | zero external |
| `spier-compiler` | `compile_upsert_scheme()`, `compile_select_scheme()`, etc. — SQL AST → `SchemeProgram` | `spier-scheme`, `spier-sql-parse`, `spier-value` |
| `spier-eavt-query` | `SchemeSession`, `SelectSchemeSession`, `SchemeHostFns`, `SelectSchemeHostFns` — runtime execution | `spier-scheme`, `spier-value`, `spier-transactor` |

---

## 2. SExpr Type System

`SExpr` is the core data type. All program text, values, and intermediate results
are represented as `SExpr` values.

### 2.1 Variants

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum SExpr {
    Void,                  // unit / nil
    Bool(bool),            // #t / #f
    Int(i64),              // 64-bit signed integer
    Float(f64),            // 64-bit IEEE float
    Str(String),           // UTF-8 string
    Bytes(Vec<u8>),        // raw bytes (printed as #b"hex")
    Symbol(String),        // identifier / function name
    List(Vec<SExpr>),      // s-expression list
    Resource(Arc<dyn std::any::Any + Send + Sync>),  // opaque resource (e.g., scanner)
}
```

### 2.2 Printing Rules

Each variant renders to text as follows:

| Variant | Output | Example |
|---------|--------|---------|
| `Void` | `#void` | `#void` |
| `Bool(true)` | `#t` | `#t` |
| `Bool(false)` | `#f` | `#f` |
| `Int(v)` | decimal integer | `42`, `-7` |
| `Float(v)` | decimal float | `3.14`, `-0.5` |
| `Str(s)` | `"escaped"` | `"hello \"world\""`, `"line\none"` |
| `Bytes(b)` | `#b"hex"` | `#b"48656c6c6f"` |
| `Symbol(s)` | bare symbol | `company.name`, `D1`, `alloc-entity` |
| `List(items)` | `(item1 item2 ...)` | `(save D1 "name" "Alice")` |
| `Resource(_)` | `#<resource>` | `#<resource>` |

String escaping: `\n` → newline, `\t` → tab, `\\` → backslash, `\"` → double quote.

Pretty-printing (`write_scheme_pretty`): uses a Wadler/Leijen-style algorithm with
`MAX_WIDTH=100`. Sub-expressions that fit within the remaining line budget are
rendered inline; otherwise they break onto a new line (2-space indent per level).

### 2.3 Parsing Rules

The parser (`spier_scheme::parse`) reads a single top-level S-expression:

- **Whitespace**: spaces, tabs, newlines are skipped.
- **Comments**: `;` to end of line is skipped.
- **Lists**: `(` ... `)` — nested, terminated by `)`.
- **Strings**: `"..."` — with escape sequences.
- **Booleans**: `#t` / `#f`.
- **Numbers**: integers (`42`, `-7`) or floats (`3.14`).
- **Symbols**: any non-delimiter characters (e.g., `company.name`, `alloc-entity`, `-1..2`).
- **Hash**: `#` followed by something other than `t`/`f` is a parse error.

Delimiters: whitespace, `(`, `)`, `"`, `;`.

### 2.4 Round-Trip Guarantee

`write_scheme(parse(text)) == text` for well-formed input. The parser rejects
empty input and trailing input after the first expression.

---

## 3. SchemeProgram

```rust
pub struct SchemeProgram {
    pub body: SExpr,          // the root expression to evaluate
    pub param_count: usize,   // number of parameters expected (0-based)
}
```

### 3.1 Construction

```rust
let prog = SchemeProgram::new(body)
    .with_param_count(2);
```

- `SchemeProgram::new(body)` — creates with `param_count: 0`.
- `.with_param_count(n)` — builder, sets the parameter count.
- `.to_string()` — returns `write_scheme(&self.body)`.

### 3.2 Storage

`SchemeProgram` is stored inside `CompiledProgram::Scheme(SchemeProgram)`, which
is wrapped in `Arc<CompiledProgram>` inside `ProgramHandle`.

---

## 4. Special Forms (Evaluator)

The tree-walking evaluator (`spier_scheme::eval`) recognizes 13 special forms.
Special forms do **not** pre-evaluate their arguments — they control evaluation
themselves.

### 4.1 Reference

| Form | Signature | Semantics |
|------|-----------|-----------|
| `let*` | `(let* ((name val) ...) body...+)` | Sequential: each binding sees previous bindings |
| `let` | `(let ((name val) ...) body...+)` | Parallel: all exprs evaluated in parent env, then bound |
| `when` | `(when test body...+)` | If test is truthy, eval body; else `Void` |
| `if` | `(if test then [else])` | If test truthy eval then, else eval else (or `Void`) |
| `begin` | `(begin expr...)` | Sequence, returns last expression |
| `set!` | `(set! name expr)` | Mutate existing binding (error if unbound) |
| `lambda` | `(lambda (params...) body...+)` | Create a closure |
| `print` | `(print [arg...])` | Eval each arg, write them space-separated to stdout + newline, return `Void` |
| `assert` | `(assert cond [msg])` | If falsy, error with message |
| `and` | `(and expr...)` | Evaluate left-to-right; if any falsy, return it (short-circuit); else last value |
| `or` | `(or expr...)` | Evaluate left-to-right; if any truthy, return it (short-circuit); else last value |
| `not` | `(not expr)` | Return `#t` if expr is falsy, `#f` otherwise |
| `depth-run` | `(depth-run (scanners...) ranges (lambda (var) body...))` | Leapfrog triejoin loop — see §11.6 |
| `depth-fixed` | `(depth-fixed (scanners...) value (lambda () body...))` | Fixed prefix scope — see §11.6 |

### 4.2 Examples

```scheme
; Sequential binding — y sees x=1
(let* ((x 1) (y (+ x 1))) y)
; => 2

; Conditional — only runs body if D1 resolved
(when D1 (save D1 "person.name" "Alice"))

; Begin — multiple expressions, last wins
(begin 1 2 3)
; => 3

; Debug — writes to stdout, returns Void
(print "x" (+ 1 2))
; prints: x 3
; => Void

; Logic — and/or short-circuit, return the decisive value
(and 1 2 3)        ; => 3 (last truthy)
(and #t #f)         ; => #f (first falsy)
(or #f #f 5)        ; => 5 (first truthy)
(not 42)            ; => #f (42 is truthy)

; Arithmetic — host functions, variadic with float promotion
(+ 1 2 3)           ; => 6
(+ 1 0.5)           ; => 1.5 (float promotion)
(/ 5 2)             ; => 2.5 (always returns float)
(< 1 2 3)           ; => #t (chain comparison)
(= 1 1.0)           ; => #t (numeric equality)
```

### 4.3 Truthiness

Everything is truthy **except**:
- `Void`
- `Bool(false)`

All other values (including `Int(0)`, `Str("")`, `Bool(true)`) are truthy.

### 4.4 Evaluator Dispatch

For `List(items)` expressions, the evaluator uses a three-way dispatch:

1. **Special form** (`is_special_form(op)`): args are NOT pre-evaluated.
2. **Native function** (`host.is_native(op)`): args ARE pre-evaluated, then `host.call()`.
3. **Default**: first item evaluated (may resolve to a symbol), args evaluated, then
   `eval_apply` re-checks `host.is_native` on the resulting symbol.

Self-evaluating forms (`Void`, `Bool`, `Int`, `Float`, `Str`, `Bytes`) return as-is.
Symbols are looked up in the `Environment` — `Unbound` error if missing.
Empty list `()` returns `Void`.

### 4.5 Environment

```rust
pub struct Environment {
    bindings: HashMap<String, SExpr>,
    pub depth_counter: usize,
}

impl Environment {
    pub fn new() -> Self;                    // empty env
    pub fn define(&mut self, name: String, value: SExpr);  // insert/overwrite
    pub fn get(&self, name: &str) -> Option<&SExpr>;       // lookup
}
```

`depth_counter` is used by the evaluator to assign unique stage keys for
leapfrog triejoin convergence across recursive depth-run calls.

### 4.6 EvalError

```rust
pub enum EvalError {
    Unbound(String),                                    // variable not found
    Arity { name: String, expected: &'static str },     // wrong argument count
    Type { expected: &'static str, got: String },       // wrong type
    NotFound(String),                                   // function not found
    Host(String),                                       // error from host function
    Other(String),                                      // other error
}
```

---

## 5. Host Functions

The `HostFns` trait bridges Scheme to the storage layer. The evaluator dispatches
to host functions when `host.is_native(name)` returns true.

### 5.1 HostFns Trait

```rust
pub trait HostFns {
    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<SExpr, EvalError>;
    fn is_native(&self, name: &str) -> bool;
}
```

- `is_native(name)` — returns true if `name` is a host function.
- `call(name, args)` — dispatches to the implementation. Args are already evaluated.

### 5.2 SchemeTracer Trait

```rust
pub trait SchemeTracer {
    fn trace_eval(&self, _form: &SExpr) {}          // called before eval
    fn trace_result(&self, _form: &SExpr, _result: &SExpr) {} // called after eval
    fn trace_log(&self, _msg: &str) {}              // legacy hook (unused)
    fn is_enabled(&self) -> bool { false }           // short-circuit check
}
```

`NullTracer` implements `SchemeTracer` with all no-ops.

### 5.3 Host Function Reference (SchemeHostFns)

These are the host functions provided by the EAVT query engine:

| Function | Arity | Signature | Description |
|----------|-------|-----------|-------------|
| `alloc-entity` | 0–1 | `(alloc-entity [partition])` | Allocate entity ID in partition (default 4) |
| `tx-entity` | 0 | `(tx-entity)` | Return current transaction entity ID |
| `param` | 1 | `(param idx)` | Get parameter by 1-based index |
| `lookup-entity` | 2 | `(lookup-entity attr value)` | Look up entity by UNIQUE attribute |
| `lookup-value` | 2 | `(lookup-value eid attr)` | Get attribute value for an entity |
| `save` | 3 | `(save eid attr value)` | Persist one datom (entity, attribute, value) |
| `retract` | 3 | `(retract eid attr value)` | Retract one datom |
| `result` | 1+ | `(result eid total)` | Return marker for result emission |
| `declare-attr` | 2–4 | `(declare-attr name type [many?] [unique?])` | Declare a new attribute |
| `declare-partition` | 1 | `(declare-partition name)` | Declare a new partition |

#### `alloc-entity`

```scheme
(alloc-entity)       ; partition defaults to 4
(alloc-entity 4)     ; explicit partition
```

Allocates a fresh entity ID in the given partition via
`transactor.allocate_in_partition(partition)`. Returns `(Int eid)`.

#### `tx-entity`

```scheme
(tx-entity)
```

Returns `(Int tx)` — the current transaction entity ID. No arguments.

#### `param`

```scheme
(param 1)    ; first parameter
(param 2)    ; second parameter
```

1-indexed. Returns `value_to_sexpr(params[idx-1])`. Error if index is 0 or
greater than the parameter count.

#### `lookup-entity`

```scheme
(lookup-entity "company.name" "ACME Corp")
(lookup-entity "person.email" (param 1))
```

Looks up an entity by UNIQUE attribute. Requires the attribute to have
`is_unique_attr` set — returns error otherwise.

- If found: returns `(Int eid)`.
- If not found: returns `Void`.
- On error: propagates `EvalError::Host`.

#### `lookup-value`

```scheme
(lookup-value 42 "person.name")
(lookup-value D1 "company.revenue")
```

Gets the current value of an attribute for an entity. Uses `QueryContext`
with `as_of_tx` (defaults to `u64::MAX` for latest).

- Returns the value as `SExpr` (Int/Float/Str/Bool/Bytes).
- Returns `Void` if the attribute has no value.

#### `save`

```scheme
(save D1 "person.name" "Alice")
(save D1 "company.revenue" 5000000)
```

Persists one datom via `transactor.eavt_save(eid, attr, val, tx, as_of_tx)`.
Returns `Void`. UNIQUEness is checked at this level.

#### `result`

```scheme
(result D1 2)
```

Return marker. Reconstructs the list as `List([Symbol("result"), ...args])`.
This is used by `SchemeSession::next_batch` to detect the result and pack
it into the output buffer.

### 5.4 Arithmetic, Comparison, and Utility Host Functions

These are pure functions (no engine state access):

| Function | Arity | Signature | Description |
|----------|-------|-----------|-------------|
| `+` | 2+ | `(+ a b ...)` | Addition; float promotion if any arg is float |
| `-` | 1+ | `(- a b ...)` | Subtraction (or negation with 1 arg); float promotion |
| `*` | 2+ | `(* a b ...)` | Multiplication; float promotion |
| `/` | 2+ | `(/ a b ...)` | Division; **always returns float** |
| `mod` | 2 | `(mod a b)` | Integer remainder; errors if b=0 |
| `<` | 2+ | `(< a b ...)` | Strict less-than chain; all numeric |
| `>` | 2+ | `(> a b ...)` | Strict greater-than chain |
| `<=` | 2+ | `(<= a b ...)` | Less-or-equal chain |
| `>=` | 2+ | `(>= a b ...)` | Greater-or-equal chain |
| `=` | 2+ | `(= a b ...)` | Numeric equality chain (Int=Float ok) |
| `!=` | 2 | `(!= a b)` | Numeric inequality |
| `min` | 1+ | `(min a b ...)` | Minimum value; float promotion |
| `max` | 1+ | `(max a b ...)` | Maximum value; float promotion |
| `abs` | 1 | `(abs n)` | Absolute value; preserves int/float type |

All numeric hosts compare/converge as `f64` internally. Promotions to
float happen when any argument is a float; otherwise integer arithmetic
is preserved.

### 5.5 Value Conversion: SExpr ↔ Value

**SExpr → Value** (`sexpr_to_value`):

| SExpr variant | Value variant |
|---------------|---------------|
| `Int(n)` | `Value::Int64(n)` |
| `Float(f)` | `Value::Float64(f)` |
| `Str(s)` | `Value::Text(s)` |
| `Bool(b)` | `Value::Bool(b as u8)` |
| `Bytes(b)` | `Value::Bytes(b)` |
| `Void` | `Value::Timestamp(0)` |
| other | Error |

**Value → SExpr** (`value_to_sexpr`):

| Value variant | SExpr variant |
|---------------|---------------|
| `Value::Int64(n)` | `Int(n)` |
| `Value::Float64(f)` | `Float(f)` |
| `Value::Text(s)` | `Str(s)` |
| `Value::Bool(b)` | `Bool(b != 0)` |
| `Value::Timestamp(ts)` | `Int(ts)` |
| `Value::Bytes(b)` | `Bytes(b)` |
| `Value::Unknown(tag, _)` | Error |

---

## 6. SQL → Scheme Compilation (UPSERT)

`compile_upsert_scheme()` translates a parsed `RustUpsertStmt` into a
`SchemeProgram`.

### 6.1 Function Signature

```rust
pub fn compile_upsert_scheme(
    stmt: &RustUpsertStmt,
    params: &[spier_value::Value],
) -> Result<SchemeProgram, String>
```

### 6.2 Input Structure

```rust
pub struct RustUpsertStmt {
    pub clauses: Vec<RustUpsertClause>,
}

pub struct RustUpsertClause {
    pub alias: Option<String>,           // explicit alias (e.g., "D1") or auto-generated
    pub entity_ref: UpsertEntityRef,     // how to resolve the entity
    pub values: Vec<RustInsertValue>,    // attribute-value pairs
}

pub struct RustInsertValue {
    pub attr: String,                    // attribute name (e.g., "person.name")
    pub value: RustValue,                // value expression
}
```

### 6.3 Entity Reference Compilation

| `UpsertEntityRef` variant | Scheme output | Notes |
|---|---|---|
| `New` | `(alloc-entity 4)` | Allocates in default partition (4) |
| `Tx` | `(tx-entity)` | Returns current tx entity |
| `ExplicitEid(idx)` | `(param idx)` | 1-indexed parameter; error if out of range |
| `Lookup { attr, value }` | `(lookup-entity attr-expr value-expr)` | UNIQUE check required |

### 6.4 Value Compilation

| `RustValue` variant | Scheme output | Notes |
|---|---|---|
| `Literal(lit)` | literal SExpr (Int/Float/Str/Bool) | Bytes not supported |
| `Param(idx)` | `(param idx)` | 1-indexed parameter |
| `AliasRef(name)` | bare `Symbol(name)` | references another clause's entity |
| `EidLookup { attr, value }` | `(lookup-entity attr-expr value-expr)` | nested entity lookup |
| `ValLookup { entity, attr }` | `(lookup-value entity-expr attr-expr)` | nested value lookup |

### 6.5 Nullable Alias Guarding

Any clause whose `entity_ref` is `UpsertEntityRef::Lookup { .. }` has its
alias added to `nullable_aliases`. The final `(result ...)` expression is
wrapped in nested `(when alias ...)` forms, one per nullable alias in
reverse order.

This ensures the result is only emitted if all looked-up entities resolved
to non-`Void` values.

```scheme
; If nullable_aliases = ["D2", "D3"]:
(when D2 (when D3 (result D1 total)))
```

If `nullable_aliases` is empty, the result is emitted unconditionally.

### 6.6 Generated Program Structure

```scheme
(let* ((D1 (alloc-entity 4))        ; bindings for each clause
       (D2 (lookup-entity "company.name" "ACME")))
  (when D1                          ; guard per clause
    (save D1 "person.name" "Alice"))
  (when D2 (begin                   ; multi-value clause → begin
    (save D2 "company.revenue" 1000)
    (save D2 "company.employees" 50)))
  (when D2                          ; guarded result if nullable
    (result D1 3)))                 ; total_values = count of all saves
```

### 6.7 Worked Examples

**Simple INSERT:**

```sql
UPSERT AS D1 SET company.name = 'ACME Corp'
```

```scheme
(let* ((D1 (alloc-entity 4)))
  (when D1
    (save D1 "company.name" "ACME Corp"))
  (result D1 1))
```

**INSERT with params:**

```sql
UPSERT AS D1 = %1 SET person.age = %2
```

```scheme
(let* ((D1 (param 1)))
  (when D1
    (save D1 "person.age" (param 2)))
  (result D1 1))
```

**Multi-clause with alias ref:**

```sql
UPSERT AS D1 SET person.name = 'Alice',
     AS D2 SET company.ceo = d1
```

```scheme
(let* ((D1 (alloc-entity 4))
       (D2 (alloc-entity 4)))
  (when D1
    (save D1 "person.name" "Alice"))
  (when D2
    (save D2 "company.ceo" D1))
  (result D1 2))
```

**INSERT with entity lookup (nullable):**

```sql
UPSERT AS D1 SET person.name = 'Alice',
     AS D2 WHERE eid('company.name', 'ACME') SET company.ceo = d1
```

```scheme
(let* ((D1 (alloc-entity 4))
       (D2 (lookup-entity "company.name" "ACME")))
  (when D1
    (save D1 "person.name" "Alice"))
  (when D2
    (save D2 "company.ceo" D1))
  (when D2
    (result D1 2)))
```

**INSERT with value lookup:**

```sql
UPSERT AS D1 = %1 SET person.age = val(eid('company.name', 'ACME'), 'company.revenue')
```

```scheme
(let* ((D1 (param 1)))
  (when D1
    (save D1 "person.age"
      (lookup-value (lookup-entity "company.name" "ACME")
                    "company.revenue")))
  (result D1 1))
```

---

## 7. Scheme Execution Runtime

### 7.1 Streaming Model: EvalStep + YieldState

The evaluator operates one step at a time via `EvalStep` and yields control
with `YieldState`:

```rust
pub enum EvalStep {
    Done(SExpr),           // evaluation complete
    Yield(SExpr, Box<EvalStep>),  // yield value, resume with next step
}

pub enum YieldState {
    Return(SExpr),         // final result (no more to yield)
    Suspend(SExpr, Box<dyn FnOnce() -> EvalStep>),  // yield value, continuation
}
```

The evaluator per-forms a single step (`EvalStep`) then yields (`YieldState::Return`
or `YieldState::Suspend`). `next_batch` resumes from the suspension point until
`max_rows` rows are produced or the program completes.

### 7.2 SchemeSession (UPSERT / DML)

`SchemeSession` implements `VMResultStream` for non-streaming DML (UPSERT,
ATTRIBUTE, PARTITION, direct DELETE).

```rust
pub struct SchemeSession {
    program: SchemeProgram,
    engine: Arc<QueryEngineInner>,
    params: Vec<Value>,
    tx: u64,
    as_of_tx: Option<u64>,
    done: bool,
}
```

**Constructor:**

```rust
SchemeSession::new(program, engine, params, tx, as_of_tx)
```

### 7.3 VMResultStream Implementation (SchemeSession)

`SchemeSession::next_batch(out, max_rows) -> Result<bool, String>`:

1. If `done` or `max_rows == 0`: return `Ok(false)`.
2. Create `SchemeHostFns`, `Environment::new()`, `NullTracer`.
3. Call `eval(&self.program.body, &mut env, &mut host, &tracer)`.
4. Match result: if `List([Symbol("result"), eid, total])`:
   - Write `[u32: 2]` (num_cols = 2)
   - Encode `eid` and `total` via `query_codec::encode_one`.
5. Set `done = true`, return `Ok(false)` (no more batches).

**Result packing format:**

```
[u32 num_cols = 2]
[encoded eid]
[encoded total_values]
```

### 7.4 SchemeHostFns Architecture

```rust
struct SchemeHostFns<'a> {
    engine: Arc<QueryEngineInner>,
    params: &'a [Value],
    tx: u64,
    as_of_tx: u64,
}
```

Implements `spier_scheme::HostFns`. The 7 host functions (section 5.3) are
dispatched in `call()`.

### 7.5 Integration in `spier-eavt-query`

`Program::Scheme` is handled in:

| Function | Behavior |
|----------|----------|
| `execute` | Allocates tx, creates `SchemeSession`, calls `next_batch`, returns packed bytes |
| `open_cursor` | Creates `SchemeSession` or `SelectSchemeSession`, wraps in `Arc<RefCell<dyn VMResultStream>>` |
| `explain` | Returns `spier_scheme::write_scheme_pretty(&p.body)` (pretty-printed S-expression) |
| `compile_sql_json` | Returns `spier_scheme::write_scheme(&p.body)` (compact S-expression) |

---

## 8. Integration Points

### 8.1 Program Enum

```rust
pub enum Program {
    Scheme(SchemeProgram),
    SelectScheme(SchemeProgram, SelectSchemeMeta),
}
```

Stored as `Arc<Program>` in `ProgramHandle`.

### 8.2 Compilation Dispatch

In `compile_dml_direct`:

```rust
RustStmt::Upsert(upsert_stmt) => {
    let scheme = scheme_compile::compile_upsert_scheme(&upsert_stmt, &params)?;
    Ok(Program::Scheme(scheme))
}
```

SELECT/UPDATE/DELETE produce `Program::SelectScheme(...)` via `compile_select_scheme()`,
`compile_update_scheme()`, `compile_delete_scheme()`.

### 8.3 Execution Dispatch

In `do_compile`, UPSERT goes through `compile_dml_direct` → `Program::Scheme`.
The `execute` / `open_cursor` functions match on the enum:

```rust
Program::Scheme(scheme_prog) => {
    let mut session = SchemeSession::new(scheme_prog, engine, params, tx, as_of_tx);
    // ... call next_batch or wrap in VMResultStream ...
}
Program::SelectScheme(scheme_prog, meta) => {
    let host = SelectSchemeHostFns::new(engine, params, tx, as_of_tx, ...);
    let mut session = SelectSchemeSession::new(scheme_prog, host);
    // ...
}
```

---

## 9. Debugging

### 9.1 EXPLAIN Output

`EXPLAIN UPSERT ...` returns the Scheme S-expression:

```python
rows = list(engine.sql("EXPLAIN UPSERT AS D1 SET company.name = 'ACME'"))
# row[0] contains the Scheme text
```

Output:

```scheme
(let* ((D1 (alloc-entity 4))) (when D1 (save D1 "company.name" "ACME")) (result D1 1))
```

### 9.2 compile_sql_json Output

`compile_sql_json` returns the Scheme text for UPSERT (not JSON), since the
Scheme S-expression is the program representation:

```python
text = engine.compile_sql_json("UPSERT AS D1 SET company.name = 'ACME'")
# text = "(let* ((D1 (alloc-entity 4))) (when D1 (save D1 \"company.name\" \"ACME\")) (result D1 1))"
```

### 9.3 Debug Primitives

The evaluator supports two debug primitives (special forms):

```scheme
; print — write to stdout
(print "label" expr)   ; prints: label <value>
(print)                ; prints empty line
(print 1 2 3)          ; prints: 1 2 3
; always returns #void

; assert — runtime assertion
(assert cond)          ; error if falsy
(assert cond "msg")    ; error with message if falsy
```

`print` writes directly to stdout via `println!` and flushes. `assert`
raises `EvalError::Other("assertion: <msg>")` when the condition is
falsy.

---

## 10. Complete Example: End-to-End

### SQL

```sql
UPSERT AS D1 SET person.name = 'Alice', person.age = %1,
     AS D2 WHERE eid('company.name', 'ACME') SET company.ceo = d1
```

### Compiled Scheme

```scheme
(let* ((D1 (alloc-entity 4))
       (D2 (lookup-entity "company.name" "ACME")))
  (when D1
    (begin
      (save D1 "person.name" "Alice")
      (save D1 "person.age" (param 1))))
  (when D2
    (save D2 "company.ceo" D1))
  (when D2
    (result D1 3)))
```

### Execution Trace

1. `(alloc-entity 4)` → D1 = 1001
2. `(lookup-entity "company.name" "ACME")` → D2 = 42
3. `(when D1 ...)` → D1 is truthy (Int(1001)), so:
   - `(save 1001 "person.name" "Alice")` → persisted
   - `(save 1001 "person.age" (param 1))` → param resolved, persisted
4. `(when D2 ...)` → D2 is truthy (Int(42)), so:
   - `(save 42 "company.ceo" 1001)` → persisted
5. `(when D2 (result D1 3))` → D2 is truthy, so:
   - `(result 1001 3)` → result marker
6. `SchemeSession::next_batch` matches `List([Symbol("result"), Int(1001), Int(3)])`
7. Output buffer: `[0x00000002][encoded 1001][encoded 3]`

### Lookup Not Found

If `(lookup-entity "company.name" "NOPE")` returns `Void`:

- D2 = `Void`
- `(when D2 ...)` → skipped (Void is falsy)
- `(when D2 (result D1 3))` → skipped
- Result: empty (no output in buffer)

This is the nullable alias guard — if any looked-up entity is not found,
the entire statement produces no result.

---

## 11. SELECT via Scheme

SELECT compiles to `Program::SelectScheme(SchemeProgram, SelectSchemeMeta)` with
a triejoin skeleton built from three layers:

1. **Scanner setup** — `(let* ((s0 (scanner-open INDEX)) ...))`
2. **Fixed prefix** — `(depth-fixed (s) value (lambda () body))` for bound attributes
3. **Triejoin nesting** — `(depth-run (scanners) ranges (lambda (var) body))`

### 11.1 Triejoin Skeleton Structure

```
(let* ((s0 (scanner-open "INDEX_NAME" [history?])) ...)
  (depth-fixed (s0) bound-value
    (lambda ()
      (depth-run (s0 s1) (and (>= val) (< val))
        (lambda (depth_var)
          (depth-run (s1) ()
            (lambda (depth_var)
              (result-row (resolve-val depth_var) ...))))))))
```

### 11.2 Projected Result Row

```scheme
(result-row _vv_d1 (attr-name _aid) (resolve-val _v_d1_bench_value) ...)
```

Each `depth-run` lambda parameter binds a variable at that depth. Projections
reference these variables directly — no `bind-get` indirection needed:

| Helper | Usage | Description |
|--------|-------|-------------|
| `attr-name` | `(attr-name aid-var)` | Resolve attribute ID to its name string |
| `resolve-val` | `(resolve-val raw-var)` | Decode a raw value using the attribute's type |
| `probe-begin` | `(probe-begin eid aid value)` | Start a fully-bound probe lookup (eid, attr, value) |

### 11.3 Range Trees

Ranges are passed as boolean trees directly to `depth-run`:

| Operator | Usage | Description |
|----------|-------|-------------|
| `and` | `(and (>= val) (< val))` | Conjunction |
| `or` | `(or (branch) (branch))` | Disjunction |
| `branch` | `(branch)` | OR branch separator |
| `=` | `(= val)` | Equality |
| `!=` | `(!= val)` | Inequality |
| `>` | `(> val)` | Greater than |
| `>=` | `(>= val)` | Greater than or equal |
| `<` | `(< val)` | Less than |
| `<=` | `(<= val)` | Less than or equal |

### 11.4 Example: Simple SELECT

```sql
SELECT eid, company.name
FROM company
WHERE company.ceo = %1
```

```scheme
(let* ((s0 (scanner-open "AEVT")))
  (depth-fixed (s0) (intern-a "company.ceo")
    (lambda ()
      (depth-run (s0) ()
        (lambda (_e_d1)
          (result-row _e_d1 (attr-name (intern-a "company.name"))))))))
```

### 11.5 Example: Range SELECT (the motivating example)

```sql
SELECT d1.val WHERE d1.bench.value >= %1 AND d1.bench.value < %2
```

```scheme
(let* ((s0 (scanner-open "AVET")) (s1 (scanner-open "AEVT")))
  (depth-fixed (s1) (intern-a "bench.value")
    (lambda ()
      (depth-run (s0) ()
        (lambda (_skip_a_avet)
          (depth-run (s0) ()
            (lambda (_vv_d1)
              (depth-run (s0 s1) ()
                (lambda (_e_d1)
                  (depth-run (s1) (and (>= (param 1)) (< (param 2)))
                    (lambda (_v_d1_bench_value)
                      (result-row (resolve-val _vv_d1)))))))))))))
```

### 11.6 Special Forms for Scanning

#### `depth-run`

```
(depth-run (scanner-refs...) range-tree (lambda (var) body...))
```

Internal host call sequence (per iteration):
1. `(scanner-init scanner var-id)` — for each scanner
2. `(scheme-leap-init stage-key scanner0 scanner1 ... ranges)` — converge
3. `(scanner-read scanner)` — read current value, bind to lambda param
4. Execute body (may call `result-row`, `save`, `retract`, etc.)
5. `(scheme-leap-next stage-key scanner0 scanner1 ... ranges)` — advance
6. `(depth-cleanup scanner)` — for each scanner, when loop ends

All host calls are made internally by the evaluator — the generated Scheme
only shows `(depth-run (s0 s1) (and (>= (param 1)) (< (param 2))) (lambda (_v) ...))`.

#### `depth-fixed`

```
(depth-fixed (scanner-refs...) value-expr (lambda () body...))
```

Internal host call sequence:
1. `(depth-fixed-begin scanner0 ... value)` — push prefix onto each scanner
2. Execute body
3. `(depth-fixed-end scanner0 ...)` — pop prefix from each scanner

This replaces manual `prefix-push`/`pop` and ensures proper scoping of
prefix bindings on scanner cursors.

---

## 12. DELETE via Scheme

DELETE compiles to a triejoin skeleton identical to SELECT, but with `retract`
calls in the leaf body and a `result-row` yielding the entity ID.

```scheme
(let* ((s0 (scanner-open "AEVT")))
  (depth-fixed (s0) (intern-a "person.name")
    (lambda ()
      (depth-run (s0) ()
        (lambda (_e_d1)
          (begin
            (retract _e_d1 "person.name" "Alice")
            (result-row _e_d1)))))))
```

Direct DELETE (eid condition) compiles to `Program::Scheme` without scanning:

```scheme
(begin
  (retract 42 "person.name" "Alice")
  (result 42))
```

---

## 13. UPDATE via Scheme

UPDATE compiles to a triejoin skeleton with `save` calls in the leaf body
and a `result-row` yielding the entity ID.

```scheme
(let* ((s0 (scanner-open "AEVT")))
  (depth-fixed (s0) (intern-a "person.age")
    (lambda ()
      (depth-run (s0) ()
        (lambda (_e_d1)
          (begin
            (save _e_d1 "person.age" 30)
            (save _e_d1 "person.city" "NYC")
            (result-row _e_d1)))))))
```

---

## 14. ATTRIBUTE/PARTITION via Scheme

These are direct DML statements compiled to `Program::Scheme`.

### ATTRIBUTE

```scheme
(begin
  (declare-attr "person.age" "LONG" #f #f)
  (result "person.age" "LONG"))
```

### PARTITION

```scheme
(let* ((pid (declare-partition "my-partition")))
  (result pid))
```

---

## 15. SelectSchemeHostFns Reference (18 functions)

These host functions are used by `SelectSchemeSession` for scanning operations.
Some are called **directly** in generated Scheme; others are called **internally**
by the `depth-run` and `depth-fixed` special forms.

### 15.1 Directly Called in Generated Scheme

| # | Function | Signature | Description |
|---|----------|-----------|-------------|
| 1 | `scanner-open` | `(scanner-open index-name [history?])` | Open a scanner on an index (name: `"EAVT"`, `"AEVT"`, `"AVET"`, `"VAET"`). Returns an opaque `Resource` |
| 2 | `prefix-push` | `(prefix-push scanner value pos-name)` | Push a bound prefix value at a named position (`"e"`, `"a"`, `"v"`, `"t"`) |
| 3 | `intern-a` | `(intern-a attr-name)` | Resolve attribute name string to integer ID |
| 4 | `attr-name` | `(attr-name aid)` | Resolve attribute ID integer to name string |
| 5 | `resolve-val` | `(resolve-val value)` | Pass-through identity for values (placeholder for type-aware decoding) |
| 6 | `param` | `(param idx)` | Get parameter by 1-based index |
| 7 | `probe-begin` | `(probe-begin eid aid value)` | Perform a point lookup via EAVT probe. Returns `Int(tx-eid)` if found, `Void` if not |
| 8 | `save` | `(save eid attr value)` | Persist one datom (used in UPDATE) |
| 9 | `retract` | `(retract eid attr value)` | Retract one datom (used in DELETE) |
| 10 | `result-row` | `(result-row val...)` | Emit a result row via `EvalStep::Yield` |

### 15.2 Called Internally by `depth-run` / `depth-fixed`

These are **not** written directly in generated Scheme — the evaluator calls them
when executing the `depth-run` and `depth-fixed` special forms:

| # | Function | Signature | Description |
|---|----------|-----------|-------------|
| 11 | `scanner-init` | `(scanner-init scanner var-id)` | Initialize scanner for a depth-run stage: open cursor, build prefix, advance to first key |
| 12 | `scanner-read` | `(scanner-read scanner)` | Read the current value from the scanner's position |
| 13 | `scheme-leap-init` | `(scheme-leap-init stage-key scanners... ranges)` | Initialize leapfrog convergence across scanners. Returns `#t` if converged, `#f` if no rows |
| 14 | `scheme-leap-next` | `(scheme-leap-next stage-key scanners... ranges)` | Advance the minimum scanner and re-converge. Returns `#t` if new row, `#f` if exhausted |
| 15 | `depth-cleanup` | `(depth-cleanup scanner)` | Pop scanner's position stack after a depth-run completes |
| 16 | `depth-fixed-begin` | `(depth-fixed-begin scanners... value)` | Push a fixed value as a prefix position onto each scanner |
| 17 | `depth-fixed-end` | `(depth-fixed-end scanners...)` | Pop the prefix from each scanner |

### 15.3 Shared Functions

`save`, `retract`, `param` are shared with `SchemeHostFns` (section 5.3).
`alloc-entity`, `tx-entity`, `lookup-entity`, `lookup-value` are available in
`SelectSchemeHostFns` but rarely used in scan contexts (they exist for
UPDATE/DELETE with nested lookups).

---

## 16. Streaming Model (EvalStep / YieldState / next_batch)

### 16.1 EvalStep Enum

```rust
pub enum EvalStep {
    Done(SExpr),
    Yield(SExpr),
}
```

The evaluator runs in a loop: each call to `eval_with_yield` returns one
`EvalStep`. `Yield(SExpr)` means a result row was produced; `Done(SExpr)`
means the program completed.

### 16.2 YieldState Struct

```rust
pub struct YieldState {
    stack: Vec<Frame>,
    depth_runs: Vec<DepthRunFrame>,
    started: bool,
}
```

`YieldState` holds the evaluator's continuation frames across calls. It is
passed as `Some(&mut state)` to `eval_with_yield`. On the first call, the
evaluator runs from the start; on subsequent calls, it resumes from the
saved `stack` and `depth_runs` state — no closures or boxed continuations.

`DepthRunFrame` preserves the leapfrog triejoin state across yield/resume:

```rust
pub struct DepthRunFrame {
    pub stage_key: i64,
    pub scanner_configs: Vec<SExpr>,
    pub body: Vec<SExpr>,
    pub captured_env: HashMap<String, SExpr>,
    pub phase: DepthRunPhase,
    pub param_name: Option<String>,
    pub ranges: SExpr,
}
```

### 16.3 next_batch Flow

`SelectSchemeSession::next_batch(out, max_rows)`:

1. Pass `self.state` (the `YieldState`) as `Some(&mut state)` to `eval_with_yield`.
2. Loop: on each `EvalStep::Yield(sexpr_row)`, decode the `result-row` contents,
   encode them into the output buffer, and increment row count.
3. When `max_rows` rows are collected, return `Ok(true)` (more available).
4. When `EvalStep::Done` is reached, mark `done = true` and return `Ok(false)`.
5. On the next call, `eval_with_yield` resumes from the saved `YieldState`.

### 16.4 Cursor Transport

`open_cursor` returns a `SessionHandle` (`Arc<RefCell<dyn VMResultStream>>`).
The caller calls `session_next_batch(handle, max_rows)` repeatedly until
empty batch is returned. Cleanup is automatic via Arc refcount + Drop.

---

## 17. Limitations

### Current Scope

- All SQL statements compile to Scheme IR (no VM bytecode).
- `Bytes` literal values are not supported in UPSERT compilation.
- The evaluator is single-threaded and synchronous.
- No user-defined functions — all functions are host-provided.

### Future Extensions

- Debug-instrumented scripts via gRPC (client edits Scheme, sends back for execution).
- Prepared statement cache for SchemeProgram (immutable, cloneable).
