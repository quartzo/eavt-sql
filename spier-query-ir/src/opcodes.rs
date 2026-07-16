use std::sync::Arc;

// RangeOp op constants (RangeOp instruction p2 field)
pub const RANGE_OP_EQ: i32 = 0;
pub const RANGE_OP_NEQ: i32 = 1;
pub const RANGE_OP_GT: i32 = 2;
pub const RANGE_OP_GTE: i32 = 3;
pub const RANGE_OP_LT: i32 = 4;
pub const RANGE_OP_LTE: i32 = 5;
pub const RANGE_OP_IN: i32 = 6;

/// Metadata for a Scheme-based SELECT program.
#[derive(Clone)]
pub struct SelectSchemeMeta {
    pub num_vars: usize,
    pub depth_var_pairs: Vec<(usize, usize)>,
    pub same_var_constraints: Vec<(i32, Vec<(usize, usize)>)>,
}

/// A compiled program: a Scheme AST program (UPSERT/DML) or a
/// Scheme-based SELECT program with triejoin metadata.
#[derive(Clone)]
pub enum Program {
    Scheme(spier_scheme::SchemeProgram),
    SelectScheme(spier_scheme::SchemeProgram, SelectSchemeMeta),
}

/// Shared, refcounted handle to a compiled program.
///
/// Cloning is a cheap `Arc` clone, so it is safe to pass as a by-value
/// parameter on every `execute` call (e.g. prepared statements). There is no
/// `free_program` — the `Arc` refcount + `Drop` handle cleanup automatically.
#[derive(Clone)]
pub struct ProgramHandle {
    pub program: Arc<Program>,
}
