use std::collections::HashMap;
use std::fmt;

use crate::ast::SExpr;
use crate::host::{HostFns, NullTracer, SchemeTracer};

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

#[derive(Debug, Clone, PartialEq)]
pub enum EvalStep {
    Done(SExpr),
    Yield(SExpr),
}

impl std::error::Error for EvalError {}

#[derive(Clone)]
pub struct Environment {
    bindings: HashMap<String, SExpr>,
    pub depth_counter: usize,
}

impl Environment {
    pub fn new() -> Self {
        Self {
            bindings: HashMap::new(),
            depth_counter: 0,
        }
    }

    pub fn define(&mut self, name: String, value: SExpr) {
        self.bindings.insert(name, value);
    }

    pub fn get(&self, name: &str) -> Option<&SExpr> {
        self.bindings.get(name)
    }
}

#[derive(Debug, Clone)]
pub enum DepthRunPhase {
    Init,
    Body,
}

#[derive(Debug, Clone)]
pub struct DepthRunFrame {
    pub stage_key: i64,
    pub scanner_configs: Vec<SExpr>,
    pub body: Vec<SExpr>,
    pub captured_env: HashMap<String, SExpr>,
    pub phase: DepthRunPhase,
    pub param_name: Option<String>,
    pub ranges: SExpr,
}

#[derive(Debug, Clone, Default)]
pub struct YieldState {
    pub(crate) stack: Vec<Frame>,
    pub depth_runs: Vec<DepthRunFrame>,
    started: bool,
}

#[derive(Debug, Clone)]
pub(crate) enum Frame {
    Eval(SExpr),
    Apply {
        func: SExpr,
        args: Vec<SExpr>,
        evaluated: usize,
    },
    LetBindings {
        op: String,
        pairs: Vec<SExpr>,
        names: Vec<String>,
        vals: Vec<SExpr>,
        current: usize,
        body: Vec<SExpr>,
    },
    WhenTest {
        condition: SExpr,
        body: Vec<SExpr>,
    },
    IfTest {
        condition: SExpr,
        then_expr: Option<SExpr>,
        else_expr: Option<SExpr>,
    },
    SetFrame {
        name: String,
        closure_env: HashMap<String, SExpr>,
    },
    DbgFrame {
        label: String,
    },
    ClosureFrame {
        body: Vec<SExpr>,
        bound_env: HashMap<String, SExpr>,
    },
    RestoreEnv {
        bindings: HashMap<String, SExpr>,
    },
    DepthRunBody,

}

enum EvalResult {
    Value(SExpr),
    Pushed,
    Yield(SExpr),
}

fn hc(host: &mut dyn HostFns, name: &str, args: &[SExpr]) -> Result<EvalResult, EvalError> {
    Ok(match host.call(name, args)? {
        EvalStep::Done(v) => EvalResult::Value(v),
        EvalStep::Yield(row) => EvalResult::Yield(row),
    })
}

fn expect_done(host: &mut dyn HostFns, name: &str, args: &[SExpr]) -> Result<SExpr, EvalError> {
    match host.call(name, args)? {
        EvalStep::Done(v) => Ok(v),
        EvalStep::Yield(row) => Ok(row),
    }
}

/// Map SQL-style operator symbols to range-op integers.
fn range_op_symbol_to_int(op: &str) -> Option<i64> {
    match op {
        "=" => Some(0),   // RANGE_OP_EQ (single value, interacts with >/<)
        "!=" => Some(1),
        ">" => Some(2),
        ">=" => Some(3),
        "<" => Some(4),
        "<=" => Some(5),
        _ => None,
    }
}

/// Map for multi-value `=` — uses RANGE_OP_IN (6) so ops_to_intervals
/// produces separate [v,v] intervals instead of overwriting lo/hi.
const RANGE_OP_IN: i64 = 6;

/// Process a range tree into a flat serialized SExpr list:
///   ((op_int val) (op_int val) (branch) (op_int val) ...)
///
/// Each `(op_int val)` is a condition; `(branch)` marks a new branch boundary.
/// Empty list means no range constraints.
fn process_ranges(
    ranges: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    let mut out = Vec::new();
    process_ranges_into(ranges, false, env, host, tracer, &mut out)?;
    Ok(SExpr::List(out))
}

fn process_ranges_into(
    ranges: &SExpr,
    is_branch: bool,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    out: &mut Vec<SExpr>,
) -> Result<(), EvalError> {
    match ranges {
        SExpr::List(items) if items.is_empty() => Ok(()),
        SExpr::List(items) => {
            if let SExpr::Symbol(op) = &items[0] {
                match op.as_str() {
                    "and" => {
                        if is_branch {
                            out.push(ranged("branch", &[]));
                        }
                        for cond in &items[1..] {
                            process_ranges_into(cond, false, env, host, tracer, out)?;
                        }
                        return Ok(());
                    }
                    "or" => {
                        for (i, branch) in items[1..].iter().enumerate() {
                            if i > 0 {
                                out.push(ranged("branch", &[]));
                            }
                            process_ranges_into(branch, true, env, host, tracer, out)?;
                        }
                        return Ok(());
                    }
                    _ => {}
                }
            }
            // Single condition: (op val1 val2 ...)
            if is_branch {
                out.push(ranged("branch", &[]));
            }
            process_one_condition(ranges, env, host, tracer, out)
        }
        _ => Err(EvalError::Type {
            expected: "ranges expression",
            got: format!("{ranges:?}"),
        }),
    }
}

fn process_one_condition(
    cond: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    out: &mut Vec<SExpr>,
) -> Result<(), EvalError> {
    match cond {
        SExpr::List(parts) if parts.len() >= 2 => {
            let op_str = match &parts[0] {
                SExpr::Symbol(s) => s.as_str(),
                _ => return Err(EvalError::Type {
                    expected: "range operator symbol",
                    got: format!("{:?}", parts[0]),
                }),
            };
            let op_int = if op_str == "=" && parts.len() > 2 {
                RANGE_OP_IN
            } else {
                range_op_symbol_to_int(op_str).ok_or_else(|| EvalError::Other(
                    format!("unknown range operator: {op_str}")
                ))?
            };
            for val_expr in &parts[1..] {
                let val = eval_recursive(val_expr, env, host, tracer)?;
                out.push(ranged("cond", &[SExpr::Int(op_int), val]));
            }
            Ok(())
        }
        _ => Err(EvalError::Type {
            expected: "(op value...) pair",
            got: format!("{cond:?}"),
        }),
    }
}

fn ranged(name: &str, args: &[SExpr]) -> SExpr {
    let mut items = vec![SExpr::Symbol(name.into())];
    items.extend_from_slice(args);
    SExpr::List(items)
}

// ═══════════════════════════════════════════════════════════════════
// Stack-based evaluator (supports yield/resume)
// ═══════════════════════════════════════════════════════════════════

