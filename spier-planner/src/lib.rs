use std::collections::HashMap;

use spier_datalog::{BoundValue, DatalogNumIRSt, FindVar};

pub mod ast;
pub mod planner;

pub use ast::*;
pub use spier_datalog::{index_order, Pattern, PlanStats, INDEX_ORDERS};

pub trait PlannerEngine: Send + Sync {
    fn plan(&self, ir: DatalogNumIRSt) -> Result<QueryPlanSt, String>;
    fn to_string(&self, plan: QueryPlanSt) -> Result<String, String>;
}

/// Pure Rust query planner. just implements [`PlannerEngine`].
pub struct Planner;

impl Planner {
    pub fn new() -> Self {
        Self
    }
}

impl Default for Planner {
    fn default() -> Self {
        Self::new()
    }
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
                    .filter_map(|(op, bv)| {
                        PlanValue::from_bound_value(bv).map(|pv| (op.clone(), pv))
                    })
                    .collect()
            })
            .collect();
        result.insert(var.clone(), rust_branches);
    }
    result
}

impl PlannerEngine for Planner {
    fn plan(&self, ir: DatalogNumIRSt) -> Result<QueryPlanSt, String> {
        let datalog = ir.num_ir.ir;
        let stats = ir.num_ir.stats;

        let where_patterns: Vec<Pattern> =
            datalog.patterns.into_iter().map(Pattern::from).collect();
        let find_vars: Vec<String> = datalog
            .find_vars
            .iter()
            .map(|fv| match fv {
                FindVar::Var(name) | FindVar::Const(name, _) => name.clone(),
            })
            .collect();
        let history = datalog.history;
        let exists_mode = datalog.exists_mode;
        let plan_find_vars = datalog.find_vars.clone();
        let range_bounds = convert_range_bounds(&datalog.range_bounds);
        let range_vars: std::collections::HashSet<String> =
            datalog.range_bounds.keys().cloned().collect();

        let mut result =
            planner::build_query_plan(where_patterns, &find_vars, &range_vars, &stats)?;
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

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};

    use spier_datalog::{
        resolve::{compute_plan_stats, resolve_ir},
        BoundValue, CompileStats, DatalogIR, DatalogNumIR, DatalogNumIRSt, DatalogPattern,
        DatalogSlot, FindVar,
    };

    use crate::{Planner, PlannerEngine, QueryPlanSt};

    /// A fixed CompileStats implementation for isolated planner tests.
    /// It does not touch the transactor, storage, or any I/O.
    struct FixedStats {
        attrs: HashMap<String, u32>,
        refs: HashSet<String>,
        sizes: HashMap<(String, Vec<u64>), f64>,
    }

    impl FixedStats {
        fn new() -> Self {
            let mut attrs = HashMap::new();
            attrs.insert("user.name".to_string(), 100);
            attrs.insert("user.age".to_string(), 101);
            attrs.insert("company.ceo".to_string(), 200);

            let mut refs = HashSet::new();
            refs.insert("company.ceo".to_string());

            let mut sizes = HashMap::new();
            // Full table scan is expensive.
            sizes.insert(("EAVT".to_string(), vec![]), 10_000_000.0);
            // Knowing the attribute makes AEVT cheap.
            sizes.insert(("AEVT".to_string(), vec![100]), 100.0);
            sizes.insert(("AEVT".to_string(), vec![101]), 100.0);
            sizes.insert(("AEVT".to_string(), vec![200]), 100.0);
            // With attribute + entity bound, AEVT is very cheap.
            sizes.insert(("AEVT".to_string(), vec![100, 0]), 10.0);
            sizes.insert(("AEVT".to_string(), vec![101, 0]), 10.0);
            sizes.insert(("AEVT".to_string(), vec![200, 0]), 10.0);
            // AVET on a single attribute is more expensive than AEVT.
            sizes.insert(("AVET".to_string(), vec![100]), 10_000.0);
            sizes.insert(("AVET".to_string(), vec![101]), 10_000.0);
            sizes.insert(("AVET".to_string(), vec![200]), 10_000.0);

            Self { attrs, refs, sizes }
        }
    }

    impl CompileStats for FixedStats {
        fn lookup_attr(&self, name: &str) -> Option<u32> {
            self.attrs.get(name).copied()
        }

        fn estimate_index_size(&self, index: &str, bound: &[u64]) -> f64 {
            self.sizes
                .get(&(index.to_string(), bound.to_vec()))
                .copied()
                .unwrap_or(1_000_000.0)
        }

        fn partition_id_for(&self, _name: &str) -> Option<u64> {
            None
        }

        fn is_ref_attr(&self, name: &str) -> bool {
            self.refs.contains(name)
        }
    }

    fn resolve_and_plan(ir: DatalogIR) -> QueryPlanSt {
        let stats = FixedStats::new();
        let resolved = resolve_ir(ir, &stats).expect("resolve_ir should succeed");
        let plan_stats = compute_plan_stats(&resolved, &stats);
        let st = DatalogNumIRSt {
            num_ir: DatalogNumIR {
                ir: resolved,
                stats: plan_stats,
            },
        };
        Planner::new().plan(st).expect("plan should succeed")
    }

