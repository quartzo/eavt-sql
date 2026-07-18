use std::sync::{Arc, Mutex};

use spier_scheme::{Environment, EvalStep, Opaque, SchemeProgram, SExpr, YieldState, eval};
use spier_value::query_codec;
use spier_value::Value;

use crate::engine::query_engine_inner::QueryEngineInner;
use crate::engine::scanner::V2Scanner;
use crate::engine::types::{ops_to_intervals, merge_intervals, BoundPart, EngineOps, QueryContext, RangeSpec, RANGE_LO_OPEN, RANGE_HI_OPEN, probe_value_matches};
use crate::VMResultStream;

fn extract_scanner<'a>(expr: &'a SExpr) -> Result<&'a Mutex<V2Scanner>, spier_scheme::EvalError> {
    match expr {
        SExpr::Resource(opaque) => opaque.0.downcast_ref::<Mutex<V2Scanner>>()
            .ok_or_else(|| spier_scheme::EvalError::Host("expected scanner resource".into())),
        _ => Err(spier_scheme::EvalError::Type {
            expected: "scanner resource",
            got: spier_scheme::write_scheme(expr),
        }),
    }
}

pub struct SchemeSession {
    program: SchemeProgram,
    engine: Arc<QueryEngineInner>,
    params: Vec<Value>,
    tx: u64,
    as_of_tx: Option<u64>,
    done: bool,
}

impl SchemeSession {
    pub fn new(
        program: SchemeProgram,
        engine: Arc<QueryEngineInner>,
        params: Vec<Value>,
        tx: u64,
        as_of_tx: Option<u64>,
    ) -> Self {
        Self {
            program,
            engine,
            params,
            tx,
            as_of_tx,
            done: false,
        }
    }
}

impl VMResultStream for SchemeSession {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String> {
        if self.done || max_rows == 0 {
            return Ok(false);
        }

        let mut host = SchemeHostFns::new(
            Arc::clone(&self.engine),
            self.params.clone(),
            self.tx,
            self.as_of_tx,
        );
        let mut env = Environment::new();
        let tracer = spier_scheme::NullTracer;

        let result = eval(&self.program.body, &mut env, &mut host, &tracer)
            .map_err(|e| format!("scheme eval error: {e}"))?;

        match result {
            SExpr::List(items)
                if items.len() >= 2
                    && matches!(items[0], SExpr::Symbol(ref s) if s == "result") =>
            {
                let cols = &items[1..];
                out.extend_from_slice(&(cols.len() as u32).to_be_bytes());
                for item in cols {
                    let val = sexpr_to_value(item)?;
                    query_codec::encode_one(out, &val);
                }
            }
            SExpr::Void => {
                out.extend_from_slice(&0u32.to_be_bytes());
            }
            _ => {
                out.extend_from_slice(&0u32.to_be_bytes());
            }
        }

        self.done = true;
        Ok(false)
    }
}

fn sexpr_to_value(expr: &SExpr) -> Result<Value, String> {
    match expr {
        SExpr::Int(n) => Ok(Value::Int64(*n)),
        SExpr::Float(f) => Ok(Value::Float64(*f)),
        SExpr::Str(s) => Ok(Value::Text(s.clone())),
        SExpr::Bool(b) => Ok(Value::Bool(*b as u8)),
        SExpr::Bytes(b) => Ok(Value::Bytes(b.clone())),
        SExpr::Void => Ok(Value::Timestamp(0)),
        other => Err(format!(
            "scheme: cannot convert {} to storage value",
            spier_scheme::write_scheme(other)
        )),
    }
}

fn expect_int(expr: &SExpr) -> Result<i64, spier_scheme::EvalError> {
    match expr {
        SExpr::Int(n) => Ok(*n),
        SExpr::Float(f) => Ok(*f as i64),
        other => Err(spier_scheme::EvalError::Type {
            expected: "int",
            got: spier_scheme::write_scheme(other),
        }),
    }
}

fn is_float(expr: &SExpr) -> bool {
    matches!(expr, SExpr::Float(_))
}