fn run_eval(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalStep, EvalError> {
    if state.stack.is_empty() {
        if state.started {
            return Ok(EvalStep::Done(SExpr::Void));
        }
        state.started = true;
        state.stack.push(Frame::Eval(expr.clone()));
    }

    while let Some(frame) = state.stack.pop() {
        match frame {
            Frame::Eval(e) => {
                match eval_frame(&e, env, host, tracer, state)? {
                    EvalResult::Value(v) => {
                        match process_value(v, env, host, state)? {
                            EvalResult::Value(final_val) => return Ok(EvalStep::Done(final_val)),
                            EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                            EvalResult::Pushed => {}
                        }
                    }
                    EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                    EvalResult::Pushed => {}
                }
            }
            Frame::WhenTest { condition, body } => {
                if is_truthy(&condition) {
                    for expr in body.iter().rev() {
                        state.stack.push(Frame::Eval(expr.clone()));
                    }
                } else {
                    match process_value(SExpr::Void, env, host, state)? {
                        EvalResult::Value(v) => return Ok(EvalStep::Done(v)),
                        EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                        EvalResult::Pushed => {}
                    }
                }
            }
            Frame::IfTest {
                condition,
                then_expr,
                else_expr,
            } => {
                let branch = if is_truthy(&condition) {
                    then_expr
                } else {
                    else_expr
                };
                match branch {
                    Some(e) => state.stack.push(Frame::Eval(e)),
                    None => {
                        match process_value(SExpr::Void, env, host, state)? {
                            EvalResult::Value(v) => return Ok(EvalStep::Done(v)),
                            EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                            EvalResult::Pushed => {}
                        }
                    }
                }
            }
            Frame::SetFrame { name, closure_env } => {
                let _ = (name, closure_env);
                unreachable!("set! should be handled inline")
            }
            Frame::DbgFrame { label } => {
                let _ = label;
                unreachable!("dbg should be handled inline")
            }
            Frame::ClosureFrame { body, bound_env } => {
                let saved = std::mem::replace(&mut env.bindings, bound_env);
                state.stack.push(Frame::RestoreEnv { bindings: saved });
                for expr in body.iter().rev() {
                    state.stack.push(Frame::Eval(expr.clone()));
                }
            }
            Frame::RestoreEnv { bindings } => {
                env.bindings = bindings;
            }
Frame::DepthRunBody => {
                let dr = match state.depth_runs.last() {
                    Some(d) => d.clone(),
                    None => continue,
                };
                let stage_key = dr.stage_key;

                let mut sids: Vec<SExpr> = Vec::new();
                for config in &dr.scanner_configs {
                    let scanner_ref = if let SExpr::List(pair) = config {
                        if !pair.is_empty() { &pair[0] } else { config }
                    } else { config };
                    let sid_val = match scanner_ref {
                        SExpr::Symbol(name) => env.get(name).cloned().ok_or_else(|| EvalError::Unbound(name.clone()))?,
                        other => eval_recursive(other, env, host, tracer)?,
                    };
                    sids.push(sid_val);
                }

                let mut leap_args = vec![SExpr::Int(stage_key)];
                leap_args.extend(sids.clone());
                leap_args.push(dr.ranges.clone());
                match hc(host, "scheme-leap-next", &leap_args)? {
                    EvalResult::Value(ok) => {
                        if is_truthy(&ok) {
                            // Re-bind scanner value to lambda param
                            if let Some(ref param_name) = dr.param_name {
                                if !sids.is_empty() {
                                    let val = expect_done(host, "scanner-read", &[sids[0].clone()])?;
                                    env.define(param_name.clone(), val);
                                }
                            }
                            state.stack.push(Frame::DepthRunBody);
                            for expr in dr.body.iter().rev() {
                                state.stack.push(Frame::Eval(expr.clone()));
                            }
                        } else {
                            for sid_expr in &sids {
                                expect_done(host, "depth-cleanup", &[sid_expr.clone()])?;
                            }
                            state.depth_runs.pop();
                            match process_value(SExpr::Void, env, host, state)? {
                                EvalResult::Value(v) => return Ok(EvalStep::Done(v)),
                                EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                                EvalResult::Pushed => {}
                            }
                        }
                    }
                    EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                    EvalResult::Pushed => {}
                }
            }

            Frame::Apply {
                func,
                args,
                evaluated,
            } => {
                if evaluated < args.len() {
                    let next_expr = args[evaluated].clone();
                    state.stack.push(Frame::Apply {
                        func,
                        args,
                        evaluated: evaluated + 1,
                    });
                    state.stack.push(Frame::Eval(next_expr));
                } else {
                    match func {
                        SExpr::Symbol(ref name) if host.is_native(name) => {
                            match hc(host, name, &args)? {
                                EvalResult::Value(v) => {
                                    match process_value(v, env, host, state)? {
                                        EvalResult::Value(final_val) => return Ok(EvalStep::Done(final_val)),
                                        EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                                        EvalResult::Pushed => {}
                                    }
                                }
                                EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                                EvalResult::Pushed => {}
                            }
                        }
                        _ => {
                            return Err(EvalError::Other(format!(
                                "cannot apply: {}",
                                crate::printer::write_scheme(&func)
                            )));
                        }
                    }
                }
            }
            Frame::LetBindings {
                op,
                pairs,
                names,
                vals,
                current,
                body,
            } => {
                if current < pairs.len() {
                    let pair = &pairs[current];
                    match pair {
                        SExpr::List(pair_items) if pair_items.len() == 2 => {
                            let _name = match &pair_items[0] {
                                SExpr::Symbol(s) => s.clone(),
                                _ => {
                                    return Err(EvalError::Type {
                                        expected: "symbol",
                                        got: format!("{:?}", pair_items[0]),
                                    });
                                }
                            };
                            let next_expr = pair_items[1].clone();
                            state.stack.push(Frame::LetBindings {
                                op,
                                pairs,
                                names,
                                vals,
                                current,
                                body,
                            });
                            state.stack.push(Frame::Eval(next_expr));
                        }
                        _ => {
                            return Err(EvalError::Other(format!(
                                "expected (name expr) pair, got: {pair:?}"
                            )));
                        }
                    }
                } else {
                    for (name, val) in names.into_iter().zip(vals) {
                        env.define(name, val);
                    }
                    if body.is_empty() {
                        match process_value(SExpr::Void, env, host, state)? {
                            EvalResult::Value(v) => return Ok(EvalStep::Done(v)),
                            EvalResult::Yield(row) => return Ok(EvalStep::Yield(row)),
                            EvalResult::Pushed => {}
                        }
                    } else {
                        for expr in body.iter().rev() {
                            state.stack.push(Frame::Eval(expr.clone()));
                        }
                    }
                }
            }
        }
    }

    Ok(EvalStep::Done(SExpr::Void))
}

fn eval_frame(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    if tracer.is_enabled() {
        tracer.trace_eval(expr);
    }

    match expr {
        SExpr::Void | SExpr::Bool(_) | SExpr::Int(_) | SExpr::Float(_) | SExpr::Str(_)
        | SExpr::Bytes(_) | SExpr::Resource(_) | SExpr::Closure { .. } => {
            Ok(EvalResult::Value(expr.clone()))
        }

        SExpr::Symbol(name) => {
            let val = env
                .get(name)
                .cloned()
                .ok_or_else(|| EvalError::Unbound(name.clone()))?;
            Ok(EvalResult::Value(val))
        }

        SExpr::List(items) if items.is_empty() => Ok(EvalResult::Value(SExpr::Void)),

        SExpr::List(items) => {
            match &items[0] {
                SExpr::Symbol(op) if is_special_form(op) => {
                    eval_special_form_frame(op, items, env, host, tracer, state)
                }
                SExpr::Symbol(op) if host.is_native(op) => {
                    // Evaluate all args eagerly via eval_recursive. Host fn args
                    // never yield (yielding is done by result-row, which is a
                    // host fn itself, not an arg to another host fn).
                    if items.len() == 1 {
                        hc(host, op, &[])
                    } else {
                        let mut args = Vec::with_capacity(items.len() - 1);
                        for arg in &items[1..] {
                            args.push(eval_recursive(arg, env, host, tracer)?);
                        }
                        hc(host, op, &args)
                    }
                }
                _ => {
                    if items.len() == 1 {
                        state.stack.push(Frame::Apply {
                            func: SExpr::Void,
                            args: vec![],
                            evaluated: 0,
                        });
                        state.stack.push(Frame::Eval(items[0].clone()));
                    } else {
                        state.stack.push(Frame::Apply {
                            func: SExpr::Void,
                            args: items[1..].to_vec(),
                            evaluated: 0,
                        });
                        state.stack.push(Frame::Eval(items[0].clone()));
                    }
                    Ok(EvalResult::Pushed)
                }
            }
        }
    }
}

fn eval_special_form_frame(
    op: &str,
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    match op {
        "begin" => {
            if items.len() <= 1 {
                return Ok(EvalResult::Value(SExpr::Void));
            }
            for expr in items[1..].iter().rev() {
                state.stack.push(Frame::Eval(expr.clone()));
            }
            Ok(EvalResult::Pushed)
        }

        "when" => {
            if items.len() < 2 {
                return Err(EvalError::Arity {
                    name: "when".into(),
                    expected: "(when test body...+)",
                });
            }
            state.stack.push(Frame::WhenTest {
                condition: SExpr::Void,
                body: items[2..].to_vec(),
            });
            state.stack.push(Frame::Eval(items[1].clone()));
            Ok(EvalResult::Pushed)
        }

        "if" => {
            if items.len() < 3 {
                return Err(EvalError::Arity {
                    name: "if".into(),
                    expected: "(if test then [else])",
                });
            }
            state.stack.push(Frame::IfTest {
                condition: SExpr::Void,
                then_expr: Some(items[2].clone()),
                else_expr: items.get(3).cloned(),
            });
            state.stack.push(Frame::Eval(items[1].clone()));
            Ok(EvalResult::Pushed)
        }

        "let" | "let*" => {
            if items.len() < 3 {
                return Err(EvalError::Arity {
                    name: op.into(),
                    expected: "(let ((name val) ...) body...+)",
                });
            }
            let pairs = match &items[1] {
                SExpr::List(p) => p.clone(),
                _ => {
                    return Err(EvalError::Type {
                        expected: "list of (name expr) pairs",
                        got: format!("{:?}", items[1]),
                    });
                }
            };
            if op == "let*" {
                if !pairs.is_empty() {
                    state.stack.push(Frame::LetBindings {
                        op: op.to_string(),
                        pairs,
                        names: Vec::new(),
                        vals: Vec::new(),
                        current: 0,
                        body: items[2..].to_vec(),
                    });
                } else {
                    for expr in items[2..].iter().rev() {
                        state.stack.push(Frame::Eval(expr.clone()));
                    }
                }
                Ok(EvalResult::Pushed)
            } else {
                state.stack.push(Frame::LetBindings {
                    op: op.to_string(),
                    pairs,
                    names: Vec::new(),
                    vals: Vec::new(),
                    current: 0,
                    body: items[2..].to_vec(),
                });
                Ok(EvalResult::Pushed)
            }
        }

        "set!" => {
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
            state.stack.push(Frame::SetFrame {
                name,
                closure_env: env.bindings.clone(),
            });
            state.stack.push(Frame::Eval(items[2].clone()));
            Ok(EvalResult::Pushed)
        }

        "dbg" => {
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
            state.stack.push(Frame::DbgFrame { label });
            state.stack.push(Frame::Eval(items[expr_idx].clone()));
            Ok(EvalResult::Pushed)
        }

        "trace" => {
            if items.len() < 2 {
                return Err(EvalError::Arity {
                    name: "trace".into(),
                    expected: "(trace expr)",
                });
            }
            let val = match eval_with_yield(&items[1], env, host, tracer, Some(state))? {
                EvalStep::Done(v) => v,
                EvalStep::Yield(row) => return Ok(EvalResult::Yield(row)),
            };
            tracer.trace_log(&format!("[scheme] (trace): {}", crate::printer::write_scheme(&val)));
            Ok(EvalResult::Value(val))
        }

        "log" => {
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
                let val = match eval_with_yield(item, env, host, tracer, Some(state))? {
                    EvalStep::Done(v) => v,
                    EvalStep::Yield(row) => return Ok(EvalResult::Yield(row)),
                };
                out.push_str(&crate::printer::write_scheme(&val));
            }
            tracer.trace_log(&format!("[scheme] {out}"));
            Ok(EvalResult::Value(SExpr::Void))
        }

        "assert" => {
            if items.len() < 2 {
                return Err(EvalError::Arity {
                    name: "assert".into(),
                    expected: "(assert cond [msg])",
                });
            }
            let test = match eval_with_yield(&items[1], env, host, tracer, Some(state))? {
                EvalStep::Done(v) => v,
                EvalStep::Yield(row) => return Ok(EvalResult::Yield(row)),
            };
            if !is_truthy(&test) {
                let msg = if items.len() > 2 {
                    let m = match eval_with_yield(&items[2], env, host, tracer, Some(state))? {
                        EvalStep::Done(v) => v,
                        EvalStep::Yield(row) => return Ok(EvalResult::Yield(row)),
                    };
                    crate::printer::write_scheme(&m)
                } else {
                    "assertion failed".into()
                };
                return Err(EvalError::Other(format!("assertion: {msg}")));
            }
            Ok(EvalResult::Value(SExpr::Void))
        }

        "lambda" => {
            let result = eval_lambda(items, env)?;
            Ok(EvalResult::Value(result))
        }

        "depth-run" => eval_depth_run_frame(items, env, host, tracer, state),

        "depth-fixed" => eval_depth_fixed_frame(items, env, host, tracer, state),

        "scanner-iterate" => eval_scanner_iterate_frame(items, env, host, tracer, state),

        "ranges-create" => {
            if items.len() != 2 {
                return Err(EvalError::Arity {
                    name: "ranges-create".into(),
                    expected: "(ranges-create range-tree)",
                });
            }
            let result = process_ranges(&items[1], env, host, tracer)?;
            Ok(EvalResult::Value(result))
        }

        _ => unreachable!("checked by is_special_form"),
    }
}

