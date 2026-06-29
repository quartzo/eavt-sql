use std::collections::{HashMap, HashSet};

use dynspire_commons::datalog::{BoundValue, DatalogSlot as Slot, PlanStats};
use dynspire_commons::planner::{
    IterPlanData, Pattern, PlanValue, QueryPlanResult, INDEX_ORDERS,
};
use dynspire_commons::query_ir::SpecKind;
use dynspire_commons::value::Value;

fn is_slot_bound(slot: &Slot, bound_vars: &HashSet<String>) -> bool {
    match slot {
        Slot::Missing => false,
        Slot::Const(BoundValue::Missing(_)) => false,
        Slot::Const(_) => true,
        Slot::Var(name) => bound_vars.contains(name),
    }
}

fn is_prefix_ok(slot: &Slot, bound_vars: &HashSet<String>) -> bool {
    match slot {
        Slot::Missing => true,
        Slot::Const(_) => true,
        Slot::Var(name) => bound_vars.contains(name),
    }
}

fn find_best_index(
    pattern: &Pattern,
    var_name: &str,
    bound_vars: &HashSet<String>,
    _ref_attrs: &HashSet<String>,
) -> Option<(String, usize, usize)> {
    let target_pos = ["e", "a", "v", "t", "added"].iter().find(|&&pos| {
        matches!(pattern.slot(pos), Slot::Var(n) if n == var_name)
    })?;

    let attr_is_ref = match &pattern.a {
        Slot::Const(BoundValue::ResolvedAttr(_, _, is_ref)) => *is_ref,
        _ => false,
    };
    let mut best: Option<(String, usize, usize)> = None;

    for (idx_name, idx_order) in INDEX_ORDERS.iter() {
        if *idx_name == "VAET" && !attr_is_ref {
            continue;
        }

        let pos_in_idx = match idx_order.iter().position(|p| p == target_pos) {
            Some(p) => p,
            None => continue,
        };

        let mut valid = true;
        for pos in &idx_order[..pos_in_idx] {
            if !is_prefix_ok(pattern.slot(pos), bound_vars) {
                valid = false;
                break;
            }
        }

        if !valid {
            continue;
        }

        let prefix_len = idx_order[..pos_in_idx].iter()
            .take_while(|&&pos| is_slot_bound(pattern.slot(pos), bound_vars))
            .count();

        let gap_count = idx_order[..pos_in_idx].iter()
            .filter(|&&pos| matches!(pattern.slot(pos), Slot::Missing))
            .count();

        if best.is_none()
            || prefix_len > best.as_ref().unwrap().1
            || (prefix_len == best.as_ref().unwrap().1 && gap_count < best.as_ref().unwrap().2)
        {
            best = Some((idx_name.to_string(), prefix_len, gap_count));
        }
    }

    best
}

fn is_var_reachable_in_index(
    pattern: &Pattern,
    var_name: &str,
    index_name: &str,
    bound_vars: &HashSet<String>,
) -> bool {
    let target_pos = match ["e", "a", "v", "t", "added"].iter().find(|&&pos| {
        matches!(pattern.slot(pos), Slot::Var(n) if n == var_name)
    }) {
        Some(p) => p,
        None => return false,
    };

    let idx_entry = match INDEX_ORDERS.iter().find(|(n, _)| *n == index_name) {
        Some(e) => e,
        None => return false,
    };

    let pos_in_idx = match idx_entry.1.iter().position(|p| p == target_pos) {
        Some(p) => p,
        None => return false,
    };

    for pos in &idx_entry.1[..pos_in_idx] {
        if !is_slot_bound(pattern.slot(pos), bound_vars) {
            return false;
        }
    }
    true
}

fn estimate_cardinality(
    pattern_idx: usize,
    index_name: &str,
    var_name: &str,
    stats: &PlanStats,
) -> f64 {
    stats
        .estimates
        .get(&(pattern_idx, index_name.to_string(), var_name.to_string()))
        .copied()
        .unwrap_or(f64::MAX)
}

use dynspire_commons::planner::{DepthTrace, PlanTrace};

struct SearchState {
    best_ordering: Option<Vec<String>>,
    best_clause_indexes: Option<Vec<Option<String>>>,
    best_cost: f64,
    traces: Vec<PlanTrace>,
}

