use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

pub use crate::engine::opcodes::{
    debug_timing_enabled,
    OpCode, InstructionData, VMProgram,
};
use crate::engine::opcodes::TimingStats;
use dynspire_commons::query_ir::{
    RANGE_OP_EQ, RANGE_OP_NEQ, RANGE_OP_GT, RANGE_OP_GTE,
    RANGE_OP_LT, RANGE_OP_LTE, RANGE_OP_IN,
};
use dynspire_commons::value::Value;

#[derive(Debug)]
pub struct EngineError(pub String);

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for EngineError {}

pub struct QueryContext {
    pub as_of_us: Option<u64>,
    pub current_t: u64,
}

pub trait VMEngine: Send + Sync {
    fn resolve_entity(&self, name_or_id: &Value) -> u64;
    fn lookup_attr(&self, name: &str) -> Option<u32>;
    fn attr_name(&self, aid: u32) -> String;
    fn open_raw_cursor(
        &self,
        cf_id: u32,
        prefix: &[u8],
    ) -> Result<std::sync::Arc<std::cell::RefCell<dyn dynspire_commons::transactor::cursor::Cursor>>, String>;
    fn collect_active(&self, cf: &str, prefix: &[u8], ctx: &QueryContext) -> Vec<RawDatomView>;
    fn probe_collect(&self, index: &str, bound: &[BoundPart], ctx: &QueryContext) -> Vec<RawDatomView>;
    fn save_with_t(&self, e: &Value, attr: &str, v: &Value, ctx: &QueryContext) -> Result<(), EngineError>;
    fn retract(&self, e: &Value, attr: &str, v: &Value, ctx: &QueryContext);
    fn allocate_in_partition(&self, partition_id: u64) -> u64;
    fn default_user_partition(&self) -> u64;
    fn declare_partition(&self, name: &str, ctx: &QueryContext) -> Result<u64, EngineError>;
    fn declare_attr_from_sql(&self, attr: &str, type_name: &str, many: bool, unique: bool, ctx: &QueryContext) -> Result<(), EngineError>;
    fn is_unique_attr(&self, attr_name: &str) -> bool;
    fn value_type_for(&self, aid: u32) -> Option<u32>;
    fn lookup_entity(&self, attr_name: &str, value: &Value, ctx: &QueryContext) -> Option<u64>;
    fn lookup_value(&self, eid: u64, attr_name: &str, ctx: &QueryContext) -> Option<Value>;
    fn allocate_t_and_write_tx(&self) -> u64;
}

#[derive(Clone)]
pub struct RawDatomView {
    pub e: u64,
    pub a: u32,
    pub v: Value,
    pub t: u64,
    pub retracted: bool,
}

pub const RANGE_LO_OPEN: i32 = 1;
pub const RANGE_HI_OPEN: i32 = 2;

#[derive(Clone)]
pub struct RangeSpec {
    pub lo: Option<Value>,
    pub hi: Option<Value>,
    pub flags: i32,
}

#[allow(dead_code)]
fn op_const_to_str(op: i32) -> &'static str {
    match op {
        RANGE_OP_EQ => "=",
        RANGE_OP_NEQ => "!=",
        RANGE_OP_GT => ">",
        RANGE_OP_GTE => ">=",
        RANGE_OP_LT => "<",
        RANGE_OP_LTE => "<=",
        RANGE_OP_IN => "in",
        _ => "",
    }
}

fn merge_intervals(
    intervals: Vec<(Option<Value>, Option<Value>, i32)>,
) -> Vec<(Option<Value>, Option<Value>, i32)> {
    if intervals.len() <= 1 {
        return intervals;
    }
    let mut sorted: Vec<_> = intervals.into_iter().collect();
    sorted.sort_by(|a, b| {
        let ord_none = (a.0.is_none() as i64, b.0.is_none() as i64);
        match ord_none {
            (1, 1) => std::cmp::Ordering::Equal,
            (1, _) => std::cmp::Ordering::Less,
            (_, 1) => std::cmp::Ordering::Greater,
            _ => a.0.as_ref().unwrap().cmp(b.0.as_ref().unwrap()),
        }
    });
    let mut merged: Vec<(Option<Value>, Option<Value>, i32)> = vec![sorted[0].clone()];
    for (lo, hi, flags) in sorted.into_iter().skip(1) {
        let (_prev_lo, prev_hi, prev_flags) = merged.last().unwrap().clone();
        let can_merge = if prev_hi.is_none() {
            true
        } else if lo.is_some() {
            let prev_hi_val = prev_hi.as_ref().unwrap();
            let lo_val = lo.as_ref().unwrap();
            if lo_val.tag() != prev_hi_val.tag() {
                false
            } else if lo_val < prev_hi_val {
                true
            } else if lo_val == prev_hi_val {
                let prev_hi_closed = !(prev_flags & RANGE_HI_OPEN != 0);
                let lo_closed = !(flags & RANGE_LO_OPEN != 0);
                prev_hi_closed && lo_closed
            } else {
                false
            }
        } else {
            false
        };
        if can_merge {
            let new_hi = match (&prev_hi, &hi) {
                (None, None) => None,
                (None, Some(h)) => Some(h.clone()),
                (Some(_), None) => None,
                (Some(ph), Some(h)) => {
                    if h > ph { Some(h.clone()) } else { Some(ph.clone()) }
                }
            };
            let new_hi_open = match (&prev_hi, &hi) {
                (None, _) => flags & RANGE_HI_OPEN != 0,
                (_, None) => false,
                (Some(ph), Some(h)) => {
                    if h > ph { flags & RANGE_HI_OPEN != 0 }
                    else if h < ph { prev_flags & RANGE_HI_OPEN != 0 }
                    else { prev_flags & RANGE_HI_OPEN != 0 && flags & RANGE_HI_OPEN != 0 }
                }
            };
            merged.last_mut().unwrap().1 = new_hi;
            merged.last_mut().unwrap().2 =
                (prev_flags & RANGE_LO_OPEN) | if new_hi_open { RANGE_HI_OPEN } else { 0 };
        } else {
            merged.push((lo, hi, flags));
        }
    }
    merged
}