/// Process a pending value on the stack (frame continuation).
/// Pop the top frame, apply the value, push result or new frames.
fn process_value(
    val: SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    let frame = match state.stack.pop() {
        Some(f) => f,
        None => return Ok(EvalResult::Value(val)),
    };

    match frame {
        Frame::Apply {
            func,
            args,
            evaluated,
        } => {
            if evaluated == 0 && func == SExpr::Void {
                if !args.is_empty() {
                    let first_arg = args[0].clone();
                    state.stack.push(Frame::Apply {
                        func: val,
                        args,
                        evaluated: 0,
                    });
                    state.stack.push(Frame::Eval(first_arg));
                    Ok(EvalResult::Pushed)
                } else {
                    match val {
                        SExpr::Symbol(ref name) if host.is_native(name) => {
                            hc(host, name, &[])
                        }
                        SExpr::Closure { params, body, env: closure_env } => {
                            if !params.is_empty() {
                                return Err(EvalError::Arity {
                                    name: "lambda".into(),
                                    expected: "matching arity",
                                });
                            }
                            state.stack.push(Frame::ClosureFrame {
                                body,
                                bound_env: closure_env,
                            });
                            Ok(EvalResult::Pushed)
                        }
                        _ => Ok(EvalResult::Value(val)),
                    }
                }
            } else {
                let mut new_args = args;
                new_args[evaluated] = val;
                let next = evaluated + 1;
                if next < new_args.len() {
                    let next_expr = new_args[next].clone();
                    state.stack.push(Frame::Apply {
                        func,
                        args: new_args,
                        evaluated: next,
                    });
                    state.stack.push(Frame::Eval(next_expr));
                    Ok(EvalResult::Pushed)
                } else {
                    match func {
                        SExpr::Symbol(ref name) if host.is_native(name) => {
                            match hc(host, name, &new_args)? {
                                EvalResult::Value(v) => process_value(v, env, host, state),
                                EvalResult::Yield(row) => Ok(EvalResult::Yield(row)),
                                EvalResult::Pushed => Ok(EvalResult::Pushed),
                            }
                        }
                        SExpr::Closure { params, body, env: closure_env } => {
                            if new_args.len() != params.len() {
                                return Err(EvalError::Arity {
                                    name: "lambda".into(),
                                    expected: "matching arity",
                                });
                            }
                            let mut bound_env = closure_env;
                            for (name, arg) in params.iter().zip(&new_args) {
                                bound_env.insert(name.clone(), arg.clone());
                            }
                            state.stack.push(Frame::ClosureFrame {
                                body,
                                bound_env,
                            });
                            Ok(EvalResult::Pushed)
                        }
                        _ => Err(EvalError::Other(format!(
                            "cannot apply: {}",
                            crate::printer::write_scheme(&func)
                        ))),
                    }
                }
            }
        }
        Frame::WhenTest { body, .. } => {
            if is_truthy(&val) {
                for expr in body.iter().rev() {
                    state.stack.push(Frame::Eval(expr.clone()));
                }
                Ok(EvalResult::Pushed)
            } else {
                Ok(EvalResult::Value(SExpr::Void))
            }
        }
        Frame::IfTest {
            then_expr,
            else_expr,
            ..
        } => {
            let branch = if is_truthy(&val) { then_expr } else { else_expr };
            match branch {
                Some(e) => {
                    state.stack.push(Frame::Eval(e));
                    Ok(EvalResult::Pushed)
                }
                None => Ok(EvalResult::Value(SExpr::Void)),
            }
        }
        Frame::SetFrame { name, closure_env } => {
            let mut e = Environment {
                bindings: closure_env,
                depth_counter: 0,
            };
            if e.get(&name).is_none() {
                return Err(EvalError::Unbound(name));
            }
            e.define(name, val.clone());
            Ok(EvalResult::Value(val))
        }
        Frame::DbgFrame { label } => {
            let _ = label;
            Ok(EvalResult::Value(val))
        }
        Frame::ClosureFrame { .. } => {
            unreachable!("ClosureFrame handled in run_eval main loop")
        }
        Frame::RestoreEnv { .. } => {
            Ok(EvalResult::Value(val))
        }
        Frame::DepthRunBody => {
            if !state.depth_runs.is_empty() {
                state.stack.push(Frame::DepthRunBody);
            }
            Ok(EvalResult::Pushed)
        }
        Frame::LetBindings {
            op,
            pairs,
            names,
            vals,
            current,
            body,
        } => {
            if current < pairs.len() {
                let pair = &pairs[current];
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
                        let mut new_names = names;
                        let mut new_vals = vals;
                        new_names.push(name);
                        new_vals.push(val);
                        state.stack.push(Frame::LetBindings {
                            op,
                            pairs,
                            names: new_names,
                            vals: new_vals,
                            current: current + 1,
                            body,
                        });
                        Ok(EvalResult::Pushed)
                    }
                    _ => unreachable!(),
                }
            } else {
                for (name, val) in names.into_iter().zip(vals) {
                    env.define(name, val);
                }
                if body.is_empty() {
                    Ok(EvalResult::Value(val))
                } else {
                    for expr in body.iter().rev() {
                        state.stack.push(Frame::Eval(expr.clone()));
                    }
                    Ok(EvalResult::Pushed)
                }
            }
        }
        Frame::Eval(e) => {
            // The previous expression produced a value, but there are more
            // expressions to evaluate. Discard the value and continue.
            state.stack.push(Frame::Eval(e));
            Ok(EvalResult::Pushed)
        }
    }
}

