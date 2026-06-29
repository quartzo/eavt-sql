use std::collections::{HashMap, HashSet};

use crate::datalog::{BoundValue, DatalogPattern, DatalogSlot, FindVar};
use crate::query_ir::SpecKind;
use crate::value::Value;

// ── PlanValue: Value or Param placeholder ─────────────────────────────

#[derive(Clone, Debug, PartialEq)]
pub enum PlanValue {
    Value(Value),
    Param(u32),
}

impl PlanValue {
    pub fn from_bound_value(bv: &BoundValue) -> Option<Self> {
        match bv {
            BoundValue::Int(n) => Some(PlanValue::Value(Value::Int64(*n))),
            BoundValue::Float(f) => Some(PlanValue::Value(Value::Float64(*f))),
            BoundValue::Str(s) | BoundValue::Attr(s) => Some(PlanValue::Value(Value::text(s.clone()))),
            BoundValue::ResolvedAttr(id, _, _) => Some(PlanValue::Value(Value::Int64(*id as i64))),
            BoundValue::Param(idx) => Some(PlanValue::Param(*idx)),
            _ => None,
        }
    }
}

// ── Index catalog ───────────────────────────────────────────────────

pub const INDEX_ORDERS: [(&str, [&str; 5]); 4] = [
    ("EAVT", ["e", "a", "v", "t", "added"]),
    ("AEVT", ["a", "e", "v", "t", "added"]),
    ("AVET", ["a", "v", "e", "t", "added"]),
    ("VAET", ["v", "a", "e", "t", "added"]),
];

// ── Pattern (planner working type, same shape as DatalogPattern) ────

#[derive(Clone, Debug)]
pub struct Pattern {
    pub e: DatalogSlot,
    pub a: DatalogSlot,
    pub v: DatalogSlot,
    pub t: DatalogSlot,
    pub added: DatalogSlot,
}

impl Pattern {
    pub fn slot(&self, pos: &str) -> &DatalogSlot {
        match pos {
            "e" => &self.e,
            "a" => &self.a,
            "v" => &self.v,
            "t" => &self.t,
            "added" => &self.added,
            _ => &self.t,
        }
    }

    pub fn is_lookup(&self) -> bool {
        let const_and_some = |s: &DatalogSlot| matches!(s, DatalogSlot::Const(bv) if !matches!(bv, BoundValue::Missing(_)));
        const_and_some(&self.e) && const_and_some(&self.a) && const_and_some(&self.v)
    }

    pub fn contains_var_in_eav(&self, var_name: &str) -> bool {
        matches!(&self.e, DatalogSlot::Var(n) if n == var_name)
            || matches!(&self.a, DatalogSlot::Var(n) if n == var_name)
            || matches!(&self.v, DatalogSlot::Var(n) if n == var_name)
            || matches!(&self.t, DatalogSlot::Var(n) if n == var_name)
            || matches!(&self.added, DatalogSlot::Var(n) if n == var_name)
    }
}

impl From<DatalogPattern> for Pattern {
    fn from(p: DatalogPattern) -> Pattern {
        Pattern { e: p.e, a: p.a, v: p.v, t: p.t, added: p.added }
    }
}

impl From<Pattern> for DatalogPattern {
    fn from(p: Pattern) -> DatalogPattern {
        DatalogPattern { e: p.e, a: p.a, v: p.v, t: p.t, added: p.added }
    }
}

// ── Plan traces (for EXPLAIN) ───────────────────────────────────────

#[derive(Clone, Debug)]
pub struct DepthTrace {
    pub var: String,
    pub active_clauses: Vec<(usize, String)>,
    pub estimated_elements: f64,
    pub is_blind: bool,
    pub step_cost: f64,
    pub penalty: bool,
}

#[derive(Clone, Debug)]
pub struct PlanTrace {
    pub ordering: Vec<String>,
    pub depths: Vec<DepthTrace>,
    pub total_cost: f64,
    pub pruned: bool,
}

impl std::fmt::Display for PlanTrace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let vars = self.ordering.join(", ");
        let prefix = if self.pruned { "PRUNED " } else { "" };
        write!(f, "{prefix}[{vars}] cost={:.1}", self.total_cost)?;
        for (i, d) in self.depths.iter().enumerate() {
            let clauses: Vec<String> = d.active_clauses.iter()
                .map(|(ci, idx)| format!("p{}@{}", ci, idx))
                .collect();
            let ncl = d.active_clauses.len();
            let pen = if d.penalty { " ×1.5pen" } else { "" };
            if d.is_blind {
                write!(f, "\n  depth {i}: {} | blind | est={:.1}{}", d.var, d.estimated_elements, pen)?;
            } else {
                write!(f, "\n  depth {i}: {} | clauses=[{}] | est={:.1} ×{}cl{} = {:.1}",
                    d.var, clauses.join(", "), d.estimated_elements, ncl, pen, d.step_cost)?;
            }
        }
        Ok(())
    }
}

