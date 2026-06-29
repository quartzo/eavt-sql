use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

static TRACE_VM: AtomicBool = AtomicBool::new(false);
static TRACE_CURSOR: AtomicBool = AtomicBool::new(false);

static TRACE_INIT: OnceLock<()> = OnceLock::new();

fn ensure_trace_init() {
    TRACE_INIT.get_or_init(|| {
        if let Ok(v) = std::env::var("EAVT_TRACE") {
            let all = v == "all" || v == "1";
            let parts: Vec<&str> = v.split(',').map(|s| s.trim()).collect();
            TRACE_VM.store(all || parts.contains(&"vm"), Ordering::Relaxed);
            TRACE_CURSOR.store(all || parts.contains(&"cursor"), Ordering::Relaxed);
        }
    });
}

pub fn trace_vm() -> bool {
    ensure_trace_init();
    TRACE_VM.load(Ordering::Relaxed)
}

pub fn trace_cursor() -> bool {
    ensure_trace_init();
    TRACE_CURSOR.load(Ordering::Relaxed)
}

// ===========================================================================
// Generated modules (host side from .dspi codegen)
// ===========================================================================

pub mod kvstore {
    use super::transactor::cursor::CursorHandle;
    include!(concat!(env!("OUT_DIR"), "/kvstore_host.rs"));
}

pub mod transactor {
    pub mod cursor;
    pub mod keys;
    pub mod query_codec;
    pub mod resolver_consts;
    pub mod types;

    include!(concat!(env!("OUT_DIR"), "/transactor_host.rs"));

    impl Clone for DynSpireTransactor {
        fn clone(&self) -> Self {
            Self { client: self.client.clone() }
        }
    }

    // Handwritten tower extensions (CompileStats impl, etc.)
    pub mod tower;

    pub use cursor::*;
}

pub mod sql_parse {
    pub mod ast;
    pub use ast::*;

    #[derive(Clone)]
    pub struct RustStmtSt {
        pub stmt: RustStmt,
    }

    include!(concat!(env!("OUT_DIR"), "/sqlparse_host.rs"));

    pub mod tower;
}

pub mod datalog {
    pub mod ast;
    pub use ast::*;

    pub mod resolve;

    use super::sql_parse::RustStmtSt;

    include!(concat!(env!("OUT_DIR"), "/datalog_host.rs"));

    pub mod tower;
}

pub mod planner {
    pub mod ast;
    pub use ast::*;

    use super::datalog::DatalogNumIRSt;

    include!(concat!(env!("OUT_DIR"), "/planner_host.rs"));

    pub mod tower;
}

pub mod sql_frontend {
    use super::sql_parse::RustStmtSt;
    use super::datalog::DatalogIRSt;

    include!(concat!(env!("OUT_DIR"), "/sqlfrontend_host.rs"));

    pub mod tower;
}

pub mod compiler {
    use super::sql_parse::RustStmtSt;
    use super::datalog::DatalogNumIRSt;
    use super::query_ir::VMProgram;
    use super::planner::PlanTrace;

    /// Compiler output — crosses FFI as 1 boxed pointer.
    /// Carries the compiled program and plan traces (for EXPLAIN).
    #[derive(Clone)]
    pub struct CompileResultSt {
        pub program: VMProgram,
        pub traces: Vec<PlanTrace>,
    }

    include!(concat!(env!("OUT_DIR"), "/compiler_host.rs"));

    // Pure Rust trait (not an IDL) — read-only schema/stats abstraction
    // used by the compiler for cost estimation.
    pub trait CompileStats: Send + Sync {
        fn lookup_attr(&self, name: &str) -> Option<u32>;
        fn estimate_index_size(&self, index: &str, bound: &[u64]) -> f64;
        fn partition_id_for(&self, name: &str) -> Option<u64>;
        fn is_ref_attr(&self, attr_name: &str) -> bool;
    }

    pub mod tower;
}

pub mod query_engine {
    use std::cell::RefCell;
    use std::sync::Arc;

    pub trait VMResultStream {
        fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String>;
    }

    #[derive(Clone)]
    pub struct SessionHandle {
        pub session: Arc<RefCell<dyn VMResultStream>>,
    }

    use super::transactor::{Value, ValueType};
    use super::query_ir::ProgramHandle;

    include!(concat!(env!("OUT_DIR"), "/query_host.rs"));
}

// ===========================================================================
// Handwritten modules
// ===========================================================================

pub mod query_ir;
pub mod value;