fn eval_depth_run_frame(
    items: &[SExpr],
    _env: &mut Environment,
    _host: &mut dyn HostFns,
    _tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    //   (depth-run scanners ranges (lambda () body))  — 4 args
    //   (depth-run scanners (lambda () body))         — 3 args
    let (ranges, lambda_item) = if items.len() == 4 {
        (&items[2], &items[3])
    } else if items.len() == 3 {
        (&SExpr::List(vec![]), &items[2])
    } else {
        return Err(EvalError::Arity {
            name: "depth-run".into(),
            expected: "(depth-run scanners [ranges] (lambda () body...))",
        });
    };
    let stage_key = state.depth_runs.len() as i64;
    let scanner_configs = match &items[1] {
        SExpr::List(pairs) => pairs.clone(),
        other => {
            return Err(EvalError::Type {
                expected: "list of scanner configs",
                got: format!("{other:?}"),
            });
        }
    };

    let processed_ranges = process_ranges(ranges, _env, _host, _tracer)?;

    let lambda = match lambda_item {
        SExpr::Symbol(name) => _env.get(name).cloned().ok_or_else(|| EvalError::Unbound(name.clone()))?,
        other => eval_recursive(other, _env, _host, _tracer)?,
    };
    let (body_exprs, captured_env, lambda_params) = match lambda {
        SExpr::Closure { params, body, env: closure_env } => { (body, closure_env, params) }
        _ => {
            return Err(EvalError::Type {
                expected: "lambda (closure)",
                got: format!("{lambda:?}"),
            });
        }
    };

    // Collect sids and call scanner-init for each scanner
    let mut sids: Vec<SExpr> = Vec::new();
    for config in &scanner_configs {
        let (scanner_ref, var_id) = if let SExpr::List(pair) = config {
            if pair.len() == 2 {
                (pair[0].clone(), sexpr_to_int(&pair[1]).unwrap_or(0) as i64)
            } else { (config.clone(), 0) }
        } else {
            (config.clone(), 0)
        };
        let scanner_val = eval_recursive(&scanner_ref, _env, _host, _tracer)?;
        expect_done(_host, "scanner-init", &[scanner_val.clone(), SExpr::Int(var_id)])?;
        sids.push(scanner_val);
    }

    let mut leap_args = vec![SExpr::Int(stage_key)];
    leap_args.extend(sids.clone());
    leap_args.push(processed_ranges.clone());
    let ok = expect_done(_host, "scheme-leap-init", &leap_args)?;
    if !is_truthy(&ok) {
        for sid_expr in &sids {
            expect_done(_host, "depth-cleanup", &[sid_expr.clone()])?;
        }
        return Ok(EvalResult::Value(SExpr::Void));
    }

    // Bind scanner value to lambda param name
    let param_name = if !lambda_params.is_empty() && !sids.is_empty() {
        let val = expect_done(_host, "scanner-read", &[sids[0].clone()])?;
        _env.define(lambda_params[0].clone(), val);
        Some(lambda_params[0].clone())
    } else {
        None
    };

    state.depth_runs.push(DepthRunFrame {
        stage_key,
        scanner_configs,
        body: body_exprs.clone(),
        captured_env: captured_env.clone(),
        phase: DepthRunPhase::Body,
        param_name,
        ranges: processed_ranges,
    });

    state.stack.push(Frame::DepthRunBody);
    for expr in body_exprs.iter().rev() {
        state.stack.push(Frame::Eval(expr.clone()));
    }

    Ok(EvalResult::Pushed)
}

fn eval_depth_fixed_frame(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    if items.len() != 4 {
        return Err(EvalError::Arity {
            name: "depth-fixed".into(),
            expected: "(depth-fixed (scanner-refs...) value-expr (lambda () body))",
        });
    }
    let scanner_configs = match &items[1] {
        SExpr::List(refs) => refs.clone(),
        _ => return Err(EvalError::Type { expected: "scanner refs list", got: format!("{:?}", items[1]) }),
    };
    let val = eval_recursive(&items[2], env, host, tracer)?;

    // Evaluate scanner configs to get resource values
    let scanners: Vec<SExpr> = scanner_configs.iter()
        .map(|config| eval_recursive(config, env, host, tracer))
        .collect::<Result<_, _>>()?;

    // Pré-callback: depth-fixed-bend(scanner0 scanner1 ... val)
    let mut begin_args: Vec<SExpr> = Vec::with_capacity(scanners.len() + 1);
    begin_args.extend(scanners.iter().cloned());
    begin_args.push(val);
    expect_done(host, "depth-fixed-begin", &begin_args)?;

    let lambda = match &items[3] {
        SExpr::Symbol(name) => env.get(name).cloned().ok_or_else(|| EvalError::Unbound(name.clone()))?,
        other => eval_recursive(other, env, host, tracer)?,
    };
    let (body_exprs, _captured_env) = match lambda {
        SExpr::Closure { params, body, .. } => {
            if !params.is_empty() {
                return Err(EvalError::Arity { name: "depth-fixed".into(), expected: "(lambda () body)" });
            }
            (body, ())
        }
        _ => return Err(EvalError::Type { expected: "lambda", got: format!("{lambda:?}") }),
    };

    // Pós-callback: (depth-fixed-end scanner0 scanner1 ...) como Frame::Eval
    let end_expr = SExpr::List({
        let mut items = vec![SExpr::Symbol("depth-fixed-end".into())];
        items.extend(scanner_configs); // re-evaluate from env (bindings unchanged)
        items
    });
    state.stack.push(Frame::Eval(end_expr));
    for expr in body_exprs.iter().rev() {
        state.stack.push(Frame::Eval(expr.clone()));
    }
    Ok(EvalResult::Pushed)
}

