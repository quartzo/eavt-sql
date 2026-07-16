use spier_value::Value;

use spier_query_ir::{
    RANGE_OP_EQ, RANGE_OP_GT, RANGE_OP_GTE, RANGE_OP_IN, RANGE_OP_LT, RANGE_OP_LTE, RANGE_OP_NEQ,
};

#[derive(Debug)]
pub struct EngineError(pub String);

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for EngineError {}

pub struct QueryContext {
    pub as_of_tx: Option<u64>,
    pub current_t: u64,
}

#[allow(dead_code)]
pub trait VMEngine: Send + Sync {
    fn resolve_entity(&self, name_or_id: &Value) -> u64;
    fn lookup_attr(&self, name: &str) -> Option<u32>;
    fn attr_name(&self, aid: u32) -> String;
    fn open_raw_cursor(
        &self,
        cf_id: u32,
        prefix: &[u8],
    ) -> Result<std::sync::Arc<std::cell::RefCell<dyn spier_storage_traits::Cursor>>, String>;
    fn collect_active(&self, cf: &str, prefix: &[u8], ctx: &QueryContext) -> Vec<RawDatomView>;
    fn probe_collect(
        &self,
        index: &str,
        bound: &[BoundPart],
        ctx: &QueryContext,
    ) -> Vec<RawDatomView>;
    fn save_with_t(
        &self,
        e: &Value,
        attr: &str,
        v: &Value,
        ctx: &QueryContext,
    ) -> Result<(), EngineError>;
    fn retract(&self, e: &Value, attr: &str, v: &Value, ctx: &QueryContext);
    fn allocate_in_partition(&self, partition_id: u64) -> u64;
    fn default_user_partition(&self) -> u64;
    fn declare_partition(&self, name: &str, ctx: &QueryContext) -> Result<u64, EngineError>;
    fn declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        ctx: &QueryContext,
    ) -> Result<(), EngineError>;
    fn is_unique_attr(&self, attr_name: &str) -> bool;
    fn value_type_for(&self, aid: u32) -> Option<u32>;
    fn lookup_entity(&self, attr_name: &str, value: &Value, ctx: &QueryContext) -> Option<u64>;
    fn lookup_value(&self, eid: u64, attr_name: &str, ctx: &QueryContext) -> Option<Value>;
    fn allocate_t_and_write_tx(&self) -> u64;
}

#[derive(Clone)]
pub struct RawDatomView {
    pub v: Value,
    pub t: u64,
    pub retracted: bool,
}

pub const RANGE_LO_OPEN: i32 = 1;
pub const RANGE_HI_OPEN: i32 = 2;

#[derive(Clone)]
pub(crate) struct RangeSpec {
    pub lo: Option<Value>,
    pub hi: Option<Value>,
    pub flags: i32,
}

pub(crate) fn merge_intervals(
    intervals: Vec<(Option<Value>, Option<Value>, i32)>,
) -> Vec<(Option<Value>, Option<Value>, i32)> {
    if intervals.len() <= 1 {
        return intervals;
    }
    let mut sorted: Vec<_> = intervals.into_iter().collect();
    sorted.sort_by(|a, b| {
        let ord_none = (a.0.is_none() as i64, b.0.is_none() as i64);
        match ord_none {
            (1, 1) => std::cmp::Ordering::Equal,
            (1, _) => std::cmp::Ordering::Less,
            (_, 1) => std::cmp::Ordering::Greater,
            _ => a.0.as_ref().unwrap().cmp(b.0.as_ref().unwrap()),
        }
    });
    let mut merged: Vec<(Option<Value>, Option<Value>, i32)> = vec![sorted[0].clone()];
    for (lo, hi, flags) in sorted.into_iter().skip(1) {
        let (_prev_lo, prev_hi, prev_flags) = merged.last().unwrap().clone();
        let can_merge = if prev_hi.is_none() {
            true
        } else if lo.is_some() {
            let prev_hi_val = prev_hi.as_ref().unwrap();
            let lo_val = lo.as_ref().unwrap();
            if lo_val.tag() != prev_hi_val.tag() {
                false
            } else if lo_val < prev_hi_val {
                true
            } else if lo_val == prev_hi_val {
                let prev_hi_closed = !(prev_flags & RANGE_HI_OPEN != 0);
                let lo_closed = !(flags & RANGE_LO_OPEN != 0);
                prev_hi_closed && lo_closed
            } else {
                false
            }
        } else {
            false
        };
        if can_merge {
            let new_hi = match (&prev_hi, &hi) {
                (None, None) => None,
                (None, Some(h)) => Some(h.clone()),
                (Some(_), None) => None,
                (Some(ph), Some(h)) => {
                    if h > ph {
                        Some(h.clone())
                    } else {
                        Some(ph.clone())
                    }
                }
            };
            let new_hi_open = match (&prev_hi, &hi) {
                (None, _) => flags & RANGE_HI_OPEN != 0,
                (_, None) => false,
                (Some(ph), Some(h)) => {
                    if h > ph {
                        flags & RANGE_HI_OPEN != 0
                    } else if h < ph {
                        prev_flags & RANGE_HI_OPEN != 0
                    } else {
                        prev_flags & RANGE_HI_OPEN != 0 && flags & RANGE_HI_OPEN != 0
                    }
                }
            };
            merged.last_mut().unwrap().1 = new_hi;
            merged.last_mut().unwrap().2 =
                (prev_flags & RANGE_LO_OPEN) | if new_hi_open { RANGE_HI_OPEN } else { 0 };
        } else {
            merged.push((lo, hi, flags));
        }
    }
    merged
}

