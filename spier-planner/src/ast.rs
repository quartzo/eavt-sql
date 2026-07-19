use std::collections::{HashMap, HashSet};

use spier_datalog::{BoundValue, FindVar, Pattern};
use spier_query_ir::SpecKind;
use spier_value::Value;

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
            BoundValue::Str(s) | BoundValue::Attr(s) => {
                Some(PlanValue::Value(Value::text(s.clone())))
            }
            BoundValue::ResolvedAttr(id, _, _, _) => Some(PlanValue::Value(Value::Int64(*id as i64))),
            BoundValue::Param(idx) => Some(PlanValue::Param(*idx)),
            _ => None,
        }
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
    pub chosen: bool,
}

impl std::fmt::Display for PlanTrace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let vars = self.ordering.join(", ");
        let prefix = if self.pruned {
            "PRUNED "
        } else if self.chosen {
            "→ "
        } else {
            ""
        };
        write!(f, "{prefix}[{vars}] cost={:.1}", self.total_cost)?;
        for (i, d) in self.depths.iter().enumerate() {
            let clauses: Vec<String> = d
                .active_clauses
                .iter()
                .map(|(ci, idx)| format!("p{}@{}", ci, idx))
                .collect();
            let ncl = d.active_clauses.len();
            let pen = if d.penalty { " ×1.5pen" } else { "" };
            if d.is_blind {
                write!(
                    f,
                    "\n  depth {i}: {} | blind | est={:.1}{}",
                    d.var, d.estimated_elements, pen
                )?;
            } else {
                write!(
                    f,
                    "\n  depth {i}: {} | clauses=[{}] | est={:.1} ×{}cl{} = {:.1}",
                    d.var,
                    clauses.join(", "),
                    d.estimated_elements,
                    ncl,
                    pen,
                    d.step_cost
                )?;
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
    pub attr_is_indexed: bool,
}

impl IterPlanData {
    /// Posições *bound* (fixas) que aparecem ANTES da variável do `depth`
    /// informado, na ordem do índice desta cláusula. O codegen consome só
    /// isto — nunca olha `idx_order` diretamente, então reordenamentos de
    /// coluna entre índices (AEVT [a,e,v] vs AVET [a,v,e]) não quebram a
    /// emissão de `scanner-push`.
    pub fn bound_positions_before(&self, depth: usize) -> Vec<(String, PlanValue)> {
        // Variável iterada neste depth para esta cláusula.
        let var_pos = self
            .var_depths
            .iter()
            .find(|&&(d, _)| d == depth)
            .map(|&(_, ref p)| p.as_str());
        let cutoff = match var_pos {
            Some(p) => self
                .idx_order
                .iter()
                .position(|x| x == p)
                .unwrap_or(self.idx_order.len()),
            None => self.idx_order.len(),
        };
        self.idx_order[..cutoff]
            .iter()
            .filter(|p| *p != "added")
            .filter_map(|p| {
                self.bound_ints
                    .get(p)
                    .map(|v| (p.clone(), v.clone()))
            })
            .collect()
    }

    /// Todas as posições bound desta cláusula, na ordem do índice, exceto
    /// "added". Usado para emitir `scanner-push` de valores que ficam após a
    /// última variável iterada.
    pub fn all_bound_positions(&self) -> Vec<(String, PlanValue)> {
        self.idx_order
            .iter()
            .filter(|p| *p != "added")
            .filter_map(|p| self.bound_ints.get(p).map(|v| (p.clone(), v.clone())))
            .collect()
    }
}

// ── Query plan result (planner output) ──────────────────────────────

pub type RangeBoundsMap = HashMap<String, Vec<Vec<(String, PlanValue)>>>;

/// Variável sintética que representa uma ocorrência duplicada de uma Var real
/// dentro da mesma cláusula (ex: `e = ?x` e `v = ?x` em p0). A duplicata é
/// inserida em `all_vars` como um passo de busca separado, com custo zero e
/// restrição de viabilidade (`source_var` precisa estar resolvido antes).
/// O compiler a traduz como `scanner-iterate` com `:ranges (ranges-create (= source_var))`.
#[derive(Clone, Debug)]
pub struct SyntheticVar {
    /// Nome único no formato `{source_var}@p{pattern_idx}.{position}`.
    pub name: String,
    /// Nome da Var real que esta synthetic confirma (ex: `_e_d2`).
    pub source_var: String,
    /// Índice da cláusula em `join_patterns` (mesmo índice usado em `iter_plans`).
    pub pattern_idx: usize,
    /// Posição na idx_order desta cláusula (`e`/`a`/`v`/`t`/`added`).
    pub position: String,
}

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
    /// Var sintéticas para confirmação same-var. Chaveada por nome p/ lookup
    /// rápido no compiler e no EXPLAIN.
    pub synthetic_vars: Vec<SyntheticVar>,
}

fn fmt_spec(spec: &SpecKind) -> String {
    match spec {
        SpecKind::Var(name) => format!("?{name}"),
        SpecKind::Bound(0) => "_".into(),
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
            writeln!(
                f,
                "Join order: [{}]{}{}",
                self.ordered_vars.join(", "),
                hist_tag,
                exists_tag
            )?;
        }

        if !self.find_vars.is_empty() {
            let projs: Vec<String> = self.find_vars.iter().map(|fv| format!("{fv}")).collect();
            writeln!(f, "Projections: {}", projs.join(", "))?;
        }

        if !self.iter_plans.is_empty() {
            writeln!(f, "Iter plans:")?;
            for (i, ip) in self.iter_plans.iter().enumerate() {
                writeln!(f, "  p{i} @ {}", ip.index_name)?;
                for (pos, slot) in ip.idx_order.iter().enumerate() {
                    let spec = &ip.specs[pos];
                    let var_at_pos = match spec {
                        SpecKind::Var(name) => Some(name.clone()),
                        _ => None,
                    };
                    let var_label = ip.var_depths
                        .iter()
                        .find(|(_, ref p)| p == slot)
                        .map(|(d, _)| {
                            if let Some(ref name) = var_at_pos {
                                if let Some(at) = name.find("@p") {
                                    let source = &name[..at];
                                    return format!("  [depth {d} - confirmation: range [{source}, {source}]]");
                                }
                            }
                            format!("  [depth {d}]")
                        });
                    match spec {
                        SpecKind::Var(name) => {
                            let display_name = match name.find("@p") {
                                Some(at) => &name[..at],
                                None => name.as_str(),
                            };
                            writeln!(f, "    {slot} = ?{display_name}{}",
                                var_label.as_deref().unwrap_or(""))?;
                        }
                        SpecKind::BoundAttr(_) | SpecKind::BoundValue(_) | SpecKind::Bound(_) | SpecKind::BoundParam(_) => {
                            let bound_val = ip.bound_ints.get(slot);
                            writeln!(f, "    {slot} = {}{}",
                                fmt_spec(spec),
                                if let Some(pv) = bound_val {
                                    format!("  (attr: {pv:?})")
                                } else {
                                    String::new()
                                })?;
                        }
                    }
                }
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

/// Planner output wrapper.
#[derive(Clone)]
pub struct QueryPlanSt {
    pub plan: QueryPlanResult,
}