fn sexpr_num_to_f64(expr: &SExpr) -> Result<f64, spier_scheme::EvalError> {
    match expr {
        SExpr::Int(n) => Ok(*n as f64),
        SExpr::Float(f) => Ok(*f),
        other => Err(spier_scheme::EvalError::Type {
            expected: "number",
            got: spier_scheme::write_scheme(other),
        }),
    }
}

fn expect_str(expr: &SExpr) -> Result<String, spier_scheme::EvalError> {
    match expr {
        SExpr::Str(s) => Ok(s.clone()),
        SExpr::Symbol(s) => Ok(s.clone()),
        other => Err(spier_scheme::EvalError::Type {
            expected: "string",
            got: spier_scheme::write_scheme(other),
        }),
    }
}

fn value_to_sexpr(val: &Value) -> Result<SExpr, spier_scheme::EvalError> {
    match val {
        Value::Int64(n) => Ok(SExpr::Int(*n)),
        Value::Float64(f) => Ok(SExpr::Float(*f)),
        Value::Text(s) => Ok(SExpr::Str(s.clone())),
        Value::Bool(b) => Ok(SExpr::Bool(*b != 0)),
        Value::Timestamp(ts) => Ok(SExpr::Int(*ts)),
        Value::Bytes(b) => Ok(SExpr::Bytes(b.clone())),
        Value::Unknown(tag, _) => Err(spier_scheme::EvalError::Type {
            expected: "concrete value",
            got: format!("unknown(tag={tag})"),
        }),
    }
}

/// Format a `Value` for human-readable range display (e.g. `(10, 20]`).
fn format_value_for_range(val: &Value) -> String {
    match val {
        Value::Int64(n) => n.to_string(),
        Value::Float64(f) => f.to_string(),
        Value::Bool(b) => (if *b != 0 { "true" } else { "false" }).to_string(),
        Value::Timestamp(ts) => format!("ts:{ts}"),
        Value::Text(s) => format!("\"{s}\""),
        Value::Bytes(b) => format!("bytes({})", b.len()),
        Value::Unknown(tag, raw) => format!("?(tag={tag},raw={raw})"),
    }
}

// ---------------------------------------------------------------------------
// SchemeHostFns — unified host functions for the Scheme evaluator
// ---------------------------------------------------------------------------

pub struct SchemeHostFns {
    engine: Arc<QueryEngineInner>,
    params: Vec<Value>,
    ctx: QueryContext,
}

impl SchemeHostFns {
    pub fn new(
        engine: Arc<QueryEngineInner>,
        params: Vec<Value>,
        tx: u64,
        as_of_tx: Option<u64>,
    ) -> Self {
        Self {
            engine,
            params,
            ctx: QueryContext { as_of_tx, current_t: tx },
        }
    }

    fn parse_ranges(sexpr: &SExpr) -> Result<Vec<Vec<(i32, Value)>>, spier_scheme::EvalError> {
        let items = match sexpr {
            SExpr::List(items) => items,
            _ => return Ok(Vec::new()),
        };
        let mut ranges: Vec<Vec<(i32, Value)>> = Vec::new();
        let mut branch: Vec<(i32, Value)> = Vec::new();
        for item in items {
            match item {
                SExpr::List(parts) if parts.len() == 1 => {
                    if let SExpr::Symbol(s) = &parts[0] {
                        if s == "branch" {
                            if !branch.is_empty() {
                                ranges.push(std::mem::take(&mut branch));
                            }
                            continue;
                        }
                    }
                }
                SExpr::List(parts) if parts.len() >= 3 => {
                    if let SExpr::Symbol(s) = &parts[0] {
                        if s == "cond" {
                            let op = expect_int(&parts[1])? as i32;
                            let val = sexpr_to_value(&parts[2])
                        .map_err(|e| spier_scheme::EvalError::Host(e))?;
                            branch.push((op, val));
                            continue;
                        }
                    }
                }
                _ => {}
            }
        }
        if !branch.is_empty() {
            ranges.push(branch);
        }
        Ok(ranges)
    }

    // -- Leapfrog internals --