fn ops_to_intervals(ops: &[(i32, Value)]) -> Vec<(Option<Value>, Option<Value>, i32)> {
    let mut neq_vals: Vec<Value> = Vec::new();
    let mut range_ops: Vec<(i32, Value)> = Vec::new();
    let mut in_vals: Vec<Value> = Vec::new();

    for (op, val) in ops {
        match *op {
            RANGE_OP_NEQ => neq_vals.push(val.clone()),
            RANGE_OP_IN => in_vals.push(val.clone()),
            _ => range_ops.push((*op, val.clone())),
        }
    }

    if !in_vals.is_empty() && range_ops.is_empty() && neq_vals.is_empty() {
        let mut sorted = in_vals;
        sorted.sort();
        let intervals: Vec<_> = sorted
            .into_iter()
            .map(|v| (Some(v.clone()), Some(v), 0))
            .collect();
        return merge_intervals(intervals);
    }

    let mut lo: Option<Value> = None;
    let mut hi: Option<Value> = None;
    let mut lo_open = false;
    let mut hi_open = false;

    for (op, val) in &range_ops {
        match *op {
            RANGE_OP_GT | RANGE_OP_GTE => {
                if lo.is_none()
                    || val > lo.as_ref().unwrap()
                    || (val == lo.as_ref().unwrap() && *op == RANGE_OP_GT)
                {
                    lo = Some(val.clone());
                    lo_open = *op == RANGE_OP_GT;
                }
            }
            RANGE_OP_LT | RANGE_OP_LTE => {
                if hi.is_none()
                    || val < hi.as_ref().unwrap()
                    || (val == hi.as_ref().unwrap() && *op == RANGE_OP_LT)
                {
                    hi = Some(val.clone());
                    hi_open = *op == RANGE_OP_LT;
                }
            }
            RANGE_OP_EQ => {
                lo = Some(val.clone());
                hi = Some(val.clone());
                lo_open = false;
                hi_open = false;
            }
            _ => {}
        }
    }

    if lo.is_some() && hi.is_some() && lo.as_ref().unwrap() > hi.as_ref().unwrap() {
        return vec![];
    }

    let mut flags = 0;
    if lo_open { flags |= RANGE_LO_OPEN; }
    if hi_open { flags |= RANGE_HI_OPEN; }

    let mut intervals: Vec<(Option<Value>, Option<Value>, i32)> = vec![(lo, hi, flags)];

    for nv in neq_vals {
        let mut new_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
        for (iv_lo, iv_hi, iv_flags) in intervals {
            let in_range = {
                let mut ok = true;
                if let Some(ref lo) = iv_lo {
                    let lo_open_i = iv_flags & RANGE_LO_OPEN != 0;
                    if lo_open_i { if &nv <= lo { ok = false; } } else { if &nv < lo { ok = false; } }
                }
                if ok {
                    if let Some(ref hi) = iv_hi {
                        let hi_open_i = iv_flags & RANGE_HI_OPEN != 0;
                        if hi_open_i { if &nv >= hi { ok = false; } } else { if &nv > hi { ok = false; } }
                    }
                }
                ok
            };
            if !in_range {
                new_intervals.push((iv_lo, iv_hi, iv_flags));
            } else {
                let left_flags = (iv_flags & !RANGE_HI_OPEN) | RANGE_HI_OPEN;
                new_intervals.push((iv_lo, Some(nv.clone()), left_flags));
                let right_flags = (iv_flags & !RANGE_LO_OPEN) | RANGE_LO_OPEN;
                new_intervals.push((Some(nv.clone()), iv_hi, right_flags));
            }
        }
        intervals = new_intervals;
    }

    merge_intervals(intervals)
}

#[derive(Debug)]
pub enum BoundPart {
    Int(u64),
    Attr(u32),
    #[allow(dead_code)]
    Val(Value),
}

fn probe_value_matches(dv: &Value, pv: &Value) -> bool {
    match pv {
        Value::Int64(_) | Value::Bool(_) | Value::Timestamp(_) => {
            dv.raw_int() == pv.raw_int()
        }
        Value::Float64(_) => dv.raw_float() == pv.raw_float(),
        _ => dv == pv,
    }
}

pub struct VM {
    prog: Arc<VMProgram>,
    regs: Vec<Option<Value>>,
    vars: Vec<Option<Value>>,
    engine: Arc<dyn VMEngine + Send + Sync>,
    ctx: QueryContext,
    params: Vec<Value>,
    limit: Option<usize>,
    pc: usize,
    count: usize,
    depth_var: HashMap<usize, usize>,
    depth_cursors: HashMap<usize, Vec<usize>>,
    range_ops: HashMap<usize, Vec<Vec<(i32, Value)>>>,
    scan_data: Vec<RawDatomView>,
    scan_idx: usize,
    emit_values: Vec<Value>,
    probe_positions: HashMap<usize, Value>,
    probe_found_t: Option<u64>,
    v2_scanners: HashMap<usize, crate::engine::scanner::V2Scanner>,
    same_var_constraints: HashMap<usize, Vec<(usize, usize)>>,
}

impl VM {
    #[allow(dead_code)]
    pub fn count(&self) -> usize {
        self.count
    }

    pub fn new(
        program: Arc<VMProgram>,
        engine: Arc<dyn VMEngine + Send + Sync>,
        params: Vec<Value>,
        limit: Option<usize>,
        current_t: u64,
        as_of_us: Option<u64>,
    ) -> Self {
        let depth_var: HashMap<usize, usize> =
            program.depth_var.iter().map(|&(d, v)| (d, v)).collect();
        let same_var_constraints: HashMap<usize, Vec<(usize, usize)>> = program
            .same_var_constraints
            .iter()
            .map(|(sid, pairs)| (*sid as usize, pairs.clone()))
            .collect();
        Self {
            regs: vec![None; program.num_registers],
            vars: vec![None; program.num_vars],
            prog: program,
            engine,
            ctx: QueryContext { as_of_us, current_t },
            params,
            limit,
            pc: 0,
            count: 0,
            depth_var,
            depth_cursors: HashMap::new(),
            range_ops: HashMap::new(),
            scan_data: Vec::new(),
            scan_idx: 0,
            emit_values: Vec::new(),
            probe_positions: HashMap::new(),
            probe_found_t: None,
            v2_scanners: HashMap::new(),
            same_var_constraints,
        }
    }

