use crate::value::Value;

#[derive(Clone, Debug, PartialEq)]
pub enum SpecKind {
    Var(String),
    Bound(u64),
    BoundAttr(u32),
    BoundValue(Value),
    BoundParam(u32),
}