    fn leap_converge(scanners: &[&Mutex<V2Scanner>]) -> bool {
        let max_iters = scanners.len() * 2 + 1;
        for _ in 0..max_iters {
            let mut max_val: Option<Value> = None;
            let mut all_equal = true;
            let mut at_end_indices: Vec<usize> = Vec::new();
            for (i, scanner) in scanners.iter().enumerate() {
                let s = scanner.lock().unwrap();
                if let Some(v) = s.extract_current() {
                    match &max_val {
                        None => max_val = Some(v),
                        Some(mv) if v != *mv => {
                            all_equal = false;
                            if v > *mv { max_val = Some(v); }
                        }
                        _ => {}
                    }
                } else {
                    // Scanner is at_end — don't give up yet; seek it later
                    at_end_indices.push(i);
                    all_equal = false;
                }
            }
            if all_equal { return true; }
            if let Some(ref mv) = max_val {
                // Seek slow scanners AND scanners that were at_end
                for (i, scanner) in scanners.iter().enumerate() {
                    let needs_seek = {
                        let s = scanner.lock().unwrap();
                        matches!(s.extract_current(), Some(v) if v < *mv) || at_end_indices.contains(&i)
                    };
                    if needs_seek {
                        let mut s = scanner.lock().unwrap();
                        s.seek_to_value(mv);
                        if s.at_end() { return false; }
                    }
                }
            } else {
                // All scanners are at_end — no max_val to seek to
                return false;
            }
        }
        false
    }

    fn apply_ranges(scanners: &[&Mutex<V2Scanner>], raw_ops: &[Vec<(i32, Value)>]) -> bool {
        if raw_ops.is_empty() { return true; }

        let mut all_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
        for branch in raw_ops {
            all_intervals.extend(ops_to_intervals(branch));
        }
        let range_specs: Vec<RangeSpec> = merge_intervals(all_intervals)
            .into_iter()
            .map(|(lo, hi, flags)| RangeSpec { lo, hi, flags })
            .collect();

        if range_specs.is_empty() { return false; }

        let max_iter = range_specs.len() + 2;
        for _ in 0..max_iter {
            let cur = {
                let scanner = scanners[0].lock().unwrap();
                match scanner.extract_current() {
                    Some(v) => v,
                    None => return false,
                }
            };
            let mut any_applied = false;
            for spec in &range_specs {
                if let Some(ref hi) = spec.hi {
                    let hi_open = spec.flags & RANGE_HI_OPEN != 0;
                    let past_hi = if hi_open { &cur >= hi } else { &cur > hi };
                    if past_hi { continue; }
                }
                if let Some(ref lo) = spec.lo {
                    let lo_open = spec.flags & RANGE_LO_OPEN != 0;
                    let before_lo = if lo_open { &cur <= lo } else { &cur < lo };
                    if before_lo {
                        if std::mem::discriminant(&cur) != std::mem::discriminant(lo) { return false; }
                        for scanner in scanners {
                            let mut s = scanner.lock().unwrap();
                            s.seek_to_value(lo);
                        }
                        if !Self::leap_converge(scanners) { return false; }
                        if lo_open {
                            let at_lo = {
                                let scanner = scanners[0].lock().unwrap();
                                scanner.extract_current().map_or(false, |v| &v == lo)
                            };
                            if at_lo {
                                for scanner in scanners {
                                    let mut s = scanner.lock().unwrap();
                                    s.leap_next_at();
                                }
                                if !Self::leap_converge(scanners) { return false; }
                            }
                        }
                        any_applied = true;
                        break;
                    } else {
                        return true;
                    }
                } else {
                    return true;
                }
            }
            if !any_applied { return false; }
        }
        false
    }
}

