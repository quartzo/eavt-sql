use std::collections::HashMap;
use std::fmt;

use crate::ast::SExpr;
use crate::host::{HostFns, SchemeTracer};

#[derive(Debug, Clone, PartialEq)]
pub enum EvalError {
    Unbound(String),
    Arity { name: String, expected: &'static str },
    Type { expected: &'static str, got: String },
    NotFound(String),
    Host(String),
    Other(String),
}

impl fmt::Display for EvalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unbound(s) => write!(f, "unbound: {s}"),
            Self::Arity { name, expected } => write!(f, "{name}: arity mismatch, expected {expected}"),
            Self::Type { expected, got } => write!(f, "type error: expected {expected}, got {got}"),
            Self::NotFound(s) => write!(f, "not found: {s}"),
            Self::Host(s) => write!(f, "host error: {s}"),
            Self::Other(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for EvalError {}

pub struct Environment {
    bindings: HashMap<String, SExpr>,
}

impl Environment {
    pub fn new() -> Self {
        Self {
            bindings: HashMap::new(),
        }
    }

    pub fn define(&mut self, name: String, value: SExpr) {
        self.bindings.insert(name, value);
    }

    pub fn get(&self, name: &str) -> Option<&SExpr> {
        self.bindings.get(name)
    }
}

pub fn eval(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if tracer.is_enabled() {
        tracer.trace_eval(expr);
    }
    let result = eval_inner(expr, env, host, tracer)?;
    if tracer.is_enabled() {
        tracer.trace_result(expr, &result);
    }
    Ok(result)
}

fn eval_inner(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    match expr {
        SExpr::Void | SExpr::Bool(_) | SExpr::Int(_) | SExpr::Float(_) | SExpr::Str(_)
        | SExpr::Bytes(_) => {
            Ok(expr.clone())
        }

        SExpr::Symbol(name) => env
            .get(name)
            .cloned()
            .ok_or_else(|| EvalError::Unbound(name.clone())),

        SExpr::List(items) if items.is_empty() => Ok(SExpr::Void),

        SExpr::List(items) => {
            match &items[0] {
                SExpr::Symbol(op) if is_special_form(op) => {
                    eval_special_form(op, items, env, host, tracer)
                }
                SExpr::Symbol(op) if host.is_native(op) => {
                    let mut args = Vec::with_capacity(items.len() - 1);
                    for arg in &items[1..] {
                        args.push(eval(arg, env, host, tracer)?);
                    }
                    host.call(op, &args)
                }
                _ => {
                    let func = eval(&items[0], env, host, tracer)?;
                    let mut args = Vec::with_capacity(items.len() - 1);
                    for arg in &items[1..] {
                        args.push(eval(arg, env, host, tracer)?);
                    }
                    eval_apply(&func, &args, host)
                }
            }
        }
    }
}

fn is_special_form(name: &str) -> bool {
    matches!(
        name,
        "let*" | "let" | "when" | "if" | "begin" | "set!" | "dbg" | "trace" | "log" | "assert"
    )
}

fn eval_special_form(
    op: &str,
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    match op {
        "let" | "let*" => eval_let(op, items, env, host, tracer),
        "when" => eval_when(items, env, host, tracer),
        "if" => eval_if(items, env, host, tracer),
        "begin" => eval_begin(items, env, host, tracer),
        "set!" => eval_set(items, env, host, tracer),
        "dbg" => eval_dbg(items, env, host, tracer),
        "trace" => eval_trace(items, env, host, tracer),
        "log" => eval_log(items, env, host, tracer),
        "assert" => eval_assert(items, env, host, tracer),
        _ => unreachable!("checked by is_special_form"),
    }
}

fn eval_let(
    op: &str,
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 3 {
        return Err(EvalError::Arity {
            name: op.into(),
            expected: "(let ((name val) ...) body...+)",
        });
    }
    let bindings = match &items[1] {
        SExpr::List(pairs) => pairs,
        _ => {
            return Err(EvalError::Type {
                expected: "list of (name expr) pairs",
                got: format!("{:?}", items[1]),
            });
        }
    };

    if op == "let*" {
        for pair in bindings {
            match pair {
                SExpr::List(pair_items) if pair_items.len() == 2 => {
                    let name = match &pair_items[0] {
                        SExpr::Symbol(s) => s.clone(),
                        _ => {
                            return Err(EvalError::Type {
                                expected: "symbol",
                                got: format!("{:?}", pair_items[0]),
                            });
                        }
                    };
                    let val = eval(&pair_items[1], env, host, tracer)?;
                    env.define(name, val);
                }
                _ => {
                    return Err(EvalError::Other(format!(
                        "expected (name expr) pair, got: {pair:?}"
                    )));
                }
            }
        }
    } else {
        // let: all exprs evaluated in parent env
        let mut vals = Vec::with_capacity(bindings.len());
        let mut names = Vec::with_capacity(bindings.len());
        for pair in bindings {
            match pair {
                SExpr::List(pair_items) if pair_items.len() == 2 => {
                    let name = match &pair_items[0] {
                        SExpr::Symbol(s) => s.clone(),
                        _ => {
                            return Err(EvalError::Type {
                                expected: "symbol",
                                got: format!("{:?}", pair_items[0]),
                            });
                        }
                    };
                    let val = eval(&pair_items[1], env, host, tracer)?;
                    names.push(name);
                    vals.push(val);
                }
                _ => {
                    return Err(EvalError::Other(format!(
                        "expected (name expr) pair, got: {pair:?}"
                    )));
                }
            }
        }
        for (name, val) in names.into_iter().zip(vals) {
            env.define(name, val);
        }
    }

    let mut result = SExpr::Void;
    for body in &items[2..] {
        result = eval(body, env, host, tracer)?;
    }
    Ok(result)
}

fn eval_when(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "when".into(),
            expected: "(when test body...+)",
        });
    }
    let test = eval(&items[1], env, host, tracer)?;
    if is_truthy(&test) {
        let mut result = SExpr::Void;
        for body in &items[2..] {
            result = eval(body, env, host, tracer)?;
        }
        Ok(result)
    } else {
        Ok(SExpr::Void)
    }
}

