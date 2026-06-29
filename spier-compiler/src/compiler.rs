use std::collections::{HashMap, HashSet};

use crate::datalog::{BoundValue, PlanValue, RangeBoundsMap, Slot};
use dynspire_commons::datalog::FindVar;
use dynspire_commons::planner::{Pattern, QueryPlanResult, IterPlanData, PlanTrace};
use dynspire_commons::value::Value;
use dynspire_commons::query_ir::{
    Instruction, InstructionData, OpCode, SpecKind, VMProgram,
    RANGE_OP_EQ, RANGE_OP_NEQ, RANGE_OP_GT, RANGE_OP_GTE,
    RANGE_OP_LT, RANGE_OP_LTE, RANGE_OP_IN,
};

/// Resolve retract pairs from DELETE conditions (non-eid conditions).
/// Each pair is (attr_name, resolved_value).
pub fn resolve_delete_pairs(
    stmt: &dynspire_commons::sql_parse::RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Vec<(String, Value)>, String> {
    use dynspire_commons::sql_parse::{RustConditionRight, RustLiteral};
    let resolve_right = |right: &RustConditionRight, params: &[Value]| -> Result<Value, String> {
        match right {
            RustConditionRight::Param(idx) => {
                let i = *idx as usize;
                if i == 0 || i > params.len() {
                    return Err(format!("parameter %{} out of range", idx));
                }
                Ok(params[i - 1].clone())
            }
            RustConditionRight::Literal(RustLiteral::Int(n)) => Ok(Value::Int64(*n)),
            RustConditionRight::Literal(RustLiteral::Float(f)) => Ok(Value::Float64(*f)),
            RustConditionRight::Literal(RustLiteral::Str(s)) => Ok(Value::text(s.clone())),
            RustConditionRight::Literal(RustLiteral::Bool(b)) => Ok(Value::Bool(*b as u8)),
            RustConditionRight::Literal(RustLiteral::Bytes(b)) => Ok(Value::Bytes(b.clone())),
            _ => Err("unsupported condition right in delete".to_string()),
        }
    };

    let mut pairs = Vec::new();
    for cond in &stmt.conditions {
        if cond.left.field != "eid" {
            let val = resolve_right(&cond.right, params)?;
            pairs.push((cond.left.field.clone(), val));
        }
    }
    Ok(pairs)
}

/// Resolve entity value from DELETE eid condition.
pub fn resolve_delete_entity(
    stmt: &dynspire_commons::sql_parse::RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Value, String> {
    use dynspire_commons::sql_parse::{RustConditionRight, RustLiteral};
    for cond in &stmt.conditions {
        if cond.left.field == "eid" {
            return match &cond.right {
                RustConditionRight::Param(idx) => {
                    let i = *idx as usize;
                    if i == 0 || i > params.len() {
                        return Err(format!("parameter %{} out of range", idx));
                    }
                    Ok(params[i - 1].clone())
                }
                RustConditionRight::Literal(RustLiteral::Int(n)) => Ok(Value::Int64(*n)),
                _ => Err("entity must be integer in DELETE WHERE".to_string()),
            };
        }
    }
    Err("DELETE direct requires eid condition".to_string())
}


struct Compiler {
    insts: Vec<Instruction>,
    num_regs: usize,
    num_vars: usize,
    num_cursors: usize,
    labels: HashMap<String, usize>,
    pending_labels: Vec<(usize, String, bool)>,
}

impl Compiler {
    fn new(num_regs: usize, num_vars: usize) -> Self {
        Self {
            insts: Vec::new(),
            num_regs,
            num_vars,
            num_cursors: 0,
            labels: HashMap::new(),
            pending_labels: Vec::new(),
        }
    }

    fn emit(&mut self, op: OpCode, p1: i32, p2: i32, p3: i32, p4: InstructionData) {
        self.insts.push(Instruction { op, p1, p2, p3, p4 });
    }

    fn emit_label(&mut self, name: &str) {
        self.labels.insert(name.to_string(), self.insts.len());
    }

    fn emit_goto(&mut self, label: &str) {
        self.pending_labels.push((self.insts.len(), label.to_string(), false));
        self.emit(OpCode::Goto, 0, 0, 0, InstructionData::None);
    }

    fn emit_leap_init(&mut self, depth: i32, label: &str) {
        self.pending_labels.push((self.insts.len(), label.to_string(), true));
        self.emit(OpCode::LeapInit, depth, 0, 0, InstructionData::None);
    }

    fn emit_leap_next(&mut self, depth: i32, label: &str) {
        self.pending_labels.push((self.insts.len(), label.to_string(), true));
        self.emit(OpCode::LeapNext, depth, 0, 0, InstructionData::None);
    }

    fn emit_probe_begin(&mut self, label: &str) {
        self.pending_labels.push((self.insts.len(), label.to_string(), false));
        self.emit(OpCode::ProbeBegin, 0, 0, 0, InstructionData::None);
    }

    fn alloc_reg(&mut self) -> i32 {
        let r = self.num_regs;
        self.num_regs += 1;
        r as i32
    }

    fn alloc_cursor(&mut self) -> i32 {
        let c = self.num_cursors;
        self.num_cursors += 1;
        c as i32
    }

    fn build(
        mut self,
        var_names: Vec<String>,
        depth_var: Vec<(usize, usize)>,
    ) -> VMProgram {
        for (inst_idx, label, is_leap) in &self.pending_labels {
            if let Some(&target) = self.labels.get(label) {
                let inst = &mut self.insts[*inst_idx];
                if *is_leap {
                    inst.p2 = target as i32;
                } else {
                    inst.p1 = target as i32;
                }
            }
        }
        VMProgram {
            instructions: self.insts,
            num_registers: self.num_regs,
            num_vars: self.num_vars,
            var_names,
            depth_var,
            same_var_constraints: Vec::new(),
            history: false,
        }
    }

    fn build_with_constraints(
        mut self,
        var_names: Vec<String>,
        depth_var: Vec<(usize, usize)>,
        same_var_constraints: Vec<(i32, Vec<(usize, usize)>)>,
    ) -> VMProgram {
        for (inst_idx, label, is_leap) in &self.pending_labels {
            if let Some(&target) = self.labels.get(label) {
                let inst = &mut self.insts[*inst_idx];
                if *is_leap {
                    inst.p2 = target as i32;
                } else {
                    inst.p1 = target as i32;
                }
            }
        }
        VMProgram {
            instructions: self.insts,
            num_registers: self.num_regs,
            num_vars: self.num_vars,
            var_names,
            depth_var,
            same_var_constraints,
            history: false,
        }
    }
}

fn find_v2_compatible_index(ip: &IterPlanData) -> &'static str {
    use dynspire_commons::planner::INDEX_ORDERS;
    use std::collections::HashSet;

    let bound: HashSet<String> = ip.bound_ints.keys().cloned().collect();

    let mut var_depths_sorted: Vec<(usize, String)> = ip.var_depths.iter()
        .map(|(d, p)| (*d, p.clone()))
        .collect();
    var_depths_sorted.sort_by_key(|(d, _)| *d);
    let mut var_positions: Vec<String> = var_depths_sorted.iter().map(|(_, p)| p.clone()).collect();
    for positions in ip.same_var_constraints.values() {
        for pos in positions {
            if !var_positions.contains(pos) {
                var_positions.push(pos.clone());
            }
        }
    }

    let spec_is_var = |pos: &str| -> bool {
        let idx = match pos { "e" => 0, "a" => 1, "v" => 2, "t" => 3, "added" => 4, _ => 4 };
        matches!(ip.specs.get(idx), Some(SpecKind::Var(_)))
    };

    for (idx_name, idx_order) in &INDEX_ORDERS {
        let n_bound_leading = idx_order.iter()
            .take_while(|p| bound.contains(**p))
            .count();

        if n_bound_leading < bound.len() { continue; }

        let var_in_idx: Vec<String> = idx_order.iter()
            .filter(|p| spec_is_var(p) && !bound.contains(**p))
            .map(|s| s.to_string())
            .collect();

        if var_in_idx == var_positions {
            return idx_name;
        }
    }

    "EAVT"
}

fn emit_plan_value(b: &mut Compiler, pv: &PlanValue) -> i32 {
    let r = b.alloc_reg();
    match pv {
        PlanValue::Value(Value::Int64(n)) => b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*n)),
        PlanValue::Value(Value::Float64(f)) => {
            b.emit(OpCode::ConstFloat, r, 0, 0, InstructionData::Float(*f));
        }
        PlanValue::Value(Value::Text(s)) => b.emit(OpCode::ConstStr, r, 0, 0, InstructionData::Str(s.clone())),
        PlanValue::Value(_) => b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0)),
        PlanValue::Param(idx) => b.emit(OpCode::Param, r, *idx as i32, 0, InstructionData::None),
    }
    r
}

