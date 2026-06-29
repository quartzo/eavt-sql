use std::collections::HashMap;

use dynspire_commons::datalog::{BoundValue, DatalogNumIRSt, FindVar};
use dynspire_commons::planner::{Pattern, PlanValue, QueryPlanSt, RangeBoundsMap};

include!(concat!(env!("OUT_DIR"), "/planner_spier.rs"));

mod planner;

struct PlannerState;

fn init(_config: &HashMap<String, String>) -> Result<PlannerState, String> {
    Ok(PlannerState)
}

fn convert_range_bounds(
    bounds: &HashMap<String, Vec<Vec<(String, BoundValue)>>>,
) -> RangeBoundsMap {
    let mut result = HashMap::new();
    for (var, branches) in bounds {
        let rust_branches: Vec<Vec<(String, PlanValue)>> = branches
            .iter()
            .map(|branch| {
                branch
                    .iter()
                    .filter_map(|(op, bv)| PlanValue::from_bound_value(bv).map(|pv| (op.clone(), pv)))
                    .collect()
            })
            .collect();
        result.insert(var.clone(), rust_branches);
    }
    result
}

impl PlannerEngine for PlannerState {
    fn plan(&self, ir: DatalogNumIRSt) -> Result<QueryPlanSt, String> {
        let datalog = ir.num_ir.ir;
        let stats = ir.num_ir.stats;

        let where_patterns: Vec<Pattern> = datalog.patterns.into_iter().map(Pattern::from).collect();
        let find_vars: Vec<String> = datalog.find_vars.iter().map(|fv| match fv {
            FindVar::Var(name) | FindVar::Const(name, _) => name.clone(),
        }).collect();
        let history = datalog.history;
        let exists_mode = datalog.exists_mode;
        let plan_find_vars = datalog.find_vars.clone();
        let range_bounds = convert_range_bounds(&datalog.range_bounds);
        let range_vars: std::collections::HashSet<String> = datalog.range_bounds.keys().cloned().collect();

        let mut result = planner::build_query_plan(where_patterns, &find_vars, &range_vars, &stats)?;
        result.history = history;
        result.exists_mode = exists_mode;
        result.find_vars = plan_find_vars;
        result.range_bounds = range_bounds;

        Ok(QueryPlanSt { plan: result })
    }

    fn to_string(&self, plan: QueryPlanSt) -> Result<String, String> {
        Ok(format!("{}", plan.plan))
    }
}

impl_planner_spier!(PlannerState, init, "spier_planner");