fn explore_ordering_depth(
    remaining_vars: &[String],
    bound_vars: &HashSet<String>,
    clause_index_map: &[Option<String>],
    accumulated_cost: f64,
    top_elements: f64,
    clauses: &[Pattern],
    find_vars: &HashSet<String>,
    range_vars: &HashSet<String>,
    total_records: f64,
    stats: &PlanStats,
    join_indices: &[usize],
    ref_attrs: &HashSet<String>,
    state: &mut SearchState,
    path: &mut Vec<String>,
    depth_traces: &mut Vec<DepthTrace>,
) {
    if remaining_vars.is_empty() {
        let trace = PlanTrace {
            ordering: path.clone(),
            depths: depth_traces.clone(),
            total_cost: accumulated_cost,
            pruned: false,
        };
        state.traces.push(trace);

        if accumulated_cost < state.best_cost {
            state.best_cost = accumulated_cost;
            state.best_ordering = Some(path.clone());
            state.best_clause_indexes = Some(clause_index_map.to_vec());
        }
        return;
    }

    if accumulated_cost >= state.best_cost {
        let trace = PlanTrace {
            ordering: path.clone(),
            depths: depth_traces.clone(),
            total_cost: accumulated_cost,
            pruned: true,
        };
        state.traces.push(trace);
        return;
    }

    let var_priority = |name: &str| -> u8 {
        if name.starts_with("_e_") {
            0
        } else if name.starts_with("_a_") {
            1
        } else if name.starts_with("_v") {
            2
        } else if name.starts_with("_t_") {
            3
        } else if name.starts_with("_added_") {
            4
        } else {
            5
        }
    };

    let mut candidates: Vec<String> = remaining_vars.to_vec();
    candidates.sort_by(|a, b| {
        let a_find = find_vars.contains(a);
        let b_find = find_vars.contains(b);
        b_find
            .cmp(&a_find)
            .then_with(|| var_priority(a).cmp(&var_priority(b)))
            .then_with(|| a.cmp(b))
    });

    for current_var in candidates {
        let mut active_clauses: Vec<(usize, String)> = Vec::new();
        let mut clause_sizes: Vec<f64> = Vec::new();
        let mut new_clause_indexes: Vec<Option<String>> = clause_index_map.to_vec();
        let mut total_gaps: usize = 0;

        for (ci, clause) in clauses.iter().enumerate() {
            if !clause.contains_var_in_eav(&current_var) {
                continue;
            }

            if let Some(ref assigned_idx) = clause_index_map[ci] {
                if is_var_reachable_in_index(clause, &current_var, assigned_idx, bound_vars) {
                    active_clauses.push((ci, assigned_idx.clone()));
                    let sz = estimate_cardinality(join_indices[ci], assigned_idx, &current_var, stats);
                    clause_sizes.push(sz);
                }
            } else {
                if let Some((idx_name, _, gap_count)) = find_best_index(clause, &current_var, bound_vars, ref_attrs) {
                    active_clauses.push((ci, idx_name.clone()));
                    new_clause_indexes[ci] = Some(idx_name.clone());
                    let sz = estimate_cardinality(join_indices[ci], &idx_name, &current_var, stats);
                    clause_sizes.push(sz);
                    total_gaps += gap_count;
                }
            }
        }

        let is_blind = active_clauses.is_empty();

        let range_sel = if range_vars.contains(&current_var) { 0.1 } else { 1.0 };

        let (level_elements, step_cost) = if is_blind {
            let el = total_records * range_sel;
            if path.is_empty() {
                (el, el * el)
            } else {
                (el, top_elements * el)
            }
        } else {
            let el = clause_sizes.iter().cloned().fold(f64::MAX, f64::min) * range_sel;
            let mut undef_penalty = 1.0_f64;
            for &(ci, _) in &active_clauses {
                let clause = &clauses[ci];
                let undef_count = [&clause.e, &clause.a, &clause.v]
                    .iter()
                    .filter_map(|s| if let Slot::Var(n) = s { Some(n) } else { None })
                    .filter(|n| *n != &current_var && !bound_vars.contains(*n))
                    .count();
                if undef_count > 0 {
                    undef_penalty = undef_penalty.max(1.0 + undef_count as f64);
                }
            }
            let cost = el * active_clauses.len() as f64 * undef_penalty * (1.0 + total_gaps as f64);
            (el, cost)
        };

        let adjusted_cost = step_cost;

        path.push(current_var.clone());
        depth_traces.push(DepthTrace {
            var: current_var.clone(),
            active_clauses: active_clauses,
            estimated_elements: level_elements,
            is_blind: is_blind,
            step_cost: adjusted_cost,
            penalty: false,
        });

        let mut new_bound = bound_vars.clone();
        new_bound.insert(current_var.clone());
        let new_remaining: Vec<String> = remaining_vars.iter()
            .filter(|v| *v != &current_var)
            .cloned()
            .collect();

        explore_ordering_depth(
            &new_remaining,
            &new_bound,
            &new_clause_indexes,
            accumulated_cost + adjusted_cost,
            level_elements,
            clauses,
            find_vars,
            range_vars,
            total_records,
            stats,
            join_indices,
            ref_attrs,
            state,
            path,
            depth_traces,
        );

        path.pop();
        depth_traces.pop();
    }
}