fn emit_literal_values(b: &mut Compiler, literal_values: &[Value]) {
    b.emit(OpCode::EmitDeclare, 0, 0, 0, InstructionData::None);
    let r_tmp = b.alloc_reg();
    for v in literal_values {
        match v {
            Value::Int64(n) => b.emit(OpCode::ConstInt, r_tmp, 0, 0, InstructionData::Int(*n)),
            Value::Float64(f) => {
                b.emit(OpCode::ConstFloat, r_tmp, 0, 0, InstructionData::Float(*f));
            }
            Value::Text(s) => b.emit(OpCode::ConstStr, r_tmp, 0, 0, InstructionData::Str(s.clone())),
            _ => b.emit(OpCode::ConstInt, r_tmp, 0, 0, InstructionData::Int(0)),
        }
        b.emit(OpCode::EmitValue, r_tmp, 0, 0, InstructionData::None);
    }
    b.emit(OpCode::EmitEnd, 0, 0, 0, InstructionData::None);
}

fn emit_load_const(b: &mut Compiler, val: &BoundValue) -> i32 {
    let r = b.alloc_reg();
    match val {
        BoundValue::Str(s) | BoundValue::Attr(s) => {
            b.emit(OpCode::ConstStr, r, 0, 0, InstructionData::Str(s.clone()));
        }
        BoundValue::Int(n) => {
            b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*n));
        }
        BoundValue::Float(f) => {
            b.emit(OpCode::ConstFloat, r, 0, 0, InstructionData::Float(*f));
        }
        BoundValue::Param(idx) => {
            b.emit(OpCode::Param, r, *idx as i32, 0, InstructionData::None);
        }
        _ => {
            b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0));
        }
    }
    r
}

fn emit_probe(b: &mut Compiler, pattern: &Pattern, fail_label: &str) -> Option<(String, i32)> {
    let r_e = match &pattern.e {
        Slot::Const(bv) => emit_load_const(b, bv),
        _ => {
            let r = b.alloc_reg();
            b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0));
            r
        }
    };
    let r_a = match &pattern.a {
        Slot::Const(bv) => {
            let r = b.alloc_reg();
            match bv {
                BoundValue::ResolvedAttr(id, _, _) => {
                    b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*id as i64));
                }
                BoundValue::Str(s) | BoundValue::Attr(s) => {
                    b.emit(OpCode::InternA, r, 0, 0, InstructionData::Str(s.clone()));
                }
                BoundValue::Int(n) => {
                    b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*n));
                }
                BoundValue::Float(f) => {
                    b.emit(OpCode::ConstFloat, r, 0, 0, InstructionData::Float(*f));
                }
                _ => {
                    b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0));
                }
            }
            r
        }
        _ => {
            let r = b.alloc_reg();
            b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0));
            r
        }
    };
    let r_v = match &pattern.v {
        Slot::Const(bv) => emit_load_const(b, bv),
        _ => {
            let r = b.alloc_reg();
            b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(0));
            r
        }
    };
    b.emit(OpCode::ProbeDeclare, 0, 0, 0, InstructionData::None);
    b.emit(OpCode::ProbeBind, 0, r_e, 0, InstructionData::None);
    b.emit(OpCode::ProbeBind, 1, r_a, 0, InstructionData::None);
    b.emit(OpCode::ProbeBind, 2, r_v, 0, InstructionData::None);
    b.emit_probe_begin(fail_label);

    if let Slot::Var(name) = &pattern.t {
        let r_t = b.alloc_reg();
        b.emit(OpCode::ProbeGetT, r_t, 0, 0, InstructionData::None);
        Some((name.clone(), r_t))
    } else {
        None
    }
}

