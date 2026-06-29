use std::collections::HashMap;

use dynspire_commons::sql_parse::RustStmtSt;

include!(concat!(env!("OUT_DIR"), "/sqlparse_spier.rs"));

mod lexer;
mod parser;

struct ParseState;

fn init(_config: &HashMap<String, String>) -> Result<ParseState, String> {
    Ok(ParseState)
}

impl SqlParseEngine for ParseState {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String> {
        Ok(RustStmtSt { stmt: parser::parse(sql)? })
    }

    fn parse_json(&self, sql: &str) -> Result<String, String> {
        let stmt = parser::parse(sql)?;
        serde_json::to_string(&stmt).map_err(|e| e.to_string())
    }
}

impl_sqlparse_spier!(ParseState, init, "spier_sql_parse");