fn build_iter_plan(
    pattern: &Pattern,
    idx_name: &str,
    mut bound_ints: HashMap<String, PlanValue>,
    global_var_order: &[String],
) -> IterPlanData {
    let idx_entry = INDEX_ORDERS.iter().find(|(n, _)| *n == idx_name).unwrap();
    let idx_order: [String; 5] = idx_entry.1.map(|s| s.to_string());

    let slots = [&pattern.e, &pattern.a, &pattern.v, &pattern.t, &pattern.added];
    let specs: [SpecKind; 5] = slots.map(|s| match s {
        Slot::Missing => SpecKind::Bound(0),
        Slot::Var(name) => SpecKind::Var(name.clone()),
        Slot::Const(bv) => match bv {
            BoundValue::Int(n) => SpecKind::BoundValue(Value::Int64(*n)),
            BoundValue::Float(f) => SpecKind::BoundValue(Value::Float64(*f)),
            BoundValue::Str(s) => SpecKind::BoundValue(Value::text(s.clone())),
            BoundValue::ResolvedAttr(id, _, _) => SpecKind::BoundAttr(*id),
            BoundValue::Attr(s) => SpecKind::BoundValue(Value::text(s.clone())),
            BoundValue::Param(idx) => SpecKind::BoundParam(*idx),
            BoundValue::Missing(_) => SpecKind::Bound(0),
            BoundValue::Var(name) => SpecKind::Var(name.clone()),
        },
    });

    let mut var_depths: Vec<(usize, String)> = Vec::new();
    let mut same_var_constraints: HashMap<usize, Vec<String>> = HashMap::new();
    let mut active_depths_set: HashSet<usize> = HashSet::new();

    let mut specs = specs;

    for pos in &idx_order {
        let spec_idx = match pos.as_str() {
            "e" => 0, "a" => 1, "v" => 2, "t" => 3, "added" => 4, _ => continue,
        };
        let slot = pattern.slot(pos);
        match slot {
            Slot::Var(name) => {
                if let Some(depth) = global_var_order.iter().position(|v| v == name) {
                    if !active_depths_set.contains(&depth) {
                        var_depths.push((depth, pos.clone()));
                        active_depths_set.insert(depth);
                    } else {
                        same_var_constraints.entry(depth).or_default().push(pos.clone());
                    }
                }
            }
            Slot::Missing => {
                let synth_name = format!("_skip_{}_{}", pos, idx_name.to_ascii_lowercase());
                if let Some(depth) = global_var_order.iter().position(|v| *v == synth_name) {
                    if !active_depths_set.contains(&depth) {
                        var_depths.push((depth, pos.clone()));
                        active_depths_set.insert(depth);
                        specs[spec_idx] = SpecKind::Var(synth_name);
                    }
                }
            }
            _ => {}
        }
    }

    let mut active_depths: Vec<usize> = active_depths_set.into_iter().collect();
    active_depths.sort();
    var_depths.sort_by_key(|(d, _)| *d);

    let mut global_var_order = global_var_order.to_vec();
    let mut trailing_bindings: Vec<(String, PlanValue)> = Vec::new();

    if let Some(&max_depth) = active_depths.last() {
        let last_var_pos = var_depths.iter()
            .find(|(d, _)| *d == max_depth)
            .map(|(_, pos)| pos.clone());
        if let Some(ref lvp) = last_var_pos {
            if let Some(last_idx) = idx_order.iter().position(|p| p == lvp) {
                for pos_idx in (last_idx + 1)..idx_order.len() {
                    let pos = idx_order[pos_idx].as_str();
                    let spec_idx = match pos {
                        "e" => 0, "a" => 1, "v" => 2, _ => continue,
                    };
                    let pv = match &specs[spec_idx] {
                        SpecKind::BoundValue(ref val) => Some(PlanValue::Value(val.clone())),
                        SpecKind::BoundParam(idx) => Some(PlanValue::Param(*idx)),
                        _ => None,
                    };
                    if let Some(pv) = pv {
                        let synth_name = format!("_trail_{}", pos);
                        let synth_depth = global_var_order.len();
                        global_var_order.push(synth_name.clone());
                        var_depths.push((synth_depth, pos.to_string()));
                        active_depths.push(synth_depth);
                        trailing_bindings.push((synth_name.clone(), pv));
                        specs[spec_idx] = SpecKind::Var(synth_name);
                        bound_ints.remove(pos);
                    }
                }
            }
        }
    }

    IterPlanData {
        index_name: idx_name.to_string(),
        idx_order,
        specs,
        bound_ints,
        var_depths,
        same_var_constraints,
        active_depths,
        global_var_order,
        trailing_bindings,
    }
}

