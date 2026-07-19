use std::collections::{HashMap, HashSet};
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

/// Build a boolean tree SExpr from range bounds.

fn bound_to_sexpr(bv: &spier_datalog::BoundValue) -> SExpr {
    match bv {
        spier_datalog::BoundValue::Int(n) => SExpr::Int(*n),
        spier_datalog::BoundValue::Float(f) => SExpr::Float(*f),
        spier_datalog::BoundValue::Str(s) | spier_datalog::BoundValue::Attr(s) => SExpr::Str(s.clone()),
        spier_datalog::BoundValue::ResolvedAttr(id, _, _, _) => SExpr::Int(*id as i64),
        spier_datalog::BoundValue::Param(idx) => SExpr::List(vec![
            SExpr::Symbol("param".into()),
            SExpr::Int(*idx as i64),
        ]),
        spier_datalog::BoundValue::Var(name) => SExpr::Symbol(format!("?{name}")),
        spier_datalog::BoundValue::Missing(_) => SExpr::Symbol("_".into()),
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
        build_projection(plan, total_proj_len, &constant_indices)
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

    let eid_get = SExpr::Symbol(target_evar.to_string());

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

    let mut leaf_stmts: Vec<SExpr> = Vec::new();
    let mut first_eid_get: Option<SExpr> = None;

    for clause in &update_stmt.clauses {
        let clause_evar = format!("_e_{}", clause.alias.to_lowercase());
        let eid_get = SExpr::Symbol(clause_evar.clone());
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
                    SExpr::Symbol(ref_evar)
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
    }

    // Build per-depth range trees from plan.range_bounds.
    let depth_ranges: HashMap<usize, SExpr> = plan.range_bounds.iter()
        .filter_map(|(var_name, branches)| {
            let depth = ordered_vars.iter().position(|v| v == var_name)?;
            let range_sexpr = build_range_tree(branches);
            Some((depth, range_sexpr))
        })
        .collect();

    // Pre-compute bind value expressions per clause. The key is the position
    // name (e.g. "a"/"e"/"v") — used only to look up the precomputed expr.
    // The *ordering* of emission is decided by the planner via
    // `bound_positions_before` / `all_bound_positions`, never by peeking at
    // idx_order here.
    let mut bind_vals: Vec<HashMap<String, SExpr>> = vec![HashMap::new(); plan.iter_plans.len()];
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        for (pos_name, pv) in &ip.bound_ints {
            let val_expr = match pv {
                PlanValue::Value(Value::Text(name)) if pos_name == "a" => {
                    SExpr::List(vec![
                        SExpr::Symbol("intern-a".into()),
                        SExpr::Str(name.clone()),
                    ])
                }
                _ => plan_value_to_sexpr(pv),
            };
            bind_vals[ip_idx].insert(pos_name.clone(), val_expr);
        }
    }

    // Build list of operations (outermost first) for the triejoin.
    //
    // Each op is a "body transformer" expressed via a `__BODY__` placeholder:
    // - bound attr becomes:  (begin (scanner-push s val) __BODY__ (scanner-pop s))
    // - iteration becomes:   (scanner-iterate (scanners) (var) [:ranges (ranges-create r)]
    //                                   (begin (scanner-push s0 var) ... __BODY__ (scanner-pop s0) ...))
    //
    // The outer build wraps the leaf_body in these templates inside-out by
    // substituting __BODY__ (via `replace_body_placeholder`).
    let mut ops: Vec<SExpr> = Vec::new();

    // Track which bound values have been emitted as scanner-push.
    let mut bound_emitted: Vec<HashSet<String>> = vec![HashSet::new(); plan.iter_plans.len()];
    // Track current position per scanner in idx_order. Each push/iterate advances.
    let mut scan_pos: Vec<usize> = vec![0; plan.iter_plans.len()];

    // Process each depth in forward order (outermost first).
    for depth in 0..num_depths {
        let var_name = &ordered_vars[depth];

        // Collect scanner refs per clause for this depth.
        let mut scanners: Vec<SExpr> = Vec::new();
        for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
            if ip.var_depths.iter().any(|&(d, _)| d == depth) {
                scanners.push(SExpr::Symbol(format!("s{ip_idx}")));
            }
        }
        if scanners.is_empty() {
            continue;
        }

        // Emit scanner-push for bound values BEFORE this depth's variable.
        for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
            if !ip.var_depths.iter().any(|&(d, _)| d == depth) {
                continue;
            }
            // Determine the variable's position name for this scanner at this depth.
            let var_pos = ip.var_depths.iter()
                .find(|(d, _)| *d == depth)
                .map(|(_, p)| p.as_str())
                .unwrap_or("");

            for (pos_name, _pv) in ip.bound_positions_before(depth) {
                if bound_emitted[ip_idx].contains(&pos_name) {
                    continue;
                }
                if let Some(val_expr) = bind_vals[ip_idx].get(&pos_name) {
                    bound_emitted[ip_idx].insert(pos_name.clone());
                    scan_pos[ip_idx] += 1;
                    ops.push(SExpr::List(vec![
                        SExpr::Symbol("begin".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-push".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                            val_expr.clone(),
                        ]),
                        SExpr::Symbol("__BODY__".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-pop".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                        ]),
                    ]));
                }
            }

            // The scanner needs to be at the variable's physical position in
            // idx_order to iterate it. If `scan_pos` is lagging (because
            // intermediate slots are not bound by this scanner), emit proxy
            // scanner-iterates for the gap positions.
            let target_idx = ip.idx_order.iter()
                .position(|s| s == var_pos)
                .unwrap_or(ip.idx_order.len());
            while scan_pos[ip_idx] < target_idx {
                let gap_slot = &ip.idx_order[scan_pos[ip_idx]];
                if bound_emitted[ip_idx].contains(gap_slot) || ip.var_depths.iter().any(|(d, s)| *d <= depth && s == gap_slot) {
                    // Already handled or will be handled at a different depth.
                    scan_pos[ip_idx] += 1;
                    continue;
                }
                let gap_var = format!("_skip_{}_{}", gap_slot, ip.index_name.to_ascii_lowercase());
                scan_pos[ip_idx] += 1;
                ops.push(SExpr::List(vec![
                    SExpr::Symbol("scanner-iterate".into()),
                    SExpr::List(vec![SExpr::Symbol(format!("s{ip_idx}"))]),
                    SExpr::List(vec![SExpr::Symbol(gap_var.clone())]),
                    SExpr::List(vec![
                        SExpr::Symbol("begin".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-push".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                            SExpr::Symbol(gap_var.clone()),
                        ]),
                        SExpr::Symbol("__BODY__".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-pop".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                        ]),
                    ]),
                ]));
            }
        }

        // Emit scanner-iterate for this variable.
        let ranges_tree = depth_ranges.get(&depth).cloned().unwrap_or(SExpr::List(vec![]));
        let ranges_is_empty = matches!(&ranges_tree, SExpr::List(items) if items.is_empty());

        // Body of scanner-iterate: (begin (scanner-push s0 var) ... __BODY__ (scanner-pop s0) ...)
        let mut inner_items: Vec<SExpr> = vec![SExpr::Symbol("begin".into())];
        for s in &scanners {
            inner_items.push(SExpr::List(vec![
                SExpr::Symbol("scanner-push".into()),
                s.clone(),
                SExpr::Symbol(var_name.clone()),
            ]));
        }
        inner_items.push(SExpr::Symbol("__BODY__".into()));
        for s in &scanners {
            inner_items.push(SExpr::List(vec![
                SExpr::Symbol("scanner-pop".into()),
                s.clone(),
            ]));
        }

        let mut iter_items: Vec<SExpr> = vec![
            SExpr::Symbol("scanner-iterate".into()),
            SExpr::List(scanners.clone()),
            SExpr::List(vec![SExpr::Symbol(var_name.clone())]),
        ];
        // Synthetic var (same-var confirmation): força range (= source_var).
        // Prevalece sobre qualquer range vinda de depth_ranges (synthetics
        // não tem ranges externas hoje).
        let synthetic = plan.synthetic_vars.iter().find(|s| s.name == *var_name);
        if let Some(synth) = synthetic {
            iter_items.push(SExpr::Symbol(":ranges".into()));
            iter_items.push(SExpr::List(vec![
                SExpr::Symbol("ranges-create".into()),
                SExpr::List(vec![
                    SExpr::Symbol("=".into()),
                    SExpr::Symbol(synth.source_var.clone()),
                ]),
            ]));
        } else if !ranges_is_empty {
            iter_items.push(SExpr::Symbol(":ranges".into()));
            iter_items.push(SExpr::List(vec![
                SExpr::Symbol("ranges-create".into()),
                ranges_tree,
            ]));
        }
        iter_items.push(SExpr::List(inner_items));
        ops.push(SExpr::List(iter_items));
    }

    // After all scanner-iterates, emit remaining scanner-push / scanner-iterate
    // for bound values that were NOT before any variable's position (trailing).
    // Rule: the LAST un-emitted bound position per scanner becomes a
    // scanner-iterate with :ranges (ranges-create (= val)) instead of a
    // plain scanner-push. This ensures even fully-bound lookups (no free
    // variables) have an existence check — the iterate filters out the body
    // if the datom doesn't exist.
    for (ip_idx, ip) in plan.iter_plans.iter().enumerate() {
        let trailing: Vec<(String, SExpr)> = ip
            .all_bound_positions()
            .into_iter()
            .filter_map(|(pos_name, _pv)| {
                if bound_emitted[ip_idx].contains(&pos_name) {
                    None
                } else {
                    bind_vals[ip_idx]
                        .get(&pos_name)
                        .map(|v| (pos_name.clone(), v.clone()))
                }
            })
            .collect();
        if trailing.is_empty() {
            continue;
        }
        let last_idx = trailing.len() - 1;
        for (i, (pos_name, val_expr)) in trailing.into_iter().enumerate() {
            bound_emitted[ip_idx].insert(pos_name.clone());
            if i == last_idx {
                // Last position → scanner-iterate with equality range
                let var_name = format!("_{pos_name}_trail");
                ops.push(SExpr::List(vec![
                    SExpr::Symbol("scanner-iterate".into()),
                    SExpr::List(vec![SExpr::Symbol(format!("s{ip_idx}"))]),
                    SExpr::List(vec![SExpr::Symbol(var_name.clone())]),
                    SExpr::Symbol(":ranges".into()),
                    SExpr::List(vec![
                        SExpr::Symbol("ranges-create".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("=".into()),
                            val_expr.clone(),
                        ]),
                    ]),
                    SExpr::List(vec![
                        SExpr::Symbol("begin".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-push".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                            SExpr::Symbol(var_name),
                        ]),
                        SExpr::Symbol("__BODY__".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-pop".into()),
                            SExpr::Symbol(format!("s{ip_idx}")),
                        ]),
                    ]),
                ]));
            } else {
                ops.push(SExpr::List(vec![
                    SExpr::Symbol("begin".into()),
                    SExpr::List(vec![
                        SExpr::Symbol("scanner-push".into()),
                        SExpr::Symbol(format!("s{ip_idx}")),
                        val_expr.clone(),
                    ]),
                    SExpr::Symbol("__BODY__".into()),
                    SExpr::List(vec![
                        SExpr::Symbol("scanner-pop".into()),
                        SExpr::Symbol(format!("s{ip_idx}")),
                    ]),
                ]));
            }
        }
    }

    // Build the nested Scheme: start from leaf_body, apply ops in reverse order.
    let mut body = leaf_body;
    for op in ops.iter().rev() {
        body = replace_body_placeholder(op, &body);
    }

    // Handle fully-bound lookup patterns (from the planner). When all (e, a, v)
    // slots are constants, the planner produces a "lookup" with no iter_plans.
    // We generate a scanner-iterate with equality ranges to check existence.
    for pattern in &plan.lookups {
        if !pattern.is_lookup() { continue; }
        let t_param = match &pattern.t {
            spier_datalog::DatalogSlot::Var(name) => name.clone(),
            _ => "_t".to_string(),
        };
        let e_val = match &pattern.e {
            spier_datalog::DatalogSlot::Const(bv) => bound_to_sexpr(bv),
            _ => continue,
        };
        let a_val = match &pattern.a {
            spier_datalog::DatalogSlot::Const(bv) => bound_to_sexpr(bv),
            _ => continue,
        };
        let v_val = match &pattern.v {
            spier_datalog::DatalogSlot::Const(bv) => bound_to_sexpr(bv),
            _ => continue,
        };
        // Determine the best index: use the bound attr to decide.
        // Default to EAVT (always works for point lookups).
        let probe_s_var = "_s_probe".to_string();
        body = SExpr::List(vec![
            SExpr::Symbol("let*".into()),
            SExpr::List(vec![
                SExpr::List(vec![
                    SExpr::Symbol(probe_s_var.clone()),
                    SExpr::List(vec![SExpr::Symbol("scanner-open".into()), SExpr::Str("EAVT".into())]),
                ]),
            ]),
            SExpr::List(vec![
                SExpr::Symbol("begin".into()),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-push".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                    e_val,
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-push".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                    a_val,
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-push".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                    v_val,
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-iterate".into()),
                    SExpr::List(vec![SExpr::Symbol(probe_s_var.clone())]),
                    SExpr::List(vec![SExpr::Symbol(t_param.clone())]),
                    SExpr::List(vec![
                        SExpr::Symbol("begin".into()),
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-push".into()),
                            SExpr::Symbol(probe_s_var.clone()),
                            SExpr::Symbol(t_param.clone()),
                        ]),
                        body,
                        SExpr::List(vec![
                            SExpr::Symbol("scanner-pop".into()),
                            SExpr::Symbol(probe_s_var.clone()),
                        ]),
                    ]),
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-pop".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-pop".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                ]),
                SExpr::List(vec![
                    SExpr::Symbol("scanner-pop".into()),
                    SExpr::Symbol(probe_s_var.clone()),
                ]),
            ]),
        ]);
    }

    let full_body = if scanner_bindings.is_empty() {
        body
    } else {
        SExpr::List(vec![
            SExpr::Symbol("let*".into()),
            SExpr::List(scanner_bindings),
            body,
        ])
    };

    // Flatten right-nested begins left by the __BODY__ substitution chain.
    // Evaluator handles either form equivalently; flat is easier to read in
    // EXPLAIN and trace.
    let full_body = flatten_begins(full_body);

    let meta = SelectSchemeMeta {
        num_vars: var_names_list.len(),
        depth_var_pairs,
        same_var_constraints: Vec::new(),
    };

    Ok((SchemeProgram::new(full_body).with_param_count(0), meta))
}