/// (scanner-iterate scanner-expr (param) [:ranges ranges-expr] body...)
///
/// Single-scanner iteration without lambda/closure. Binds `param` directly
/// in the current Environment. Reuses the `DepthRunBody` frame handler for
/// the loop — zero duplicated loop logic.
///
/// The optional `:ranges ranges-expr` keyword pair injects a flat ranges
/// value (produced by `ranges-create`) into scheme-leap-init / scheme-leap-next,
/// filtering the iterated values at the current scanner position.
fn eval_scanner_iterate_frame(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    state: &mut YieldState,
) -> Result<EvalResult, EvalError> {
    if items.len() < 4 {
        return Err(EvalError::Arity {
            name: "scanner-iterate".into(),
            expected: "(scanner-iterate scanner-expr (param) [:ranges ranges-expr] body...+)",
        });
    }
    let scanner_expr = &items[1];
    let params = match &items[2] {
        SExpr::List(p) if !p.is_empty() => p,
        _ => {
            return Err(EvalError::Type {
                expected: "(param) — non-empty list of symbols",
                got: crate::printer::write_scheme(&items[2]),
            })
        }
    };
    let param_name = match &params[0] {
        SExpr::Symbol(s) => s.clone(),
        other => {
            return Err(EvalError::Type {
                expected: "symbol",
                got: crate::printer::write_scheme(other),
            })
        }
    };

    // Parse the optional `:ranges ranges-expr` keyword from items[3..].
    // The keyword may appear in any position among the body forms; its value
    // is removed from the body sequence.
    let mut ranges_expr: Option<SExpr> = None;
    let mut body_exprs: Vec<SExpr> = Vec::new();
    let mut i = 3;
    while i < items.len() {
        if let SExpr::Symbol(s) = &items[i] {
            if s == ":ranges" {
                if ranges_expr.is_some() {
                    return Err(EvalError::Other(
                        "scanner-iterate: :ranges specified more than once".into(),
                    ));
                }
                if i + 1 >= items.len() {
                    return Err(EvalError::Other(
                        "scanner-iterate: :ranges requires a value".into(),
                    ));
                }
                ranges_expr = Some(items[i + 1].clone());
                i += 2;
                continue;
            }
        }
        body_exprs.push(items[i].clone());
        i += 1;
    }

    if body_exprs.is_empty() {
        return Err(EvalError::Arity {
            name: "scanner-iterate".into(),
            expected: "(scanner-iterate scanner-expr (param) [:ranges ranges-expr] body...+)",
        });
    }

    // Evaluate ranges-expr (if present) into the flat form used internally.
    // None → empty list (matches previous behavior — no filtering).
    let ranges_val = match ranges_expr {
        Some(e) => eval_recursive(&e, env, host, tracer)?,
        None => SExpr::List(vec![]),
    };

    // Eval scanner-expr → resource.
    // The cursor was already opened by scanner-open and is ready to use.
    let scanner_val = eval_recursive(scanner_expr, env, host, tracer)?;

    // scanner-seek-prefix: push_position (sets bound_prefix = prefix_bytes_cache)
    // + advance_to_active_at (finds first key matching prefix, or at_end).
    // Does NOT reopen the cursor — on second call, cursor is past prefix → at_end.
    expect_done(host, "scanner-seek-prefix", &[scanner_val.clone()])?;

    // scheme-leap-init(0, scanner, ranges) — checks if cursor has an active key
    // within the prefix. If cursor is past the prefix (second iterate), returns
    // false. When ranges is non-empty, apply_ranges also filters/positions.
    let leap_args = vec![SExpr::Int(0), scanner_val.clone(), ranges_val.clone()];
    let ok = expect_done(host, "scheme-leap-init", &leap_args)?;
    if !is_truthy(&ok) {
        // Scanner exhausted for this prefix — pop the position and return.
        expect_done(host, "depth-cleanup", &[scanner_val])?;
        return Ok(EvalResult::Value(SExpr::Void));
    }

    // scanner-read → bind param directly in env (no closure)
    let val = expect_done(host, "scanner-read", &[scanner_val.clone()])?;
    env.define(param_name.clone(), val);

    // Push DepthRunFrame — the DepthRunBody handler reuses this for the loop.
    let stage_key = state.depth_runs.len() as i64;
    state.depth_runs.push(DepthRunFrame {
        stage_key,
        scanner_configs: vec![scanner_val],
        body: body_exprs.clone(),
        captured_env: HashMap::new(),
        phase: DepthRunPhase::Body,
        param_name: Some(param_name),
        ranges: ranges_val,
    });

    state.stack.push(Frame::DepthRunBody);
    for expr in body_exprs.iter().rev() {
        state.stack.push(Frame::Eval(expr.clone()));
    }

    Ok(EvalResult::Pushed)
}

// ═══════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════

pub fn eval(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    match eval_with_yield(expr, env, host, tracer, None)? {
        EvalStep::Done(v) => Ok(v),
        EvalStep::Yield(_) => unreachable!("eval() does not yield"),
    }
}

pub fn eval_with_yield(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
    yield_state: Option<&mut YieldState>,
) -> Result<EvalStep, EvalError> {
    if let Some(state) = yield_state {
        run_eval(expr, env, host, tracer, state)
    } else {
        eval_recursive(expr, env, host, tracer).map(EvalStep::Done)
    }
}

// ═══════════════════════════════════════════════════════════════════
// Recursive evaluator (backward compatible, no yield support)
// ═══════════════════════════════════════════════════════════════════

fn eval_recursive(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if tracer.is_enabled() {
        tracer.trace_eval(expr);
    }
    let result = eval_recursive_inner(expr, env, host, tracer)?;
    if tracer.is_enabled() {
        tracer.trace_result(expr, &result);
    }
    Ok(result)
}

fn eval_recursive_inner(
    expr: &SExpr,
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    match expr {
        SExpr::Void | SExpr::Bool(_) | SExpr::Int(_) | SExpr::Float(_) | SExpr::Str(_)
        | SExpr::Bytes(_) | SExpr::Resource(_) | SExpr::Closure { .. } => Ok(expr.clone()),

        SExpr::Symbol(name) => env
            .get(name)
            .cloned()
            .ok_or_else(|| EvalError::Unbound(name.clone())),

        SExpr::List(items) if items.is_empty() => Ok(SExpr::Void),

        SExpr::List(items) => {
            match &items[0] {
                SExpr::Symbol(op) if is_special_form(op) => {
                    eval_special_form_recursive(op, items, env, host, tracer)
                }
                SExpr::Symbol(op) if host.is_native(op) => {
                    let mut args = Vec::with_capacity(items.len() - 1);
                    for arg in &items[1..] {
                        args.push(eval_recursive(arg, env, host, tracer)?);
                    }
                    expect_done(host, op, &args)
                }
                _ => {
                    let func = eval_recursive(&items[0], env, host, tracer)?;
                    let mut args = Vec::with_capacity(items.len() - 1);
                    for arg in &items[1..] {
                        args.push(eval_recursive(arg, env, host, tracer)?);
                    }
                    eval_apply_recursive(&func, &args, host)
                }
            }
        }
    }
}

