# Slot-Based FFI Dispatch

The DynSpire FFI uses a `Vec<u64>` slot model: all parameters and return values
cross the `.so` boundary as a flat array of `u64` words. No byte-level
serialization, no arena allocation.

## Core Concept

The FFI dispatch function receives input as a read-only slice of `u64` slots:

```rust
type FnDispatch = unsafe extern "C" fn(
    state: *mut c_void,
    in_slots: *const u64,
    in_count: usize,
    out_slots: *mut u64,
    out_capacity: usize,
) -> u8;  // 0 = dispatch ok, 1 = transport error
```

Each method encodes its parameters into `in_slots` and decodes its return value
from `out_slots`. The caller allocates both arrays — no spier-side allocation
for the transport itself.

Transport error detail: when the return tag is `1`, `out_slots[0..]` contains
an ownership-transferred `String` (ptr, len). Application-level errors
(`Result::Err`) live in the slot payload — see [Error Handling](#error-handling).

## Input Model

| Rust Type         | Slot Count | Slot Layout             | Semantics         |
|-------------------|------------|-------------------------|-------------------|
| `u32`             | 1          | `[value]`               | Copy (by value)   |
| `u64`             | 1          | `[value]`               | Copy (by value)   |
| `bool`            | 1          | `[0 or 1]`              | Copy (by value)   |
| `[u8; 16]`        | 2          | `[lo_u64, hi_u64]`      | Copy (by value)   |
| `&[u8]`           | 2          | `[ptr, len]`            | Zero-copy borrow  |
| `&str`            | 2          | `[ptr, len]`            | Zero-copy borrow  |
| `&mut Vec<u8>`    | 1          | `[ptr_to_vec]`          | Caller-owned fill |

### Borrows are zero-copy

`&[u8]` passes `(as_ptr(), len)` — the spier reads directly from the caller's
memory. No copy. Safe because all dispatch calls are synchronous; the caller's
data is valid for the entire call duration.

### `&mut` out-params

`&mut Vec<u8>` passes a pointer to the caller's `Vec<u8>`. The spier
dereferences and fills it in-place (`clear()` + `extend_from_slice()`). This
eliminates allocation on hot paths like cursor iteration:

```rust
fn scan_key(cursor: u64, buf: &mut Vec<u8>) -> Result<bool, String>;
```

### Tuple dispatch

`SlotEncode` is implemented for tuples `()`, `(A,)`, `(A, B)`, `(A, B, C)`.
Each element is encoded sequentially. This enables one-liner dispatch:

```rust
self.client.call::<(), _>(TransactorOp::ScanStep as usize, (cid,))
self.client.call::<(), _>(TransactorOp::ScanSeek as usize, (cid, target))
```

## Output Model

Return values always transfer ownership. For owned heap types, the spier
transfers the allocation; the caller assumes ownership.

| Return Type       | Out-Slot Count | Layout                  | Ownership         |
|-------------------|----------------|-------------------------|-------------------|
| `()`              | 0              | —                       | Nothing           |
| `bool`            | 1              | `[value]`               | Copy              |
| `u32`             | 1              | `[value]`               | Copy              |
| `u64`             | 1              | `[value]`               | Copy              |
| `[u8; 16]`        | 2              | `[lo, hi]`              | Copy              |
| `Vec<u8>`         | 2              | `[ptr, len]`            | Transfer (boxed)  |
| `String`          | 2              | `[ptr, len]`            | Transfer (boxed)  |
| `Vec<[u8; 16]>`   | 2              | `[ptr, count]`          | Transfer (boxed)  |
| `Vec<String>`     | 2              | `[ptr, count]`          | Transfer (boxed)  |
| `Vec<Vec<u8>>`    | 2              | `[ptr, count]`          | Transfer (boxed)  |
| `Vec<(A, B)>`     | 2              | `[ptr, count]`          | Transfer (boxed)  |

For boxed-slice returns (`Vec<T>` where `T` is not `u8`): spier calls
`into_boxed_slice()` → `Box::into_raw()` → writes `(ptr, count)` to out-slots.
Caller reconstructs via `Box::from_raw(slice_from_raw_parts_mut(ptr, count))` →
`.into_vec()`.

## Conditional Types (Sum Types)

`Option<T>`, `Result<T, E>`, and enums serialize as a discriminant slot
followed by the active variant's payload.

### Unified Layout

```
[discriminant: u64] [variant payload...]
```

### Option&lt;T&gt;

| Variant   | Discriminant | Payload    |
|-----------|-------------|------------|
| `None`    | 0           | —          |
| `Some(T)` | 1           | T's slots  |

### Result&lt;T, E&gt;

| Variant  | Discriminant | Payload   |
|----------|-------------|-----------|
| `Ok(T)`  | 0           | T's slots |
| `Err(E)` | 1           | E's slots |

Making `Result` a first-class slot type means `E` can be any `SlotReturn` type
(error enum, `u32` code), not just `String`.

### Nesting

Conditional types compose recursively:

```
Option<Result<T, E>>:
  [tag₀: 0=None | 1=Some]
  if Some: [tag₁: 0=Ok | 1=Err] [T or E payload]
```

## Error Handling

Two error levels are cleanly separated:

### Transport errors (dispatch-level)

The `FnDispatch` return `u8` signals transport-level failures only — panics,
null state pointers, ABI mismatches:

```
return 0 → dispatch OK → decode return type from out_slots
return 1 → transport error → out_slots = [err_ptr, err_len]
```

### Application errors (Result in slots)

Application errors live in the slot payload as `Result<T, E>`:

```
u8 = 0, out_slots = [0, ...T-slots...]   // Ok(T)
u8 = 0, out_slots = [1, ...E-slots...]   // Err(E)
```

## Trait System

Input and output are asymmetric — separate traits:

```rust
/// Caller-side: encode Rust value into u64 slots (input params)
trait SlotEncode {
    fn encode(&self, w: &mut SlotWriter);
}

/// Spier-side: decode from u64 slots into Rust value (input params)
trait SlotDecode<'a>: Sized {
    unsafe fn decode(r: &mut SlotReader<'a>) -> Self;
}

/// Spier-side: write return value into out-slots (ownership transfer)
trait SlotReturn: Sized {
    fn into_slots(self, w: &mut SlotWriter);
}

/// Caller-side: read return value from out-slots (take ownership)
trait SlotReceive: Sized {
    unsafe fn from_slots(r: &mut SlotReader) -> Self;
}
```

Tuple impls compose: `(A, B)` encodes `A` then `B` sequentially. All scalar
types, borrows, `Option<T>`, `Result<T, E>` have impls.

## Client Dispatch

Consumers call the IDL trait via the codegen-generated tower client (`Dyn*`
struct). `DynSpireClient::call` provides typed dispatch:

```rust
impl DynSpireClient {
    pub fn call<R: SlotReceive, A: SlotEncode>(
        &self, op: usize, args: A,
    ) -> Result<R, String> {
        let mut w = SlotWriter::new();
        A::encode(&args, &mut w);
        let resp = self.dispatch(op, w.into_slots())?;
        read_response::<Result<R, String>>(&resp)
    }
}
```

The generated tower wraps this in a `dispatch` helper and implements the IDL:

```rust
// Generated by dynspire-codegen
impl BlobStoreEngine for DynSpireBlobStore {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
        // dispatch via self.inner.call(BlobStoreOp::Put as usize, (data,))
    }
}
```

No duplicated `*Client` traits, no blanket impls. Type-checking is enforced
by the single IDL trait on both sides (spier implements, tower dispatches).

## Vec Helper FFI

For foreign callers (Python ctypes), dynspire exports lifecycle helpers that
avoid relying on Rust's `Vec<u8>` internal layout:

```rust
#[repr(C)]
pub struct VecView { pub ptr: *const u8, pub len: usize }

fn dynspire_vec_create() -> *mut Vec<u8>;
fn dynspire_vec_view(v: *const Vec<u8>) -> VecView;
fn dynspire_vec_free(v: *mut Vec<u8>);
fn dynspire_vec_u8_sizeof() -> usize;
```

Proper `Vec::new()` construction, `Drop` destruction, layout-independent field
access via `VecView`. No UB, no leaks, no hardcoded offsets.

## Thread Safety

The IDL interfaces (declared in `.dspi` files) carry no `Send + Sync` bounds —
they describe the protocol, not the threading model. Thread safety is handled
at two levels:

1. **`Arc<Handle>`** in `DynSpireClient`: each instance holds a `Handle` (a
   `*mut c_void` to the spier's state) wrapped in `Arc`. All locking lives in
   the spier implementations, not in the client. `#[concurrent]` and
   `#[exclusive]` annotations on IDL methods are advisory metadata.

2. **Consumer-level bounds**: `GenericPageStore` declares
   `Box<dyn BlobStoreEngine + Send + Sync>` — the constraint travels with the
   trait object, not the `.dspi` interface definition.
