use pyo3::prelude::*;
use spier_sql_parse::SqlParseEngine;
use spier_sql_parse::SqlParser;

/// PyO3 bindings for spier-sql-parse.
#[pyclass(name = "SqlParser")]
pub struct SqlParserPy {
    inner: SqlParser,
}

#[pymethods]
impl SqlParserPy {
    #[new]
    fn new() -> Self {
        Self {
            inner: SqlParser::new(),
        }
    }

    /// Parse SQL and return the raw JSON AST string.
    fn parse_json(&self, sql: &str) -> PyResult<String> {
        self.inner
            .parse_json(sql)
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))
    }

    /// Alias for parse_json to keep API compatibility with the old parser client.
    fn parse(&self, sql: &str) -> PyResult<String> {
        self.parse_json(sql)
    }

    /// No-op close for API compatibility with the old ctypes client.
    fn close(&self) {}
}

#[pymodule]
fn spier_sql_parse_py(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<SqlParserPy>()?;
    Ok(())
}
