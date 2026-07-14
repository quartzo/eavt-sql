use std::collections::HashMap;

use crate::ast::{BoundValue, DatalogIR, DatalogSlot, PlanStats};
use crate::pattern::{Pattern, INDEX_ORDERS};
use crate::stats::CompileStats;

/// Resolve attribute names to numeric IDs in a DatalogIR.
///
/// Called by the query engine between the frontend (parse + datalog) and the
/// compiler (plan + codegen) stages. `stats` supplies schema lookups only;
/// cardinality estimation happens separately via [`compute_plan_stats`].
pub fn resolve_ir(ir: DatalogIR, stats: &dyn CompileStats) -> Result<DatalogIR, String> {
    let mut ir = ir;

    // Resolve attr names in pattern "a" positions
    for pattern in &mut ir.patterns {
        let name = match &pattern.a {
            DatalogSlot::Const(BoundValue::Attr(n)) | DatalogSlot::Const(BoundValue::Str(n)) => {
                Some(n.clone())
            }
            _ => None,
        };
        if let Some(name) = name {
            let id = stats
                .lookup_attr(&name)
                .ok_or_else(|| format!("unknown attribute: {}", name))?;
            let is_ref = stats.is_ref_attr(&name);
            pattern.a = DatalogSlot::Const(BoundValue::ResolvedAttr(id, name, is_ref));
        }
    }

    // Resolve attr names in range_bounds
    for branches in ir.range_bounds.values_mut() {
        for branch in branches.iter_mut() {
            for (_, bv) in branch.iter_mut() {
                let name = match bv {
                    BoundValue::Attr(n) | BoundValue::Str(n) => Some(n.clone()),
                    _ => None,
                };
                if let Some(name) = name {
                    let id = stats
                        .lookup_attr(&name)
                        .ok_or_else(|| format!("unknown attribute: {}", name))?;
                    let is_ref = stats.is_ref_attr(&name);
                    *bv = BoundValue::ResolvedAttr(id, name, is_ref);
                }
            }
        }
    }

    Ok(ir)
}

/// Pre-compute all cardinality estimates the planner might need.
/// For each (pattern, index, variable_in_pattern), builds the same bound_vals
/// that the planner's `estimate_cardinality` would build, and calls
/// `estimate_index_size`.
///
/// This is kept separate from `resolve_ir` so attribute resolution (schema)
/// and cardinality estimation (query-engine concern) remain independent.
pub fn compute_plan_stats(ir: &DatalogIR, stats: &dyn CompileStats) -> PlanStats {
    let total_eavt = stats.estimate_index_size("EAVT", &[]).max(1.0);
    let mut estimates = HashMap::new();

    for (pat_idx, pattern) in ir.patterns.iter().enumerate() {
        let p = Pattern::from(pattern.clone());
        for (index_name, index_order) in INDEX_ORDERS.iter() {
            for pos in index_order {
                // Find variable name at this position
                let var_name = match p.slot(pos) {
                    DatalogSlot::Var(n) => n.clone(),
                    _ => continue,
                };

                // Build bound_vals: positions before this var in index order
                let pos_in_idx = index_order.iter().position(|x| *x == *pos).unwrap_or(0);
                let mut bound_vals: Vec<u64> = Vec::new();
                for before_pos in &index_order[..pos_in_idx] {
                    let slot = p.slot(before_pos);
                    match slot {
                        DatalogSlot::Const(bv) => match bv {
                            BoundValue::Int(n) => bound_vals.push(*n as u64),
                            BoundValue::ResolvedAttr(id, _, _) => bound_vals.push(*id as u64),
                            _ => bound_vals.push(0),
                        },
                        _ => bound_vals.push(0),
                    }
                }

                let est = stats.estimate_index_size(index_name, &bound_vals).max(1.0);
                estimates.insert((pat_idx, index_name.to_string(), var_name), est);
            }
        }
    }

    PlanStats {
        total_eavt,
        estimates,
    }
}