fn emit_projection(
    b: &mut Compiler,
    find_vars: &[String],
    var_id_map: &HashMap<String, usize>,
    _e_vars: &HashSet<String>,
    attr_vars: &HashSet<String>,
    t_vars: &HashSet<String>,
    constant_indices: &HashMap<usize, PlanValue>,
    total_proj_len: usize,
) {
    let r_start = b.alloc_reg();
    let first_r = r_start;
    let mut fv_idx = 0;
    for i in 0..total_proj_len {
        let r = if i > 0 { b.alloc_reg() } else { r_start };
        if let Some(pv) = constant_indices.get(&i) {
            match pv {
                PlanValue::Value(Value::Int64(n)) => b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*n)),
                PlanValue::Value(Value::Float64(f)) => {
                    b.emit(OpCode::ConstFloat, r, 0, 0, InstructionData::Float(*f));
                }
                PlanValue::Value(Value::Text(s)) => b.emit(OpCode::ConstStr, r, 0, 0, InstructionData::Str(s.clone())),
                PlanValue::Value(_) => b.emit(OpCode::Null, r, 0, 0, InstructionData::None),
                PlanValue::Param(idx) => b.emit(OpCode::Param, r, *idx as i32, 0, InstructionData::None),
            }
            continue;
        }
        if fv_idx >= find_vars.len() {
            b.emit(OpCode::Null, r, 0, 0, InstructionData::None);
            continue;
        }
        let var_name = &find_vars[fv_idx];
        fv_idx += 1;
        if let Some(&vid) = var_id_map.get(var_name) {
            b.emit(OpCode::BindGet, r, vid as i32, 0, InstructionData::None);
        } else {
            b.emit(OpCode::Null, r, 0, 0, InstructionData::None);
            continue;
        }
        if t_vars.contains(var_name) {
        } else if attr_vars.contains(var_name) {
            b.emit(OpCode::AttrName, r, 0, 0, InstructionData::None);
        } else {
            b.emit(OpCode::ResolveVal, r, 0, 0, InstructionData::None);
        }
    }
    b.emit(OpCode::ResultRow, first_r, total_proj_len as i32, 0, InstructionData::None);
}

struct TriejoinContext {
    var_id_map: HashMap<String, usize>,
    var_names_list: Vec<String>,
    num_depths: usize,
    effective_deepest: usize,
    max_projected: i32,
    dedup: bool,
    cursor_map: HashMap<usize, i32>,
    depth_groups: HashMap<usize, Vec<i32>>,
    depth_var_pairs: Vec<(usize, usize)>,
}