// ── Iteration plan (per join pattern) ───────────────────────────────

#[derive(Clone)]
pub struct IterPlanData {
    pub index_name: String,
    pub idx_order: [String; 5],
    pub specs: [SpecKind; 5],
    pub bound_ints: HashMap<String, PlanValue>,
    pub var_depths: Vec<(usize, String)>,
    pub same_var_constraints: HashMap<usize, Vec<String>>,
    pub active_depths: Vec<usize>,
    #[allow(dead_code)]
    pub global_var_order: Vec<String>,
    pub trailing_bindings: Vec<(String, PlanValue)>,
}

// ── Query plan result (planner output) ──────────────────────────────

pub type RangeBoundsMap = HashMap<String, Vec<Vec<(String, PlanValue)>>>;

#[derive(Clone)]
pub struct QueryPlanResult {
    pub iter_plans: Vec<IterPlanData>,
    pub lookups: Vec<Pattern>,
    pub join_patterns: Vec<Pattern>,
    pub ordered_vars: Vec<String>,
    pub e_vars: HashSet<String>,
    pub attr_vars: HashSet<String>,
    pub t_lookup_vars: Vec<String>,
    pub var_order: Vec<String>,
    pub plan_traces: Vec<PlanTrace>,
    pub history: bool,
    pub exists_mode: bool,
    pub find_vars: Vec<FindVar>,
    pub range_bounds: RangeBoundsMap,
}

fn fmt_spec(spec: &SpecKind) -> String {
    match spec {
        SpecKind::Var(name) => format!("?{name}"),
        SpecKind::Bound(n) => format!("#{n}"),
        SpecKind::BoundAttr(aid) => format!("attr({aid})"),
        SpecKind::BoundValue(v) => format!("{v:?}"),
        SpecKind::BoundParam(idx) => format!("%{idx}"),
    }
}

impl std::fmt::Display for QueryPlanResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let hist_tag = if self.history { " (history)" } else { "" };
        let exists_tag = if self.exists_mode { " (exists)" } else { "" };
        if self.ordered_vars.is_empty() {
            writeln!(f, "Plan: lookups-only (no join){hist_tag}{exists_tag}")?;
        } else {
            writeln!(f, "Join order: [{}]{}{}", self.ordered_vars.join(", "), hist_tag, exists_tag)?;
        }

        if !self.find_vars.is_empty() {
            let projs: Vec<String> = self.find_vars.iter().map(|fv| format!("{fv}")).collect();
            writeln!(f, "Projections: {}", projs.join(", "))?;
        }

        if !self.iter_plans.is_empty() {
            writeln!(f, "Iter plans:")?;
            for (i, ip) in self.iter_plans.iter().enumerate() {
                let specs: Vec<String> = ip.specs.iter().map(fmt_spec).collect();
                let bound: Vec<String> = ip.bound_ints.iter()
                    .map(|(k, pv)| format!("{k}={pv:?}")).collect();
                let depths: Vec<String> = ip.var_depths.iter()
                    .map(|(d, pos)| format!("{pos}@d{d}")).collect();
                writeln!(f, "  p{i} @ {} [{}] depths=[{}]{}",
                    ip.index_name,
                    specs.join(", "),
                    depths.join(", "),
                    if bound.is_empty() { String::new() } else { format!(" bound={{{}}}", bound.join(", ")) })?;
            }
        }

        if !self.lookups.is_empty() {
            writeln!(f, "Lookups: {}", self.lookups.len())?;
        }

        for trace in &self.plan_traces {
            let is_winner = !trace.pruned && trace.ordering == self.ordered_vars;
            if is_winner {
                writeln!(f, "★ {trace}")?;
            } else {
                writeln!(f, "{trace}")?;
            }
        }

        Ok(())
    }
}

/// Wrapper — crosses FFI as 1 boxed pointer (opaque in .dspi).
#[derive(Clone)]
pub struct QueryPlanSt {
    pub plan: QueryPlanResult,
}
