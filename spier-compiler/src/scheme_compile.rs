use std::collections::HashMap;

use spier_datalog::BoundValue;
use spier_planner::{PlanValue, QueryPlanResult};
use spier_query_ir::SelectSchemeMeta;
use spier_scheme::{SchemeProgram, SExpr};
use spier_sql_parse::{RustConditionRight, RustDeleteWhereStmt, RustLiteral, RustUpsertStmt, RustValue, UpsertEntityRef};
use spier_value::Value;

pub(crate) fn resolve_delete_pairs(
    stmt: &RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Vec<(String, Value)>, String> {
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

pub(crate) fn resolve_delete_entity(
    stmt: &RustDeleteWhereStmt,
    params: &[Value],
) -> Result<Value, String> {
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

pub fn compile_upsert_scheme(
    stmt: &RustUpsertStmt,
    params: &[spier_value::Value],
) -> Result<SchemeProgram, String> {
    let mut total_values: usize = 0;
    for clause in &stmt.clauses {
        total_values += clause.values.len();
    }

    let mut bindings = Vec::new();
    let mut when_clauses = Vec::new();
    let mut first_alias: Option<String> = None;
    let mut nullable_aliases: Vec<String> = Vec::new();

    for (clause_idx, clause) in stmt.clauses.iter().enumerate() {
        let alias = clause
            .alias
            .clone()
            .unwrap_or_else(|| format!("_auto_{clause_idx}"));
        if first_alias.is_none() {
            first_alias = Some(alias.clone());
        }

        if matches!(clause.entity_ref, UpsertEntityRef::Lookup { .. }) {
            nullable_aliases.push(alias.clone());
        }

        let entity_expr = compile_entity_ref(&clause.entity_ref, params)?;
        bindings.push(SExpr::List(vec![
            SExpr::Symbol(alias.clone()),
            entity_expr,
        ]));

        let mut saves = Vec::new();
        for iv in &clause.values {
            let value_expr = compile_value(&iv.value, &alias)?;
            saves.push(SExpr::List(vec![
                SExpr::Symbol("save".into()),
                SExpr::Symbol(alias.clone()),
                SExpr::Str(iv.attr.clone()),
                value_expr,
            ]));
        }

        let body = if saves.len() == 1 {
            saves.remove(0)
        } else {
            SExpr::List({
                let mut v = vec![SExpr::Symbol("begin".into())];
                v.extend(saves);
                v
            })
        };

        when_clauses.push(SExpr::List(vec![
            SExpr::Symbol("when".into()),
            SExpr::Symbol(alias),
            body,
        ]));
    }

    let first = first_alias.ok_or("UPSERT requires at least one clause")?;

    let result_expr = SExpr::List(vec![
        SExpr::Symbol("result".into()),
        SExpr::Symbol(first),
        SExpr::Int(total_values as i64),
    ]);

    let guarded_result = if nullable_aliases.is_empty() {
        result_expr
    } else {
        let mut inner = result_expr;
        for alias in nullable_aliases.iter().rev() {
            inner = SExpr::List(vec![
                SExpr::Symbol("when".into()),
                SExpr::Symbol(alias.clone()),
                inner,
            ]);
        }
        inner
    };

    when_clauses.push(guarded_result);

    let body = SExpr::List({
        let mut v = vec![
            SExpr::Symbol("let*".into()),
            SExpr::List(bindings),
        ];
        v.extend(when_clauses);
        v
    });

    let param_count = params.len();
    Ok(SchemeProgram::new(body).with_param_count(param_count))
}

pub fn compile_delete_direct_scheme(
    entity_val: &spier_value::Value,
    retract_pairs: &[(String, spier_value::Value)],
) -> SchemeProgram {
    let eid_sexpr = match entity_val {
        spier_value::Value::Int64(n) => SExpr::Int(*n),
        _ => SExpr::Int(0),
    };

    let mut stmts: Vec<SExpr> = Vec::new();
    for (attr, val) in retract_pairs {
        let val_sexpr = match val {
            spier_value::Value::Int64(n) => SExpr::Int(*n),
            spier_value::Value::Float64(f) => SExpr::Float(*f),
            spier_value::Value::Text(s) => SExpr::Str(s.clone()),
            spier_value::Value::Bool(b) => SExpr::Bool(*b != 0),
            spier_value::Value::Timestamp(t) => SExpr::Int(*t),
            spier_value::Value::Bytes(b) => SExpr::Bytes(b.clone()),
            _ => SExpr::Int(0),
        };
        stmts.push(SExpr::List(vec![
            SExpr::Symbol("retract".into()),
            eid_sexpr.clone(),
            SExpr::Str(attr.clone()),
            val_sexpr,
        ]));
    }

    stmts.push(SExpr::List(vec![
        SExpr::Symbol("result".into()),
        eid_sexpr,
    ]));

    let body = if stmts.len() == 1 {
        stmts.remove(0)
    } else {
        SExpr::List({
            let mut v = vec![SExpr::Symbol("begin".into())];
            v.extend(stmts);
            v
        })
    };

    SchemeProgram::new(body).with_param_count(0)
}

pub fn compile_attribute_scheme(stmt: &spier_sql_parse::RustAttributeStmt) -> SchemeProgram {
    let attr = SExpr::Str(stmt.attr.clone());
    let vt = SExpr::Str(stmt.value_type.clone());
    let many = SExpr::Bool(stmt.many);
    let unique = SExpr::Bool(stmt.unique);
    let body = SExpr::List(vec![
        SExpr::Symbol("begin".into()),
        SExpr::List(vec![
            SExpr::Symbol("declare-attr".into()),
            attr.clone(),
            vt.clone(),
            many,
            unique,
        ]),
        SExpr::List(vec![
            SExpr::Symbol("result".into()),
            attr,
            vt,
        ]),
    ]);
    SchemeProgram::new(body).with_param_count(0)
}

pub fn compile_partition_scheme(stmt: &spier_sql_parse::RustPartitionStmt) -> SchemeProgram {
    let body = SExpr::List(vec![
        SExpr::Symbol("let*".into()),
        SExpr::List(vec![
            SExpr::List(vec![
                SExpr::Symbol("pid".into()),
                SExpr::List(vec![
                    SExpr::Symbol("declare-partition".into()),
                    SExpr::Str(stmt.name.clone()),
                ]),
            ]),
        ]),
        SExpr::List(vec![
            SExpr::Symbol("result".into()),
            SExpr::Symbol("pid".into()),
        ]),
    ]);
    SchemeProgram::new(body).with_param_count(0)
}

fn compile_entity_ref(
    entity_ref: &UpsertEntityRef,
    params: &[spier_value::Value],
) -> Result<SExpr, String> {
    Ok(match entity_ref {
        UpsertEntityRef::New => {
            SExpr::List(vec![
                SExpr::Symbol("alloc-entity".into()),
                SExpr::Int(4),
            ])
        }
        UpsertEntityRef::Tx => SExpr::List(vec![SExpr::Symbol("tx-entity".into())]),
        UpsertEntityRef::ExplicitEid(idx) => {
            let i = *idx as usize;
            if i == 0 || i > params.len() {
                return Err(format!("parameter %{} out of range", idx));
            }
            SExpr::List(vec![
                SExpr::Symbol("param".into()),
                SExpr::Int(*idx as i64),
            ])
        }
        UpsertEntityRef::Lookup { attr, value } => {
            let attr_expr = compile_value(attr, "")?;
            let value_expr = compile_value(value, "")?;
            SExpr::List(vec![
                SExpr::Symbol("lookup-entity".into()),
                attr_expr,
                value_expr,
            ])
        }
    })
}

fn compile_value(value: &RustValue, _alias: &str) -> Result<SExpr, String> {
    match value {
        RustValue::Literal(lit) => compile_literal_value(lit),
        RustValue::Param(idx) => Ok(SExpr::List(vec![
            SExpr::Symbol("param".into()),
            SExpr::Int(*idx as i64),
        ])),
        RustValue::AliasRef(name) => Ok(SExpr::Symbol(name.clone())),
        RustValue::EidLookup { attr, value } => {
            let attr_expr = compile_value(attr, _alias)?;
            let value_expr = compile_value(value, _alias)?;
            Ok(SExpr::List(vec![
                SExpr::Symbol("lookup-entity".into()),
                attr_expr,
                value_expr,
            ]))
        }
        RustValue::ValLookup { entity, attr } => {
            let entity_expr = match entity.as_ref() {
                RustValue::EidLookup {
                    attr: ea,
                    value: ev,
                } => {
                    let a = compile_value(ea, _alias)?;
                    let v = compile_value(ev, _alias)?;
                    SExpr::List(vec![SExpr::Symbol("lookup-entity".into()), a, v])
                }
                other => compile_value(other, _alias)?,
            };
            let attr_expr = compile_value(attr, _alias)?;
            Ok(SExpr::List(vec![
                SExpr::Symbol("lookup-value".into()),
                entity_expr,
                attr_expr,
            ]))
        }
    }
}

fn compile_literal_value(lit: &RustLiteral) -> Result<SExpr, String> {
    Ok(match lit {
        RustLiteral::Int(n) => SExpr::Int(*n),
        RustLiteral::Float(f) => SExpr::Float(*f),
        RustLiteral::Str(s) => SExpr::Str(s.clone()),
        RustLiteral::Bool(b) => SExpr::Bool(*b),
        RustLiteral::Bytes(_) => return Err("BYTES values are not supported in UPSERT".into()),
    })
}

fn plan_value_to_sexpr(pv: &PlanValue) -> SExpr {
    match pv {
        PlanValue::Value(Value::Int64(n)) => SExpr::Int(*n),
        PlanValue::Value(Value::Float64(f)) => SExpr::Float(*f),
        PlanValue::Value(Value::Text(s)) => SExpr::Str(s.clone()),
        PlanValue::Value(Value::Bool(b)) => SExpr::Bool(*b != 0),
        PlanValue::Value(Value::Timestamp(t)) => SExpr::Int(*t),
        PlanValue::Value(Value::Bytes(b)) => SExpr::Bytes(b.clone()),
        PlanValue::Value(Value::Unknown(tag, _)) => SExpr::Symbol(format!("unknown({tag})")),
        PlanValue::Param(idx) => SExpr::List(vec![
            SExpr::Symbol("param".into()),
            SExpr::Int(*idx as i64),
        ]),
    }
}

fn bound_value_to_sexpr(bv: &BoundValue) -> SExpr {
    match bv {
        BoundValue::Int(n) => SExpr::Int(*n),
        BoundValue::Float(f) => SExpr::Float(*f),
        BoundValue::Str(s) | BoundValue::Attr(s) => SExpr::Str(s.clone()),
        BoundValue::ResolvedAttr(id, _, _, _) => SExpr::Int(*id as i64),
        BoundValue::Param(idx) => SExpr::List(vec![
            SExpr::Symbol("param".into()),
            SExpr::Int(*idx as i64),
        ]),
        BoundValue::Var(name) => SExpr::Symbol(format!("?{name}")),
        BoundValue::Missing(_) => SExpr::Symbol("_".into()),
    }
}

/// Build a boolean tree SExpr from range bounds.
/// Each branch is a Vec of (op_str, PlanValue) — ANDed within the branch.
/// Multiple branches are ORed.
///
/// "in" entries within the same branch are collected into a single
/// (= v1 v2 v3) form — multiple values use IN semantics.
///
/// Single branch, multiple conditions → (and (op val) (op val) ...)
/// Multiple branches → (or (and (op val) ...) (and (op val) ...))
/// Single branch, single condition → (op val) (implicit AND)
fn build_range_tree(branches: &Vec<Vec<(String, PlanValue)>>) -> SExpr {
    fn build_branch(branch: &Vec<(String, PlanValue)>) -> SExpr {
        // Collect "in" values into a single (= v1 v2 ...) form
        let mut in_vals: Vec<SExpr> = Vec::new();
        let mut other_conds: Vec<SExpr> = Vec::new();
        for (op, pv) in branch {
            if op == "in" {
                in_vals.push(plan_value_to_sexpr(pv));
            } else {
                other_conds.push(SExpr::List(vec![
                    SExpr::Symbol(op.clone()),
                    plan_value_to_sexpr(pv),
                ]));
            }
        }
        // (= v1 v2 ...) for collected IN values
        if !in_vals.is_empty() {
            let mut eq_items = vec![SExpr::Symbol("=".into())];
            eq_items.extend(in_vals);
            other_conds.push(SExpr::List(eq_items));
        }
        if other_conds.len() == 1 {
            other_conds.into_iter().next().unwrap()
        } else {
            let mut and_items = vec![SExpr::Symbol("and".into())];
            and_items.extend(other_conds);
            SExpr::List(and_items)
        }
    }

    if branches.len() == 1 {
        build_branch(&branches[0])
    } else {
        let branch_sexprs: Vec<SExpr> = branches.iter().map(build_branch).collect();
        let mut or_items = vec![SExpr::Symbol("or".into())];
        or_items.extend(branch_sexprs);
        SExpr::List(or_items)
    }
}

pub fn compile_select_scheme(
    plan: &QueryPlanResult,
    total_proj_len: usize,
    find_vars_in: &[spier_datalog::FindVar],
) -> Result<(SchemeProgram, SelectSchemeMeta), String> {
    let mut find_vars: Vec<String> = Vec::new();
    let mut constant_indices: HashMap<usize, PlanValue> = HashMap::new();
    for (i, fv) in find_vars_in.iter().enumerate() {
        match fv {
            spier_datalog::FindVar::Var(name) => find_vars.push(name.clone()),
            spier_datalog::FindVar::Const(name, bv) => {
                find_vars.push(name.clone());
                if let Some(pv) = PlanValue::from_bound_value(bv) {
                    constant_indices.insert(i, pv);
                }
            }
        }
    }

    let leaf_body = if plan.exists_mode && constant_indices.is_empty() {
        SExpr::List(vec![
            SExpr::Symbol("result-row".into()),
            SExpr::Int(1),
        ])
    } else {
        let (_, var_id_map) = build_var_names_and_id_map(plan);
        let probe_only = plan.ordered_vars.is_empty();
        build_projection(plan, &var_id_map, total_proj_len, &constant_indices, probe_only)
    };

    build_triejoin_scheme(plan, &find_vars, leaf_body)
}

pub fn compile_delete_scheme(
    plan: &QueryPlanResult,
    find_vars: &[String],
    target_evar: &str,
    delete_stmt: &spier_sql_parse::RustDeleteWhereStmt,
) -> Result<(SchemeProgram, SelectSchemeMeta), String> {
    use spier_sql_parse::{RustConditionRight, RustLiteral};

    let (_, var_id_map) = build_var_names_and_id_map(plan);
    let e_var_id = var_id_map.get(target_evar).copied().unwrap_or(0);

    let eid_get = SExpr::List(vec![SExpr::Symbol("bind-get".into()), SExpr::Int(e_var_id as i64)]);

    let mut leaf_stmts: Vec<SExpr> = Vec::new();

    for cond in &delete_stmt.conditions {
        if cond.left.field == "eid" {
            continue;
        }
        let attr = cond.left.field.clone();
        let val_sexpr = match &cond.right {
            RustConditionRight::Param(idx) => SExpr::List(vec![
                SExpr::Symbol("param".into()),
                SExpr::Int(*idx as i64),
            ]),
            RustConditionRight::Literal(RustLiteral::Int(n)) => SExpr::Int(*n),
            RustConditionRight::Literal(RustLiteral::Float(f)) => SExpr::Float(*f),
            RustConditionRight::Literal(RustLiteral::Str(s)) => SExpr::Str(s.clone()),
            RustConditionRight::Literal(RustLiteral::Bool(b)) => SExpr::Bool(*b),
            RustConditionRight::Literal(RustLiteral::Bytes(b)) => SExpr::Bytes(b.clone()),
            _ => SExpr::Int(0),
        };
        leaf_stmts.push(SExpr::List(vec![
            SExpr::Symbol("retract".into()),
            eid_get.clone(),
            SExpr::Str(attr),
            val_sexpr,
        ]));
    }

    leaf_stmts.push(SExpr::List(vec![
        SExpr::Symbol("result-row".into()),
        eid_get,
    ]));

    let leaf_body = if leaf_stmts.len() == 1 {
        leaf_stmts.remove(0)
    } else {
        SExpr::List({
            let mut v = vec![SExpr::Symbol("begin".into())];
            v.extend(leaf_stmts);
            v
        })
    };

    build_triejoin_scheme(plan, find_vars, leaf_body)
}

pub fn compile_update_scheme(
    plan: &QueryPlanResult,
    find_vars: &[String],
    update_stmt: &spier_sql_parse::RustUpdateStmt,
) -> Result<(SchemeProgram, SelectSchemeMeta), String> {
    use spier_sql_parse::{RustLiteral, RustValue};

    let (_, var_id_map) = build_var_names_and_id_map(plan);

    let mut leaf_stmts: Vec<SExpr> = Vec::new();
    let mut first_eid_get: Option<SExpr> = None;

    for clause in &update_stmt.clauses {
        let clause_evar = format!("_e_{}", clause.alias.to_lowercase());
        let e_var_id = var_id_map.get(&clause_evar).copied().unwrap_or(0);
        let eid_get = SExpr::List(vec![
            SExpr::Symbol("bind-get".into()),
            SExpr::Int(e_var_id as i64),
        ]);
        if first_eid_get.is_none() {
            first_eid_get = Some(eid_get.clone());
        }

        for iv in &clause.values {
            let val_sexpr = match &iv.value {
                RustValue::Literal(RustLiteral::Int(n)) => SExpr::Int(*n),
                RustValue::Literal(RustLiteral::Float(f)) => SExpr::Float(*f),
                RustValue::Literal(RustLiteral::Str(s)) => SExpr::Str(s.clone()),
                RustValue::Literal(RustLiteral::Bool(b)) => SExpr::Bool(*b),
                RustValue::Literal(RustLiteral::Bytes(b)) => SExpr::Bytes(b.clone()),
                RustValue::Param(idx) => SExpr::List(vec![
                    SExpr::Symbol("param".into()),
                    SExpr::Int(*idx as i64),
                ]),
                RustValue::AliasRef(name) => {
                    let ref_evar = format!("_e_{}", name.to_lowercase());
                    let ref_vid = var_id_map.get(&ref_evar).copied().unwrap_or(0);
                    SExpr::List(vec![
                        SExpr::Symbol("bind-get".into()),
                        SExpr::Int(ref_vid as i64),
                    ])
                }
                _ => SExpr::Int(0),
            };
            leaf_stmts.push(SExpr::List(vec![
                SExpr::Symbol("save".into()),
                eid_get.clone(),
                SExpr::Str(iv.attr.clone()),
                val_sexpr,
            ]));
        }
    }

    leaf_stmts.push(SExpr::List(vec![
        SExpr::Symbol("result-row".into()),
        first_eid_get.unwrap_or(SExpr::Int(0)),
    ]));

    let leaf_body = if leaf_stmts.len() == 1 {
        leaf_stmts.remove(0)
    } else {
        SExpr::List({
            let mut v = vec![SExpr::Symbol("begin".into())];
            v.extend(leaf_stmts);
            v
        })
    };

    build_triejoin_scheme(plan, find_vars, leaf_body)
}

fn build_var_names_and_id_map(plan: &QueryPlanResult) -> (Vec<String>, HashMap<String, usize>) {
    let mut var_names_list: Vec<String> = plan.ordered_vars.clone();
    for tn in &plan.t_lookup_vars {
        if !var_names_list.contains(tn) {
            var_names_list.push(tn.clone());
        }
    }
    for ip in &plan.iter_plans {
        for (name, _) in &ip.trailing_bindings {
            if !var_names_list.contains(name) {
                var_names_list.push(name.clone());
            }
        }
    }
    let var_id_map = var_names_list
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect();
    (var_names_list, var_id_map)
}

fn build_triejoin_scheme(
    plan: &QueryPlanResult,
    _find_vars: &[String],
    leaf_body: SExpr,
) -> Result<(SchemeProgram, SelectSchemeMeta), String> {
    let ordered_vars = &plan.ordered_vars;
    let num_depths = ordered_vars.len();

    let (var_names_list, var_id_map) = build_var_names_and_id_map(plan);
    let depth_var_pairs: Vec<(usize, usize)> = ordered_vars
        .iter()
        .enumerate()
        .map(|(d, name)| (d, *var_id_map.get(name).unwrap()))
        .collect();

    let mut stmts: Vec<SExpr> = Vec::new();
    let mut prefix_stmts: Vec<SExpr> = Vec::new();

    // Build let* bindings for scanners: (s0 (scanner-open INDEX_NAME [history]))
    let mut scanner_bindings: Vec<SExpr> = Vec::new();
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        let scanner_name = format!("s{ip_idx}");
        let index_name = ip.index_name.to_ascii_uppercase();
        let mut open_args = vec![
            SExpr::Symbol("scanner-open".into()),
            SExpr::Str(index_name),
        ];
        if plan.history {
            open_args.push(SExpr::Bool(true));
        }
        scanner_bindings.push(SExpr::List(vec![
            SExpr::Symbol(scanner_name.clone()),
            SExpr::List(open_args),
        ]));

        let v2_order: Vec<&str> = ip.idx_order.iter().map(|s| s.as_str()).collect();
        for pos_name in &v2_order {
            if let Some(pv) = ip.bound_ints.get(*pos_name) {
                let val_expr = match pv {
                    PlanValue::Value(Value::Text(name)) if *pos_name == "a" => {
                        SExpr::List(vec![
                            SExpr::Symbol("intern-a".into()),
                            SExpr::Str(name.clone()),
                        ])
                    }
                    _ => plan_value_to_sexpr(pv),
                };
                prefix_stmts.push(SExpr::List(vec![
                    SExpr::Symbol("prefix-push".into()),
                    SExpr::Symbol(format!("s{ip_idx}")),
                    val_expr,
                    SExpr::Str(pos_name.to_string()),
                ]));
            }
        }
    }

    stmts.extend(prefix_stmts);

    // Build per-depth range trees from plan.range_bounds.
    // Each depth's ranges become a boolean tree: (and (op val) ...) or (or branch1 branch2)
    let depth_ranges: HashMap<usize, SExpr> = plan.range_bounds.iter()
        .filter_map(|(var_name, branches)| {
            let depth = ordered_vars.iter().position(|v| v == var_name)?;
            let range_sexpr = build_range_tree(branches);
            Some((depth, range_sexpr))
        })
        .collect();

    let depth_groups = build_depth_groups(plan);

    let mut depth_scanners: Vec<Vec<usize>> = Vec::new();
    for depth in 0..num_depths {
        depth_scanners.push(
            depth_groups.get(&depth).cloned().unwrap_or_default()
        );
    }

    let mut body = leaf_body;
    for depth in (0..num_depths).rev() {
        let scanners = &depth_scanners[depth];
        let scanner_args: Vec<SExpr> = scanners
            .iter()
            .map(|&sid| SExpr::Symbol(format!("s{sid}")))
            .collect();
        let ranges = depth_ranges.get(&depth).cloned().unwrap_or(SExpr::List(vec![]));
        body = SExpr::List(vec![
            SExpr::Symbol("depth-run".into()),
            SExpr::Int(depth as i64),
            SExpr::List(scanner_args),
            ranges,
            SExpr::List(vec![SExpr::Symbol("lambda".into()), SExpr::List(vec![]), body]),
        ]);
    }

    // Emit probe: if plan.lookups has a fully-bound lookup pattern,
    // wrap the triejoin body in (when (probe-begin eid attr value) ...)
    for pattern in &plan.lookups {
        if !pattern.is_lookup() { continue; }
        let e_val = match &pattern.e {
            spier_datalog::DatalogSlot::Const(bv) => bound_value_to_sexpr(bv),
            _ => continue,
        };
        let a_val = match &pattern.a {
            spier_datalog::DatalogSlot::Const(bv) => bound_value_to_sexpr(bv),
            _ => continue,
        };
        let v_val = match &pattern.v {
            spier_datalog::DatalogSlot::Const(bv) => bound_value_to_sexpr(bv),
            _ => continue,
        };
        let probe_call = SExpr::List(vec![
            SExpr::Symbol("probe-begin".into()),
            e_val,
            a_val,
            v_val,
        ]);
        body = SExpr::List(vec![
            SExpr::Symbol("when".into()),
            probe_call,
            body,
        ]);
    }

    stmts.push(body);

    // Build the full body: (let* (scanner bindings) body)
    let inner_body = if stmts.len() == 1 {
        stmts.remove(0)
    } else {
        SExpr::List({
            let mut v = vec![SExpr::Symbol("begin".into())];
            v.extend(stmts);
            v
        })
    };

    let full_body = if scanner_bindings.is_empty() {
        inner_body
    } else {
        SExpr::List(vec![
            SExpr::Symbol("let*".into()),
            SExpr::List(scanner_bindings),
            inner_body,
        ])
    };

    // Compute same_var_constraints for the Scheme path.
    // For each scanner (sid = ip_idx), find positions in the index order
    // that map to the same variable and create constraint pairs.
    let mut same_var_constraints: Vec<(i32, Vec<(usize, usize)>)> = Vec::new();
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        let v2_order: Vec<&str> = ip.idx_order.iter().map(|s| s.as_str()).collect();
        let mut var_positions: HashMap<&str, Vec<usize>> = HashMap::new();
        for (idx, pos) in v2_order.iter().enumerate() {
            let var_name = match *pos {
                "e" => ip.specs.get(0),
                "a" => ip.specs.get(1),
                "v" => ip.specs.get(2),
                _ => None,
            }
            .and_then(|s| match s {
                spier_query_ir::SpecKind::Var(n) => Some(n.as_str()),
                _ => None,
            });
            if let Some(var_name) = var_name {
                var_positions.entry(var_name).or_default().push(idx);
            }
        }
        for positions in var_positions.values() {
            if positions.len() >= 2 {
                let pairs: Vec<(usize, usize)> =
                    positions[1..].iter().map(|&p| (positions[0], p)).collect();
                same_var_constraints.push((ip_idx as i32, pairs));
            }
        }
    }

    let meta = SelectSchemeMeta {
        num_vars: var_names_list.len(),
        depth_var_pairs,
        same_var_constraints,
    };

    Ok((SchemeProgram::new(full_body).with_param_count(0), meta))
}

fn build_depth_groups(plan: &QueryPlanResult) -> HashMap<usize, Vec<usize>> {
    let mut depth_groups: HashMap<usize, Vec<usize>> = HashMap::new();
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        for &d in &ip.active_depths {
            depth_groups.entry(d).or_default().push(ip_idx);
        }
    }
    depth_groups
}