fn eval_if(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 3 {
        return Err(EvalError::Arity {
            name: "if".into(),
            expected: "(if test then [else])",
        });
    }
    let test = eval(&items[1], env, host, tracer)?;
    if is_truthy(&test) {
        eval(&items[2], env, host, tracer)
    } else if items.len() > 3 {
        eval(&items[3], env, host, tracer)
    } else {
        Ok(SExpr::Void)
    }
}

fn eval_begin(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    let mut result = SExpr::Void;
    for expr in &items[1..] {
        result = eval(expr, env, host, tracer)?;
    }
    Ok(result)
}

fn eval_set(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() != 3 {
        return Err(EvalError::Arity {
            name: "set!".into(),
            expected: "(set! name expr)",
        });
    }
    let name = match &items[1] {
        SExpr::Symbol(s) => s.clone(),
        _ => {
            return Err(EvalError::Type {
                expected: "symbol",
                got: format!("{:?}", items[1]),
            });
        }
    };
    let val = eval(&items[2], env, host, tracer)?;
    if env.get(&name).is_none() {
        return Err(EvalError::Unbound(name));
    }
    env.define(name, val.clone());
    Ok(val)
}

fn eval_dbg(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "dbg".into(),
            expected: "(dbg [label] expr)",
        });
    }
    let (label, expr_idx) = if items.len() == 2 {
        (format!("{:?}", items[1]), 1)
    } else {
        match &items[1] {
            SExpr::Str(s) => (s.clone(), 2),
            SExpr::Symbol(s) => (s.clone(), 2),
            _ => (format!("{:?}", items[1]), 2),
        }
    };
    let val = eval(&items[expr_idx], env, host, tracer)?;
    tracer.trace_log(&format!("[scheme] {label}: {}", crate::printer::write_scheme(&val)));
    Ok(val)
}

fn eval_trace(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "trace".into(),
            expected: "(trace expr)",
        });
    }
    let val = eval(&items[1], env, host, tracer)?;
    tracer.trace_log(&format!("[scheme] (trace): {}", crate::printer::write_scheme(&val)));
    Ok(val)
}

fn eval_log(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "log".into(),
            expected: "(log msg [args...])",
        });
    }
    let mut out = String::new();
    for item in &items[1..] {
        if !out.is_empty() {
            out.push(' ');
        }
        let val = eval(item, env, host, tracer)?;
        out.push_str(&crate::printer::write_scheme(&val));
    }
    tracer.trace_log(&format!("[scheme] {out}"));
    Ok(SExpr::Void)
}

