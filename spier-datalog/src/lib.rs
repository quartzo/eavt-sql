use std::collections::HashMap;

use dynspire_commons::datalog::DatalogIRSt;
use dynspire_commons::sql_parse::RustStmtSt;
use dynspire_commons::transactor::query_codec::decode_values;

include!(concat!(env!("OUT_DIR"), "/datalog_spier.rs"));

mod translate;

struct DatalogState;

fn init(_config: &HashMap<String, String>) -> Result<DatalogState, String> {
    Ok(DatalogState)
}

impl DatalogEngine for DatalogState {
    fn build(&self, wrapped: RustStmtSt, params: &[u8]) -> Result<DatalogIRSt, String> {
        let params = decode_values(params)?;
        let ir = translate::build_datalog_ir(wrapped.stmt, &params)?;
        Ok(DatalogIRSt { ir })
    }

    fn to_string(&self, ir: DatalogIRSt) -> Result<String, String> {
        Ok(format!("{}", ir.ir))
    }
}

impl_datalog_spier!(DatalogState, init, "spier_datalog");
