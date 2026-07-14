use dynspire_commons::datalog::{DatalogEngine, DatalogIRSt};
use dynspire_commons::sql_parse::ast::{RustFieldRef, RustProjection, RustSelectStmt, RustUpdateStmt, RustDeleteWhereStmt};
use dynspire_commons::sql_parse::{RustStmt, RustStmtSt, SqlParseEngine};
use spier_datalog::DatalogBuilder;
use spier_sql_parse::SqlParser;

/// Pure Rust SQL frontend. Combines parser + datalog builder.
pub struct SqlFrontend {
    parser: SqlParser,
    datalog: DatalogBuilder,
}

impl SqlFrontend {
    pub fn new() -> Self {
        Self {
            parser: SqlParser::new(),
            datalog: DatalogBuilder::new(),
        }
    }
}

impl Default for SqlFrontend {
    fn default() -> Self {
        Self::new()
    }
}

impl dynspire_commons::sql_frontend::SqlFrontendEngine for SqlFrontend {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String> {
        self.parser.parse(sql)
    }

    fn build_datalog(&self, stmt: RustStmtSt, sql_params: &[u8]) -> Result<DatalogIRSt, String> {
        let stmt = stmt.stmt;
        let select_stmt = match &stmt {
            RustStmt::Select(_) | RustStmt::DatalogSelect(_) => stmt,
            RustStmt::Update(u) => RustStmt::Select(fake_select_from_update(u)),
            RustStmt::Delete(d) => RustStmt::Select(fake_select_from_delete(d)),
            _ => return Err("build_datalog only supports SELECT, UPDATE, DELETE".to_string()),
        };
        self.datalog.build(RustStmtSt { stmt: select_stmt }, sql_params)
    }
}

/// Build a fake SELECT from UPDATE conditions (projects first alias eid).
fn fake_select_from_update(stmt: &RustUpdateStmt) -> RustSelectStmt {
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
fn fake_select_from_delete(stmt: &RustDeleteWhereStmt) -> RustSelectStmt {
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
