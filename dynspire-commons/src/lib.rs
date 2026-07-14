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
// Handwritten trait modules
// ===========================================================================

// Storage-layer traits.
pub mod blobstore {
    pub trait BlobStoreEngine: Send + Sync {
        fn put(&self, data: &[u8]) -> Result<[u8; 16], String>;
        fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String>;
        fn delete(&self, id: [u8; 16]) -> Result<(), String>;
        fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String>;
        fn list(&self) -> Result<Vec<[u8; 16]>, String>;
        fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String>;
        fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String>;
        fn list_roots(&self) -> Result<Vec<String>, String>;
        fn delete_root(&self, name: &str) -> Result<(), String>;
    }
}

pub mod journal {
    pub trait JournalEngine: Send + Sync {
        fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
        fn journal_read(&self) -> Result<Vec<u8>, String>;
        fn journal_truncate(&self) -> Result<(), String>;
    }
}

pub mod memtable {
    use std::sync::Arc;

    #[derive(Clone)]
    pub struct MemTableSnapshot {
        pub data: Arc<dyn std::any::Any + Send + Sync>,
    }

    pub trait MemTableEngine: Send + Sync {
        fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String>;
        fn batch_write(&self, ops: &[u8]) -> Result<u64, String>;
        fn clear(&self) -> Result<(), String>;
        fn snapshot(&self) -> Result<MemTableSnapshot, String>;
        fn scan_prefix(&self, snap: MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn scan_prefix_reverse(&self, snap: MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn contains(&self, snap: MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String>;
    }
}

pub mod kvstore {
    use super::transactor::cursor::CursorHandle;

    pub trait KVStoreEngine: Send + Sync {
        fn put(&self, cf: u32, key: &[u8]) -> Result<(), String>;
        fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
        fn batch_write(&self, ops: &[u8]) -> Result<(), String>;
        fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
        fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String>;
        fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn items(&self, cf: u32) -> Result<Vec<u8>, String>;
        fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
        fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
        fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String>;
        fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String>;
        fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String>;
        fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String>;
        fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String>;
        fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String>;
        fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
        fn journal_scan(&self) -> Result<Vec<u8>, String>;
        fn journal_size(&self) -> Result<u64, String>;
        fn memtable_size(&self) -> Result<u64, String>;
        fn memtable_count(&self, cf: u32) -> Result<u64, String>;
        fn path(&self) -> Result<String, String>;
        fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String>;
        fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
        fn db_stats(&self) -> Result<Vec<u8>, String>;
        fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
        fn internal_status(&self, target: &str) -> Result<String, String>;
        fn flush(&self) -> Result<(), String>;
        fn close(&self) -> Result<(), String>;
    }
}

pub mod transactor {
    pub mod cursor;
    pub mod keys;
    pub mod query_codec;
    pub mod resolver_consts;
    pub mod stats;
    pub mod types;

    #[derive(Clone, Debug, PartialEq)]
    pub enum Value {
        Text(String),
        Bytes(Vec<u8>),
        Bool(u8),
        Int64(i64),
        Float64(f64),
        Timestamp(i64),
        Unknown(i8, u64),
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub enum ValueType {
        String,
        Ref,
        Long,
        Keyword,
        Boolean,
        Instant,
        Bytes,
        Float,
        Blob,
    }

    pub trait TransactorEngine: Send + Sync {
        // KV methods
        fn put(&self, cf: u32, key: &[u8]) -> Result<(), String>;
        fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
        fn batch_write(&self, ops: &[u8]) -> Result<(), String>;
        fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
        fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String>;
        fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
        fn items(&self, cf: u32) -> Result<Vec<u8>, String>;
        fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
        fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
        fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String>;
        fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String>;
        fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String>;
        fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String>;
        fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String>;
        fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String>;
        fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
        fn journal_scan(&self) -> Result<Vec<u8>, String>;
        fn journal_size(&self) -> Result<u64, String>;
        fn memtable_size(&self) -> Result<u64, String>;
        fn memtable_count(&self, cf: u32) -> Result<u64, String>;
        fn path(&self) -> Result<String, String>;
        fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String>;
        fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
        fn db_stats(&self) -> Result<Vec<u8>, String>;
        fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
        fn internal_status(&self, target: &str) -> Result<String, String>;
        fn flush(&self) -> Result<(), String>;
        fn close(&self) -> Result<(), String>;

        // EAVT methods
        fn eavt_save(&self, e_id: u64, attr: &str, v: Value, t: u64, as_of_us: u64) -> Result<(), String>;
        fn eavt_retract(&self, e_id: u64, attr: &str, v: Value, current_t: u64, as_of_us: u64) -> Result<(), String>;
        fn eavt_declare_attr(&self, name: &str, value_type: ValueType, many: bool, current_t: u64) -> Result<u32, String>;
        fn eavt_declare_attr_from_sql(&self, attr: &str, type_name: &str, many: bool, unique: bool, current_t: u64) -> Result<(), String>;
        fn eavt_declare_partition(&self, name: &str, current_t: u64) -> Result<u64, String>;
        fn eavt_allocate_tx(&self) -> Result<u64, String>;
        fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String>;
        fn is_declared(&self, aid: u32) -> Result<bool, String>;
        fn attr_name(&self, aid: u32) -> Result<String, String>;
        fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String>;
        fn is_many(&self, aid: u32) -> Result<bool, String>;
        fn is_unique(&self, aid: u32) -> Result<bool, String>;
        fn is_unique_attr(&self, name: &str) -> Result<bool, String>;
        fn default_user_partition(&self) -> Result<u64, String>;
        fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String>;
        fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String>;
        fn allocate_entity_id(&self) -> Result<u64, String>;
        fn allocate_in_partition(&self, partition_id: u64) -> Result<u64, String>;
        fn allocate_t(&self) -> Result<u64, String>;
    }

    pub use cursor::*;
}

pub mod sql_parse {
    pub mod ast;
    pub use ast::*;

    #[derive(Clone)]
    pub struct RustStmtSt {
        pub stmt: RustStmt,
    }

    pub trait SqlParseEngine: Send + Sync {
        fn parse(&self, sql: &str) -> Result<RustStmtSt, String>;
        fn parse_json(&self, sql: &str) -> Result<String, String>;
    }
}

pub mod datalog {
    pub mod ast;
    pub use ast::*;

    pub mod resolve;

    use super::sql_parse::RustStmtSt;

    pub trait DatalogEngine: Send + Sync {
        fn build(&self, stmt: RustStmtSt, params: &[u8]) -> Result<DatalogIRSt, String>;
        fn to_string(&self, ir: DatalogIRSt) -> Result<String, String>;
    }
}

pub mod planner {
    pub mod ast;
    pub use ast::*;

    use super::datalog::DatalogNumIRSt;

    pub trait PlannerEngine: Send + Sync {
        fn plan(&self, ir: DatalogNumIRSt) -> Result<QueryPlanSt, String>;
        fn to_string(&self, plan: QueryPlanSt) -> Result<String, String>;
    }
}

pub mod sql_frontend {
    use super::sql_parse::RustStmtSt;
    use super::datalog::DatalogIRSt;

    pub trait SqlFrontendEngine: Send + Sync {
        fn parse(&self, sql: &str) -> Result<RustStmtSt, String>;
        fn build_datalog(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<DatalogIRSt, String>;
    }
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

    pub trait CompilerEngine: Send + Sync {
        fn compile_select(&self, num_ir: DatalogNumIRSt) -> Result<CompileResultSt, String>;
        fn compile_dml_scan(
            &self,
            stmt: RustStmtSt,
            num_ir: DatalogNumIRSt,
            sql_params: &[u8],
        ) -> Result<CompileResultSt, String>;
        fn compile_dml_direct(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<CompileResultSt, String>;
    }

    pub mod stats;
    pub use stats::CompileStats;
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

    // Concrete VMResultStream implementations are thread-local-free; this lets
    // PyO3 bindings release the GIL around streaming operations.
    unsafe impl Send for SessionHandle {}

    use super::transactor::{Value, ValueType};
    use super::query_ir::ProgramHandle;

    pub trait QueryEngine: Send + Sync {
        fn compile_sql(&self, sql: &str, sql_params: &[u8]) -> Result<ProgramHandle, String>;
        fn run_vm(&self, program: ProgramHandle, sql_params: &[u8], limit: u64, as_of_us: u64) -> Result<Vec<u8>, String>;
        fn run_vm_cursor(&self, program: ProgramHandle, sql_params: &[u8], limit: u64, as_of_us: u64) -> Result<SessionHandle, String>;
        fn session_next_batch(&self, session: SessionHandle, max_rows: u64) -> Result<Vec<u8>, String>;
        fn explain(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
        fn explain_plan(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
        fn compile_sql_json(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
        fn scan_datoms(&self, as_of_us: u64) -> Result<Vec<u8>, String>;
        fn declare_attr(&self, name: &str, value_type: ValueType, many: bool) -> Result<u32, String>;
        fn declare_attr_from_sql(&self, attr: &str, type_name: &str, many: bool, unique: bool) -> Result<(), String>;
        fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String>;
        fn attr_name(&self, aid: u32) -> Result<String, String>;
        fn is_declared(&self, aid: u32) -> Result<bool, String>;
        fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String>;
        fn is_many(&self, aid: u32) -> Result<bool, String>;
        fn is_unique_attr(&self, name: &str) -> Result<bool, String>;
        fn declare_partition(&self, name: &str) -> Result<u64, String>;
        fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String>;
        fn save(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String>;
        fn retract(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String>;
        fn allocate_entity_id(&self) -> Result<u64, String>;
        fn allocate_tx(&self) -> Result<u64, String>;
        fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String>;
        fn flush(&self) -> Result<(), String>;
        fn close(&self) -> Result<(), String>;
        fn path(&self) -> Result<String, String>;
        fn memtable_size(&self) -> Result<u64, String>;
        fn memtable_count(&self, cf: u32) -> Result<u64, String>;
        fn journal_size(&self) -> Result<u64, String>;
        fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
        fn db_stats(&self) -> Result<Vec<u8>, String>;
        fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
        fn internal_status(&self, target: &str) -> Result<String, String>;
    }
}

// ===========================================================================
// Handwritten modules
// ===========================================================================

pub mod query_ir;
pub mod value;