fn build_triejoin_skeleton<F>(
    plan: &QueryPlanResult,
    range_bounds: &RangeBoundsMap,
    find_vars: &[String],
    history: bool,
    emit_leaf: F,
) -> (Compiler, TriejoinContext)
where
    F: FnOnce(&mut Compiler, &TriejoinContext),
{
    let ordered_vars = &plan.ordered_vars;

    let mut var_names_list: Vec<String> = ordered_vars.clone();

    for tn in &plan.t_lookup_vars {
        if !var_names_list.contains(tn) {
            var_names_list.push(tn.clone());
        }
    }

    let mut synth_trailing: Vec<(String, PlanValue)> = Vec::new();
    for ip in &plan.iter_plans {
        for (name, val) in &ip.trailing_bindings {
            if !var_names_list.contains(name) {
                synth_trailing.push((name.clone(), val.clone()));
            }
        }
    }
    let mut synth_ordered: Vec<String> = ordered_vars.clone();
    for (name, _) in &synth_trailing {
        var_names_list.push(name.clone());
        synth_ordered.push(name.clone());
    }

    let var_id_map: HashMap<String, usize> = var_names_list.iter().enumerate().map(|(i, n)| (n.clone(), i)).collect();
    let depth_var_pairs: Vec<(usize, usize)> = synth_ordered.iter().enumerate()
        .map(|(d, name)| (d, var_id_map[name])).collect();
    let num_depths = synth_ordered.len();

    let mut b = Compiler::new(32, var_names_list.len());

    // Trailing bindings: emit as RangeOp EQ
    for (name, pv) in &synth_trailing {
        let depth = synth_ordered.iter().position(|v| v == name).unwrap();
        let r = emit_plan_value(&mut b, pv);
        b.emit(OpCode::RangeOp, depth as i32, RANGE_OP_EQ, r, InstructionData::None);
    }

    for pattern in &plan.lookups {
        if let Some((t_name, r_t)) = emit_probe(&mut b, pattern, "halt") {
            if let Some(&vid) = var_id_map.get(&t_name) {
                b.emit(OpCode::BindSet, vid as i32, r_t, 0, InstructionData::None);
            }
        }
    }

    for (var_name, branches) in range_bounds {
        let depth = match ordered_vars.iter().position(|v| v == var_name) {
            Some(d) => d,
            None => continue,
        };
        for (branch_idx, branch) in branches.iter().enumerate() {
            if branch_idx > 0 {
                b.emit(OpCode::RangeBranch, depth as i32, 0, 0, InstructionData::None);
            }
            for (op, pv) in branch {
                let op_const = match op.as_str() {
                    "=" => RANGE_OP_EQ,
                    "!=" => RANGE_OP_NEQ,
                    ">" => RANGE_OP_GT,
                    ">=" => RANGE_OP_GTE,
                    "<" => RANGE_OP_LT,
                    "<=" => RANGE_OP_LTE,
                    "in" => RANGE_OP_IN,
                    _ => continue,
                };
                let r = emit_plan_value(&mut b, pv);
                b.emit(OpCode::RangeOp, depth as i32, op_const, r, InstructionData::None);
            }
        }
    }

    let mut cursor_map: HashMap<usize, i32> = HashMap::new();
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        let cid = b.alloc_cursor();
        cursor_map.insert(ip_idx, cid);

        let v2_order: Vec<&str> = ip.idx_order.iter().map(|s| s.as_str()).collect();
        let cf_id = match ip.index_name.to_ascii_uppercase().as_str() {
            "EAVT" => 0i32, "AEVT" => 1, "AVET" => 2, "VAET" => 3, _ => 0,
        };
        b.emit(OpCode::ScannerOpen, cid, cf_id, if history { 1 } else { 0 }, InstructionData::None);
        for pos_name in &v2_order {
            let pv = match ip.bound_ints.get(*pos_name) {
                Some(pv) => pv,
                None => break,
            };
            let pos_idx = v2_order.iter().position(|s| **s == **pos_name).unwrap_or(0);
            let r = match pv {
                PlanValue::Value(Value::Int64(id)) if *pos_name == "a" => {
                    let r = b.alloc_reg();
                    b.emit(OpCode::ConstInt, r, 0, 0, InstructionData::Int(*id));
                    r
                }
                PlanValue::Value(Value::Text(name)) if *pos_name == "a" => {
                    let r = b.alloc_reg();
                    b.emit(OpCode::InternA, r, 0, 0, InstructionData::Str(name.clone()));
                    r
                }
                _ => emit_plan_value(&mut b, pv),
            };
            b.emit(OpCode::PrefixPush, cid, r, pos_idx as i32, InstructionData::None);
        }
    }

    let mut depth_groups: HashMap<usize, Vec<i32>> = HashMap::new();
    let mut depth_pos_map: HashMap<(i32, usize), usize> = HashMap::new();
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        if let Some(&cid) = cursor_map.get(&ip_idx) {
            for &d in &ip.active_depths {
                depth_groups.entry(d).or_default().push(cid);
            }
            for (depth, pos_name) in &ip.var_depths {
                let pos_idx = ip.idx_order.iter().position(|s| s == pos_name).unwrap_or(0);
                depth_pos_map.insert((cid, *depth), pos_idx);
            }
        }
    }

    let find_var_names: HashSet<String> = find_vars.iter().cloned().collect();
    let mut max_projected: i32 = -1;
    for d in 0..num_depths {
        if find_var_names.contains(&synth_ordered[d]) {
            max_projected = d as i32;
        }
    }
    if max_projected < 0 {
        max_projected = num_depths as i32 - 1;
    }
    let effective_deepest: usize = (0..num_depths).rev()
        .find(|&d| depth_groups.get(&d).map_or(false, |v| !v.is_empty()))
        .unwrap_or(0);
    let dedup = max_projected < effective_deepest as i32;

    for depth in 0..num_depths {
        let cursor_ids = depth_groups.get(&depth).cloned().unwrap_or_default();
        if cursor_ids.is_empty() { continue; }

        let fail_label = if depth == 0 { "done".to_string() } else { format!("d{}_back", depth) };
        b.emit_label(&format!("d{}_open", depth));
        for &cid in &cursor_ids {
            let pos_idx = depth_pos_map.get(&(cid, depth)).copied().unwrap_or(0) as i32;
            b.emit(OpCode::DepthEnter, depth as i32, cid, pos_idx, InstructionData::None);
        }
        b.emit_leap_init(depth as i32, &fail_label);
    }

    let ctx = TriejoinContext {
        var_id_map,
        var_names_list,
        num_depths,
        effective_deepest,
        max_projected,
        dedup,
        cursor_map,
        depth_groups,
        depth_var_pairs,
    };

    b.emit_label("leaf");
    emit_leaf(&mut b, &ctx);

    (b, ctx)
}

fn emit_triejoin_loop(b: &mut Compiler, ctx: &TriejoinContext) {
    let num_depths = ctx.num_depths;
    let effective_deepest = ctx.effective_deepest;
    let max_projected = ctx.max_projected;
    let dedup = ctx.dedup;

    if num_depths > 0 {
        if dedup {
            for depth in (max_projected as usize + 1..num_depths).rev() {
                let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
                for &cid in &cursor_ids {
                    b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
                }
            }
            let mp_fail = if max_projected == 0 { "done".to_string() } else { format!("d{}_back", max_projected) };
            b.emit_label(&format!("d{}_iter", max_projected));
            b.emit_leap_next(max_projected, &mp_fail);
            let next_depth = (max_projected as usize + 1..num_depths)
                .find(|&d| ctx.depth_groups.get(&d).map_or(false, |v| !v.is_empty()));
            match next_depth {
                Some(d) => b.emit_goto(&format!("d{}_open", d)),
                None => b.emit_goto("done"),
            }
        } else {
            let deepest = effective_deepest;
            let deepest_cursors = ctx.depth_groups.get(&deepest).cloned().unwrap_or_default();
            if !deepest_cursors.is_empty() {
                let fail_label = if deepest == 0 { "done".to_string() } else { format!("d{}_back", deepest) };
                b.emit_label(&format!("d{}_loop", deepest));
                b.emit_leap_next(deepest as i32, &fail_label);
                b.emit_goto("leaf");
            }
        }

        for depth in (1..num_depths).rev() {
            let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
            if cursor_ids.is_empty() { continue; }
            let parent_fail = if depth - 1 == 0 { "done".to_string() } else { format!("d{}_back", depth - 1) };
            b.emit_label(&format!("d{}_back", depth));
            for &cid in &cursor_ids {
                b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
            }
            b.emit_leap_next((depth - 1) as i32, &parent_fail);
            b.emit_goto(&format!("d{}_open", depth));
        }
    }

    b.emit_label("done");
    for depth in (0..num_depths).rev() {
        let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
        for &cid in &cursor_ids {
            b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
        }
    }
    for &cid in ctx.cursor_map.values() {
        b.emit(OpCode::CursorClose, cid, 0, 0, InstructionData::None);
    }
}

