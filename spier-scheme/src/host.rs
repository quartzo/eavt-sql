use crate::ast::SExpr;
use crate::eval::EvalError;

pub trait HostFns {
    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<SExpr, EvalError>;
    fn is_native(&self, name: &str) -> bool;
}

pub trait SchemeTracer {
    fn trace_eval(&self, _form: &SExpr) {}
    fn trace_result(&self, _form: &SExpr, _result: &SExpr) {}
    fn trace_log(&self, _msg: &str) {}
    fn is_enabled(&self) -> bool {
        false
    }
}

pub struct NullTracer;

impl SchemeTracer for NullTracer {}