impl spier_scheme::HostFns for SchemeHostFns {
    fn is_native(&self, name: &str) -> bool {
        matches!(
            name,
            "alloc-entity" | "tx-entity" | "param"
                | "lookup-entity" | "lookup-value"
                | "save" | "retract" | "result"
                | "declare-attr" | "declare-partition"
                | "scanner-open" | "scanner-read"
                | "scanner-push" | "scanner-pop" | "scanner-prefix"
                | "scheme-leap-init" | "scheme-leap-next"
                | "intern-a" | "result-row"
                | "resolve-val" | "attr-name"
                | "dbg-scanners" | "ranges-show"
                | "+" | "-" | "*" | "/" | "mod"
                | "<" | ">" | "=" | "!=" | "<=" | ">="
                | "min" | "max" | "abs"
        )
    }

    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, spier_scheme::EvalError> {
        let he = spier_scheme::EvalError::Host;
        match name {
            // -- Scanner open --

            "scanner-open" => {
                let index_name = expect_str(&args[0])?;
                let history = args.get(1).map_or(false, |a| matches!(a, SExpr::Bool(true)));
                let upper = index_name.to_ascii_uppercase();
                let base_order : &[&str] = match upper.as_str() {
                    "EAVT" => &["e", "a", "v"],
                    "AEVT" => &["a", "e", "v"],
                    "AVET" => &["a", "v", "e"],
                    "VAET" => &["v", "a", "e"],
                    _ => &["e", "a", "v"],
                };
                let idx_order: Vec<String> = base_order.iter()
                    .chain(["t", "added"].iter())
                    .map(|s| s.to_string())
                    .collect();
                let mut scanner = V2Scanner::new(&index_name, idx_order, self.ctx.as_of_tx, None);
                if history { scanner.set_history_mode(); }

                // Open cursor immediately at the start of the index (empty prefix).
                // The cursor is ready to use — no separate "init" step required.
                let cf_id: u32 = match upper.as_str() {
                    "AEVT" => 1, "AVET" => 2, "VAET" => 3, _ => 0,
                };
                let cursor = match self.engine.open_raw_cursor(cf_id, &[]) {
                    Ok(c) => c,
                    Err(_) => Arc::new(std::cell::RefCell::new(
                        crate::engine::scanner::InvalidCursor,
                    )),
                };
                scanner.set_cursor(cursor);
                scanner.advance_to_active_at();

                let resource: Arc<dyn std::any::Any + Send + Sync> = Arc::new(Mutex::new(scanner));
                Ok(EvalStep::Done(SExpr::Resource(Opaque(resource))))
            }

            "scanner-read" => {
                let scanner = extract_scanner(&args[0])?;
                let s = scanner.lock().unwrap();
                match s.extract_current() {
                    Some(val) => Ok(EvalStep::Done(value_to_sexpr(&val).unwrap_or(SExpr::Void))),
                    None => Ok(EvalStep::Done(SExpr::Void)),
                }
            }

            // -- Leapfrog --

            "scheme-leap-init" => {
                let stage_key = expect_int(&args[0])? as usize;
                let ranges_sexpr = args.last().ok_or_else(|| he("missing ranges arg".to_string()))?;
                let scanner_exprs = &args[1..args.len() - 1];
                let scanners: Vec<&Mutex<V2Scanner>> = scanner_exprs.iter()
                    .map(|a| extract_scanner(a))
                    .collect::<Result<_, _>>()?;
                // Position each scanner's cursor at the start of its current
                // prefix (derived from caller's scanner-push sequence) and
                // advance to the first active key. This is the equivalent of
                // what scanner-init used to do, but WITHOUT pushing any
                // Scanned entry — the iteration level is determined entirely
                // by the Fixed entries already on the stack.
                for sm in &scanners {
                    let mut s = sm.lock().unwrap();
                    if let Some(aid) = s.attr_id_from_prefix_bytes() {
                        let vt = self.engine.value_type_for(aid);
                        s.set_value_attr_type(vt);
                    }
                    s.advance_to_active_at();
                    if s.value_attr_type().is_none() {
                        if let Some(aid) = s.attr_id_from_key() {
                            let vt = self.engine.value_type_for(aid);
                            s.set_value_attr_type(vt);
                        }
                    }
                }
                let raw_ops = Self::parse_ranges(ranges_sexpr)?;
                let ok = if raw_ops.is_empty() {
                    Self::leap_converge(&scanners)
                } else {
                    Self::apply_ranges(&scanners, &raw_ops)
                };
                Ok(EvalStep::Done(SExpr::Bool(ok)))
            }

            "scheme-leap-next" => {
                let stage_key = expect_int(&args[0])? as usize;
                let ranges_sexpr = args.last().ok_or_else(|| he("missing ranges arg".to_string()))?;
                let scanner_exprs = &args[1..args.len() - 1];
                let scanners: Vec<&Mutex<V2Scanner>> = scanner_exprs.iter()
                    .map(|a| extract_scanner(a))
                    .collect::<Result<_, _>>()?;
                if scanners.is_empty() { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                let raw_ops = Self::parse_ranges(ranges_sexpr)?;

                let mut min_idx = 0usize;
                let mut min_val: Option<Value> = None;
                for (i, sm) in scanners.iter().enumerate() {
                    let s = sm.lock().unwrap();
                    let val = s.extract_current();
                    match &min_val {
                        None => { min_val = val.clone(); min_idx = i; }
                        Some(mv) => {
                            if let Some(ref v) = val {
                                if v < mv { min_val = Some(v.clone()); min_idx = i; }
                            }
                        }
                    }
                }
                {
                    let mut s = scanners[min_idx].lock().unwrap();
                    s.leap_next_at();
                    if s.at_end() { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                }
                if Self::leap_converge(&scanners) {
                    // converged
                } else {
                    return Ok(EvalStep::Done(SExpr::Bool(false)));
                }
                if !raw_ops.is_empty() && !Self::apply_ranges(&scanners, &raw_ops) {
                    return Ok(EvalStep::Done(SExpr::Bool(false)));
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }

            // -- Attribute / param access --

            "intern-a" => {
                let name = expect_str(&args[0])?;
                let aid = self.engine.tx().lookup_attr(&name)
                    .map_err(|e| he(e))?
                    .ok_or_else(|| he(format!("undeclared attribute '{name}'")))?;
                Ok(EvalStep::Done(SExpr::Int(aid as i64)))
            }

            "attr-name" => {
                let aid = expect_int(&args[0])? as u32;
                let name = self.engine.tx().attr_name(aid).map_err(|e| he(e))?;
                Ok(EvalStep::Done(SExpr::Str(name)))
            }

            "param" => {
                let idx = expect_int(&args[0])? as usize;
                if idx == 0 || idx > self.params.len() {
                    return Err(he(format!("param index {idx} out of range (1..{})", self.params.len())));
                }
                Ok(EvalStep::Done(value_to_sexpr(&self.params[idx - 1]).map_err(|e| he(e.to_string()))?))
            }

            "resolve-val" => {
                // For now just pass through (value already decoded by scanner)
                Ok(EvalStep::Done(args[0].clone()))
            }

            // -- DML: save / retract --

            "save" => {
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let val = sexpr_to_value(&args[2]).map_err(|e| he(e))?;
                self.engine
                    .save_with_t(&Value::entity_id(eid), &attr, &val, &self.ctx)
                    .map_err(|e| he(e.0))?;
                Ok(EvalStep::Done(SExpr::Void))
            }

            "retract" => {
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let val = sexpr_to_value(&args[2]).map_err(|e| he(e))?;
                self.engine.retract(&Value::entity_id(eid), &attr, &val, &self.ctx);
                Ok(EvalStep::Done(SExpr::Void))
            }

            // -- Result emission (yield) --

            "result-row" => {
                let mut row = Vec::with_capacity(args.len());
                for arg in args {
                    row.push(sexpr_to_value(arg).map_err(|e| he(e))?);
                }
                // Yield the row as a Scheme list — no internal buffer
                let sexpr_row = SExpr::List(
                    row.into_iter().map(|v| value_to_sexpr(&v).unwrap_or(SExpr::Void)).collect()
                );
                Ok(EvalStep::Yield(sexpr_row))
            }

            // -- DML (terminal result) --

            "alloc-entity" => {
                let partition = if args.is_empty() {
                    4u64
                } else {
                    expect_int(&args[0])? as u64
                };
                let eid = self
                    .engine
                    .tx()
                    .allocate_in_partition(partition)
                    .map_err(|e| he(e.to_string()))?;
                Ok(EvalStep::Done(SExpr::Int(eid as i64)))
            }
            "tx-entity" => Ok(EvalStep::Done(SExpr::Int(self.ctx.current_t as i64))),
            "lookup-entity" => {
                if args.len() != 2 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "lookup-entity".into(),
                        expected: "(lookup-entity attr value)",
                    });
                }
                let attr = expect_str(&args[0])?;
                let val = sexpr_to_value(&args[1]).map_err(|e| he(e))?;
                let is_unique = self.engine
                    .tx()
                    .is_unique_attr(&attr)
                    .unwrap_or(false);
                if !is_unique {
                    return Err(he(format!(
                        "UPSERT WHERE requires a UNIQUE attribute: '{attr}'"
                    )));
                }
                match self.engine.tx().lookup_entity(&attr, val) {
                    Ok(Some(eid)) => Ok(EvalStep::Done(SExpr::Int(eid as i64))),
                    Ok(None) => Ok(EvalStep::Done(SExpr::Void)),
                    Err(e) => Err(he(e)),
                }
            }
            "lookup-value" => {
                if args.len() != 2 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "lookup-value".into(),
                        expected: "(lookup-value eid attr)",
                    });
                }
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                match self.engine.lookup_value(eid, &attr, &self.ctx) {
                    Some(v) => Ok(EvalStep::Done(value_to_sexpr(&v)?)),
                    None => Ok(EvalStep::Done(SExpr::Void)),
                }
            }
            "result" => {
                let mut items = vec![SExpr::Symbol("result".into())];
                items.extend_from_slice(args);
                Ok(EvalStep::Done(SExpr::List(items)))
            }
            "declare-attr" => {
                let attr = expect_str(&args[0])?;
                let vt_name = expect_str(&args[1])?;
                let many = args.get(2).map_or(false, |a| matches!(a, SExpr::Bool(true)));
                let unique = args.get(3).map_or(false, |a| matches!(a, SExpr::Bool(true)));
                self.engine
                    .declare_attr_from_sql(&attr, &vt_name, many, unique, &self.ctx)
                    .map_err(|e| he(e.0))?;
                Ok(EvalStep::Done(SExpr::Void))
            }
            "declare-partition" => {
                let name = expect_str(&args[0])?;
                let pid = self.engine.declare_partition(&name, &self.ctx).unwrap_or(0);
                Ok(EvalStep::Done(SExpr::Int(pid as i64)))
            }

            // -- Scanner prefix manipulation (new) --

            "scanner-push" => {
                let scanner = extract_scanner(&args[0])?;
                let val = sexpr_to_value(&args[1]).map_err(|e| he(e))?;
                let mut s = scanner.lock().unwrap();
                s.save_value(&val);
                Ok(EvalStep::Done(SExpr::Void))
            }
            "scanner-pop" => {
                let scanner = extract_scanner(&args[0])?;
                let mut s = scanner.lock().unwrap();
                s.pop_saved_value();
                Ok(EvalStep::Done(SExpr::Void))
            }
            "scanner-prefix" => {
                let scanner = extract_scanner(&args[0])?;
                let s = scanner.lock().unwrap();
                Ok(EvalStep::Done(SExpr::Bytes(s.prefix_bytes())))
            }

            // -- Range debugging --

            "ranges-show" => {
                if args.len() != 1 {
                    return Err(he("ranges-show: expected 1 arg (ranges)".to_string()));
                }
                let raw_ops = Self::parse_ranges(&args[0])?;
                if raw_ops.is_empty() {
                    return Ok(EvalStep::Done(SExpr::Str("(-inf, +inf)".into())));
                }
                let mut all_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
                for branch in &raw_ops {
                    all_intervals.extend(ops_to_intervals(branch));
                }
                let specs: Vec<RangeSpec> = merge_intervals(all_intervals)
                    .into_iter()
                    .map(|(lo, hi, flags)| RangeSpec { lo, hi, flags })
                    .collect();
                if specs.is_empty() {
                    return Ok(EvalStep::Done(SExpr::Str("∅ (empty)".into())));
                }
                let parts: Vec<String> = specs.iter().map(|spec| {
                    let lo = match &spec.lo {
                        None => "-inf".to_string(),
                        Some(v) => format_value_for_range(v),
                    };
                    let hi = match &spec.hi {
                        None => "+inf".to_string(),
                        Some(v) => format_value_for_range(v),
                    };
                    // None (infinite) bounds are always rendered as open parens.
                    let l = if spec.lo.is_none() || spec.flags & RANGE_LO_OPEN != 0 { "(" } else { "[" };
                    let r = if spec.hi.is_none() || spec.flags & RANGE_HI_OPEN != 0 { ")" } else { "]" };
                    format!("{l}{lo}, {hi}{r}")
                }).collect();
                Ok(EvalStep::Done(SExpr::Str(parts.join(", "))))
            }

            // -- Arithmetic --

            "+" => {
                if args.len() < 2 {
                    return Err(he("(+) requires at least 2 arguments".to_string()));
                }
                let mut any_float = false;
                let mut result = sexpr_num_to_f64(&args[0])?;
                any_float = is_float(&args[0]);
                for arg in &args[1..] {
                    any_float |= is_float(arg);
                    result += sexpr_num_to_f64(arg)?;
                }
                Ok(EvalStep::Done(if any_float {
                    SExpr::Float(result)
                } else {
                    SExpr::Int(result as i64)
                }))
            }
            "-" => {
                if args.is_empty() {
                    return Err(he("(-) requires at least 1 argument".to_string()));
                }
                let mut any_float = is_float(&args[0]);
                let mut result = sexpr_num_to_f64(&args[0])?;
                if args.len() == 1 {
                    result = -result;
                } else {
                    for arg in &args[1..] {
                        any_float |= is_float(arg);
                        result -= sexpr_num_to_f64(arg)?;
                    }
                }
                Ok(EvalStep::Done(if any_float {
                    SExpr::Float(result)
                } else {
                    SExpr::Int(result as i64)
                }))
            }
            "*" => {
                if args.len() < 2 {
                    return Err(he("(*) requires at least 2 arguments".to_string()));
                }
                let mut any_float = false;
                let mut result = sexpr_num_to_f64(&args[0])?;
                any_float = is_float(&args[0]);
                for arg in &args[1..] {
                    any_float |= is_float(arg);
                    result *= sexpr_num_to_f64(arg)?;
                }
                Ok(EvalStep::Done(if any_float {
                    SExpr::Float(result)
                } else {
                    SExpr::Int(result as i64)
                }))
            }
            "/" => {
                if args.len() < 2 {
                    return Err(he("(/) requires at least 2 arguments".to_string()));
                }
                let mut result = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let n = sexpr_num_to_f64(arg)?;
                    if n == 0.0 {
                        return Err(he("division by zero".to_string()));
                    }
                    result /= n;
                }
                Ok(EvalStep::Done(SExpr::Float(result)))
            }
            "mod" => {
                if args.len() != 2 {
                    return Err(he("(mod) requires exactly 2 arguments".to_string()));
                }
                let a = expect_int(&args[0])?;
                let b = expect_int(&args[1])?;
                if b == 0 {
                    return Err(he("mod: division by zero".to_string()));
                }
                Ok(EvalStep::Done(SExpr::Int(a % b)))
            }

            // -- Comparison --

            "<" => {
                if args.len() < 2 {
                    return Ok(EvalStep::Done(SExpr::Bool(true)));
                }
                let mut prev = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let cur = sexpr_num_to_f64(arg)?;
                    if prev >= cur {
                        return Ok(EvalStep::Done(SExpr::Bool(false)));
                    }
                    prev = cur;
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }
            ">" => {
                if args.len() < 2 {
                    return Ok(EvalStep::Done(SExpr::Bool(true)));
                }
                let mut prev = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let cur = sexpr_num_to_f64(arg)?;
                    if prev <= cur {
                        return Ok(EvalStep::Done(SExpr::Bool(false)));
                    }
                    prev = cur;
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }
            "<=" => {
                if args.len() < 2 {
                    return Ok(EvalStep::Done(SExpr::Bool(true)));
                }
                let mut prev = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let cur = sexpr_num_to_f64(arg)?;
                    if prev > cur {
                        return Ok(EvalStep::Done(SExpr::Bool(false)));
                    }
                    prev = cur;
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }
            ">=" => {
                if args.len() < 2 {
                    return Ok(EvalStep::Done(SExpr::Bool(true)));
                }
                let mut prev = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let cur = sexpr_num_to_f64(arg)?;
                    if prev < cur {
                        return Ok(EvalStep::Done(SExpr::Bool(false)));
                    }
                    prev = cur;
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }
            "=" => {
                if args.len() < 2 {
                    return Ok(EvalStep::Done(SExpr::Bool(true)));
                }
                let mut prev = sexpr_num_to_f64(&args[0])?;
                for arg in &args[1..] {
                    let cur = sexpr_num_to_f64(arg)?;
                    if (prev - cur).abs() > 0.0 {
                        return Ok(EvalStep::Done(SExpr::Bool(false)));
                    }
                    prev = cur;
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }
            "!=" => {
                if args.len() != 2 {
                    return Err(he("(!=) requires exactly 2 arguments".to_string()));
                }
                Ok(EvalStep::Done(SExpr::Bool(
                    (sexpr_num_to_f64(&args[0])? - sexpr_num_to_f64(&args[1])?).abs() > 0.0,
                )))
            }

            // -- Min / Max / Abs --

            "min" => {
                if args.is_empty() {
                    return Err(he("(min) requires at least 1 argument".to_string()));
                }
                let mut any_float = false;
                let mut best = sexpr_num_to_f64(&args[0])?;
                any_float = is_float(&args[0]);
                for arg in &args[1..] {
                    any_float |= is_float(arg);
                    let n = sexpr_num_to_f64(arg)?;
                    if n < best { best = n; }
                }
                Ok(EvalStep::Done(if any_float {
                    SExpr::Float(best)
                } else {
                    SExpr::Int(best as i64)
                }))
            }
            "max" => {
                if args.is_empty() {
                    return Err(he("(max) requires at least 1 argument".to_string()));
                }
                let mut any_float = false;
                let mut best = sexpr_num_to_f64(&args[0])?;
                any_float = is_float(&args[0]);
                for arg in &args[1..] {
                    any_float |= is_float(arg);
                    let n = sexpr_num_to_f64(arg)?;
                    if n > best { best = n; }
                }
                Ok(EvalStep::Done(if any_float {
                    SExpr::Float(best)
                } else {
                    SExpr::Int(best as i64)
                }))
            }
            "abs" => {
                if args.len() != 1 {
                    return Err(he("(abs) requires exactly 1 argument".to_string()));
                }
                match &args[0] {
                    SExpr::Int(n) => Ok(EvalStep::Done(SExpr::Int(n.abs()))),
                    SExpr::Float(f) => Ok(EvalStep::Done(SExpr::Float(f.abs()))),
                    other => Err(spier_scheme::EvalError::Type {
                        expected: "number",
                        got: spier_scheme::write_scheme(other),
                    }),
                }
            }

            _ => Err(spier_scheme::EvalError::NotFound(name.into())),
        }
    }
}

