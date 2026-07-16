use std::collections::HashMap;
use std::sync::Arc;

use spier_scheme::{Environment, EvalStep, SchemeProgram, SExpr, YieldState, eval};
use spier_value::query_codec;
use spier_value::Value;

use crate::engine::query_engine_inner::QueryEngineInner;
use crate::engine::scanner::V2Scanner;
use crate::engine::types::{ops_to_intervals, merge_intervals, BoundPart, EngineOps, QueryContext, RangeSpec, RANGE_LO_OPEN, RANGE_HI_OPEN, probe_value_matches};
use crate::VMResultStream;

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

        let as_of_u64 = self.as_of_tx.unwrap_or(u64::MAX);
        let mut host = SchemeHostFns {
            engine: Arc::clone(&self.engine),
            params: &self.params,
            tx: self.tx,
            as_of_tx: as_of_u64,
        };
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

struct SchemeHostFns<'a> {
    engine: Arc<QueryEngineInner>,
    params: &'a [Value],
    tx: u64,
    as_of_tx: u64,
}

impl<'a> spier_scheme::HostFns for SchemeHostFns<'a> {
    fn is_native(&self, name: &str) -> bool {
        matches!(
            name,
            "alloc-entity"
                | "tx-entity"
                | "param"
                | "lookup-entity"
                | "lookup-value"
                | "save"
                | "retract"
                | "result"
                | "declare-attr"
                | "declare-partition"
        )
    }

    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, spier_scheme::EvalError> {
        match name {
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
                    .map_err(spier_scheme::EvalError::Host)?;
                Ok(EvalStep::Done(SExpr::Int(eid as i64)))
            }
            "tx-entity" => Ok(EvalStep::Done(SExpr::Int(self.tx as i64))),
            "param" => {
                if args.len() != 1 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "param".into(),
                        expected: "(param idx)",
                    });
                }
                let idx = expect_int(&args[0])? as usize;
                if idx == 0 || idx > self.params.len() {
                    return Err(spier_scheme::EvalError::Host(format!(
                        "param index {} out of range (1..{})",
                        idx,
                        self.params.len()
                    )));
                }
                Ok(EvalStep::Done(value_to_sexpr(&self.params[idx - 1])?))
            }
            "lookup-entity" => {
                if args.len() != 2 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "lookup-entity".into(),
                        expected: "(lookup-entity attr value)",
                    });
                }
                let attr = expect_str(&args[0])?;
                let val = sexpr_to_value(&args[1]).map_err(spier_scheme::EvalError::Host)?;
                let is_unique = self.engine
                    .tx()
                    .is_unique_attr(&attr)
                    .unwrap_or(false);
                if !is_unique {
                    return Err(spier_scheme::EvalError::Host(format!(
                        "UPSERT WHERE requires a UNIQUE attribute: '{attr}'"
                    )));
                }
                match self.engine.tx().lookup_entity(&attr, val) {
                    Ok(Some(eid)) => Ok(EvalStep::Done(SExpr::Int(eid as i64))),
                    Ok(None) => Ok(EvalStep::Done(SExpr::Void)),
                    Err(e) => Err(spier_scheme::EvalError::Host(e)),
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
                let ctx = QueryContext {
                    as_of_tx: if self.as_of_tx == u64::MAX {
                        None
                    } else {
                        Some(self.as_of_tx)
                    },
                    current_t: self.tx,
                };
                match self.engine.lookup_value(eid, &attr, &ctx) {
                    Some(v) => Ok(EvalStep::Done(value_to_sexpr(&v)?)),
                    None => Ok(EvalStep::Done(SExpr::Void)),
                }
            }
            "save" => {
                if args.len() != 3 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "save".into(),
                        expected: "(save eid attr value)",
                    });
                }
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let val = sexpr_to_value(&args[2]).map_err(spier_scheme::EvalError::Host)?;
                self.engine
                    .tx()
                    .eavt_save(eid, &attr, val, self.tx, self.as_of_tx)
                    .map_err(spier_scheme::EvalError::Host)?;
                Ok(EvalStep::Done(SExpr::Void))
            }
            "retract" => {
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let val = sexpr_to_value(&args[2]).map_err(spier_scheme::EvalError::Host)?;
                self.engine
                    .retract(&Value::entity_id(eid), &attr, &val, &QueryContext {
                        as_of_tx: if self.as_of_tx == u64::MAX { None } else { Some(self.as_of_tx) },
                        current_t: self.tx,
                    });
                Ok(EvalStep::Done(SExpr::Void))
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
                let ctx = QueryContext {
                    as_of_tx: if self.as_of_tx == u64::MAX { None } else { Some(self.as_of_tx) },
                    current_t: self.tx,
                };
                self.engine
                    .declare_attr_from_sql(&attr, &vt_name, many, unique, &ctx)
                    .map_err(|e| spier_scheme::EvalError::Host(e.0))?;
                Ok(EvalStep::Done(SExpr::Void))
            }
            "declare-partition" => {
                let name = expect_str(&args[0])?;
                let ctx = QueryContext {
                    as_of_tx: if self.as_of_tx == u64::MAX { None } else { Some(self.as_of_tx) },
                    current_t: self.tx,
                };
                let pid = self.engine.declare_partition(&name, &ctx).unwrap_or(0);
                Ok(EvalStep::Done(SExpr::Int(pid as i64)))
            }
            _ => Err(spier_scheme::EvalError::NotFound(name.into())),
        }
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