pub fn compile_triejoin(
    plan: &QueryPlanResult,
    range_bounds: &RangeBoundsMap,
    find_vars: &[String],
    constant_indices: &HashMap<usize, PlanValue>,
    total_proj_len: usize,
    exists_mode: bool,
    literal_values: &[Value],
    history: bool,
) -> VMProgram {
    let e_vars = &plan.e_vars;
    let attr_vars = &plan.attr_vars;

    let (mut b, ctx) = build_triejoin_skeleton(plan, range_bounds, find_vars, history, |b, ctx| {
        if exists_mode {
            emit_literal_values(b, literal_values);
        } else {
            emit_projection(b, find_vars, &ctx.var_id_map, e_vars, attr_vars, &HashSet::new(), constant_indices, total_proj_len);
        }
    });

    let num_depths = ctx.num_depths;

    if num_depths > 0 {
        let dedup = ctx.dedup;
        let max_projected = ctx.max_projected;
        let effective_deepest = ctx.effective_deepest;

        if dedup {
            for depth in (max_projected as usize + 1..num_depths).rev() {
                let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
                for &cid in &cursor_ids {
                    b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
                }
            }
            let mp_fail = if max_projected == 0 { "done".to_string() } else { format!("d{}_back", max_projected) };
            b.emit_label(&format!("d{}_iter", max_projected));
            b.emit_leap_next(max_projected, &mp_fail);
            let next_depth = (max_projected as usize + 1..num_depths)
                .find(|&d| ctx.depth_groups.get(&d).map_or(false, |v| !v.is_empty()));
            match next_depth {
                Some(d) => b.emit_goto(&format!("d{}_open", d)),
                None => b.emit_goto("done"),
            }
        } else {
            let deepest = effective_deepest;
            let deepest_cursors = ctx.depth_groups.get(&deepest).cloned().unwrap_or_default();
            if !deepest_cursors.is_empty() {
                let fail_label = if deepest == 0 { "done".to_string() } else { format!("d{}_back", deepest) };
                b.emit_label(&format!("d{}_loop", deepest));
                b.emit_leap_next(deepest as i32, &fail_label);

                if exists_mode {
                    emit_literal_values(&mut b, literal_values);
                } else {
                    emit_projection(&mut b, find_vars, &ctx.var_id_map, e_vars, attr_vars, &HashSet::new(), constant_indices, total_proj_len);
                    b.emit_goto(&format!("d{}_loop", deepest));
                }
            }
        }

        for depth in (1..num_depths).rev() {
            let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
            if cursor_ids.is_empty() { continue; }
            let parent_fail = if depth - 1 == 0 { "done".to_string() } else { format!("d{}_back", depth - 1) };
            b.emit_label(&format!("d{}_back", depth));
            for &cid in &cursor_ids {
                b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
            }
            b.emit_leap_next((depth - 1) as i32, &parent_fail);
            b.emit_goto(&format!("d{}_open", depth));
        }
    }

    b.emit_label("done");
    for depth in (0..num_depths).rev() {
        let cursor_ids = ctx.depth_groups.get(&depth).cloned().unwrap_or_default();
        for &cid in &cursor_ids {
            b.emit(OpCode::DepthUp, depth as i32, cid, 0, InstructionData::None);
        }
    }
    for &cid in ctx.cursor_map.values() {
        b.emit(OpCode::ScannerClose, cid, 0, 0, InstructionData::None);
    }

    b.emit_label("halt");
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);

    let mut same_var_constraints: Vec<(i32, Vec<(usize, usize)>)> = Vec::new();
    for (&ip_idx, &cid) in &ctx.cursor_map {
        if let Some(ip) = plan.iter_plans.get(ip_idx) {
            let v2_idx = find_v2_compatible_index(ip);
            let v2_order = dynspire_commons::transactor::keys::index_order(v2_idx);
            let spec_for_pos = |pos: &str| -> Option<&str> {
                match pos {
                    "e" => ip.specs.get(0),
                    "a" => ip.specs.get(1),
                    "v" => ip.specs.get(2),
                    _ => None,
                }.and_then(|s| match s { SpecKind::Var(n) => Some(n.as_str()), _ => None })
            };
            let mut var_positions: HashMap<&str, Vec<usize>> = HashMap::new();
            for (idx, pos) in v2_order.iter().enumerate() {
                if let Some(var_name) = spec_for_pos(pos) {
                    var_positions.entry(var_name).or_default().push(idx);
                }
            }
            for positions in var_positions.values() {
                if positions.len() >= 2 {
                    let pairs: Vec<(usize, usize)> = positions[1..]
                        .iter().map(|&p| (positions[0], p)).collect();
                    same_var_constraints.push((cid, pairs));
                }
            }
        }
    }
    let program = b.build_with_constraints(ctx.var_names_list, ctx.depth_var_pairs, same_var_constraints);
    program
}

pub fn compile_probes_only(
    lookups: &[Pattern],
    exists_mode: bool,
    literal_values: &[Value],
    find_vars: &[String],
    constant_indices: &HashMap<usize, PlanValue>,
    total_proj_len: usize,
    attr_vars: &HashSet<String>,
) -> VMProgram {
    let mut t_var_names: Vec<String> = Vec::new();
    for p in lookups {
        if let Slot::Var(name) = &p.t {
            if !t_var_names.contains(name) {
                t_var_names.push(name.clone());
            }
        }
    }
    let var_id_map: HashMap<String, usize> = t_var_names.iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect();
    let t_var_set: HashSet<String> = t_var_names.iter().cloned().collect();

    let mut b = Compiler::new(16, t_var_names.len());

    for pattern in lookups {
        if let Some((t_name, r_t)) = emit_probe(&mut b, pattern, "done") {
            if let Some(&vid) = var_id_map.get(&t_name) {
                b.emit(OpCode::BindSet, vid as i32, r_t, 0, InstructionData::None);
            }
        }
    }
    if exists_mode {
        emit_literal_values(&mut b, literal_values);
    } else if !find_vars.is_empty() {
        emit_projection(&mut b, find_vars, &var_id_map, &HashSet::new(), attr_vars, &t_var_set, constant_indices, total_proj_len);
    } else {
        b.emit(OpCode::ResultRow, 0, 0, 0, InstructionData::None);
    }
    b.emit_label("done");
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);

    b.build(t_var_names, vec![])
}