/// Recursively replace Symbol("__BODY__") with `replacement` in the given SExpr.
fn replace_body_placeholder(expr: &SExpr, replacement: &SExpr) -> SExpr {
    match expr {
        SExpr::Symbol(s) if s == "__BODY__" => replacement.clone(),
        SExpr::List(items) => SExpr::List(items.iter().map(|item| replace_body_placeholder(item, replacement)).collect()),
        other => other.clone(),
    }
}

/// Flatten right/left-nested `(begin ...)` forms: a begin whose last (or only)
/// non-head item is itself a begin gets inlined. Idempotent on already-flat
/// begins. Preserves begins inside other forms (scanner-iterate, when, let*,
/// etc.) — those are structurally required by the host form.
///
/// Rationale: `replace_body_placeholder` chains produce right-nested begins
/// like `(begin A (begin B (begin C D)))`. The evaluator handles either form
/// equivalently, but a flat begin is easier to read in EXPLAIN and to debug.
fn flatten_begins(expr: SExpr) -> SExpr {
    match expr {
        SExpr::List(items) => {
            // Recurse top-down so inner begins are already flat when the
            // outer begin inspects them.
            let items: Vec<SExpr> = items.into_iter().map(flatten_begins).collect();
            if let Some(SExpr::Symbol(s)) = items.first() {
                if s == "begin" {
                    let mut result: Vec<SExpr> = vec![items[0].clone()];
                    for item in items.into_iter().skip(1) {
                        match item {
                            SExpr::List(inner)
                                if matches!(inner.first(),
                                    Some(SExpr::Symbol(s)) if s == "begin") =>
                            {
                                result.extend(inner.into_iter().skip(1));
                            }
                            other => result.push(other),
                        }
                    }
                    return SExpr::List(result);
                }
            }
            SExpr::List(items)
        }
        other => other,
    }
}

