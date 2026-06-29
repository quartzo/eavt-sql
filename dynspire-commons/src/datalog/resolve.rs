use std::collections::HashMap;

use crate::compiler::CompileStats;
use crate::datalog::{BoundValue, DatalogIR, DatalogNumIR, DatalogSlot, PlanStats};
use crate::planner::{Pattern, INDEX_ORDERS};
use crate::transactor::DynSpireTransactor;

/// Resolve attribute names to IDs in a DatalogIR, producing a DatalogNumIR.
/// Also pre-computes cardinality stats so the planner is a pure function.
///
/// Called by the query engine (which owns the transactor) between the
/// frontend (parse + datalog) and the compiler (plan + codegen) stages.
pub fn resolve_ir(ir: DatalogIR, tx: &DynSpireTransactor) -> Result<DatalogNumIR, String> {
    let mut ir = ir;

    // Resolve attr names in pattern "a" positions
    for pattern in &mut ir.patterns {
        let name = match &pattern.a {
            DatalogSlot::Const(BoundValue::Attr(n)) | DatalogSlot::Const(BoundValue::Str(n)) => Some(n.clone()),
            _ => None,
        };
        if let Some(name) = name {
            let id = CompileStats::lookup_attr(tx, &name)
                .ok_or_else(|| format!("unknown attribute: {}", name))?;
            let is_ref = CompileStats::is_ref_attr(tx, &name);
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
                    let id = CompileStats::lookup_attr(tx, &name)
                        .ok_or_else(|| format!("unknown attribute: {}", name))?;
                    let is_ref = CompileStats::is_ref_attr(tx, &name);
                    *bv = BoundValue::ResolvedAttr(id, name, is_ref);
                }
            }
        }
    }

    let stats = compute_stats(&ir, tx);
    Ok(DatalogNumIR { ir, stats })
}

/// Pre-compute all cardinality estimates the planner might need.
/// For each (pattern, index, variable_in_pattern), builds the same bound_vals
/// that `estimate_cardinality` would build, and calls estimate_index_size.
fn compute_stats(ir: &DatalogIR, tx: &DynSpireTransactor) -> PlanStats {
    let total_eavt = CompileStats::estimate_index_size(tx, "EAVT", &[]).max(1.0);
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

                let est = CompileStats::estimate_index_size(tx, index_name, &bound_vals).max(1.0);
                estimates.insert((pat_idx, index_name.to_string(), var_name), est);
            }
        }
    }

    PlanStats { total_eavt, estimates }
}