fn eval_assert(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "assert".into(),
            expected: "(assert cond [msg])",
        });
    }
    let test = eval(&items[1], env, host, tracer)?;
    if !is_truthy(&test) {
        let msg = if items.len() > 2 {
            let m = eval(&items[2], env, host, tracer)?;
            crate::printer::write_scheme(&m)
        } else {
            "assertion failed".into()
        };
        return Err(EvalError::Other(format!("assertion: {msg}")));
    }
    Ok(SExpr::Void)
}

fn eval_apply(
    func: &SExpr,
    args: &[SExpr],
    host: &mut dyn HostFns,
) -> Result<SExpr, EvalError> {
    let name = match func {
        SExpr::Symbol(s) => s.as_str(),
        _ => {
            return Err(EvalError::Other(format!(
                "cannot apply non-symbol: {}",
                crate::printer::write_scheme(func)
            )));
        }
    };
    if host.is_native(name) {
        host.call(name, args)
    } else {
        Err(EvalError::NotFound(name.into()))
    }
}

fn is_truthy(expr: &SExpr) -> bool {
    !matches!(expr, SExpr::Void | SExpr::Bool(false))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::NullTracer;
    use crate::parser::parse;
    use crate::printer::write_scheme;

    struct MockHost;

    impl HostFns for MockHost {
        fn call(&mut self, name: &str, args: &[SExpr]) -> Result<SExpr, EvalError> {
            match name {
                "+" | "-" | "*" if args.len() != 2 => {
                    Err(EvalError::Arity { name: name.into(), expected: "2 args" })
                }
                "+" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(SExpr::Int(a + b))
                }
                "-" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(SExpr::Int(a - b))
                }
                "*" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(SExpr::Int(a * b))
                }
                "save" => Ok(SExpr::Void),
                "result" => Ok(SExpr::Void),
                _ => Err(EvalError::NotFound(name.into())),
            }
        }

        fn is_native(&self, name: &str) -> bool {
            matches!(name, "+" | "-" | "*" | "save" | "result")
        }
    }

    fn expect_int(e: &SExpr) -> Result<i64, EvalError> {
        match e {
            SExpr::Int(v) => Ok(*v),
            _ => Err(EvalError::Type {
                expected: "int",
                got: write_scheme(e),
            }),
        }
    }

    fn run(input: &str) -> Result<SExpr, EvalError> {
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = MockHost;
        eval(&expr, &mut env, &mut host, &NullTracer)
    }

    #[test]
    fn literals() {
        assert_eq!(run("42").unwrap(), SExpr::Int(42));
        assert_eq!(run("#t").unwrap(), SExpr::Bool(true));
        assert_eq!(run("\"hi\"").unwrap(), SExpr::Str("hi".into()));
        assert_eq!(run("()").unwrap(), SExpr::Void);
    }

    #[test]
    fn let_star() {
        assert_eq!(
            run("(let* ((x 1) (y (+ x 1))) y)").unwrap(),
            SExpr::Int(2)
        );
    }

    #[test]
    fn when_true() {
        assert_eq!(run("(when #t 1 2 3)").unwrap(), SExpr::Int(3));
    }

    #[test]
    fn when_false() {
        assert_eq!(run("(when #f 1)").unwrap(), SExpr::Void);
    }

    #[test]
    fn if_else() {
        assert_eq!(run("(if #t 1 2)").unwrap(), SExpr::Int(1));
        assert_eq!(run("(if #f 1 2)").unwrap(), SExpr::Int(2));
        assert_eq!(run("(if #f 1)").unwrap(), SExpr::Void);
    }

    #[test]
    fn begin() {
        assert_eq!(run("(begin 1 2 3)").unwrap(), SExpr::Int(3));
    }

    #[test]
    fn nested_let_begin() {
        let input = "(let* ((x 10)) (begin (let* ((y 20)) (+ x y))))";
        assert_eq!(run(input).unwrap(), SExpr::Int(30));
    }

    #[test]
    fn dbg_transparent() {
        let input = r#"(dbg "x" (+ 1 2))"#;
        assert_eq!(run(input).unwrap(), SExpr::Int(3));
    }

    #[test]
    fn unbound() {
        assert!(matches!(run("x"), Err(EvalError::Unbound(_))));
    }

    #[test]
    fn arity() {
        assert!(matches!(run("(+ 1)"), Err(EvalError::Arity { .. })));
    }
}