pub fn compile_single_empty() -> VMProgram {
    let mut b = Compiler::new(1, 0);
    b.emit(OpCode::ResultRow, 0, 0, 0, InstructionData::None);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    b.build(vec![], vec![])
}

pub fn compile_emit_exists(literal_values: &[Value]) -> VMProgram {
    let mut b = Compiler::new(4, 0);
    emit_literal_values(&mut b, literal_values);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    b.build(vec![], vec![])
}

// --- Rust AST compile functions (no PyO3 dependency) ---

pub fn compile_rust_attribute(stmt: &dynspire_commons::sql_parse::RustAttributeStmt) -> VMProgram {
    let mut b = Compiler::new(4, 0);
    let r_attr = b.alloc_reg();
    let r_vt = b.alloc_reg();
    let r_card = b.alloc_reg();
    b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(stmt.attr.clone()));
    b.emit(OpCode::ConstStr, r_vt, 0, 0, InstructionData::Str(stmt.value_type.clone()));
    let flags = (if stmt.many { 1 } else { 0 }) | (if stmt.unique { 2 } else { 0 });
    b.emit(OpCode::ExecAttribute, r_attr, flags, r_vt, InstructionData::None);
    b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(stmt.attr.clone()));
    let card_label = if stmt.unique {
        format!("{} unique", if stmt.many { "many" } else { "one" })
    } else {
        (if stmt.many { "many" } else { "one" }).to_string()
    };
    b.emit(OpCode::ConstStr, r_card, 0, 0, InstructionData::Str(card_label));
    b.emit(OpCode::ResultRow, r_attr, 2, 0, InstructionData::None);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    b.build(vec![], vec![])
}

pub fn compile_rust_partition(stmt: &dynspire_commons::sql_parse::RustPartitionStmt) -> VMProgram {
    let mut b = Compiler::new(4, 0);
    let r_name = b.alloc_reg();
    let r_part_id = b.alloc_reg();
    b.emit(OpCode::ConstStr, r_name, 0, 0, InstructionData::Str(stmt.name.clone()));
    b.emit(OpCode::DeclarePartition, r_name, r_part_id, 0, InstructionData::None);
    b.emit(OpCode::ResultRow, r_part_id, 1, 0, InstructionData::None);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    b.build(vec![], vec![])
}

pub fn compile_rust_delete_direct(
    entity_val: &dynspire_commons::value::Value,
    pairs: &[(String, dynspire_commons::value::Value)],
) -> Result<VMProgram, String> {
    let mut b = Compiler::new(16, 0);

    let r_ent = b.alloc_reg();
    match entity_val {
        dynspire_commons::value::Value::Int64(n) => {
            b.emit(OpCode::ConstInt, r_ent, 0, 0, InstructionData::Int(*n));
        }
        _ => return Err("entity must be integer in DELETE WHERE".to_string()),
    }

    for (attr, val) in pairs {
        let r_attr = b.alloc_reg();
        b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(attr.clone()));
        let r_val = b.alloc_reg();
        match val {
            dynspire_commons::value::Value::Int64(n) => b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(*n)),
            dynspire_commons::value::Value::Float64(f) => b.emit(OpCode::ConstFloat, r_val, 0, 0, InstructionData::Float(*f)),
            dynspire_commons::value::Value::Text(s) => b.emit(OpCode::ConstStr, r_val, 0, 0, InstructionData::Str(s.clone())),
            _ => b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(0)),
        }
        b.emit(OpCode::ExecRetract, r_ent, r_attr, r_val, InstructionData::Int(-1));
    }
    b.emit(OpCode::ResultRow, r_ent, 1, 0, InstructionData::None);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    Ok(b.build(vec![], vec![]))
}

pub fn compile_triejoin_delete(
    plan: &QueryPlanResult,
    range_bounds: &crate::datalog::RangeBoundsMap,
    find_vars: &[String],
    target_evar: &str,
    retract_pairs: &[(String, dynspire_commons::value::Value)],
) -> Result<VMProgram, String> {
    let target_evar = target_evar.to_string();
    let retract_pairs = retract_pairs.to_vec();

    let (mut b, ctx) = build_triejoin_skeleton(plan, range_bounds, find_vars, false, |b, ctx| {
        let e_var_id = ctx.var_id_map.get(&target_evar).copied().unwrap_or(0);
        let r_ent = b.alloc_reg();
        b.emit(OpCode::BindGet, r_ent, e_var_id as i32, 0, InstructionData::None);

        for (attr, val) in &retract_pairs {
            let r_attr = b.alloc_reg();
            b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(attr.clone()));
            let r_val = b.alloc_reg();
            match val {
                Value::Int64(n) => b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(*n)),
                Value::Float64(f) => b.emit(OpCode::ConstFloat, r_val, 0, 0, InstructionData::Float(*f)),
                Value::Text(s) => b.emit(OpCode::ConstStr, r_val, 0, 0, InstructionData::Str(s.clone())),
                Value::Bool(bv) => b.emit(OpCode::ConstBool, r_val, if *bv != 0 { 1 } else { 0 }, 0, InstructionData::None),
                _ => b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(0)),
            }
            b.emit(OpCode::ExecRetract, r_ent, r_attr, r_val, InstructionData::Int(-1));
        }

        b.emit(OpCode::ResultRow, r_ent, 1, 0, InstructionData::None);
    });

    emit_triejoin_loop(&mut b, &ctx);
    b.emit_label("halt");
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    Ok(b.build(ctx.var_names_list, ctx.depth_var_pairs))
}

