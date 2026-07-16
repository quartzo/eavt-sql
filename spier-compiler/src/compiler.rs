use spier_value::Value;

/// Resolve retract pairs from DELETE conditions (non-eid conditions).
/// Each pair is (attr_name, resolved_value).
pub fn resolve_delete_pairs(
    stmt: &spier_sql_parse::RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Vec<(String, Value)>, String> {
    use spier_sql_parse::{RustConditionRight, RustLiteral};
    let resolve_right = |right: &RustConditionRight, params: &[Value]| -> Result<Value, String> {
        match right {
            RustConditionRight::Param(idx) => {
                let i = *idx as usize;
                if i == 0 || i > params.len() {
                    return Err(format!("parameter %{} out of range", idx));
                }
                Ok(params[i - 1].clone())
            }
            RustConditionRight::Literal(RustLiteral::Int(n)) => Ok(Value::Int64(*n)),
            RustConditionRight::Literal(RustLiteral::Float(f)) => Ok(Value::Float64(*f)),
            RustConditionRight::Literal(RustLiteral::Str(s)) => Ok(Value::text(s.clone())),
            RustConditionRight::Literal(RustLiteral::Bool(b)) => Ok(Value::Bool(*b as u8)),
            RustConditionRight::Literal(RustLiteral::Bytes(b)) => {
                Ok(Value::Bytes(b.clone().into()))
            }
            _ => Err("unsupported condition right in delete".to_string()),
        }
    };

    let mut pairs = Vec::new();
    for cond in &stmt.conditions {
        if cond.left.field != "eid" {
            let val = resolve_right(&cond.right, params)?;
            pairs.push((cond.left.field.clone(), val));
        }
    }
    Ok(pairs)
}

/// Resolve entity value from DELETE eid condition.
pub fn resolve_delete_entity(
    stmt: &spier_sql_parse::RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Value, String> {
    use spier_sql_parse::{RustConditionRight, RustLiteral};
    for cond in &stmt.conditions {
        if cond.left.field == "eid" {
            return match &cond.right {
                RustConditionRight::Param(idx) => {
                    let i = *idx as usize;
                    if i == 0 || i > params.len() {
                        return Err(format!("parameter %{} out of range", idx));
                    }
                    Ok(params[i - 1].clone())
                }
                RustConditionRight::Literal(RustLiteral::Int(n)) => Ok(Value::Int64(*n)),
                _ => Err("entity must be integer in DELETE WHERE".to_string()),
            };
        }
    }
    Err("DELETE direct requires eid condition".to_string())
}
