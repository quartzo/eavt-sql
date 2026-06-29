use std::collections::HashMap;

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum BoundValue {
    Int(i64),
    Float(f64),
    Str(String),
    Attr(String),
    ResolvedAttr(u32, String, bool), // (attr_id, attr_name, is_ref) — pre-resolved by compiler
    Var(String),
    Missing(String),
    Param(u32),
}

impl std::fmt::Display for BoundValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BoundValue::Int(n) => write!(f, "{}", n),
            BoundValue::Float(fl) => write!(f, "{}", fl),
            BoundValue::Str(s) => write!(f, "\"{}\"", s),
            BoundValue::Attr(s) => write!(f, "Attr({})", s),
            BoundValue::ResolvedAttr(id, name, is_ref) => write!(f, "Attr({}, id={}, ref={})", name, id, is_ref),
            BoundValue::Var(s) => write!(f, "?{}", s),
            BoundValue::Missing(_) => write!(f, "_"),
            BoundValue::Param(n) => write!(f, "%{}", n),
        }
    }
}

impl BoundValue {
    pub fn to_value(&self) -> Option<crate::value::Value> {
        use crate::value::Value;
        match self {
            BoundValue::Int(n) => Some(Value::Int64(*n)),
            BoundValue::Float(f) => Some(Value::Float64(*f)),
            BoundValue::Str(s) | BoundValue::Attr(s) => Some(Value::text(s.clone())),
            BoundValue::ResolvedAttr(_, name, _) => Some(Value::text(name.clone())),
            _ => None,
        }
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum DatalogSlot {
    Var(String),
    Const(BoundValue),
    Missing,
}

impl std::fmt::Display for DatalogSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DatalogSlot::Var(n) => write!(f, "?{}", n),
            DatalogSlot::Const(bv) => write!(f, "{}", bv),
            DatalogSlot::Missing => write!(f, "_"),
        }
    }
}

impl DatalogSlot {
    pub fn is_var(&self) -> bool {
        matches!(self, DatalogSlot::Var(_))
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum FindVar {
    Var(String),
    Const(String, BoundValue),
}

impl std::fmt::Display for FindVar {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FindVar::Var(name) => write!(f, "?{}", name),
            FindVar::Const(name, bv) => write!(f, "{}={}", name, bv),
        }
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct DatalogPattern {
    pub e: DatalogSlot,
    pub a: DatalogSlot,
    pub v: DatalogSlot,
    pub t: DatalogSlot,
    pub added: DatalogSlot,
}

impl std::fmt::Display for DatalogPattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}, {}, {}, {}, {}]", self.e, self.a, self.v, self.t, self.added)
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone)]
pub struct DatalogIR {
    pub patterns: Vec<DatalogPattern>,
    pub find_vars: Vec<FindVar>,
    pub range_bounds: HashMap<String, Vec<Vec<(String, BoundValue)>>>,
    pub star: bool,
    pub exists_mode: bool,
    pub has_conditions: bool,
    pub history: bool,
}

impl std::fmt::Display for DatalogIR {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let fv: Vec<String> = self.find_vars.iter().map(|fv| format!("{}", fv)).collect();
        writeln!(f, "Find: {}", fv.join(", "))?;
        for (i, p) in self.patterns.iter().enumerate() {
            writeln!(f, "  p{}: {}", i, p)?;
        }
        if !self.range_bounds.is_empty() {
            writeln!(f, "  Range:")?;
            for (var, branches) in &self.range_bounds {
                for branch in branches {
                    let conds: Vec<String> = branch.iter().map(|(op, bv)| format!("{} {}", op, bv)).collect();
                    writeln!(f, "    {} {}", var, conds.join(" AND "))?;
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct DatalogIRSt {
    pub ir: DatalogIR,
}

/// Pre-computed cardinality estimates for the planner.
/// Keyed by (pattern_idx, index_name, var_name) → estimated row count.
/// Computed once by the compiler via `estimate_index_size`, so the
/// planner is a pure function with no transactor dependency.
#[derive(Clone, Default)]
pub struct PlanStats {
    pub total_eavt: f64,
    pub estimates: HashMap<(usize, String, String), f64>,
}

/// DatalogIR with pre-resolved attribute IDs. Produced by the compiler
/// via resolve_ir(). Patterns carry `BoundValue::ResolvedAttr(id, name, is_ref)`
/// instead of `BoundValue::Attr(name)`.
#[derive(Clone)]
pub struct DatalogNumIR {
    pub ir: DatalogIR,
    pub stats: PlanStats,
}

impl std::fmt::Display for DatalogNumIR {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Same Display as DatalogIR — the difference is that slots carry
        // ResolvedAttr(id, name, is_ref) instead of Attr(name).
        write!(f, "{}", self.ir)
    }
}

#[derive(Clone)]
pub struct DatalogNumIRSt {
    pub num_ir: DatalogNumIR,
}