pub fn compile_upsert(
    stmt: &dynspire_commons::sql_parse::RustUpsertStmt,
    params: &[dynspire_commons::value::Value],
) -> Result<VMProgram, String> {
    use dynspire_commons::sql_parse::{UpsertEntityRef, RustValue};

    let mut b = Compiler::new(32, 0);

    let mut total_values: usize = 0;
    for clause in &stmt.clauses {
        total_values += clause.values.len();
    }

    let mut alias_regs: HashMap<String, i32> = HashMap::new();
    let mut first_eid_reg: i32 = -1;
    let mut r_count: i32 = -1;

    for (clause_idx, clause) in stmt.clauses.iter().enumerate() {
        let r = b.alloc_reg();
        let alias_key = clause.alias.clone().unwrap_or_else(|| format!("_auto_{}", clause_idx));
        alias_regs.insert(alias_key.clone(), r);

        if clause_idx == 0 {
            first_eid_reg = r;
            r_count = b.alloc_reg();
        }

        match &clause.entity_ref {
            UpsertEntityRef::New => {
                let partition_id: u64 = 4;
                b.emit(OpCode::AllocEntP, r, 0, 0, InstructionData::Int(partition_id as i64));
            }
            UpsertEntityRef::Tx => {
                b.emit(OpCode::LoadTxEnt, r, 0, 0, InstructionData::None);
            }
            UpsertEntityRef::ExplicitEid(idx) => {
                let i = *idx as usize;
                if i == 0 || i > params.len() {
                    return Err(format!("parameter %{} out of range", idx));
                }
                b.emit(OpCode::Param, r, *idx as i32, 0, InstructionData::None);
            }
            UpsertEntityRef::Lookup { attr, value } => {
                let r_attr = b.alloc_reg();
                emit_upsert_value(&mut b, r_attr, attr, &params)?;
                let r_val = b.alloc_reg();
                emit_upsert_value(&mut b, r_val, value, &params)?;
                b.emit(OpCode::LookupEntity, r, r_attr, r_val, InstructionData::None);
            }
        }
    }

    for clause in &stmt.clauses {
        let alias_key = clause.alias.clone().unwrap_or_else(|| "_auto_0".to_string());
        let r_ent = *alias_regs.get(&alias_key).ok_or("missing alias reg")?;

        for iv in &clause.values {
            let r_attr = b.alloc_reg();
            b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(iv.attr.clone()));

            let r_val = b.alloc_reg();
            match &iv.value {
                RustValue::AliasRef(name) => {
                    let src = alias_regs.get(name).ok_or_else(|| format!("unknown alias: {}", name))?;
                    b.emit(OpCode::ExecInsert, r_ent, r_attr, *src, InstructionData::Int(-1));
                    continue;
                }
                RustValue::EidLookup { attr, value } => {
                    let r_lookup_attr = b.alloc_reg();
                    emit_upsert_value(&mut b, r_lookup_attr, attr, &params)?;
                    let r_lookup_val = b.alloc_reg();
                    emit_upsert_value(&mut b, r_lookup_val, value, &params)?;
                    b.emit(OpCode::LookupEntity, r_val, r_lookup_attr, r_lookup_val, InstructionData::None);
                }
                RustValue::ValLookup { entity, attr } => {
                    let r_entity = b.alloc_reg();
                    match entity.as_ref() {
                        RustValue::EidLookup { attr: ea, value: ev } => {
                            let r_ea = b.alloc_reg();
                            emit_upsert_value(&mut b, r_ea, ea, &params)?;
                            let r_ev = b.alloc_reg();
                            emit_upsert_value(&mut b, r_ev, ev, &params)?;
                            b.emit(OpCode::LookupEntity, r_entity, r_ea, r_ev, InstructionData::None);
                        }
                        _ => emit_upsert_value(&mut b, r_entity, entity, &params)?,
                    }
                    let r_val_attr = b.alloc_reg();
                    emit_upsert_value(&mut b, r_val_attr, attr, &params)?;
                    b.emit(OpCode::LookupValue, r_val, r_entity, r_val_attr, InstructionData::None);
                }
                _ => emit_upsert_value(&mut b, r_val, &iv.value, &params)?,
            }
            b.emit(OpCode::ExecInsert, r_ent, r_attr, r_val, InstructionData::Int(-1));
        }
    }

    b.emit(OpCode::ConstInt, r_count, 0, 0, InstructionData::Int(total_values as i64));
    b.emit(OpCode::ResultRow, first_eid_reg, 2, 0, InstructionData::None);
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);
    Ok(b.build(vec![], vec![]))
}

fn emit_upsert_value(
    b: &mut Compiler,
    r_val: i32,
    value: &dynspire_commons::sql_parse::RustValue,
    _params: &[dynspire_commons::value::Value],
) -> Result<(), String> {
    use dynspire_commons::sql_parse::{RustLiteral, RustValue};
    match value {
        RustValue::Literal(RustLiteral::Int(n)) => {
            b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(*n));
        }
        RustValue::Literal(RustLiteral::Float(f)) => {
            b.emit(OpCode::ConstFloat, r_val, 0, 0, InstructionData::Float(*f));
        }
        RustValue::Literal(RustLiteral::Str(s)) => {
            b.emit(OpCode::ConstStr, r_val, 0, 0, InstructionData::Str(s.clone()));
        }
        RustValue::Literal(RustLiteral::Bool(bv)) => {
            b.emit(OpCode::ConstBool, r_val, if *bv { 1 } else { 0 }, 0, InstructionData::None);
        }
        RustValue::Param(idx) => {
            b.emit(OpCode::Param, r_val, *idx as i32, 0, InstructionData::None);
        }
        RustValue::Literal(RustLiteral::Bytes(_)) => {
            return Err("BYTES values are not supported in UPSERT".to_string());
        }
        RustValue::AliasRef(_) => {
            return Err("AliasRef should be handled by caller".to_string());
        }
        RustValue::EidLookup { .. } => {
            return Err("EidLookup should be handled by caller".to_string());
        }
        RustValue::ValLookup { .. } => {
            return Err("ValLookup should be handled by caller".to_string());
        }
    }
    Ok(())
}

