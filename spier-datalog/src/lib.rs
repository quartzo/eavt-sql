pub mod ast;
pub mod pattern;
pub mod resolve;
pub mod stats;
pub mod translate;

pub use ast::*;
pub use pattern::*;
pub use resolve::{compute_plan_stats, resolve_ir};
pub use stats::CompileStats;

use spier_sql_parse::RustStmtSt;
use spier_value::query_codec::decode_values;

#[derive(Clone)]
pub struct DatalogIRSt {
    pub ir: DatalogIR,
}

pub trait DatalogEngine: Send + Sync {
    fn build(&self, stmt: RustStmtSt, params: &[u8]) -> Result<DatalogIRSt, String>;
    fn to_string(&self, ir: DatalogIRSt) -> Result<String, String>;
}

/// Pure Rust Datalog IR builder. No dynspire/FFI — just implements [`DatalogEngine`].
pub struct DatalogBuilder;

impl DatalogBuilder {
    pub fn new() -> Self {
        Self
    }
}

impl Default for DatalogBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl DatalogEngine for DatalogBuilder {
    fn build(&self, wrapped: RustStmtSt, params: &[u8]) -> Result<DatalogIRSt, String> {
        let params = decode_values(params)?;
        let ir = translate::build_datalog_ir(wrapped.stmt, &params)?;
        Ok(DatalogIRSt { ir })
    }

    fn to_string(&self, ir: DatalogIRSt) -> Result<String, String> {
        Ok(format!("{}", ir.ir))
    }
}