fn eval_special_form_recursive(
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
        "lambda" => eval_lambda(items, env),
        "depth-run" => eval_depth_run_recursive(items, env, host, tracer),

        "depth-fixed" => eval_depth_fixed_recursive(items, env, host, tracer),

        "scanner-iterate" => Err(EvalError::Other(
            "scanner-iterate requires yield-mode evaluation (use SelectSchemeSession)".into(),
        )),

        "ranges-create" => {
            if items.len() != 2 {
                return Err(EvalError::Arity {
                    name: "ranges-create".into(),
                    expected: "(ranges-create range-tree)",
                });
            }
            process_ranges(&items[1], env, host, tracer)
        }

        _ => unreachable!("checked by is_special_form"),
    }
}

fn eval_depth_run_recursive(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    let (ranges, lambda_item) = if items.len() == 4 {
        (&items[2], &items[3])
    } else if items.len() == 3 {
        (&SExpr::List(vec![]), &items[2])
    } else {
        return Err(EvalError::Arity {
            name: "depth-run".into(),
            expected: "(depth-run scanners [ranges] (lambda () body...))",
        });
    };
    let stage_key = env.depth_counter;
    env.depth_counter += 1;
    let scanner_configs = match &items[1] {
        SExpr::List(pairs) => pairs.clone(),
        other => {
            return Err(EvalError::Type {
                expected: "list of scanner configs",
                got: format!("{other:?}"),
            });
        }
    };

    let processed_ranges = process_ranges(ranges, env, host, tracer)?;

    let lambda = match lambda_item {
        SExpr::Symbol(name) => env.get(name).cloned().ok_or_else(|| EvalError::Unbound(name.clone()))?,
        other => eval_recursive(other, env, host, tracer)?,
    };
    let (body_exprs, captured_env, lambda_params) = match lambda {
        SExpr::Closure { params, body, env: closure_env } => { (body, closure_env, params) }
        _ => {
            return Err(EvalError::Type {
                expected: "lambda (closure)",
                got: format!("{lambda:?}"),
            });
        }
    };

    loop {
        let mut sids: Vec<SExpr> = Vec::new();
        for config in &scanner_configs {
            let (scanner_ref, var_id) = if let SExpr::List(pair) = config {
                if pair.len() == 2 {
                    (pair[0].clone(), sexpr_to_int(&pair[1]).unwrap_or(0) as usize)
                } else { continue; }
            } else {
                (config.clone(), 0)
            };
            let scanner_val = eval_recursive(&scanner_ref, env, host, tracer)?;
            expect_done(host, "scanner-init", &[scanner_val.clone(), SExpr::Int(var_id as i64)])?;
            sids.push(scanner_val);
        }

        let mut leap_args = vec![SExpr::Int(stage_key as i64)];
        leap_args.extend(sids.clone());
        leap_args.push(processed_ranges.clone());
        let ok = expect_done(host, "scheme-leap-init", &leap_args)?;
        if !is_truthy(&ok) {
            break;
        }

        // Bind scanner value to lambda param
        let param_val = if !lambda_params.is_empty() && !sids.is_empty() {
            let val = expect_done(host, "scanner-read", &[sids[0].clone()])?;
            Some(val)
        } else {
            None
        };

        let mut inner_env = Environment {
            bindings: captured_env.clone(),
            depth_counter: env.depth_counter,
        };
        if let Some(ref val) = param_val {
            inner_env.define(lambda_params[0].clone(), val.clone());
        }
        for expr in &body_exprs {
            eval_recursive(expr, &mut inner_env, host, tracer)?;
        }

        let mut leap_next_args = vec![SExpr::Int(stage_key as i64)];
        leap_next_args.extend(sids.clone());
        leap_next_args.push(processed_ranges.clone());
        let ok = expect_done(host, "scheme-leap-next", &leap_next_args)?;
        if !is_truthy(&ok) {
            break;
        }
    }

    for config in &scanner_configs {
        let scanner_ref = if let SExpr::List(pair) = config {
            if !pair.is_empty() { &pair[0] } else { config }
        } else { config };
        let scanner_val = eval_recursive(scanner_ref, env, host, tracer)?;
        expect_done(host, "depth-cleanup", &[scanner_val])?;
    }
    Ok(SExpr::Void)
}

fn eval_depth_fixed_recursive(
    items: &[SExpr],
    env: &mut Environment,
    host: &mut dyn HostFns,
    tracer: &dyn SchemeTracer,
) -> Result<SExpr, EvalError> {
    if items.len() != 4 {
        return Err(EvalError::Arity {
            name: "depth-fixed".into(),
            expected: "(depth-fixed (scanner-refs...) value-expr (lambda () body))",
        });
    }
    let scanner_configs = match &items[1] {
        SExpr::List(refs) => refs.clone(),
        _ => return Err(EvalError::Type { expected: "scanner refs list", got: format!("{:?}", items[1]) }),
    };
    let val = eval_recursive(&items[2], env, host, tracer)?;

    let scanners: Vec<SExpr> = scanner_configs.iter()
        .map(|config| eval_recursive(config, env, host, tracer))
        .collect::<Result<_, _>>()?;

    let mut begin_args: Vec<SExpr> = Vec::with_capacity(scanners.len() + 1);
    begin_args.extend(scanners.iter().cloned());
    begin_args.push(val);
    expect_done(host, "depth-fixed-begin", &begin_args)?;

    let lambda = match &items[3] {
        SExpr::Symbol(name) => env.get(name).cloned().ok_or_else(|| EvalError::Unbound(name.clone()))?,
        other => eval_recursive(other, env, host, tracer)?,
    };
    let (body_exprs, captured_env) = match lambda {
        SExpr::Closure { params, body, env: closure_env } => {
            if !params.is_empty() {
                return Err(EvalError::Arity { name: "depth-fixed".into(), expected: "(lambda () body)" });
            }
            (body, closure_env)
        }
        _ => return Err(EvalError::Type { expected: "lambda", got: format!("{lambda:?}") }),
    };
    let mut inner_env = Environment { bindings: captured_env, depth_counter: 0 };
    for expr in &body_exprs {
        eval_recursive(expr, &mut inner_env, host, tracer)?;
    }
    expect_done(host, "depth-fixed-end", &scanners)?;
    Ok(SExpr::Void)
}

// ═══════════════════════════════════════════════════════════════════
// Shared helpers
// ═══════════════════════════════════════════════════════════════════

