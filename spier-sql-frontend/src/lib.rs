use spier_datalog::{DatalogEngine, DatalogIRSt};
use spier_sql_parse::ast::{
    RustDeleteWhereStmt, RustFieldRef, RustProjection, RustSelectStmt, RustUpdateStmt,
};
use spier_sql_parse::{RustStmt, RustStmtSt, SqlParseEngine};

pub trait SqlFrontendEngine: Send + Sync {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String>;
    fn build_datalog(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<DatalogIRSt, String>;
}

/// Pure Rust SQL frontend. Combines parser + datalog builder.
pub struct SqlFrontend;

impl SqlFrontend {
    pub fn new() -> Self {
        Self
    }
}

impl Default for SqlFrontend {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlFrontendEngine for SqlFrontend {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String> {
        spier_sql_parse::SqlParser::new().parse(sql)
    }

    fn build_datalog(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<DatalogIRSt, String> {
        let stmt = stmt.stmt;
        let select_stmt = match &stmt {
            RustStmt::Select(_) | RustStmt::DatalogSelect(_) => stmt,
            RustStmt::Update(u) => RustStmt::Select(fake_select_from_update(u)),
            RustStmt::Delete(d) => RustStmt::Select(fake_select_from_delete(d)),
            _ => return Err("build_datalog only supports SELECT, UPDATE, DELETE".to_string()),
        };
        spier_datalog::DatalogBuilder::new().build(RustStmtSt { stmt: select_stmt }, sql_params)
    }
}

/// Build a fake SELECT from UPDATE conditions (projects first alias eid).
fn fake_select_from_update(stmt: &RustUpdateStmt) -> RustSelectStmt {
    let first_alias = stmt
        .clauses
        .first()
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
fn fake_select_from_delete(stmt: &RustDeleteWhereStmt) -> RustSelectStmt {
    let first_alias = stmt
        .conditions
        .first()
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