// ---------------------------------------------------------------------------
// SelectSchemeSession — streaming cursor for Scheme-based SELECT queries
// ---------------------------------------------------------------------------

pub struct SelectSchemeSession {
    program: SchemeProgram,
    env: Environment,
    host: SchemeHostFns,
    state: YieldState,
    done: bool,
}

impl SelectSchemeSession {
    pub fn new(program: SchemeProgram, host: SchemeHostFns) -> Self {
        Self {
            program,
            env: Environment::new(),
            host,
            state: YieldState::default(),
            done: false,
        }
    }
}

impl VMResultStream for SelectSchemeSession {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String> {
        if self.done || max_rows == 0 {
            return Ok(false);
        }

        let tracer = spier_scheme::NullTracer;
        let mut rows_written = 0usize;

        loop {
            let step = spier_scheme::eval_with_yield(
                &self.program.body,
                &mut self.env,
                &mut self.host,
                &tracer,
                &mut self.state,
            )
            .map_err(|e| format!("scheme eval error: {e}"))?;

            match step {
                EvalStep::Yield(sexpr_row) => {
                    // Extract values from the row list
                    if let SExpr::List(items) = sexpr_row {
                        out.extend_from_slice(&(items.len() as u32).to_be_bytes());
                        for item in &items {
                            let val = sexpr_to_value(item)
                                .map_err(|e| format!("scheme row value error: {e}"))?;
                            query_codec::encode_one(out, &val);
                        }
                        rows_written += 1;
                        if rows_written >= max_rows {
                            return Ok(true);
                        }
                    }
                }
                EvalStep::Done(_) => {
                    self.done = true;
                    return Ok(false);
                }
            }
        }
    }
}