fn is_special_form(name: &str) -> bool {
    matches!(
        name,
        "let*" | "let" | "when" | "if" | "begin" | "set!" | "dbg" | "trace" | "log" | "assert"
            | "lambda" | "depth-run" | "depth-fixed" | "scanner-iterate" | "ranges-create"
    )
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
                    let val = eval_recursive(&pair_items[1], env, host, tracer)?;
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
                    let val = eval_recursive(&pair_items[1], env, host, tracer)?;
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
        result = eval_recursive(body, env, host, tracer)?;
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
    let test = eval_recursive(&items[1], env, host, tracer)?;
    if is_truthy(&test) {
        let mut result = SExpr::Void;
        for body in &items[2..] {
            result = eval_recursive(body, env, host, tracer)?;
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
    let test = eval_recursive(&items[1], env, host, tracer)?;
    if is_truthy(&test) {
        eval_recursive(&items[2], env, host, tracer)
    } else if items.len() > 3 {
        eval_recursive(&items[3], env, host, tracer)
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
        result = eval_recursive(expr, env, host, tracer)?;
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
    let val = eval_recursive(&items[2], env, host, tracer)?;
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
    let val = eval_recursive(&items[expr_idx], env, host, tracer)?;
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
    let val = eval_recursive(&items[1], env, host, tracer)?;
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
        let val = eval_recursive(item, env, host, tracer)?;
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
    let test = eval_recursive(&items[1], env, host, tracer)?;
    if !is_truthy(&test) {
        let msg = if items.len() > 2 {
            let m = eval_recursive(&items[2], env, host, tracer)?;
            crate::printer::write_scheme(&m)
        } else {
            "assertion failed".into()
        };
        return Err(EvalError::Other(format!("assertion: {msg}")));
    }
    Ok(SExpr::Void)
}

fn eval_lambda(
    items: &[SExpr],
    env: &Environment,
) -> Result<SExpr, EvalError> {
    if items.len() < 2 {
        return Err(EvalError::Arity {
            name: "lambda".into(),
            expected: "(lambda (params...) body...+)",
        });
    }
    let params = match &items[1] {
        SExpr::List(pairs) => {
            let mut p = Vec::new();
            for item in pairs {
                match item {
                    SExpr::Symbol(s) => p.push(s.clone()),
                    _ => {
                        return Err(EvalError::Type {
                            expected: "symbol in param list",
                            got: format!("{item:?}"),
                        });
                    }
                }
            }
            p
        }
        _ => {
            return Err(EvalError::Type {
                expected: "parameter list",
                got: format!("{:?}", items[1]),
            });
        }
    };
    if items.len() < 3 {
        return Err(EvalError::Arity {
            name: "lambda".into(),
            expected: "(lambda (params...) body...+)",
        });
    }
    let body = items[2..].to_vec();
    let captured = env.bindings.clone();
    Ok(SExpr::Closure { params, body, env: captured })
}

fn eval_apply_recursive(
    func: &SExpr,
    args: &[SExpr],
    host: &mut dyn HostFns,
) -> Result<SExpr, EvalError> {
    match func {
        SExpr::Closure { params, body, env: closure_env } => {
            if args.len() != params.len() {
                return Err(EvalError::Arity {
                    name: "lambda".into(),
                    expected: "matching arity",
                });
            }
            let mut inner_env = Environment {
                bindings: closure_env.clone(),
                depth_counter: 0,
            };
            for (name, arg) in params.iter().zip(args) {
                inner_env.define(name.clone(), arg.clone());
            }
            let mut result = SExpr::Void;
            for expr in body {
                result = eval_recursive(expr, &mut inner_env, host, &NullTracer)?;
            }
            Ok(result)
        }
        SExpr::Symbol(name) => {
            if host.is_native(name) {
                expect_done(host, name, args)
            } else {
                Err(EvalError::NotFound(name.into()))
            }
        }
        _ => Err(EvalError::Other(format!(
            "cannot apply non-symbol: {}",
            crate::printer::write_scheme(func)
        ))),
    }
}

fn sexpr_to_int(expr: &SExpr) -> Result<i64, EvalError> {
    match expr {
        SExpr::Int(n) => Ok(*n),
        SExpr::Float(f) => Ok(*f as i64),
        SExpr::Symbol(name) => Err(EvalError::Type {
            expected: "int",
            got: format!("symbol '{name}'"),
        }),
        other => Err(EvalError::Type {
            expected: "int",
            got: format!("{other:?}"),
        }),
    }
}

fn is_truthy(expr: &SExpr) -> bool {
    !matches!(expr, SExpr::Void | SExpr::Bool(false))
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::NullTracer;
    use crate::parser::parse;
    use crate::printer::write_scheme;

    struct MockHost;

    impl HostFns for MockHost {
        fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, EvalError> {
            match name {
                "+" | "-" | "*" if args.len() != 2 => {
                    Err(EvalError::Arity { name: name.into(), expected: "2 args" })
                }
                "+" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(EvalStep::Done(SExpr::Int(a + b)))
                }
                "-" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(EvalStep::Done(SExpr::Int(a - b)))
                }
                "*" => {
                    let a = expect_int(&args[0])?;
                    let b = expect_int(&args[1])?;
                    Ok(EvalStep::Done(SExpr::Int(a * b)))
                }
                "save" => Ok(EvalStep::Done(SExpr::Void)),
                "result" => Ok(EvalStep::Done(SExpr::Void)),
                "scanner-init" => Ok(EvalStep::Done(SExpr::Void)),
                "scheme-leap-init" => Ok(EvalStep::Done(SExpr::Bool(true))),
                "scheme-leap-next" => Ok(EvalStep::Done(SExpr::Bool(false))),
                "depth-cleanup" => Ok(EvalStep::Done(SExpr::Void)),
                "result-row" => Ok(EvalStep::Done(SExpr::Void)),
                "bind-get" => Ok(EvalStep::Done(SExpr::Int(42))),
                _ => Err(EvalError::NotFound(name.into())),
            }
        }

        fn is_native(&self, name: &str) -> bool {
            matches!(name, "+" | "-" | "*" | "save" | "result" | "depth-run" | "scanner-init" | "scheme-leap-init" | "scheme-leap-next" | "depth-cleanup" | "result-row" | "bind-get")
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

    #[test]
    fn lambda_creates_closure() {
        let result = run("(lambda () 42)").unwrap();
        assert!(matches!(result, SExpr::Closure { .. }));
    }

    #[test]
    fn lambda_application() {
        assert_eq!(run("((lambda (x) (+ x 1)) 5)").unwrap(), SExpr::Int(6));
    }

    #[test]
    fn lambda_captures_env() {
        let input = "(let* ((y 10)) ((lambda (x) (+ x y)) 5))";
        assert_eq!(run(input).unwrap(), SExpr::Int(15));
    }

    #[test]
    fn depth_run_calls_host() {
        let result = run("(depth-run () (lambda () 42))").unwrap();
        assert_eq!(result, SExpr::Void);
    }

    #[test]
    fn depth_run_with_let_binding() {
        let input = "(let* ((f (lambda () 1))) (depth-run () f))";
        let result = run(input).unwrap();
        assert_eq!(result, SExpr::Void);
    }

    #[test]
    fn depth_run_loops_when_leap_next_returns_true() {
        use std::cell::Cell;

        struct CountingHost<'a> {
            leap_next_count: &'a Cell<u32>,
            max_leap_next: u32,
        }

        impl<'a> HostFns for CountingHost<'a> {
            fn is_native(&self, name: &str) -> bool {
                matches!(
                    name,
                    "scanner-init"
                        | "scheme-leap-init"
                        | "scheme-leap-next"
                        | "depth-cleanup"
                        | "result-row"
                        | "bind-get"
                )
            }

            fn call(&mut self, name: &str, _args: &[SExpr]) -> Result<EvalStep, EvalError> {
                match name {
                    "scanner-init" => Ok(EvalStep::Done(SExpr::Void)),
                    "scheme-leap-init" => Ok(EvalStep::Done(SExpr::Bool(true))),
                    "scheme-leap-next" => {
                        let n = self.leap_next_count.get();
                        self.leap_next_count.set(n + 1);
                        Ok(EvalStep::Done(SExpr::Bool(n + 1 < self.max_leap_next)))
                    }
                    "depth-cleanup" => Ok(EvalStep::Done(SExpr::Void)),
                    "result-row" => Ok(EvalStep::Done(SExpr::Void)),
                    "bind-get" => Ok(EvalStep::Done(SExpr::Int(42))),
                    _ => Err(EvalError::NotFound(name.into())),
                }
            }
        }

        let leap_next_count = Cell::new(0u32);

        let input = "(depth-run () (lambda () (begin (bind-get 0) 42)))";
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = CountingHost {
            leap_next_count: &leap_next_count,
            max_leap_next: 3,
        };
        let result = eval(&expr, &mut env, &mut host, &NullTracer).unwrap();
        assert_eq!(result, SExpr::Void);
        assert_eq!(leap_next_count.get(), 3);
    }

    #[test]
    fn depth_run_nested() {
        use std::collections::HashMap;
        use std::cell::RefCell;

        struct NestedHost<'a> {
            call_counts: &'a RefCell<HashMap<i64, u32>>,
            limits: HashMap<i64, u32>,
        }

        impl<'a> HostFns for NestedHost<'a> {
            fn is_native(&self, name: &str) -> bool {
                matches!(
                    name,
                    "scanner-init"
                        | "scheme-leap-init"
                        | "scheme-leap-next"
                        | "depth-cleanup"
                        | "result-row"
                        | "bind-get"
                )
            }

            fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, EvalError> {
                match name {
                    "scanner-init" => Ok(EvalStep::Done(SExpr::Void)),
                    "scheme-leap-init" => Ok(EvalStep::Done(SExpr::Bool(true))),
                    "scheme-leap-next" => {
                        let depth = super::sexpr_to_int(&args[0]).unwrap_or(0);
                        let mut counts = self.call_counts.borrow_mut();
                        let n = *counts.entry(depth).or_insert(0);
                        counts.insert(depth, n + 1);
                        let limit = self.limits.get(&depth).copied().unwrap_or(0);
                        Ok(EvalStep::Done(SExpr::Bool(n + 1 < limit)))
                    }
                    "depth-cleanup" => Ok(EvalStep::Done(SExpr::Void)),
                    "result-row" => Ok(EvalStep::Done(SExpr::Void)),
                    "bind-get" => Ok(EvalStep::Done(SExpr::Int(1))),
                    _ => Err(EvalError::NotFound(name.into())),
                }
            }
        }

        let call_counts = RefCell::new(HashMap::new());
        let mut limits = HashMap::new();
        limits.insert(0, 3);
        limits.insert(1, 3);

        let input = "\
            (depth-run () (lambda () \
                (depth-run () (lambda () \
                    (result-row 1 2)))))";
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = NestedHost {
            call_counts: &call_counts,
            limits,
        };
        let result = eval(&expr, &mut env, &mut host, &NullTracer).unwrap();
        assert_eq!(result, SExpr::Void);
        let counts = call_counts.borrow();
        assert!(counts.get(&0).copied().unwrap_or(0) >= 3, "outer should have at least 3 leap-next calls");
        assert!(counts.get(&1).copied().unwrap_or(0) >= 3, "inner should have at least 3 leap-next calls");
    }

    // ── yield / resume tests ────────────────────────────────────────

    struct YieldingHost {
        rows: Vec<Vec<i64>>,
        yield_after: usize,
        call_count: usize,
    }

    impl HostFns for YieldingHost {
        fn is_native(&self, name: &str) -> bool {
            matches!(name, "result-row")
        }
        fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, EvalError> {
            match name {
                "result-row" => {
                    self.call_count += 1;
                    let row: Vec<i64> = args.iter().filter_map(|a| match a {
                        SExpr::Int(n) => Some(*n),
                        _ => None,
                    }).collect();
                    self.rows.push(row);
                    if self.yield_after > 0 && self.call_count % self.yield_after == 0 {
                        Ok(EvalStep::Yield(SExpr::Void))
                    } else {
                        Ok(EvalStep::Done(SExpr::Void))
                    }
                }
                _ => Err(EvalError::NotFound(name.into())),
            }
        }
    }

    #[test]
    fn yield_resume_basic() {
        let input = "(begin (result-row 1) (result-row 2) (result-row 3))";
        let expr = parse(input).unwrap();
        let mut host = YieldingHost { rows: vec![], yield_after: 1, call_count: 0 };
        let mut env = Environment::new();
        let mut state = YieldState::default();

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![1]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![1], vec![2]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![1], vec![2], vec![3]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(r.is_ok());
        assert_eq!(host.rows.len(), 3);
    }

    #[test]
    fn yield_resume_no_yield() {
        let input = "(begin (result-row 10) (result-row 20))";
        let expr = parse(input).unwrap();
        let mut host = YieldingHost { rows: vec![], yield_after: 0, call_count: 0 };
        let mut env = Environment::new();
        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, None);
        assert!(r.is_ok());
        assert_eq!(host.rows, vec![vec![10], vec![20]]);
    }

    #[test]
    fn yield_resume_in_when_true() {
        let input = "(when #t (begin (result-row 1) (result-row 2)))";
        let expr = parse(input).unwrap();
        let mut host = YieldingHost { rows: vec![], yield_after: 1, call_count: 0 };
        let mut env = Environment::new();
        let mut state = YieldState::default();

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![1]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![1], vec![2]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(r.is_ok());
    }

    #[test]
    fn yield_resume_in_lambda_body() {
        let input = "((lambda () (begin (result-row 100) (result-row 200))))";
        let expr = parse(input).unwrap();
        let mut host = YieldingHost { rows: vec![], yield_after: 1, call_count: 0 };
        let mut env = Environment::new();
        let mut state = YieldState::default();

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![100]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows, vec![vec![100], vec![200]]);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(r.is_ok());
    }

    #[test]
    fn yield_resume_depth_run() {
        use std::cell::Cell;

        struct DepthYieldHost<'a> {
            leap_next_count: &'a Cell<u32>,
            max_loops: u32,
            rows: Vec<Vec<i64>>,
            yield_count: usize,
        }

        impl<'a> HostFns for DepthYieldHost<'a> {
            fn is_native(&self, name: &str) -> bool {
                matches!(name, "scanner-init" | "scheme-leap-init" | "scheme-leap-next"
                    | "depth-cleanup" | "result-row" | "bind-get")
            }
            fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, EvalError> {
                match name {
                    "scanner-init" => Ok(EvalStep::Done(SExpr::Void)),
                    "scheme-leap-init" => Ok(EvalStep::Done(SExpr::Bool(true))),
                    "scheme-leap-next" => {
                        let n = self.leap_next_count.get();
                        self.leap_next_count.set(n + 1);
                        Ok(EvalStep::Done(SExpr::Bool(n + 1 < self.max_loops)))
                    }
                    "depth-cleanup" => Ok(EvalStep::Done(SExpr::Void)),
                    "bind-get" => Ok(EvalStep::Done(SExpr::Int(42))),
                    "result-row" => {
                        self.yield_count += 1;
                        let row: Vec<i64> = args.iter().filter_map(|a| match a {
                            SExpr::Int(n) => Some(*n),
                            _ => None,
                        }).collect();
                        self.rows.push(row);
                        Ok(EvalStep::Yield(SExpr::Void))
                    }
                    _ => Err(EvalError::NotFound(name.into())),
                }
            }
        }

        let leap_next_count = Cell::new(0u32);
        let input = "(depth-run () (lambda () (result-row 42)))";
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = DepthYieldHost {
            leap_next_count: &leap_next_count,
            max_loops: 3,
            rows: vec![],
            yield_count: 0,
        };
        let mut state = YieldState::default();

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows.len(), 1);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows.len(), 2);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(matches!(r, Ok(EvalStep::Yield(_))));
        assert_eq!(host.rows.len(), 3);

        let r = eval_with_yield(&expr, &mut env, &mut host, &NullTracer, Some(&mut state));
        assert!(r.is_ok());
        assert_eq!(host.rows.len(), 3);
        assert_eq!(leap_next_count.get(), 3);
    }

    #[test]
    fn let_with_returning_host_fn() {
        // Test that let* correctly binds a value returned by a host function
        struct SidHost {
            next: i64,
        }
        impl HostFns for SidHost {
            fn is_native(&self, name: &str) -> bool {
                name == "scanner-open" || name == "result-row"
            }
            fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, EvalError> {
                match name {
                    "scanner-open" => {
                        let sid = self.next;
                        self.next += 1;
                        Ok(EvalStep::Done(SExpr::Int(sid)))
                    }
                    "result-row" => {
                        Ok(EvalStep::Done(args[0].clone()))
                    }
                    _ => Err(EvalError::NotFound(name.into())),
                }
            }
        }

        // (let* ((s0 (scanner-open))) (result-row s0))
        // s0 should be 0
        let input = "(let* ((s0 (scanner-open))) (result-row s0))";
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = SidHost { next: 0 };
        let result = eval(&expr, &mut env, &mut host, &NullTracer).unwrap();
        assert_eq!(result, SExpr::Int(0));

        // (let* ((s0 (scanner-open)) (s1 (scanner-open))) (result-row s1))
        // s1 should be 1
        let input = "(let* ((s0 (scanner-open)) (s1 (scanner-open))) (result-row s1))";
        let expr = parse(input).unwrap();
        let mut env = Environment::new();
        let mut host = SidHost { next: 0 };
        let result = eval(&expr, &mut env, &mut host, &NullTracer).unwrap();
        assert_eq!(result, SExpr::Int(1));
    }
}