    fn v2_leap_converge(&mut self, depth: usize, sids: &[usize]) -> bool {
        let max_iters = sids.len() * 2 + 1;
        for _ in 0..max_iters {
            let mut max_val: Option<Value> = None;
            let mut all_equal = true;

            for &sid in sids {
                if let Some(scanner) = self.v2_scanners.get(&sid) {
                    let pos = scanner.depth_position(depth);
                    match scanner.extract_value(pos) {
                        Some(v) => {
                            match &max_val {
                                None => max_val = Some(v),
                                Some(mv) if v != *mv => {
                                    all_equal = false;
                                    if v > *mv {
                                        max_val = Some(v);
                                    }
                                }
                                _ => {}
                            }
                        }
                        None => return false,
                    }
                } else {
                    return false;
                }
            }

            if all_equal {
                return true;
            }

            if let Some(ref mv) = max_val {
                for &sid in sids {
                    let needs_seek = {
                        if let Some(scanner) = self.v2_scanners.get(&sid) {
                            let pos = scanner.depth_position(depth);
                            match scanner.extract_value(pos) {
                                Some(v) => v < *mv,
                                None => return false,
                            }
                        } else {
                            false
                        }
                    };
                    if needs_seek {
                        if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
                            let pos = scanner.depth_position(depth);
                            scanner.seek_to_value(pos, mv);
                            if scanner.at_end() {
                                return false;
                            }
                        }
                    }
                }
            }
        }
        false
    }

    fn v2_check_same_var(&self, _depth: usize, sids: &[usize]) -> bool {
        for &sid in sids {
            if let Some(pairs) = self.same_var_constraints.get(&sid) {
                if let Some(scanner) = self.v2_scanners.get(&sid) {
                    if !scanner.check_same_var_pairs(pairs) {
                        return false;
                    }
                }
            }
        }
        true
    }

    fn v2_leap_init_full(&mut self, depth: usize, sids: &[usize]) -> bool {
        for _ in 0..100 {
            if !self.v2_leap_init_with_ranges(depth, sids) {
                return false;
            }
            if self.v2_check_same_var(depth, sids) {
                return true;
            }
            let mut advanced = false;
            for &sid in sids {
                if self.same_var_constraints.contains_key(&sid) {
                    if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
                        let pos = scanner.depth_position(depth);
                        scanner.leap_next_at(pos);
                        if scanner.at_end() {
                            return false;
                        }
                        advanced = true;
                        break;
                    }
                }
            }
            if !advanced {
                return true;
            }
            if !self.v2_leap_converge(depth, sids) {
                return false;
            }
        }
        false
    }

    fn v2_leap_init_with_ranges(&mut self, depth: usize, sids: &[usize]) -> bool {
        if !self.v2_leap_converge(depth, sids) {
            return false;
        }
        let raw_ops = match self.range_ops.get(&depth) {
            Some(r) => r.clone(),
            None => return true,
        };
        if raw_ops.is_empty() {
            return true;
        }

        // Resolve raw ops to intervals at runtime (params now have values)
        // Each branch is processed independently (OR semantics), then merged
        let mut all_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
        for branch in &raw_ops {
            all_intervals.extend(ops_to_intervals(branch));
        }
        let range_specs: Vec<RangeSpec> = merge_intervals(all_intervals)
            .into_iter()
            .map(|(lo, hi, flags)| RangeSpec { lo, hi, flags })
            .collect();
        if range_specs.is_empty() {
            return false; // empty intervals = no possible values
        }

        let max_iter = range_specs.len() + 2;
        for _ in 0..max_iter {
            let cur = {
                let sid = sids[0];
                let scanner = match self.v2_scanners.get(&sid) {
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
                    if past_hi {
                        continue;
                    }
                }
                if let Some(ref lo) = spec.lo {
                    let lo_open = spec.flags & RANGE_LO_OPEN != 0;
                    let before_lo = if lo_open { &cur <= lo } else { &cur < lo };
                    if before_lo {
                        if std::mem::discriminant(&cur) != std::mem::discriminant(lo) {
                            return false;
                        }
                        for &sid in sids {
                            if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
                                let pos = scanner.depth_position(depth);
                                scanner.seek_to_value(pos, lo);
                            }
                        }
                        if !self.v2_leap_converge(depth, sids) {
                            return false;
                        }
                        if lo_open {
                            let at_lo = {
                                if let Some(scanner) = self.v2_scanners.get(&sids[0]) {
                                    let pos = scanner.depth_position(depth);
                                    scanner.extract_value(pos).map_or(false, |v| &v == lo)
                                } else { false }
                            };
                            if at_lo {
                                for &sid in sids {
                                    if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
                                        let pos = scanner.depth_position(depth);
                                        scanner.advance_to_active_at(pos);
                                    }
                                }
                                if !self.v2_leap_converge(depth, sids) {
                                    return false;
                                }
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
            if !any_applied {
                return false;
            }
        }
        false
    }

    pub fn run(&mut self) -> Result<Vec<Vec<Value>>, EngineError> {
        let mut results: Vec<Vec<Value>> = Vec::new();
        loop {
            let suspended = self.run_batch(&mut results, usize::MAX)?;
            if !suspended {
                break;
            }
        }
        Ok(results)
    }

    pub fn run_batch(
        &mut self,
        out: &mut Vec<Vec<Value>>,
        max_rows: usize,
    ) -> Result<bool, EngineError> {
        let num_instructions = self.prog.instructions.len();
        let do_timing = debug_timing_enabled();
        let wall_start = Instant::now();
        let mut timing = TimingStats::new();

        let trace_vm = dynspire_commons::trace_vm();

        while self.pc < num_instructions {
            let inst = self.prog.instructions[self.pc].clone();
            let op = inst.op;

            if trace_vm {
                eprintln!("[VM] pc={} op={:?}", self.pc, op);
            }

            match op {
                OpCode::Halt => {
                    if do_timing {
                        timing.print(wall_start.elapsed());
                    }
                    return Ok(false);
                }

                OpCode::Goto => {
                    self.pc = inst.p1 as usize;
                    continue;
                }

                OpCode::Null => {
                    self.regs[inst.p1 as usize] = None;
                }

                OpCode::Param => {
                    let idx = (inst.p2 - 1) as usize;
                    if idx < self.params.len() {
                        self.regs[inst.p1 as usize] = Some(self.params[idx].clone());
                    }
                }

                OpCode::ConstInt => {
                    let val = match &inst.p4 {
                        InstructionData::Int(n) => *n,
                        _ => inst.p2 as i64,
                    };
                    self.regs[inst.p1 as usize] = Some(Value::int64(val));
                }

                OpCode::ConstStr => {
                    if let InstructionData::Str(ref s) = inst.p4 {
                        self.regs[inst.p1 as usize] = Some(Value::text(s.as_str()));
                    }
                }

                OpCode::ConstFloat => {
                    if let InstructionData::Float(f) = inst.p4 {
                        self.regs[inst.p1 as usize] = Some(Value::float64(f));
                    }
                }

                OpCode::ConstBool => {
                    self.regs[inst.p1 as usize] = Some(Value::Bool(if inst.p2 != 0 { 1 } else { 0 }));
                }

                OpCode::InternA => {
                    let attr_name = match &inst.p4 {
                        InstructionData::Str(s) => s.clone(),
                        _ => String::new(),
                    };
                    let aid = self.engine.lookup_attr(&attr_name)
                        .ok_or_else(|| EngineError(format!("INTERN_A: undeclared attribute '{}'", attr_name)))?;
                    self.regs[inst.p1 as usize] = Some(Value::int64(aid as i64));
                }

                OpCode::AttrName => {
                    let r = inst.p1 as usize;
                    if let Some(v) = &self.regs[r] {
                        let name = self.engine.attr_name(v.raw_int() as u32);
                        self.regs[r] = Some(Value::text(name));
                    }
                }

                OpCode::ResolveVal => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    let r = inst.p1 as usize;
                    if let Some(v) = self.regs[r].take() {
                        self.regs[r] = Some(v);
                    }
                    if let Some(t0) = t0 { timing.resolve_val.add(t0.elapsed()); }
                }

                OpCode::DepthUp => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    let depth = inst.p1 as usize;
                    let cid = inst.p2 as usize;

                    if let Some(scanner) = self.v2_scanners.get_mut(&cid) {
                        scanner.unbind_depth(depth);
                    }
                    if let Some(dc) = self.depth_cursors.get_mut(&depth) {
                        dc.retain(|&c| c != cid);
                        if dc.is_empty() {
                            self.depth_cursors.remove(&depth);
                        }
                    }
                    if let Some(t0) = t0 { timing.depth_up.add(t0.elapsed()); }
                }

                OpCode::LeapInit => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    let depth = inst.p1 as usize;
                    let fail_addr = inst.p2 as usize;
                    let cursor_ids = self
                        .depth_cursors
                        .get(&depth)
                        .cloned()
                        .unwrap_or_default();

                    if !self.v2_leap_init_full(depth, &cursor_ids) {
                        if let Some(t0) = t0 { timing.leap_init.add(t0.elapsed()); }
                        self.pc = fail_addr;
                        continue;
                    }
                    if let Some(&var_id) = self.depth_var.get(&depth) {
                        if let Some(sid) = cursor_ids.first() {
                            if let Some(scanner) = self.v2_scanners.get(sid) {
                                let pos = scanner.depth_position(depth);
                                if let Some(val) = scanner.extract_value(pos) {
                                    self.vars[var_id] = Some(val);
                                }
                            }
                        }
                    }
                    if let Some(t0) = t0 { timing.leap_init.add(t0.elapsed()); }
                }

                OpCode::LeapNext => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    let depth = inst.p1 as usize;
                    let fail_addr = inst.p2 as usize;
                    let cursor_ids = self
                        .depth_cursors
                        .get(&depth)
                        .cloned()
                        .unwrap_or_default();

                    if cursor_ids.is_empty() {
                        self.pc = fail_addr;
                        continue;
                    }
                    let mut min_sid = cursor_ids[0];
                    let mut min_val: Option<Value> = None;
                    for &sid in &cursor_ids {
                        if let Some(scanner) = self.v2_scanners.get(&sid) {
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
                    if let Some(scanner) = self.v2_scanners.get_mut(&min_sid) {
                        let pos = scanner.depth_position(depth);
                        scanner.leap_next_at(pos);
                        if scanner.at_end() {
                            if let Some(t0) = t0 { timing.leap_next.add(t0.elapsed()); }
                            self.pc = fail_addr;
                            continue;
                        }
                        if depth > 0 {
                            if let Some(&ppos) = scanner.depth_positions.get(&(depth - 1)) {
                                let parent_val = scanner.extract_value(ppos);
                                let bound_val = self.depth_var.get(&(depth - 1))
                                    .and_then(|&vid| self.vars.get(vid).cloned())
                                    .flatten();
                                if parent_val != bound_val {
                                    if let Some(t0) = t0 { timing.leap_next.add(t0.elapsed()); }
                                    self.pc = fail_addr;
                                    continue;
                                }
                            }
                        }
                    }
                    if !self.v2_leap_init_full(depth, &cursor_ids) {
                        if let Some(t0) = t0 { timing.leap_next.add(t0.elapsed()); }
                        self.pc = fail_addr;
                        continue;
                    }
                    if let Some(&var_id) = self.depth_var.get(&depth) {
                        if let Some(scanner) = self.v2_scanners.get(&min_sid) {
                            let pos = scanner.depth_position(depth);
                            if let Some(val) = scanner.extract_value(pos) {
                                self.vars[var_id] = Some(val);
                            }
                        }
                    }
                    if let Some(t0) = t0 { timing.leap_next.add(t0.elapsed()); }
                }

                OpCode::BindGet => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    self.regs[inst.p1 as usize] = self.vars[inst.p2 as usize].clone();
                    if let Some(t0) = t0 { timing.bind_get.add(t0.elapsed()); }
                }

                OpCode::BindSet => {
                    self.vars[inst.p1 as usize] = self.regs[inst.p2 as usize].clone();
                }

                OpCode::RangeOp => {
                    let val = self.regs.get(inst.p3 as usize).and_then(|v| v.clone());
                    if let Some(v) = val {
                        let branches = self.range_ops.entry(inst.p1 as usize).or_default();
                        if branches.is_empty() {
                            branches.push(vec![]);
                        }
                        branches.last_mut().unwrap().push((inst.p2, v));
                    }
                }

                OpCode::RangeBranch => {
                    let branches = self.range_ops.entry(inst.p1 as usize).or_default();
                    if branches.is_empty() {
                        branches.push(vec![]);
                    }
                    branches.push(vec![]);
                }

                OpCode::ResultRow => {
                    let t0 = if do_timing { Some(Instant::now()) } else { None };
                    let start = inst.p1 as usize;
                    let ncols = inst.p2 as usize;
                    if ncols == 0 {
                        out.push(Vec::new());
                        self.count += 1;
                        if let Some(limit) = self.limit {
                            if self.count >= limit {
                                if let Some(t0) = t0 { timing.result_row.add(t0.elapsed()); }
                                if do_timing { timing.print(wall_start.elapsed()); }
                                return Ok(false);
                            }
                        }
                        self.pc += 1;
                        if let Some(t0) = t0 { timing.result_row.add(t0.elapsed()); }
                        if out.len() >= max_rows {
                            if do_timing { timing.print(wall_start.elapsed()); }
                            return Ok(true);
                        }
                        continue;
                    }
                    let mut row: Vec<Value> = Vec::with_capacity(ncols);
                    let mut all_present = true;
                    for i in 0..ncols {
                        match &self.regs[start + i] {
                            Some(v) => row.push(v.clone()),
                            None => {
                                all_present = false;
                                break;
                            }
                        }
                    }
                    if all_present {
                        out.push(row);
                        self.count += 1;
                        if let Some(limit) = self.limit {
                            if self.count >= limit {
                                if let Some(t0) = t0 { timing.result_row.add(t0.elapsed()); }
                                if do_timing { timing.print(wall_start.elapsed()); }
                                return Ok(false);
                            }
                        }
                    }
                    if let Some(t0) = t0 { timing.result_row.add(t0.elapsed()); }
                    if out.len() >= max_rows {
                        self.pc += 1;
                        if do_timing { timing.print(wall_start.elapsed()); }
                        return Ok(true);
                    }
                }

                OpCode::EmitDeclare => {
                    self.emit_values.clear();
                }

                OpCode::EmitValue => {
                    if let Some(ref v) = self.regs[inst.p1 as usize] {
                        self.emit_values.push(v.clone());
                    }
                }

                OpCode::EmitEnd => {
                    out.push(self.emit_values.clone());
                    self.count += 1;
                    if let Some(limit) = self.limit {
                        if self.count >= limit {
                            if do_timing { timing.print(wall_start.elapsed()); }
                            return Ok(false);
                        }
                    }
                    if out.len() >= max_rows {
                        self.pc += 1;
                        if do_timing { timing.print(wall_start.elapsed()); }
                        return Ok(true);
                    }
                }

                OpCode::ProbeDeclare => {
                    self.probe_positions.clear();
                }

                OpCode::ProbeBind => {
                    if let Some(ref v) = self.regs[inst.p2 as usize] {
                        self.probe_positions.insert(inst.p1 as usize, v.clone());
                    }
                }

                OpCode::ProbeBegin => {
                    let e_val = match self.probe_positions.get(&0) {
                        Some(v) => v.raw_int() as u64,
                        None => {
                            self.probe_found_t = None;
                            self.pc = inst.p1 as usize;
                            continue;
                        }
                    };
                    let a_val = match self.probe_positions.get(&1) {
                        Some(v) => v.raw_int() as u32,
                        None => {
                            self.probe_found_t = None;
                            self.pc = inst.p1 as usize;
                            continue;
                        }
                    };
                    let bound = [BoundPart::Int(e_val), BoundPart::Attr(a_val)];
                    let datoms = self.engine.probe_collect("EAVT", &bound, &self.ctx);
                    let v_probe = self.probe_positions.get(&2);
                    let ts_probe = self.probe_positions.get(&3);
                    let mut found_t: Option<u64> = None;
                    let found = datoms.iter().any(|d| {
                        if d.retracted {
                            return false;
                        }
                        if let Some(ref pv) = v_probe {
                            if !probe_value_matches(&d.v, pv) {
                                return false;
                            }
                        }
                        if let Some(ref ts) = ts_probe {
                            if d.t != ts.raw_int() as u64 {
                                return false;
                            }
                        }
                        found_t = Some(d.t);
                        true
                    });
                    if !found {
                        self.probe_found_t = None;
                        self.pc = inst.p1 as usize;
                        continue;
                    }
                    self.probe_found_t = found_t;
                }

                OpCode::ProbeGetT => {
                    if let Some(t) = self.probe_found_t {
                        let tx_eid = dynspire_commons::transactor::resolver_consts::make_entity_id(
                            dynspire_commons::transactor::resolver_consts::PART_TX, t,
                        );
                        self.regs[inst.p1 as usize] = Some(Value::int64(tx_eid as i64));
                    } else {
                        self.regs[inst.p1 as usize] = None;
                    }
                }

                OpCode::ScanNext => {
                    if self.scan_idx < self.scan_data.len() {
                        self.scan_idx += 1;
                    } else {
                        self.pc = inst.p1 as usize;
                        continue;
                    }
                }

                OpCode::AllocEntP => {
                    let partition_id = match &inst.p4 {
                        InstructionData::Int(p) => *p as u64,
                        _ => self.engine.default_user_partition(),
                    };
                    let new_id = self.engine.allocate_in_partition(partition_id);
                    self.regs[inst.p1 as usize] = Some(Value::entity_id(new_id));
                }

                OpCode::DeclarePartition => {
                    let name = match &self.regs[inst.p1 as usize] {
                        Some(Value::Text(s)) => s.clone(),
                        _ => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let p = self.engine.declare_partition(&name, &self.ctx).unwrap_or(0);
                    if inst.p2 > 0 {
                        self.regs[inst.p2 as usize] = Some(Value::Int64(p as i64));
                    }
                }

                OpCode::LoadTxEnt => {
                    let tx_eid = dynspire_commons::transactor::resolver_consts::make_entity_id(
                        dynspire_commons::transactor::resolver_consts::PART_TX,
                    self.ctx.current_t,
                    );
                    self.regs[inst.p1 as usize] = Some(Value::Int64(tx_eid as i64));
                }

                OpCode::ExecInsert => {
                    let entity_val = match &self.regs[inst.p1 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr_val = match &self.regs[inst.p2 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let value_val = match &self.regs[inst.p3 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr = match &attr_val {
                        Value::Text(s) => s.clone(),
                        _ => attr_val.raw_int().to_string(),
                    };
                    self.engine.save_with_t(&entity_val, &attr, &value_val, &self.ctx)?;
                }

                OpCode::ExecRetract => {
                    let entity_val = match &self.regs[inst.p1 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr_val = match &self.regs[inst.p2 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let value_val = match &self.regs[inst.p3 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr = match &attr_val {
                        Value::Text(s) => s.clone(),
                        _ => attr_val.raw_int().to_string(),
                    };
                    self.engine.retract(&entity_val, &attr, &value_val, &self.ctx);
                }

                OpCode::ExecAttribute => {
                    let attr_val = match &self.regs[inst.p1 as usize] {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr = match &attr_val {
                        Value::Text(s) => s.clone(),
                        _ => attr_val.raw_int().to_string(),
                    };
                    let vt_name = match &self.regs.get(inst.p3 as usize).and_then(|r| r.as_ref()) {
                        Some(Value::Text(s)) => s.clone(),
                        _ => "STRING".to_string(),
                    };
                    self.engine.declare_attr_from_sql(&attr, &vt_name, inst.p2 & 1 != 0, inst.p2 & 2 != 0, &self.ctx)?;
                }

                OpCode::LookupEntity => {
                    let dst = inst.p1 as usize;
                    let attr_reg = inst.p2 as usize;
                    let val_reg = inst.p3 as usize;
                    let attr_name = match &self.regs[attr_reg] {
                        Some(Value::Text(s)) => s.clone(),
                        _ => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    if !self.engine.is_unique_attr(&attr_name) {
                        return Err(EngineError(format!(
                            "UPSERT WHERE requires a UNIQUE attribute: '{attr_name}'"
                        )));
                    }
                    let val = match &self.regs[val_reg].clone() {
                        Some(v) => v.clone(),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    match self.engine.lookup_entity(&attr_name, &val, &self.ctx) {
                        Some(eid) => self.regs[dst] = Some(Value::entity_id(eid)),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    }
                }

                OpCode::LookupValue => {
                    let dst = inst.p1 as usize;
                    let eid_reg = inst.p2 as usize;
                    let attr_reg = inst.p3 as usize;
                    let eid = match &self.regs[eid_reg] {
                        Some(v) => v.raw_int() as u64,
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    let attr_name = match &self.regs[attr_reg] {
                        Some(Value::Text(s)) => s.clone(),
                        _ => {
                            self.pc += 1;
                            continue;
                        }
                    };
                    match self.engine.lookup_value(eid, &attr_name, &self.ctx) {
                        Some(v) => self.regs[dst] = Some(v),
                        None => {
                            self.pc += 1;
                            continue;
                        }
                    }
                }

                OpCode::ScannerOpen => {
                    let sid = inst.p1 as usize;
                    let cf_id = inst.p2 as u32;
                    let history = inst.p3 != 0;
                    let (index_name, base_order): (&str, &[&str]) = match cf_id {
                        0 => ("EAVT", &["e", "a", "v"]),
                        1 => ("AEVT", &["a", "e", "v"]),
                        2 => ("AVET", &["a", "v", "e"]),
                        3 => ("VAET", &["v", "a", "e"]),
                        _ => ("EAVT", &["e", "a", "v"]),
                    };
                    let idx_order: Vec<String> = base_order.iter()
                        .chain(["t", "added"].iter())
                        .map(|s| s.to_string()).collect();
                    let mut scanner = crate::engine::scanner::V2Scanner::new(
                        index_name,
                        idx_order,
                        self.ctx.as_of_us,
                        None,
                    );
                    if history {
                        scanner.set_history_mode();
                    }
                    self.v2_scanners.insert(sid, scanner);
                }

                OpCode::PrefixPush => {
                    let sid = inst.p1 as usize;
                    let reg = inst.p2 as usize;
                    let pos_in_idx = inst.p3 as usize;
                    if let Some(ref val) = self.regs[reg] {
                        if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
                            scanner.push_prefix_at(pos_in_idx, val);
                        }
                    }
                }

                OpCode::DepthEnter => {
                    let depth = inst.p1 as usize;
                    let sid = inst.p2 as usize;
                    let pos_idx = inst.p3 as usize;

                    if let Some(scanner) = self.v2_scanners.get_mut(&sid) {
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
                                Err(_) => std::sync::Arc::new(std::cell::RefCell::new(
                                    crate::engine::scanner::InvalidCursor
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
                        } else if scanner.depth_positions.keys().min().map(|md| *md >= depth).unwrap_or(true) {
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
                        if let Some(scanner) = self.v2_scanners.get(&sid) {
                            if let Some(val) = scanner.extract_value(scanner.depth_position(depth)) {
                                self.vars[var_id] = Some(val);
                            }
                        }
                    }
                }

                OpCode::ScannerClose => {
                    let sid = inst.p1 as usize;
                    self.v2_scanners.remove(&sid);
                }

                OpCode::CursorDeclare | OpCode::CursorBind | OpCode::CursorClose | OpCode::DepthOpen | OpCode::RangeAdd => {
                    // v1 opcodes — replaced by RangeOp / v2 scanner system
                }
            }

            self.pc += 1;
        }

        if do_timing { timing.print(wall_start.elapsed()); }
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn merge_bindings(
        a: &[(usize, Value)],
        b: &[(usize, Value)],
    ) -> Option<Vec<(usize, Value)>> {
        let mut result: HashMap<usize, Value> = HashMap::new();
        for (k, v) in a.iter().chain(b.iter()) {
            if let Some(existing) = result.get(k) {
                if existing != v {
                    return None;
                }
            } else {
                result.insert(*k, v.clone());
            }
        }
        let mut vec: Vec<(usize, Value)> = result.into_iter().collect();
        vec.sort_by_key(|(k, _)| *k);
        Some(vec)
    }

    fn choose_scan_params(
        e: Option<u64>,
        a: Option<u32>,
        v: Option<&Value>,
    ) -> (&'static str, Option<u64>, Option<u32>) {
        let cf = if a.is_some() && e.is_none() && v.is_none() {
            "AEVT"
        } else {
            "EAVT"
        };
        (cf, e, a)
    }

    #[test]
    fn test_instruction_default() {
        let d = InstructionData::default();
        match d {
            InstructionData::None => {}
            _ => panic!("expected None"),
        }
    }

    #[test]
    fn test_merge_bindings_compatible() {
        let a = vec![(0, Value::int64(1)), (1, Value::int64(2))];
        let b = vec![(2, Value::int64(3))];
        let merged = merge_bindings(&a, &b).unwrap();
        assert_eq!(merged.len(), 3);
    }

    #[test]
    fn test_merge_bindings_conflict() {
        let a = vec![(0, Value::int64(1))];
        let b = vec![(0, Value::int64(2))];
        assert!(merge_bindings(&a, &b).is_none());
    }

    #[test]
    fn test_choose_scan_params_all_bound() {
        let (cf, _, _) = choose_scan_params(Some(1), Some(2), Some(&Value::int64(3)));
        assert_eq!(cf, "EAVT");
    }

    #[test]
    fn test_choose_scan_params_e_only() {
        let (cf, _, _) = choose_scan_params(Some(1), None, None);
        assert_eq!(cf, "EAVT");
    }

    #[test]
    fn test_choose_scan_params_a_only() {
        let (cf, _, _) = choose_scan_params(None, Some(2), None);
        assert_eq!(cf, "AEVT");
    }

    #[test]
    fn test_choose_scan_params_none() {
        let (cf, _, _) = choose_scan_params(None, None, None);
        assert_eq!(cf, "EAVT");
    }

    #[test]
    fn test_probe_bind_accumulates() {
        let mut probe_positions: HashMap<usize, Value> = HashMap::new();
        probe_positions.insert(0, Value::int64(42));
        probe_positions.insert(1, Value::int64(5));
        probe_positions.insert(2, Value::int64(30));
        assert_eq!(probe_positions.len(), 3);
        assert_eq!(probe_positions[&0], Value::int64(42));
        assert_eq!(probe_positions[&1], Value::int64(5));
        assert_eq!(probe_positions[&2], Value::int64(30));
    }

    #[test]
    fn test_probe_bind_with_timestamp() {
        let mut probe_positions: HashMap<usize, Value> = HashMap::new();
        probe_positions.insert(0, Value::int64(42));
        probe_positions.insert(1, Value::int64(5));
        probe_positions.insert(2, Value::int64(30));
        probe_positions.insert(3, Value::int64(1000000));
        assert_eq!(probe_positions.len(), 4);
        assert_eq!(probe_positions[&3], Value::int64(1000000));
    }

    #[test]
    fn test_probe_declare_clears() {
        let mut probe_positions: HashMap<usize, Value> = HashMap::new();
        probe_positions.insert(0, Value::int64(42));
        probe_positions.clear();
        assert!(probe_positions.is_empty());
    }
}

#[cfg(test)]
mod v2_vm_tests {
    use super::*;
    use crate::engine::scanner::InvalidCursor;
    use dynspire_commons::transactor::cursor::Cursor;
    use dynspire_commons::transactor::keys as eavt_keys;
    use dynspire_commons::query_ir::Instruction;
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    struct MockCursor2 {
        keys: Vec<Vec<u8>>,
        pos: usize,
    }

    impl MockCursor2 {
        fn new(keys: Vec<Vec<u8>>) -> Self {
            Self { keys, pos: 0 }
        }
    }

    impl Cursor for MockCursor2 {
        fn is_valid(&self) -> bool { self.pos < self.keys.len() }
        fn current_key(&self) -> Option<&[u8]> { self.keys.get(self.pos).map(|k| k.as_slice()) }
        fn step(&mut self) { self.pos += 1; }
        fn skip_group(&mut self, group_end: usize) {
            if self.pos >= self.keys.len() { return; }
            let cur = &self.keys[self.pos][..group_end];
            while self.pos < self.keys.len() && self.keys[self.pos][..group_end] == *cur {
                self.pos += 1;
            }
        }
        fn seek(&mut self, target: &[u8]) {
            self.pos = self.keys.partition_point(|k| k.as_slice() < target);
        }
        fn update_end(&mut self, _end: &[u8]) {}
        fn invalidate(&mut self) { self.pos = self.keys.len(); }
    }

    struct MockEngine {
        cf_keys: BTreeMap<u32, Vec<Vec<u8>>>,
        attrs: BTreeMap<String, u32>,
        attr_names: BTreeMap<u32, String>,
    }

    impl MockEngine {
        fn new() -> Self {
            Self {
                cf_keys: BTreeMap::new(),
                attrs: BTreeMap::new(),
                attr_names: BTreeMap::new(),
            }
        }

        fn add_attr(&mut self, name: &str, aid: u32) {
            self.attrs.insert(name.to_string(), aid);
            self.attr_names.insert(aid, name.to_string());
        }

        fn add_avet_datom(&mut self, a: u32, v: i64, e: u64, t: u64, retracted: bool) {
            let suffix = eavt_keys::encode_suffix(t, retracted);
            let mut key = Vec::new();
            key.extend_from_slice(&a.to_be_bytes());
            key.extend_from_slice(&eavt_keys::encode_int64(v).to_be_bytes());
            key.extend_from_slice(&e.to_be_bytes());
            key.extend_from_slice(&suffix.to_be_bytes());
            self.cf_keys.entry(2).or_default().push(key);
        }

        fn build(&mut self) {
            for keys in self.cf_keys.values_mut() {
                keys.sort();
            }
        }
    }

    impl VMEngine for MockEngine {
        fn resolve_entity(&self, name_or_id: &Value) -> u64 { name_or_id.raw_int() as u64 }
        fn lookup_attr(&self, name: &str) -> Option<u32> { self.attrs.get(name).copied() }
        fn attr_name(&self, aid: u32) -> String { self.attr_names.get(&aid).cloned().unwrap_or_default() }
        fn open_raw_cursor(
            &self, cf_id: u32, prefix: &[u8],
        ) -> Result<std::sync::Arc<std::cell::RefCell<dyn Cursor>>, String> {
            let all_keys = self.cf_keys.get(&cf_id).cloned().unwrap_or_default();
            let filtered: Vec<Vec<u8>> = all_keys.into_iter()
                .filter(|k| k.starts_with(prefix))
                .collect();
            if filtered.is_empty() {
                Ok(std::sync::Arc::new(RefCell::new(InvalidCursor)))
            } else {
                Ok(std::sync::Arc::new(RefCell::new(MockCursor2::new(filtered))))
            }
        }
        fn collect_active(&self, _cf: &str, _prefix: &[u8], _ctx: &QueryContext) -> Vec<RawDatomView> { vec![] }
        fn probe_collect(&self, _index: &str, _bound: &[BoundPart], _ctx: &QueryContext) -> Vec<RawDatomView> { vec![] }
        fn save_with_t(&self, _e: &Value, _attr: &str, _v: &Value, _ctx: &QueryContext) -> Result<(), EngineError> { Ok(()) }
        fn retract(&self, _e: &Value, _attr: &str, _v: &Value, _ctx: &QueryContext) {}
        fn allocate_in_partition(&self, _partition_id: u64) -> u64 { 0 }
        fn default_user_partition(&self) -> u64 { 100 }
        fn declare_partition(&self, _name: &str, _ctx: &QueryContext) -> Result<u64, EngineError> { Ok(0) }
        fn declare_attr_from_sql(&self, _attr: &str, _type_name: &str, _many: bool, _unique: bool, _ctx: &QueryContext) -> Result<(), EngineError> { Ok(()) }
        fn is_unique_attr(&self, _attr_name: &str) -> bool { false }
        fn value_type_for(&self, _aid: u32) -> Option<u32> { None }
        fn lookup_entity(&self, _attr_name: &str, _value: &Value, _ctx: &QueryContext) -> Option<u64> { None }
        fn lookup_value(&self, _eid: u64, _attr_name: &str, _ctx: &QueryContext) -> Option<Value> { None }
        fn allocate_t_and_write_tx(&self) -> u64 { 1 }
    }

    fn make_program(instructions: Vec<Instruction>, num_registers: usize, num_vars: usize, depth_var: Vec<(usize, usize)>) -> VMProgram {
        VMProgram {
            instructions,
            num_registers,
            num_vars,
            var_names: vec!["v".to_string()],
            depth_var,
            same_var_constraints: vec![],
            history: false,
        }
    }

    #[test]
    fn test_v2_vm_range_query() {
        let mut engine = MockEngine::new();
        engine.add_attr("bench.name", 10);
        engine.add_avet_datom(10, 1, 100, 1000, false);
        engine.add_avet_datom(10, 2, 101, 1000, false);
        engine.add_avet_datom(10, 3, 102, 1000, false);
        engine.add_avet_datom(10, 4, 103, 1000, false);
        engine.add_avet_datom(10, 5, 104, 1000, false);
        engine.build();

        let instructions = vec![
            Instruction { op: OpCode::ConstInt, p1: 0, p2: 0, p3: 0, p4: InstructionData::Int(2) },
            Instruction { op: OpCode::ConstInt, p1: 1, p2: 0, p3: 0, p4: InstructionData::Int(4) },
            Instruction { op: OpCode::RangeOp, p1: 0, p2: RANGE_OP_GTE, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::RangeOp, p1: 0, p2: RANGE_OP_LT, p3: 1, p4: InstructionData::None },
            Instruction { op: OpCode::InternA, p1: 2, p2: 0, p3: 0, p4: InstructionData::Str("bench.name".into()) },
            Instruction { op: OpCode::ScannerOpen, p1: 0, p2: 2, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::PrefixPush, p1: 0, p2: 2, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::DepthEnter, p1: 0, p2: 0, p3: 1, p4: InstructionData::None },
            Instruction { op: OpCode::LeapInit, p1: 0, p2: 17, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::BindGet, p1: 3, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResolveVal, p1: 3, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResultRow, p1: 3, p2: 1, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::LeapNext, p1: 0, p2: 17, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::BindGet, p1: 3, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResolveVal, p1: 3, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResultRow, p1: 3, p2: 1, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::Goto, p1: 12, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ScannerClose, p1: 0, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::Halt, p1: 0, p2: 0, p3: 0, p4: InstructionData::None },
        ];

        let program = make_program(instructions, 4, 1, vec![(0, 0)]);
        let _ctx = QueryContext { as_of_us: None, current_t: 1 };
        let mut vm = VM::new(Arc::new(program), Arc::new(engine), vec![], None, 1, None);
        let results = vm.run().unwrap();

        assert_eq!(results.len(), 2);
        assert_eq!(results[0][0].raw_int(), 2);
        assert_eq!(results[1][0].raw_int(), 3);
    }

    #[test]
    fn test_v2_vm_single_value() {
        let mut engine = MockEngine::new();
        engine.add_attr("bench.name", 10);
        engine.add_avet_datom(10, 42, 200, 1000, false);
        engine.add_avet_datom(10, 99, 201, 1000, false);
        engine.build();

        let instructions = vec![
            Instruction { op: OpCode::InternA, p1: 0, p2: 0, p3: 0, p4: InstructionData::Str("bench.name".into()) },
            Instruction { op: OpCode::ScannerOpen, p1: 0, p2: 2, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::PrefixPush, p1: 0, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::DepthEnter, p1: 0, p2: 0, p3: 1, p4: InstructionData::None },
            Instruction { op: OpCode::LeapInit, p1: 0, p2: 13, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::BindGet, p1: 1, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResolveVal, p1: 1, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResultRow, p1: 1, p2: 1, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::LeapNext, p1: 0, p2: 13, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::BindGet, p1: 1, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResolveVal, p1: 1, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ResultRow, p1: 1, p2: 1, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::Goto, p1: 8, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::ScannerClose, p1: 0, p2: 0, p3: 0, p4: InstructionData::None },
            Instruction { op: OpCode::Halt, p1: 0, p2: 0, p3: 0, p4: InstructionData::None },
        ];

        let program = make_program(instructions, 2, 1, vec![(0, 0)]);
        let mut vm = VM::new(Arc::new(program), Arc::new(engine), vec![], None, 1, None);
        let results = vm.run().unwrap();

        assert_eq!(results.len(), 2);
        let vals: Vec<i64> = results.iter().map(|r| r[0].raw_int()).collect();
        assert!(vals.contains(&42));
        assert!(vals.contains(&99));
    }
}