    #[test]
    fn test_lookup_only_plan() {
        let ir = DatalogIR {
            patterns: vec![DatalogPattern {
                e: DatalogSlot::Const(BoundValue::Int(7)),
                a: DatalogSlot::Const(BoundValue::Attr("user.name".to_string())),
                v: DatalogSlot::Const(BoundValue::Str("Alice".to_string())),
                t: DatalogSlot::Missing,
                added: DatalogSlot::Missing,
            }],
            find_vars: vec![FindVar::Var("x".to_string())],
            range_bounds: HashMap::new(),
            star: false,
            exists_mode: false,
            has_conditions: false,
            history: false,
        };

        let plan = resolve_and_plan(ir);
        assert!(
            plan.plan.iter_plans.is_empty(),
            "lookup pattern should produce no iter plans"
        );
        assert_eq!(
            plan.plan.lookups.len(),
            1,
            "lookup pattern should produce one lookup"
        );
        assert_eq!(
            plan.plan.ordered_vars.len(),
            0,
            "lookup-only plan has no ordered vars"
        );
        match &plan.plan.lookups[0].a {
            DatalogSlot::Const(BoundValue::ResolvedAttr(id, name, is_ref)) => {
                assert_eq!(*id, 100);
                assert_eq!(name, "user.name");
                assert!(!is_ref);
            }
            other => panic!(
                "expected ResolvedAttr(user.name, id=100, ref=false), got {:?}",
                other
            ),
        }
    }

    #[test]
    fn test_join_prefers_aevt_when_attribute_is_bound() {
        let ir = DatalogIR {
            patterns: vec![
                DatalogPattern {
                    e: DatalogSlot::Var("e".to_string()),
                    a: DatalogSlot::Const(BoundValue::Attr("user.name".to_string())),
                    v: DatalogSlot::Var("name".to_string()),
                    t: DatalogSlot::Missing,
                    added: DatalogSlot::Missing,
                },
                DatalogPattern {
                    e: DatalogSlot::Var("e".to_string()),
                    a: DatalogSlot::Const(BoundValue::Attr("user.age".to_string())),
                    v: DatalogSlot::Var("age".to_string()),
                    t: DatalogSlot::Missing,
                    added: DatalogSlot::Missing,
                },
            ],
            find_vars: vec![
                FindVar::Var("e".to_string()),
                FindVar::Var("name".to_string()),
                FindVar::Var("age".to_string()),
            ],
            range_bounds: HashMap::new(),
            star: false,
            exists_mode: false,
            has_conditions: false,
            history: false,
        };

        let plan = resolve_and_plan(ir);
        assert_eq!(
            plan.plan.ordered_vars.first().map(String::as_str),
            Some("e"),
            "planner should start from the entity variable because AEVT is cheap when the attribute is bound"
        );
        assert_eq!(plan.plan.iter_plans.len(), 2);
        assert!(
            plan.plan
                .iter_plans
                .iter()
                .all(|ip| ip.index_name == "AEVT"),
            "both patterns should use AEVT when the attribute is known"
        );
    }

    #[test]
    fn test_ref_attr_is_resolved() {
        // company.ceo is marked as a ref attribute in FixedStats.
        let ir = DatalogIR {
            patterns: vec![DatalogPattern {
                e: DatalogSlot::Var("e".to_string()),
                a: DatalogSlot::Const(BoundValue::Attr("company.ceo".to_string())),
                v: DatalogSlot::Var("ceo".to_string()),
                t: DatalogSlot::Missing,
                added: DatalogSlot::Missing,
            }],
            find_vars: vec![
                FindVar::Var("e".to_string()),
                FindVar::Var("ceo".to_string()),
            ],
            range_bounds: HashMap::new(),
            star: false,
            exists_mode: false,
            has_conditions: false,
            history: false,
        };

        let plan = resolve_and_plan(ir);
        assert!(
            plan.plan.lookups.is_empty(),
            "join pattern should not be a lookup"
        );
        assert_eq!(plan.plan.iter_plans.len(), 1);
        match &plan.plan.join_patterns[0].a {
            DatalogSlot::Const(BoundValue::ResolvedAttr(id, name, is_ref)) => {
                assert_eq!(*id, 200);
                assert_eq!(name, "company.ceo");
                assert!(is_ref);
            }
            other => panic!(
                "expected ResolvedAttr(company.ceo, id=200, ref=true), got {:?}",
                other
            ),
        }
        // The optimizer is free to pick AEVT or VAET; AEVT is cheaper in our
        // fixed stats, so it wins.
        assert_eq!(plan.plan.iter_plans[0].index_name, "AEVT");
    }

    #[test]
    fn test_compile_stats_trait_boundary() {
        // This test documents the architectural boundary: resolve_ir requires
        // CompileStats, not TransactorEngine. The FixedStats type does not
        // implement any transactor trait.
        fn compile_only_accepts_compile_stats(_stats: &dyn CompileStats) {}
        let stats = FixedStats::new();
        compile_only_accepts_compile_stats(&stats);
    }
}
