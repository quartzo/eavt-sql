use std::collections::HashMap;

use dynspire_commons::sql_parse::{DynSpireSqlParse, RustStmt, RustStmtSt, SqlParseEngine};
use dynspire_commons::datalog::{DynSpireDatalog, DatalogEngine, DatalogIRSt};
use dynspire_commons::sql_parse::ast::{RustSelectStmt, RustProjection, RustFieldRef};

include!(concat!(env!("OUT_DIR"), "/sqlfrontend_spier.rs"));

struct FrontendState {
    parser: DynSpireSqlParse,
    datalog: DynSpireDatalog,
}

fn init(config: &HashMap<String, String>) -> Result<FrontendState, String> {
    let parser = DynSpireSqlParse::connect("spier_sql_parse", config)?;
    let datalog = DynSpireDatalog::connect("spier_datalog", config)?;
    Ok(FrontendState { parser, datalog })
}

/// Build a fake SELECT from UPDATE conditions (projects first alias eid).
fn fake_select_from_update(stmt: &dynspire_commons::sql_parse::RustUpdateStmt) -> RustSelectStmt {
    let first_alias = stmt.clauses.first()
        .map(|c| c.alias.clone())
        .unwrap_or_else(|| "D1".to_string());
    RustSelectStmt {
        projections: vec![RustProjection {
            field: Some(RustFieldRef {
                alias: first_alias.to_lowercase(),
                field: "eid".to_string(),
            }),
            literal: None,
        }],
        conditions: stmt.conditions.clone(),
        exists_mode: false,
        star: false,
        history: false,
    }
}

/// Build a fake SELECT from DELETE conditions (projects first alias eid).
fn fake_select_from_delete(stmt: &dynspire_commons::sql_parse::RustDeleteWhereStmt) -> RustSelectStmt {
    let first_alias = stmt.conditions.first()
        .map(|c| c.left.alias.clone())
        .unwrap_or_else(|| "D1".to_string());
    RustSelectStmt {
        projections: vec![RustProjection {
            field: Some(RustFieldRef {
                alias: first_alias.to_lowercase(),
                field: "eid".to_string(),
            }),
            literal: None,
        }],
        conditions: stmt.conditions.clone(),
        exists_mode: false,
        star: false,
        history: false,
    }
}

impl SqlFrontendEngine for FrontendState {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String> {
        SqlParseEngine::parse(&self.parser, sql)
    }

    fn build_datalog(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<DatalogIRSt, String> {
        let stmt = stmt.stmt;
        let select_stmt = match &stmt {
            RustStmt::Select(_) | RustStmt::DatalogSelect(_) => stmt,
            RustStmt::Update(u) => RustStmt::Select(fake_select_from_update(u)),
            RustStmt::Delete(d) => RustStmt::Select(fake_select_from_delete(d)),
            _ => return Err("build_datalog only supports SELECT, UPDATE, DELETE".to_string()),
        };
        DatalogEngine::build(&self.datalog, RustStmtSt { stmt: select_stmt }, sql_params)
    }
}

impl_sqlfrontend_spier!(FrontendState, init, "spier_sql_frontend");