// ---------------------------------------------------------------------------
// SelectSchemeHostFns — triejoin host functions for SELECT queries
// ---------------------------------------------------------------------------

pub struct SelectSchemeHostFns {
    engine: Arc<QueryEngineInner>,
    params: Vec<Value>,
    ctx: QueryContext,

    scanners: HashMap<usize, V2Scanner>,
    depth_cursors: HashMap<usize, Vec<usize>>,
    depth_var: HashMap<usize, usize>,
    vars: Vec<Option<Value>>,
    same_var_constraints: HashMap<usize, Vec<(usize, usize)>>,
    range_ops: HashMap<usize, Vec<Vec<(i32, Value)>>>,
    probe_found_t: Option<u64>,
    next_sid: usize,
}

impl SelectSchemeHostFns {
    pub fn new(
        engine: Arc<QueryEngineInner>,
        params: Vec<Value>,
        tx: u64,
        as_of_tx: Option<u64>,
        num_vars: usize,
        depth_var_pairs: &[(usize, usize)],
        same_var_constraints: &[(i32, Vec<(usize, usize)>)],
    ) -> Self {
        let depth_var: HashMap<usize, usize> = depth_var_pairs.iter().map(|&(d, v)| (d, v)).collect();
        let svc: HashMap<usize, Vec<(usize, usize)>> = same_var_constraints
            .iter()
            .map(|(sid, pairs)| (*sid as usize, pairs.clone()))
            .collect();
        Self {
            engine,
            params,
            ctx: QueryContext { as_of_tx, current_t: tx },
            scanners: HashMap::new(),
            depth_cursors: HashMap::new(),
            depth_var,
            vars: vec![None; num_vars],
            same_var_constraints: svc,
            range_ops: HashMap::new(),
            probe_found_t: None,
            next_sid: 0,
        }
    }

    // -- Leapfrog internals (ported from VM) --

