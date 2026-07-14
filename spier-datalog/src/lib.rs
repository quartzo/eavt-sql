use dynspire_commons::datalog::{DatalogEngine, DatalogIRSt};
use dynspire_commons::sql_parse::RustStmtSt;
use dynspire_commons::transactor::query_codec::decode_values;

mod translate;

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
