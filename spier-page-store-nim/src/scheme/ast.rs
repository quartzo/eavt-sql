use crate::write_scheme;
use std::any::Any;
use std::fmt;
use std::sync::Arc;

#[derive(Clone)]
pub struct Opaque(pub Arc<dyn Any + Send + Sync>);

impl fmt::Debug for Opaque {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("#<opaque>")
    }
}

impl PartialEq for Opaque {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SExpr {
    Void,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Bytes(Vec<u8>),
    Symbol(String),
    List(Vec<SExpr>),
    Resource(Opaque),
}

#[derive(Debug, Clone)]
pub struct SchemeProgram {
    pub body: SExpr,
    pub param_count: usize,
}

impl SchemeProgram {
    pub fn new(body: SExpr) -> Self {
        Self {
            body,
            param_count: 0,
        }
    }

    pub fn with_param_count(mut self, n: usize) -> Self {
        self.param_count = n;
        self
    }

    pub fn to_string(&self) -> String {
        write_scheme(&self.body)
    }
}

impl fmt::Display for SExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", write_scheme(self))
    }
}
