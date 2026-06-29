use crate::datalog::{DatalogEngine, DynSpireDatalog, DatalogIRSt};
use crate::sql_parse::RustStmtSt;
use crate::transactor::query_codec::encode_values;
use crate::value::Value;

impl DynSpireDatalog {
    /// Convenience wrapper: accepts &[Value] instead of packed &[u8].
    pub fn build_with_values(&self, stmt: RustStmtSt, params: &[Value]) -> Result<DatalogIRSt, String> {
        let params_bytes = encode_values(params);
        DatalogEngine::build(self, stmt, &params_bytes)
    }
}