fn build_projection(
    plan: &QueryPlanResult,
    total_proj_len: usize,
    constant_indices: &HashMap<usize, PlanValue>,
) -> SExpr {
    let mut proj_args: Vec<SExpr> = Vec::new();
    let mut fv_idx = 0;
    let find_vars: Vec<String> = plan.find_vars.iter().map(|fv| match fv {
        spier_datalog::FindVar::Var(n) => n.clone(),
        spier_datalog::FindVar::Const(n, _) => n.clone(),
    }).collect();

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
        let bind = SExpr::Symbol(var_name.clone());
        if plan.attr_vars.contains(var_name) {
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

    // Helper para construir SExpr::List de forma concisa nos testes abaixo.
    fn list(items: Vec<SExpr>) -> SExpr {
        SExpr::List(items)
    }
    fn sym(s: &str) -> SExpr {
        SExpr::Symbol(s.into())
    }
    fn begin(items: Vec<SExpr>) -> SExpr {
        let mut v = vec![sym("begin")];
        v.extend(items);
        list(v)
    }

    #[test]
    fn flatten_begins_right_nested() {
        // (begin A (begin B C)) → (begin A B C)
        let input = begin(vec![sym("A"), begin(vec![sym("B"), sym("C")])]);
        let expected = begin(vec![sym("A"), sym("B"), sym("C")]);
        assert_eq!(flatten_begins(input), expected);
    }

    #[test]
    fn flatten_begins_deep_recursion() {
        // (begin A (begin B (begin C D))) → (begin A B C D)
        let input = begin(vec![
            sym("A"),
            begin(vec![sym("B"), begin(vec![sym("C"), sym("D")])]),
        ]);
        let expected = begin(vec![sym("A"), sym("B"), sym("C"), sym("D")]);
        assert_eq!(flatten_begins(input), expected);
    }

    #[test]
    fn flatten_begins_left_nested() {
        // (begin (begin A B) C) → (begin A B C)
        let input = begin(vec![begin(vec![sym("A"), sym("B")]), sym("C")]);
        let expected = begin(vec![sym("A"), sym("B"), sym("C")]);
        assert_eq!(flatten_begins(input), expected);
    }

    #[test]
    fn flatten_begins_idempotent_on_flat() {
        // (begin A B C) → (begin A B C)
        let input = begin(vec![sym("A"), sym("B"), sym("C")]);
        let result = flatten_begins(input.clone());
        assert_eq!(result, input);
    }

    #[test]
    fn flatten_begins_preserves_inside_non_begin() {
        // (scanner-iterate (s0) (x) (begin A B)) → inalterado
        // O begin interno é body do scanner-iterate, NÃO deve ser achatado.
        let input = list(vec![
            sym("scanner-iterate"),
            list(vec![sym("s0")]),
            list(vec![sym("x")]),
            begin(vec![sym("A"), sym("B")]),
        ]);
        let result = flatten_begins(input.clone());
        assert_eq!(result, input);
    }

    #[test]
    fn flatten_begins_preserves_inside_when() {
        // (when cond (begin A B)) → inalterado
        let input = list(vec![
            sym("when"),
            sym("cond"),
            begin(vec![sym("A"), sym("B")]),
        ]);
        let result = flatten_begins(input.clone());
        assert_eq!(result, input);
    }

    #[test]
    fn flatten_begins_nested_inside_let_star() {
        // (let* (...) (begin A (begin B C))) → (let* (...) (begin A B C))
        // O begin dentro do let* deve ser achatado (recursão top-down).
        let input = list(vec![
            sym("let*"),
            list(vec![]),
            begin(vec![sym("A"), begin(vec![sym("B"), sym("C")])]),
        ]);
        let expected = list(vec![
            sym("let*"),
            list(vec![]),
            begin(vec![sym("A"), sym("B"), sym("C")]),
        ]);
        assert_eq!(flatten_begins(input), expected);
    }
}
