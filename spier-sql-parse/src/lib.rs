pub mod ast;
pub mod lexer;
pub mod parser;

pub use ast::*;

#[derive(Clone)]
pub struct RustStmtSt {
    pub stmt: RustStmt,
}

pub trait SqlParseEngine: Send + Sync {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String>;
    fn parse_json(&self, sql: &str) -> Result<String, String>;
}

/// Pure Rust SQL parser. just implements [`SqlParseEngine`].
pub struct SqlParser;

impl SqlParser {
    pub fn new() -> Self {
        Self
    }
}

impl Default for SqlParser {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlParseEngine for SqlParser {
    fn parse(&self, sql: &str) -> Result<RustStmtSt, String> {
        Ok(RustStmtSt {
            stmt: parser::parse(sql)?,
        })
    }

    fn parse_json(&self, sql: &str) -> Result<String, String> {
        let stmt = parser::parse(sql)?;
        serde_json::to_string(&stmt).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_select() {
        let p = SqlParser::new();
        let stmt = p.parse("SELECT *").unwrap();
        assert!(matches!(stmt.stmt, RustStmt::Select(_)));
    }

    #[test]
    fn parse_json_returns_string() {
        let p = SqlParser::new();
        let json = p.parse_json("SELECT *").unwrap();
        assert!(json.contains("Select"));
    }

    #[test]
    fn parse_invalid_sql_errors() {
        let p = SqlParser::new();
        assert!(p.parse("NOT SQL").is_err());
    }
}