pub fn compile_triejoin_update(
    plan: &QueryPlanResult,
    range_bounds: &crate::datalog::RangeBoundsMap,
    find_vars: &[String],
    all_set_values: &[(String, Vec<dynspire_commons::sql_parse::RustInsertValue>)],
    _target_evar: &str,
) -> Result<VMProgram, String> {
    let all_set_values = all_set_values.to_vec();

    let (mut b, ctx) = build_triejoin_skeleton(plan, range_bounds, find_vars, false, |b, ctx| {
        let mut first_r_ent = 0i32;
        for (i, (clause_alias, set_values)) in all_set_values.iter().enumerate() {
            let alias_lower = clause_alias.to_lowercase();
            let clause_evar = format!("_e_{}", alias_lower);
            let e_var_id = ctx.var_id_map.get(&clause_evar).copied().unwrap_or(0);
            let r_ent = b.alloc_reg();
            b.emit(OpCode::BindGet, r_ent, e_var_id as i32, 0, InstructionData::None);
            if i == 0 {
                first_r_ent = r_ent;
            }

            for iv in set_values {
                let r_attr = b.alloc_reg();
                b.emit(OpCode::ConstStr, r_attr, 0, 0, InstructionData::Str(iv.attr.clone()));
                let r_val = b.alloc_reg();
                match &iv.value {
                    dynspire_commons::sql_parse::RustValue::Literal(dynspire_commons::sql_parse::RustLiteral::Int(n)) => {
                        b.emit(OpCode::ConstInt, r_val, 0, 0, InstructionData::Int(*n));
                    }
                    dynspire_commons::sql_parse::RustValue::Literal(dynspire_commons::sql_parse::RustLiteral::Float(f)) => {
                        b.emit(OpCode::ConstFloat, r_val, 0, 0, InstructionData::Float(*f));
                    }
                    dynspire_commons::sql_parse::RustValue::Literal(dynspire_commons::sql_parse::RustLiteral::Str(s)) => {
                        b.emit(OpCode::ConstStr, r_val, 0, 0, InstructionData::Str(s.clone()));
                    }
                    dynspire_commons::sql_parse::RustValue::Literal(dynspire_commons::sql_parse::RustLiteral::Bool(bv)) => {
                        b.emit(OpCode::ConstBool, r_val, if *bv { 1 } else { 0 }, 0, InstructionData::None);
                    }
                    dynspire_commons::sql_parse::RustValue::Param(idx) => {
                        b.emit(OpCode::Param, r_val, *idx as i32, 0, InstructionData::None);
                    }
                    dynspire_commons::sql_parse::RustValue::AliasRef(name) => {
                        let ref_evar = format!("_e_{}", name.to_lowercase());
                        if let Some(&vid) = ctx.var_id_map.get(&ref_evar) {
                            b.emit(OpCode::BindGet, r_val, vid as i32, 0, InstructionData::None);
                        }
                    }
                    _ => {}
                }
                b.emit(OpCode::ExecInsert, r_ent, r_attr, r_val, InstructionData::Int(-1));
            }
        }
        b.emit(OpCode::ResultRow, first_r_ent, 1, 0, InstructionData::None);
    });

    emit_triejoin_loop(&mut b, &ctx);
    b.emit_label("halt");
    b.emit(OpCode::Halt, 0, 0, 0, InstructionData::None);

    Ok(b.build(ctx.var_names_list, ctx.depth_var_pairs))
}

pub struct SelectResult {
    pub program: VMProgram,
    pub traces: Vec<PlanTrace>,
}

pub fn compile_from_plan(plan: &QueryPlanResult) -> Result<SelectResult, String> {
    let mut find_vars: Vec<String> = Vec::new();
    let mut constant_indices: HashMap<usize, PlanValue> = HashMap::new();
    for (i, fv) in plan.find_vars.iter().enumerate() {
        match fv {
            FindVar::Var(name) => find_vars.push(name.clone()),
            FindVar::Const(name, bv) => {
                find_vars.push(name.clone());
                if let Some(pv) = PlanValue::from_bound_value(bv) {
                    constant_indices.insert(i, pv);
                }
            }
        }
    }

    let lit_vals: Vec<Value> = if plan.exists_mode {
        plan.find_vars.iter().map(|fv| match fv {
            FindVar::Const(_, bv) => bv.to_value().unwrap_or(Value::Int64(1)),
            FindVar::Var(_) => Value::Int64(1),
        }).collect()
    } else {
        Vec::new()
    };

    let mut where_names: HashSet<String> = plan.var_order.iter().cloned().collect();
    for tn in &plan.t_lookup_vars {
        where_names.insert(tn.clone());
    }
    let mut triejoin_find_vars: Vec<String> = Vec::new();
    for (i, fv_name) in find_vars.iter().enumerate() {
        if constant_indices.contains_key(&i) { continue; }
        if where_names.contains(fv_name) || fv_name.starts_with("_added_") {
            triejoin_find_vars.push(fv_name.clone());
        }
    }

    let total_proj_len = find_vars.len();
    let exists = plan.exists_mode && find_vars.is_empty();
    let fv_pass: &[String] = if exists { &[] } else { &triejoin_find_vars };

    let mut program = if plan.join_patterns.is_empty() {
        if !plan.lookups.is_empty() {
            compile_probes_only(
                &plan.lookups, exists || plan.exists_mode, &lit_vals,
                fv_pass, &constant_indices, total_proj_len, &plan.attr_vars,
            )
        } else if plan.exists_mode {
            compile_emit_exists(&lit_vals)
        } else {
            compile_single_empty()
        }
    } else {
        compile_triejoin(
            plan, &plan.range_bounds, fv_pass, &constant_indices,
            total_proj_len,
            plan.exists_mode, &lit_vals,
            plan.history,
        )
    };

    program.history = plan.history;

    let traces = plan.plan_traces.clone();

    Ok(SelectResult { program, traces })
}