pub fn build_query_plan(
    where_patterns: Vec<Pattern>,
    find_vars: &[String],
    range_vars: &HashSet<String>,
    stats: &PlanStats,
) -> Result<QueryPlanResult, String> {
    let lookups: Vec<Pattern> = where_patterns.iter().filter(|p| p.is_lookup()).cloned().collect();
    let join_indices: Vec<usize> = where_patterns.iter().enumerate()
        .filter(|(_, p)| !p.is_lookup())
        .map(|(i, _)| i)
        .collect();
    let join_patterns: Vec<Pattern> = where_patterns.iter().filter(|p| !p.is_lookup()).cloned().collect();

    if join_patterns.is_empty() {
        let mut t_lookup_vars: Vec<String> = Vec::new();
        for p in &lookups {
            if let Slot::Var(name) = &p.t {
                if !t_lookup_vars.contains(name) {
                    t_lookup_vars.push(name.clone());
                }
            }
        }
        return Ok(QueryPlanResult {
            iter_plans: Vec::new(),
            lookups,
            join_patterns,
            ordered_vars: Vec::new(),
            e_vars: HashSet::new(),
            attr_vars: HashSet::new(),
            t_lookup_vars,
            var_order: Vec::new(),
            plan_traces: Vec::new(),
            history: false,
            exists_mode: false,
            find_vars: Vec::new(),
            range_bounds: HashMap::new(),
        });
    }

    let mut seen: HashSet<String> = HashSet::new();
    let mut var_order: Vec<String> = Vec::new();
    let mut all_vars: Vec<String> = Vec::new();
    for pattern in &join_patterns {
        for slot in [&pattern.e, &pattern.a, &pattern.v, &pattern.t, &pattern.added] {
            if let Slot::Var(name) = slot {
                if !seen.contains(name) {
                    seen.insert(name.clone());
                    var_order.push(name.clone());
                    all_vars.push(name.clone());
                }
            }
        }
    }

    let mut e_vars: HashSet<String> = HashSet::new();
    let mut attr_vars: HashSet<String> = HashSet::new();
    for pattern in &join_patterns {
        if let Slot::Var(name) = &pattern.e { e_vars.insert(name.clone()); }
        if let Slot::Var(name) = &pattern.a { attr_vars.insert(name.clone()); }
    }

    let find_set: HashSet<String> = find_vars.iter().cloned().collect();
    let total_records = stats.total_eavt;

    let ref_attrs: HashSet<String> = join_patterns.iter()
        .filter_map(|p| match &p.a {
            Slot::Const(BoundValue::ResolvedAttr(_, name, true)) => Some(name.clone()),
            _ => None,
        })
        .collect();

    let clause_index_map: Vec<Option<String>> = vec![None; join_patterns.len()];

    let mut state = SearchState {
        best_ordering: None,
        best_clause_indexes: None,
        best_cost: f64::INFINITY,
        traces: Vec::new(),
    };

    let mut path: Vec<String> = Vec::new();
    let mut depth_traces: Vec<DepthTrace> = Vec::new();

    explore_ordering_depth(
        &all_vars,
        &HashSet::new(),
        &clause_index_map,
        0.0,
        1.0,
        &join_patterns,
        &find_set,
        range_vars,
        total_records,
        stats,
        &join_indices,
        &ref_attrs,
        &mut state,
        &mut path,
        &mut depth_traces,
    );

    let best_ordering_orig = state.best_ordering.clone();
    let mut ordered_vars = state.best_ordering.unwrap_or_else(|| all_vars.clone());
    let clause_indexes = state.best_clause_indexes.unwrap_or_else(|| clause_index_map);

    // Pre-compute skip vars for Missing gaps so all iter_plans share consistent depth numbering
    for (pat_idx, pattern) in join_patterns.iter().enumerate() {
        let idx_name = match &clause_indexes[pat_idx] {
            Some(idx) => idx.clone(),
            None => continue,
        };
        let idx_entry = INDEX_ORDERS.iter().find(|(n, _)| *n == idx_name).unwrap();
        let idx_order = idx_entry.1;

        let first_var_pos = idx_order.iter().position(|pos| {
            matches!(pattern.slot(pos), Slot::Var(_))
        });
        if let Some(fvp) = first_var_pos {
            let target_var = if let Slot::Var(name) = pattern.slot(idx_order[fvp]) {
                name.clone()
            } else {
                continue;
            };
            for pos_idx in 0..fvp {
                let pos = idx_order[pos_idx];
                if matches!(pattern.slot(pos), Slot::Missing) {
                    let synth_name = format!("_skip_{}_{}", pos, idx_name.to_ascii_lowercase());
                    if !ordered_vars.contains(&synth_name) {
                        if let Some(vp) = ordered_vars.iter().position(|v| v == &target_var) {
                            ordered_vars.insert(vp, synth_name);
                        } else {
                            ordered_vars.push(synth_name);
                        }
                    }
                }
            }
        }
    }

    let mut iter_plans: Vec<IterPlanData> = Vec::new();
    if !ordered_vars.is_empty() {
        for (pat_idx, pattern) in join_patterns.iter().enumerate() {
            let idx_name = match &clause_indexes[pat_idx] {
                Some(idx) => idx.clone(),
                None => continue,
            };

            let mut bound_ints: HashMap<String, PlanValue> = HashMap::new();
            if let Slot::Const(bv) = &pattern.e {
                match bv {
                    BoundValue::Int(n) => { bound_ints.insert("e".to_string(), PlanValue::Value(Value::Int64(*n))); }
                    BoundValue::Str(s) | BoundValue::Attr(s) => {
                        bound_ints.insert("e".to_string(), PlanValue::Value(Value::Text(s.clone())));
                    }
                    BoundValue::Param(idx) => { bound_ints.insert("e".to_string(), PlanValue::Param(*idx)); }
                    _ => {}
                }
            }
            if let Slot::Const(bv) = &pattern.a {
                match bv {
                    BoundValue::ResolvedAttr(id, _, _) => {
                        bound_ints.insert("a".to_string(), PlanValue::Value(Value::Int64(*id as i64)));
                    }
                    BoundValue::Str(s) | BoundValue::Attr(s) => {
                        bound_ints.insert("a".to_string(), PlanValue::Value(Value::Text(s.clone())));
                    }
                    BoundValue::Param(idx) => { bound_ints.insert("a".to_string(), PlanValue::Param(*idx)); }
                    _ => {}
                }
            }
            if let Slot::Const(bv) = &pattern.v {
                match bv {
                    BoundValue::Int(n) => { bound_ints.insert("v".to_string(), PlanValue::Value(Value::Int64(*n))); }
                    BoundValue::Float(f) => { bound_ints.insert("v".to_string(), PlanValue::Value(Value::Float64(*f))); }
                    BoundValue::Str(s) => { bound_ints.insert("v".to_string(), PlanValue::Value(Value::text(s.clone()))); }
                    BoundValue::Attr(s) => { bound_ints.insert("v".to_string(), PlanValue::Value(Value::text(s.clone()))); }
                    BoundValue::Param(idx) => { bound_ints.insert("v".to_string(), PlanValue::Param(*idx)); }
                    _ => {}
                }
            }

            iter_plans.push(build_iter_plan(pattern, &idx_name, bound_ints, &ordered_vars));
        }
    }

    let mut t_lookup_vars: Vec<String> = Vec::new();
    for p in &lookups {
        if let Slot::Var(name) = &p.t {
            if !t_lookup_vars.contains(name) {
                t_lookup_vars.push(name.clone());
            }
        }
    }

    let mut plan_traces = state.traces;
    for trace in &mut plan_traces {
        if trace.pruned { continue; }
        // Only reformat the winning trace to include synthetic vars;
        // all other traces keep their real ordering and depths
        if best_ordering_orig.as_deref() == Some(trace.ordering.as_slice()) {
            let old_depths: std::collections::HashMap<String, DepthTrace> =
                trace.depths.drain(..).map(|d| (d.var.clone(), d)).collect();
            for var in &ordered_vars {
                if let Some(d) = old_depths.get(var) {
                    trace.depths.push(d.clone());
                } else {
                    trace.depths.push(DepthTrace {
                        var: var.clone(),
                        active_clauses: vec![],
                        estimated_elements: 0.0,
                        is_blind: false,
                        step_cost: 0.0,
                        penalty: false,
                    });
                }
            }
            trace.ordering = ordered_vars.clone();
        }
    }

    Ok(QueryPlanResult {
        iter_plans,
        lookups,
        join_patterns,
        ordered_vars,
        e_vars,
        attr_vars,
        t_lookup_vars,
        var_order,
        plan_traces,
        history: false,
        exists_mode: false,
        find_vars: Vec::new(),
        range_bounds: HashMap::new(),
    })
}