fn build_projection(
    plan: &QueryPlanResult,
    var_id_map: &HashMap<String, usize>,
    total_proj_len: usize,
    constant_indices: &HashMap<usize, PlanValue>,
    probe_only: bool,
) -> SExpr {
    let mut proj_args: Vec<SExpr> = Vec::new();
    let mut fv_idx = 0;
    let find_vars: Vec<String> = plan.find_vars.iter().map(|fv| match fv {
        spier_datalog::FindVar::Var(n) => n.clone(),
        spier_datalog::FindVar::Const(n, _) => n.clone(),
    }).collect();

    let t_vars: std::collections::HashSet<&String> = plan.t_lookup_vars.iter().collect();

    for i in 0..total_proj_len {
        if let Some(pv) = constant_indices.get(&i) {
            proj_args.push(plan_value_to_sexpr(pv));
            fv_idx += 1;
            continue;
        }
        if fv_idx >= find_vars.len() {
            proj_args.push(SExpr::Void);
            continue;
        }
        let var_name = &find_vars[fv_idx];
        fv_idx += 1;
        if let Some(&vid) = var_id_map.get(var_name) {
            let bind = SExpr::List(vec![
                SExpr::Symbol("bind-get".into()),
                SExpr::Int(vid as i64),
            ]);
            if t_vars.contains(var_name) {
                if probe_only {
                    proj_args.push(SExpr::List(vec![
                        SExpr::Symbol("probe-get-t".into()),
                    ]));
                } else {
                    proj_args.push(bind);
                }
            } else if plan.attr_vars.contains(var_name) {
                proj_args.push(SExpr::List(vec![
                    SExpr::Symbol("attr-name".into()),
                    bind,
                ]));
            } else {
                proj_args.push(SExpr::List(vec![
                    SExpr::Symbol("resolve-val".into()),
                    bind,
                ]));
            }
        } else {
            proj_args.push(SExpr::Void);
        }
    }

    SExpr::List({
        let mut v = vec![SExpr::Symbol("result-row".into())];
        v.extend(proj_args);
        v
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use spier_scheme::write_scheme;

    fn make_params(count: usize) -> Vec<spier_value::Value> {
        (0..count)
            .map(|i| spier_value::Value::Int64(i as i64))
            .collect()
    }

    #[test]
    fn simple_new() {
        let stmt = RustUpsertStmt {
            clauses: vec![spier_sql_parse::RustUpsertClause {
                alias: Some("D1".into()),
                entity_ref: UpsertEntityRef::New,
                values: vec![spier_sql_parse::RustInsertValue {
                    attr: "person.name".into(),
                    value: RustValue::Literal(RustLiteral::Str("Alice".into())),
                }],
            }],
        };
        let params = make_params(0);
        let prog = compile_upsert_scheme(&stmt, &params).unwrap();
        let s = write_scheme(&prog.body);
        assert!(s.contains("alloc-entity"));
        assert!(s.contains("save"));
        assert!(s.contains("person.name"));
        assert!(s.contains("Alice"));
    }

    #[test]
    fn with_param() {
        let stmt = RustUpsertStmt {
            clauses: vec![spier_sql_parse::RustUpsertClause {
                alias: Some("D1".into()),
                entity_ref: UpsertEntityRef::ExplicitEid(1),
                values: vec![spier_sql_parse::RustInsertValue {
                    attr: "person.age".into(),
                    value: RustValue::Param(2),
                }],
            }],
        };
        let params = make_params(2);
        let prog = compile_upsert_scheme(&stmt, &params).unwrap();
        let s = write_scheme(&prog.body);
        assert!(s.contains("(param 1)"));
        assert!(s.contains("(param 2)"));
    }

    #[test]
    fn out_of_range_param() {
        let stmt = RustUpsertStmt {
            clauses: vec![spier_sql_parse::RustUpsertClause {
                alias: Some("D1".into()),
                entity_ref: UpsertEntityRef::ExplicitEid(5),
                values: vec![],
            }],
        };
        let params = make_params(2);
        assert!(compile_upsert_scheme(&stmt, &params).is_err());
    }

    #[test]
    fn alias_ref() {
        let stmt = RustUpsertStmt {
            clauses: vec![
                spier_sql_parse::RustUpsertClause {
                    alias: Some("D1".into()),
                    entity_ref: UpsertEntityRef::New,
                    values: vec![spier_sql_parse::RustInsertValue {
                        attr: "person.name".into(),
                        value: RustValue::Literal(RustLiteral::Str("A".into())),
                    }],
                },
                spier_sql_parse::RustUpsertClause {
                    alias: Some("D2".into()),
                    entity_ref: UpsertEntityRef::New,
                    values: vec![spier_sql_parse::RustInsertValue {
                        attr: "company.ceo".into(),
                        value: RustValue::AliasRef("D1".into()),
                    }],
                },
            ],
        };
        let params = make_params(0);
        let prog = compile_upsert_scheme(&stmt, &params).unwrap();
        let s = write_scheme(&prog.body);
        assert!(s.contains("D1"));
        assert!(s.contains("D2"));
        assert!(s.contains("(result D1 2)"));
    }

    #[test]
    fn round_trip_parseable() {
        let stmt = RustUpsertStmt {
            clauses: vec![spier_sql_parse::RustUpsertClause {
                alias: Some("D1".into()),
                entity_ref: UpsertEntityRef::New,
                values: vec![
                    spier_sql_parse::RustInsertValue {
                        attr: "person.age".into(),
                        value: RustValue::Param(1),
                    },
                    spier_sql_parse::RustInsertValue {
                        attr: "person.name".into(),
                        value: RustValue::Literal(RustLiteral::Str("Bob".into())),
                    },
                ],
            }],
        };
        let params = make_params(1);
        let prog = compile_upsert_scheme(&stmt, &params).unwrap();
        let s = write_scheme(&prog.body);
        let reparsed = spier_scheme::parse(&s).unwrap();
        assert_eq!(reparsed, prog.body);
    }
}
