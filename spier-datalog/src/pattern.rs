use crate::ast::{BoundValue, DatalogPattern, DatalogSlot};

// ── Index catalog ───────────────────────────────────────────────────

pub const INDEX_ORDERS: [(&str, [&str; 5]); 4] = [
    ("EAVT", ["e", "a", "v", "t", "added"]),
    ("AEVT", ["a", "e", "v", "t", "added"]),
    ("AVET", ["a", "v", "e", "t", "added"]),
    ("VAET", ["v", "a", "e", "t", "added"]),
];

pub fn index_order(index: &str) -> &'static [&'static str] {
    let upper = index.to_ascii_uppercase();
    INDEX_ORDERS
        .iter()
        .find(|(name, _)| *name == upper)
        .map(|(_, order)| order.as_slice())
        .unwrap_or(&["e", "a", "v"])
}

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
        Pattern {
            e: p.e,
            a: p.a,
            v: p.v,
            t: p.t,
            added: p.added,
        }
    }
}

impl From<Pattern> for DatalogPattern {
    fn from(p: Pattern) -> DatalogPattern {
        DatalogPattern {
            e: p.e,
            a: p.a,
            v: p.v,
            t: p.t,
            added: p.added,
        }
    }
}