    fn leap_converge(&mut self, depth: usize, sids: &[usize]) -> bool {
        let max_iters = sids.len() * 2 + 1;
        for _ in 0..max_iters {
            let mut max_val: Option<Value> = None;
            let mut all_equal = true;
            for &sid in sids {
                if let Some(scanner) = self.scanners.get(&sid) {
                    let pos = scanner.depth_position(depth);
                    if let Some(v) = scanner.extract_value(pos) {
                        match &max_val {
                            None => max_val = Some(v),
                            Some(mv) if v != *mv => {
                                all_equal = false;
                                if v > *mv { max_val = Some(v); }
                            }
                            _ => {}
                        }
                    } else {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            if all_equal { return true; }
            if let Some(ref mv) = max_val {
                for &sid in sids {
                    let needs_seek = if let Some(scanner) = self.scanners.get(&sid) {
                        let pos = scanner.depth_position(depth);
                        matches!(scanner.extract_value(pos), Some(v) if v < *mv)
                    } else { false };
                    if needs_seek {
                        if let Some(scanner) = self.scanners.get_mut(&sid) {
                            let pos = scanner.depth_position(depth);
                            scanner.seek_to_value(pos, mv);
                            if scanner.at_end() { return false; }
                        }
                    }
                }
            }
        }
        false
    }

    fn check_same_var(&self, _depth: usize, sids: &[usize]) -> bool {
        for &sid in sids {
            if let Some(pairs) = self.same_var_constraints.get(&sid) {
                if let Some(scanner) = self.scanners.get(&sid) {
                    if !scanner.check_same_var_pairs(pairs) { return false; }
                }
            }
        }
        true
    }

    fn leap_init_full(&mut self, depth: usize, sids: &[usize]) -> bool {
        for _ in 0..100 {
            if !self.leap_init_with_ranges(depth, sids) { return false; }
            if self.check_same_var(depth, sids) { return true; }
            let mut advanced = false;
            for &sid in sids {
                if self.same_var_constraints.contains_key(&sid) {
                    if let Some(scanner) = self.scanners.get_mut(&sid) {
                        let pos = scanner.depth_position(depth);
                        scanner.leap_next_at(pos);
                        if scanner.at_end() { return false; }
                        advanced = true;
                        break;
                    }
                }
            }
            if !advanced { return true; }
            if !self.leap_converge(depth, sids) { return false; }
        }
        false
    }

    fn leap_init_with_ranges(&mut self, depth: usize, sids: &[usize]) -> bool {
        if !self.leap_converge(depth, sids) { return false; }
        let raw_ops = match self.range_ops.get(&depth) {
            Some(r) => r.clone(),
            None => return true,
        };
        if raw_ops.is_empty() { return true; }

        let mut all_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
        for branch in &raw_ops {
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
                let sid = sids[0];
                let scanner = match self.scanners.get(&sid) {
                    Some(s) => s,
                    None => return false,
                };
                let pos = scanner.depth_position(depth);
                match scanner.extract_value(pos) {
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
                        for &sid in sids {
                            if let Some(scanner) = self.scanners.get_mut(&sid) {
                                let pos = scanner.depth_position(depth);
                                scanner.seek_to_value(pos, lo);
                            }
                        }
                        if !self.leap_converge(depth, sids) { return false; }
                        if lo_open {
                            let at_lo = if let Some(scanner) = self.scanners.get(&sids[0]) {
                                let pos = scanner.depth_position(depth);
                                scanner.extract_value(pos).map_or(false, |v| &v == lo)
                            } else { false };
                            if at_lo {
                                for &sid in sids {
                                    if let Some(scanner) = self.scanners.get_mut(&sid) {
                                        let pos = scanner.depth_position(depth);
                                        scanner.advance_to_active_at(pos);
                                    }
                                }
                                if !self.leap_converge(depth, sids) { return false; }
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

impl spier_scheme::HostFns for SelectSchemeHostFns {
    fn is_native(&self, name: &str) -> bool {
        matches!(
            name,
            "scanner-open" | "scanner-close" | "prefix-push" | "scanner-init"
                | "scheme-leap-init" | "scheme-leap-next" | "depth-cleanup"
                | "bind-get" | "bind-set" | "intern-a" | "param"
                | "result-row" | "range-op" | "range-branch"
                | "resolve-val" | "attr-name" | "probe-begin" | "probe-get-t"
                | "save" | "retract" | "scanner-push" | "scanner-pop"
        )
    }

    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<EvalStep, spier_scheme::EvalError> {
        let he = spier_scheme::EvalError::Host;
        match name {
            // -- Scanner lifecycle --

            "scanner-open" => {
                let index_name = expect_str(&args[0])?;
                let history = args.get(1).map_or(false, |a| matches!(a, SExpr::Bool(true)));
                let base_order : &[&str] = match index_name.to_ascii_uppercase().as_str() {
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
                let sid = self.next_sid;
                self.next_sid += 1;
                self.scanners.insert(sid, scanner);
                Ok(EvalStep::Done(SExpr::Int(sid as i64)))
            }

            "scanner-close" => {
                let sid = expect_int(&args[0])? as usize;
                self.scanners.remove(&sid);
                Ok(EvalStep::Done(SExpr::Void))
            }

            "prefix-push" => {
                let sid = expect_int(&args[0])? as usize;
                let val = sexpr_to_value(&args[1]).map_err(|e| he(e))?;
                let pos_name = expect_str(&args[2])?;
                if let Some(scanner) = self.scanners.get_mut(&sid) {
                    let pos_idx = scanner.idx_order.iter()
                        .position(|s| *s == pos_name)
                        .unwrap_or(0);
                    scanner.push_prefix_at(pos_idx, &val);
                }
                Ok(EvalStep::Done(SExpr::Void))
            }

            "scanner-push" => {
                let sid = expect_int(&args[0])? as usize;
                let val = sexpr_to_value(&args[1]).map_err(|e| he(e))?;
                if let Some(scanner) = self.scanners.get_mut(&sid) {
                    scanner.push_prefix_at(scanner.positions_filled, &val);
                }
                Ok(EvalStep::Done(SExpr::Void))
            }

            "scanner-pop" => {
                let sid = expect_int(&args[0])? as usize;
                if let Some(scanner) = self.scanners.get_mut(&sid) {
                    scanner.pop_prefix();
                }
                Ok(EvalStep::Done(SExpr::Void))
            }

            // -- DepthEnter (called by depth-run) --

            "scanner-init" => {
                let sid = expect_int(&args[0])? as usize;
                let depth = expect_int(&args[1])? as usize;
                if let Some(scanner) = self.scanners.get_mut(&sid) {
                    let pos_idx = if let Some(&existing) = scanner.depth_positions.get(&depth) {
                        existing
                    } else {
                        scanner.next_free_pos()
                    };
                    if !scanner.is_open() {
                        if let Some(aid) = scanner.attr_id_from_prefix() {
                            let vt = self.engine.value_type_for(aid);
                            scanner.set_value_attr_type(vt);
                        }
                        scanner.build_prefix_bytes();
                        let cf_id = match scanner.index_name() {
                            "EAVT" => 0u32, "AEVT" => 1, "AVET" => 2, "VAET" => 3, _ => 0,
                        };
                        let prefix = scanner.prefix_bytes().to_vec();
                        let cursor = match self.engine.open_raw_cursor(cf_id, &prefix) {
                            Ok(c) => c,
                            Err(_) => Arc::new(std::cell::RefCell::new(
                                crate::engine::scanner::InvalidCursor,
                            )),
                        };
                        scanner.set_cursor(cursor);
                        scanner.advance_to_active_at(pos_idx);
                        if scanner.value_attr_type().is_none() {
                            if let Some(aid) = scanner.attr_id_from_key() {
                                let vt = self.engine.value_type_for(aid);
                                scanner.set_value_attr_type(vt);
                            }
                        }
                    } else if scanner.depth_positions.keys().min().map_or(true, |md| *md >= depth) {
                        scanner.seek_to_prefix_start();
                        scanner.advance_to_active_at(pos_idx);
                    }
                    scanner.clear_at_end();
                    if scanner.prefix_values_is_empty() {
                        if let Some(aid) = scanner.attr_id_from_key() {
                            let vt = self.engine.value_type_for(aid);
                            scanner.set_value_attr_type(vt);
                        }
                    }
                    scanner.bind_depth(depth, pos_idx);
                }
                self.depth_cursors.entry(depth).or_default().push(sid);
                if let Some(&var_id) = self.depth_var.get(&depth) {
                    if let Some(scanner) = self.scanners.get(&sid) {
                        let pos = scanner.depth_position(depth);
                        if let Some(val) = scanner.extract_value(pos) {
                            self.vars[var_id] = Some(val);
                        }
                    }
                }
                Ok(EvalStep::Done(SExpr::Void))
            }

            // -- Leapfrog --

            "scheme-leap-init" => {
                let depth = expect_int(&args[0])? as usize;
                let sids = self.depth_cursors.get(&depth).cloned().unwrap_or_default();
                let ok = self.leap_init_full(depth, &sids);
                if ok {
                    if let Some(&var_id) = self.depth_var.get(&depth) {
                        if let Some(&sid) = sids.first() {
                            if let Some(scanner) = self.scanners.get(&sid) {
                                let pos = scanner.depth_position(depth);
                                if let Some(val) = scanner.extract_value(pos) {
                                    self.vars[var_id] = Some(val);
                                }
                            }
                        }
                    }
                }
                Ok(EvalStep::Done(SExpr::Bool(ok)))
            }

            "scheme-leap-next" => {
                let depth = expect_int(&args[0])? as usize;
                let sids = self.depth_cursors.get(&depth).cloned().unwrap_or_default();
                if sids.is_empty() { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                // Find scanner with minimum value at this depth
                let mut min_sid = sids[0];
                let mut min_val: Option<Value> = None;
                for &sid in &sids {
                    if let Some(scanner) = self.scanners.get(&sid) {
                        let pos = scanner.depth_position(depth);
                        let val = scanner.extract_value(pos);
                        match &min_val {
                            None => { min_val = val.clone(); min_sid = sid; }
                            Some(mv) => {
                                if let Some(ref v) = val {
                                    if v < mv { min_val = Some(v.clone()); min_sid = sid; }
                                }
                            }
                        }
                    }
                }
                // Advance the min scanner
                if let Some(scanner) = self.scanners.get_mut(&min_sid) {
                    let pos = scanner.depth_position(depth);
                    scanner.leap_next_at(pos);
                    if scanner.at_end() { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                    // Check parent value consistency
                    if depth > 0 {
                        if let Some(&ppos) = scanner.depth_positions.get(&(depth - 1)) {
                            let parent_val = scanner.extract_value(ppos);
                            let bound_val = self.depth_var.get(&(depth - 1))
                                .and_then(|&vid| self.vars.get(vid).cloned())
                                .flatten();
                            if parent_val != bound_val { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                        }
                    }
                }
                // Re-converge after advance
                if !self.leap_init_full(depth, &sids) { return Ok(EvalStep::Done(SExpr::Bool(false))); }
                if let Some(&var_id) = self.depth_var.get(&depth) {
                    if let Some(scanner) = self.scanners.get(&min_sid) {
                        let pos = scanner.depth_position(depth);
                        if let Some(val) = scanner.extract_value(pos) {
                            self.vars[var_id] = Some(val);
                        }
                    }
                }
                Ok(EvalStep::Done(SExpr::Bool(true)))
            }

            "depth-cleanup" => {
                let depth = expect_int(&args[0])? as usize;
                if let Some(sids) = self.depth_cursors.remove(&depth) {
                    for sid in sids {
                        if let Some(scanner) = self.scanners.get_mut(&sid) {
                            scanner.unbind_depth(depth);
                        }
                    }
                }
                Ok(EvalStep::Done(SExpr::Void))
            }

            // -- Variable access --

            "bind-get" => {
                let var_id = expect_int(&args[0])? as usize;
                match self.vars.get(var_id).and_then(|v| v.as_ref()) {
                    Some(val) => Ok(EvalStep::Done(value_to_sexpr(val).map_err(|e| he(e.to_string()))?)),
                    None => Ok(EvalStep::Done(SExpr::Void)),
                }
            }

            "bind-set" => {
                let var_id = expect_int(&args[0])? as usize;
                let val = sexpr_to_value(&args[1]).map_err(|e| he(e.to_string()))?;
                if var_id < self.vars.len() {
                    self.vars[var_id] = Some(val);
                }
                Ok(EvalStep::Done(SExpr::Void))
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

            // -- Range constraints --

            "range-op" => {
                let depth = expect_int(&args[0])? as usize;
                let op: i32 = expect_int(&args[1])?.try_into().map_err(|_| he("range op out of i32 range".to_string()))?;
                let val = sexpr_to_value(&args[2]).map_err(|e| he(e.to_string()))?;
                let branches = self.range_ops.entry(depth).or_default();
                if branches.is_empty() { branches.push(vec![]); }
                branches.last_mut().unwrap().push((op, val));
                Ok(EvalStep::Done(SExpr::Void))
            }

            "range-branch" => {
                let depth = expect_int(&args[0])? as usize;
                let branches = self.range_ops.entry(depth).or_default();
                if branches.is_empty() { branches.push(vec![]); }
                branches.push(vec![]);
                Ok(EvalStep::Done(SExpr::Void))
            }

            // -- Probe (point lookup before scan) --

            "probe-begin" => {
                let e_val = expect_int(&args[0])? as u64;
                let a_val = expect_int(&args[1])? as u32;
                let v_probe = sexpr_to_value(&args[2]).map_err(|e| he(e))?;
                let bound = [
                    BoundPart::Int(e_val),
                    BoundPart::Attr(a_val),
                ];
                let datoms = self.engine.probe_collect("EAVT", &bound, &self.ctx);
                let mut found_t: Option<u64> = None;
                let found = datoms.iter().any(|d| {
                    if d.retracted { return false; }
                    if !probe_value_matches(&d.v, &v_probe) { return false; }
                    found_t = Some(d.t);
                    true
                });
                self.probe_found_t = found_t;
                Ok(EvalStep::Done(SExpr::Bool(found)))
            }

            "probe-get-t" => {
                match self.probe_found_t {
                    Some(t) => {
                        let tx_eid = spier_transactor::resolver_consts::make_entity_id(
                            spier_transactor::resolver_consts::PART_TX,
                            t,
                        );
                        Ok(EvalStep::Done(SExpr::Int(tx_eid as i64)))
                    }
                    None => Ok(EvalStep::Done(SExpr::Void)),
                }
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

            // -- Result emission --

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
    host: SelectSchemeHostFns,
    state: YieldState,
    done: bool,
}

impl SelectSchemeSession {
    pub fn new(program: SchemeProgram, host: SelectSchemeHostFns) -> Self {
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
                Some(&mut self.state),
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