pub(crate) fn ops_to_intervals(ops: &[(i32, Value)]) -> Vec<(Option<Value>, Option<Value>, i32)> {
    let mut neq_vals: Vec<Value> = Vec::new();
    let mut range_ops: Vec<(i32, Value)> = Vec::new();
    let mut in_vals: Vec<Value> = Vec::new();

    for (op, val) in ops {
        match *op {
            RANGE_OP_NEQ => neq_vals.push(val.clone()),
            RANGE_OP_IN => in_vals.push(val.clone()),
            _ => range_ops.push((*op, val.clone())),
        }
    }

    if !in_vals.is_empty() && range_ops.is_empty() && neq_vals.is_empty() {
        let mut sorted = in_vals;
        sorted.sort();
        let intervals: Vec<_> = sorted
            .into_iter()
            .map(|v| (Some(v.clone()), Some(v), 0))
            .collect();
        return merge_intervals(intervals);
    }

    let mut lo: Option<Value> = None;
    let mut hi: Option<Value> = None;
    let mut lo_open = false;
    let mut hi_open = false;

    for (op, val) in &range_ops {
        match *op {
            RANGE_OP_GT | RANGE_OP_GTE => {
                if lo.is_none()
                    || val > lo.as_ref().unwrap()
                    || (val == lo.as_ref().unwrap() && *op == RANGE_OP_GT)
                {
                    lo = Some(val.clone());
                    lo_open = *op == RANGE_OP_GT;
                }
            }
            RANGE_OP_LT | RANGE_OP_LTE => {
                if hi.is_none()
                    || val < hi.as_ref().unwrap()
                    || (val == hi.as_ref().unwrap() && *op == RANGE_OP_LT)
                {
                    hi = Some(val.clone());
                    hi_open = *op == RANGE_OP_LT;
                }
            }
            RANGE_OP_EQ => {
                lo = Some(val.clone());
                hi = Some(val.clone());
                lo_open = false;
                hi_open = false;
            }
            _ => {}
        }
    }

    if lo.is_some() && hi.is_some() && lo.as_ref().unwrap() > hi.as_ref().unwrap() {
        return vec![];
    }

    let mut flags = 0;
    if lo_open {
        flags |= RANGE_LO_OPEN;
    }
    if hi_open {
        flags |= RANGE_HI_OPEN;
    }

    let mut intervals: Vec<(Option<Value>, Option<Value>, i32)> = vec![(lo, hi, flags)];

    for nv in neq_vals {
        let mut new_intervals: Vec<(Option<Value>, Option<Value>, i32)> = Vec::new();
        for (iv_lo, iv_hi, iv_flags) in intervals {
            let in_range = {
                let mut ok = true;
                if let Some(ref lo) = iv_lo {
                    let lo_open_i = iv_flags & RANGE_LO_OPEN != 0;
                    if lo_open_i {
                        if &nv <= lo {
                            ok = false;
                        }
                    } else {
                        if &nv < lo {
                            ok = false;
                        }
                    }
                }
                if ok {
                    if let Some(ref hi) = iv_hi {
                        let hi_open_i = iv_flags & RANGE_HI_OPEN != 0;
                        if hi_open_i {
                            if &nv >= hi {
                                ok = false;
                            }
                        } else {
                            if &nv > hi {
                                ok = false;
                            }
                        }
                    }
                }
                ok
            };
            if !in_range {
                new_intervals.push((iv_lo, iv_hi, iv_flags));
            } else {
                let left_flags = (iv_flags & !RANGE_HI_OPEN) | RANGE_HI_OPEN;
                new_intervals.push((iv_lo, Some(nv.clone()), left_flags));
                let right_flags = (iv_flags & !RANGE_LO_OPEN) | RANGE_LO_OPEN;
                new_intervals.push((Some(nv.clone()), iv_hi, right_flags));
            }
        }
        intervals = new_intervals;
    }

    merge_intervals(intervals)
}

#[derive(Debug)]
pub enum BoundPart {
    Int(u64),
    Attr(u32),
    #[allow(dead_code)]
    Val(Value),
}

pub(crate) fn probe_value_matches(dv: &Value, pv: &Value) -> bool {
    match pv {
        Value::Int64(_) | Value::Bool(_) | Value::Timestamp(_) => dv.raw_int() == pv.raw_int(),
        Value::Float64(_) => dv.raw_float() == pv.raw_float(),
        _ => dv == pv,
    }
}
