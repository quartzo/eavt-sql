use std::collections::{HashMap, HashSet};

use dynspire_commons::datalog::*;
use dynspire_commons::sql_parse::*;
use dynspire_commons::value::Value;

// ── Alias state ─────────────────────────────────────────────────────

struct AliasState {
    alias: String,
    e_var: String,
    attrs: Vec<String>,
    has_attr_wild: bool,
    has_val_wild: bool,
    tx_requested: bool,
    tx_var: String,
    added_requested: bool,
    e_bound_value: Option<BoundValue>,
    attr_values: HashMap<String, BoundValue>,
    attr_bound_value: Option<BoundValue>,
    val_bound_value: Option<BoundValue>,
    range_conds: HashMap<String, Vec<Vec<(String, BoundValue)>>>,
}

impl AliasState {
    fn new(alias: String) -> Self {
        Self {
            e_var: format!("_e_{}", alias),
            tx_var: format!("_t_{}", alias),
            alias,
            attrs: Vec::new(),
            has_attr_wild: false,
            has_val_wild: false,
            tx_requested: false,
            added_requested: false,
            e_bound_value: None,
            attr_values: HashMap::new(),
            attr_bound_value: None,
            val_bound_value: None,
            range_conds: HashMap::new(),
        }
    }

    fn v_var(&self, attr: &str) -> String {
        format!("_v_{}_{}", self.alias, safe_attr_name(attr))
    }

    fn a_var(&self) -> String { format!("_a_{}", self.alias) }
    fn val_var(&self) -> String { format!("_vv_{}", self.alias) }
    fn added_var(&self) -> String { format!("_added_{}", self.alias) }
}

fn safe_attr_name(attr: &str) -> String {
    attr.replace('.', "_").replace(':', "_c_").replace('/', "_s_").replace('-', "_h_")
}

fn ensure_alias(aliases: &mut HashMap<String, AliasState>, name: &str) {
    aliases.entry(name.to_string()).or_insert_with(|| AliasState::new(name.to_string()));
}

fn slot_var(n: &str) -> DatalogSlot { DatalogSlot::Var(n.to_string()) }
fn slot_const(bv: BoundValue) -> DatalogSlot { DatalogSlot::Const(bv) }
fn slot_missing() -> DatalogSlot { DatalogSlot::Missing }

// ── Constant propagation ────────────────────────────────────────────

fn propagate_constants(aliases: &mut HashMap<String, AliasState>) {
    let bindings: Vec<(String, BoundValue)> = aliases.iter()
        .filter_map(|(_, st)| {
            if let Some(ref bv) = st.e_bound_value {
                if !matches!(bv, BoundValue::Var(_)) { return Some((st.e_var.clone(), bv.clone())); }
            }
            None
        }).collect();
    for (e_var, const_val) in &bindings {
        for (_, st) in aliases.iter_mut() {
            for val in st.attr_values.values_mut() {
                if let BoundValue::Var(ref name) = val {
                    if name == e_var { *val = const_val.clone(); }
                }
            }
            if let Some(ref mut bv) = st.e_bound_value {
                if let BoundValue::Var(ref name) = bv {
                    if name == e_var { *bv = const_val.clone(); }
                }
            }
        }
    }
}

// ── Slot construction ───────────────────────────────────────────────

fn e_slot(st: &AliasState) -> DatalogSlot {
    match &st.e_bound_value {
        Some(BoundValue::Var(name)) => slot_var(name),
        Some(bv) => slot_const(bv.clone()),
        None => slot_var(&st.e_var),
    }
}

fn wildcard_pattern(st: &AliasState, t_slot: &DatalogSlot) -> DatalogPattern {
    let e = e_slot(st);
    let a = match &st.attr_bound_value {
        Some(BoundValue::Var(name)) => slot_var(name),
        Some(bv) => slot_const(bv.clone()),
        None if st.has_attr_wild => slot_var(&st.a_var()),
        None => slot_missing(),
    };
    let v = match &st.val_bound_value {
        Some(BoundValue::Var(name)) => slot_var(name),
        Some(bv) => slot_const(bv.clone()),
        None if st.has_val_wild => slot_var(&st.val_var()),
        None => slot_missing(),
    };
    let added = if st.added_requested { slot_var(&st.added_var()) } else { slot_missing() };
    DatalogPattern { e, a, v, t: t_slot.clone(), added }
}

fn attr_pattern(st: &AliasState, attr: &str, t_slot: &DatalogSlot) -> DatalogPattern {
    let e = e_slot(st);
    let a = slot_const(BoundValue::Attr(attr.to_string()));
    let v = match st.attr_values.get(attr) {
        Some(BoundValue::Var(name)) => slot_var(name),
        Some(bv) => slot_const(bv.clone()),
        None => slot_var(&st.v_var(attr)),
    };
    let added = if st.added_requested { slot_var(&st.added_var()) } else { slot_missing() };
    DatalogPattern { e, a, v, t: t_slot.clone(), added }
}

fn build_where_patterns(aliases: &HashMap<String, AliasState>, star: bool, has_conditions: bool) -> Vec<DatalogPattern> {
    let mut patterns = Vec::new();
    if star && !has_conditions { return patterns; }
    let mut sorted_keys: Vec<&String> = aliases.keys().collect();
    sorted_keys.sort();

    for alias_name in &sorted_keys {
        let st = aliases.get(*alias_name).unwrap();
        let t_slot = if st.tx_requested { slot_var(&st.tx_var) } else { slot_missing() };

        if !has_conditions {
            if !st.attrs.is_empty() {
                for attr in &st.attrs { patterns.push(attr_pattern(st, attr, &t_slot)); }
            } else {
                patterns.push(wildcard_pattern(st, &t_slot));
            }
            continue;
        }
        if star {
            patterns.push(wildcard_pattern(st, &t_slot));
            for attr in &st.attrs { patterns.push(attr_pattern(st, attr, &t_slot)); }
        } else {
            let has_wild = st.has_attr_wild || st.has_val_wild
                || st.attr_bound_value.is_some() || st.val_bound_value.is_some()
                || (st.e_bound_value.is_some() && st.attrs.is_empty());
            if has_wild { patterns.push(wildcard_pattern(st, &t_slot)); }
            for attr in &st.attrs { patterns.push(attr_pattern(st, attr, &t_slot)); }
        }
    }
    patterns
}

// ── Param + literal extraction ──────────────────────────────────────

fn resolve_param(_params: &[Value], index: u32) -> BoundValue {
    BoundValue::Param(index)
}

fn extract_literal(lit: &RustLiteral) -> BoundValue {
    match lit {
        RustLiteral::Int(n) => BoundValue::Int(*n),
        RustLiteral::Float(f) => BoundValue::Float(*f),
        RustLiteral::Str(s) => if s.contains('.') { BoundValue::Attr(s.clone()) } else { BoundValue::Str(s.clone()) },
        RustLiteral::Bool(b) => BoundValue::Int(if *b { 1 } else { 0 }),
        RustLiteral::Bytes(b) => BoundValue::Str(format!("{:?}", b)),
    }
}

fn extract_right(right: &RustConditionRight, params: &[Value]) -> BoundValue {
    match right {
        RustConditionRight::Param(idx) => resolve_param(params, *idx),
        RustConditionRight::Literal(lit) => extract_literal(lit),
        RustConditionRight::Field(fr) => {
            if fr.field == "eid" { BoundValue::Var(format!("_e_{}", fr.alias)) }
            else if fr.field == "val" { BoundValue::Var(format!("_vv_{}", fr.alias)) }
            else if fr.field == "attr" { BoundValue::Var(format!("_a_{}", fr.alias)) }
            else { BoundValue::Var(format!("_v_{}_{}", fr.alias, safe_attr_name(&fr.field))) }
        }
        RustConditionRight::In(_) | RustConditionRight::Or(_) => BoundValue::Missing("compound".into()),
    }
}

// ── Plan IR ─────────────────────────────────────────────────────────

struct PlanIR {
    aliases: HashMap<String, AliasState>,
    find_vars: Vec<FindVar>,
    star: bool,
    exists_mode: bool,
    has_conditions: bool,
    history: bool,
}

fn build_plan_ir(stmt: &RustSelectStmt, params: &[Value]) -> Result<PlanIR, String> {
    let mut aliases: HashMap<String, AliasState> = HashMap::new();
    let mut where_aliases: HashSet<String> = HashSet::new();

    collect_aliases(stmt, &mut aliases, &mut where_aliases);
    let has_conditions = !stmt.conditions.is_empty();
    if has_conditions { process_conditions(stmt, params, &mut aliases)?; }

    for st in aliases.values() {
        if let Some(BoundValue::Missing(name)) = &st.e_bound_value { return Err(format!("missing parameter: {}", name)); }
        if let Some(BoundValue::Missing(name)) = &st.attr_bound_value { return Err(format!("missing parameter: {}", name)); }
        if let Some(BoundValue::Missing(name)) = &st.val_bound_value { return Err(format!("missing parameter: {}", name)); }
        for bv in st.attr_values.values() {
            if let BoundValue::Missing(name) = bv { return Err(format!("missing parameter: {}", name)); }
        }
    }

    propagate_constants(&mut aliases);
    let projections = process_projections(stmt, &mut aliases)?;

    let mut alias_e_vars: HashMap<String, String> = HashMap::new();
    for (_, st) in &aliases {
        alias_e_vars
            .entry(st.alias.clone())
            .or_insert_with(|| st.e_var.clone());
    }

    let find_vars = build_find_vars(stmt, &aliases, &alias_e_vars, &projections);

    if has_conditions && !stmt.star {
        for proj in &projections {
            if let Some((alias, _)) = proj {
                if !where_aliases.contains(alias) {
                    return Err(format!("alias {} in SELECT but not in WHERE", alias));
                }
            }
        }
    }

    Ok(PlanIR { aliases, find_vars, star: stmt.star, exists_mode: stmt.exists_mode, has_conditions, history: stmt.history })
}

fn collect_aliases(stmt: &RustSelectStmt, aliases: &mut HashMap<String, AliasState>, where_aliases: &mut HashSet<String>) {
    for cond in &stmt.conditions {
        match &cond.right {
            RustConditionRight::Or(branches) => {
                where_aliases.insert(cond.left.alias.clone());
                ensure_alias(aliases, &cond.left.alias);
                for branch in branches {
                    for inner in branch {
                        if let RustConditionRight::Field(fr) = &inner.value {
                            where_aliases.insert(fr.alias.clone());
                            ensure_alias(aliases, &fr.alias);
                        }
                    }
                }
            }
            RustConditionRight::In(_) => {
                where_aliases.insert(cond.left.alias.clone());
                ensure_alias(aliases, &cond.left.alias);
            }
            RustConditionRight::Field(fr) => {
                where_aliases.insert(cond.left.alias.clone());
                ensure_alias(aliases, &cond.left.alias);
                where_aliases.insert(fr.alias.clone());
                ensure_alias(aliases, &fr.alias);
            }
            _ => {
                where_aliases.insert(cond.left.alias.clone());
                ensure_alias(aliases, &cond.left.alias);
            }
        }
    }
    if stmt.conditions.is_empty() {
        for proj in &stmt.projections {
            if let Some(ref fr) = proj.field { ensure_alias(aliases, &fr.alias); }
        }
    }
}

fn process_conditions(stmt: &RustSelectStmt, params: &[Value], aliases: &mut HashMap<String, AliasState>) -> Result<(), String> {
    for cond in &stmt.conditions {
        match &cond.right {
            RustConditionRight::Or(branches) => process_or(&cond.left, branches, params, aliases)?,
            RustConditionRight::In(values) => process_in(&cond.left, values, params, aliases)?,
            _ => {
                let (la, lf) = (cond.left.alias.as_str(), cond.left.field.as_str());
                match cond.op.as_str() {
                    "=" => process_eq(la, lf, &cond.right, params, aliases)?,
                    ">" | "<" | ">=" | "<=" | "!=" => process_range(la, lf, &cond.op, &cond.right, params, aliases)?,
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

fn process_eq(la: &str, lf: &str, right: &RustConditionRight, params: &[Value], aliases: &mut HashMap<String, AliasState>) -> Result<(), String> {
    match lf {
        "eid" => match right {
            RustConditionRight::Param(idx) => { ensure_alias(aliases, la); aliases.get_mut(la).unwrap().e_bound_value = Some(resolve_param(params, *idx)); }
            RustConditionRight::Literal(lit) => { ensure_alias(aliases, la); aliases.get_mut(la).unwrap().e_bound_value = Some(extract_literal(lit)); }
            RustConditionRight::Field(fr) => {
                let (ra, rf) = (fr.alias.clone(), fr.field.clone());
                if rf == "eid" {
                    ensure_alias(aliases, la); ensure_alias(aliases, &ra);
                    let right_evar = aliases.get(&ra).unwrap().e_var.clone();
                    aliases.get_mut(la).unwrap().e_var = right_evar;
                } else {
                    ensure_alias(aliases, la); ensure_alias(aliases, &ra);
                    if !aliases.get(&ra).unwrap().attrs.contains(&rf) { aliases.get_mut(&ra).unwrap().attrs.push(rf.clone()); }
                    let rv = aliases.get(&ra).unwrap().v_var(&rf);
                    aliases.get_mut(la).unwrap().e_bound_value = Some(BoundValue::Var(rv));
                }
            }
            _ => {}
        },
        "attr" => { ensure_alias(aliases, la); match right {
            RustConditionRight::Literal(lit) => { aliases.get_mut(la).unwrap().attr_bound_value = Some(extract_literal(lit)); }
            _ => { aliases.get_mut(la).unwrap().has_attr_wild = true; }
        }},
        "val" => { ensure_alias(aliases, la); match right {
            RustConditionRight::Literal(lit) => { aliases.get_mut(la).unwrap().val_bound_value = Some(extract_literal(lit)); }
            _ => { aliases.get_mut(la).unwrap().has_val_wild = true; }
        }},
        "tx" => {
            ensure_alias(aliases, la);
            aliases.get_mut(la).unwrap().tx_requested = true;
            if let RustConditionRight::Field(fr) = right {
                let (ra, rf) = (fr.alias.clone(), fr.field.clone());
                ensure_alias(aliases, &ra);
                if rf == "eid" {
                    let tv = aliases.get(la).unwrap().tx_var.clone();
                    aliases.get_mut(&ra).unwrap().e_var = tv;
                } else if rf == "tx" {
                    aliases.get_mut(&ra).unwrap().tx_requested = true;
                    let left_tv = aliases.get(la).unwrap().tx_var.clone();
                    let right_tv = aliases.get(&ra).unwrap().tx_var.clone();
                    let new_var = left_tv.min(right_tv);
                    aliases.get_mut(la).unwrap().tx_var = new_var.clone();
                    aliases.get_mut(&ra).unwrap().tx_var = new_var;
                }
            }
        },
        "added" => {
            ensure_alias(aliases, la);
            aliases.get_mut(la).unwrap().added_requested = true;
        },
        _ => {
            validate_attr_name(lf)?;
            ensure_alias(aliases, la);
            let field_str = lf.to_string();
            if !aliases.get(la).unwrap().attrs.contains(&field_str) { aliases.get_mut(la).unwrap().attrs.push(field_str.clone()); }
            match right {
                RustConditionRight::Field(fr) => {
                    let (ra, rf) = (fr.alias.clone(), fr.field.clone());
                    ensure_alias(aliases, &ra);
                    match rf.as_str() {
                        "eid" => { let ev = aliases.get(&ra).unwrap().e_var.clone(); aliases.get_mut(la).unwrap().attr_values.insert(field_str, BoundValue::Var(ev)); }
                        "val" => { let vv = aliases.get(&ra).unwrap().val_var(); aliases.get_mut(la).unwrap().attr_values.insert(field_str, BoundValue::Var(vv)); aliases.get_mut(la).unwrap().has_val_wild = true; }
                        "attr" => { let av = aliases.get(&ra).unwrap().a_var(); aliases.get_mut(la).unwrap().attr_values.insert(field_str, BoundValue::Var(av)); aliases.get_mut(&ra).unwrap().has_attr_wild = true; }
                        _ => { if !aliases.get(&ra).unwrap().attrs.contains(&rf) { aliases.get_mut(&ra).unwrap().attrs.push(rf.clone()); } let rv = aliases.get(&ra).unwrap().v_var(&rf); aliases.get_mut(la).unwrap().attr_values.insert(field_str, BoundValue::Var(rv)); }
                    }
                }
                RustConditionRight::Param(idx) => { aliases.get_mut(la).unwrap().attr_values.insert(field_str, resolve_param(params, *idx)); }
                RustConditionRight::Literal(lit) => { aliases.get_mut(la).unwrap().attr_values.insert(field_str, extract_literal(lit)); }
                _ => {}
            }
        }
    }
    Ok(())
}

fn process_range(la: &str, lf: &str, op: &str, right: &RustConditionRight, params: &[Value], aliases: &mut HashMap<String, AliasState>) -> Result<(), String> {
    if matches!(lf, "attr" | "val" | "tx") { return Ok(()); }
    ensure_alias(aliases, la);
    if lf == "eid" {
        let evar = aliases.get(la).unwrap().e_var.clone();
        let bv = extract_right(right, params);
        let entry = aliases.get_mut(la).unwrap().range_conds.entry(evar).or_default();
        if entry.is_empty() {
            entry.push(vec![(op.to_string(), bv)]);
        } else {
            entry[0].push((op.to_string(), bv));
        }
        return Ok(());
    }
    validate_attr_name(lf)?;
    let field_str = lf.to_string();
    if !aliases.get(la).unwrap().attrs.contains(&field_str) { aliases.get_mut(la).unwrap().attrs.push(field_str.clone()); }
    let bv = extract_right(right, params);
    let entry = aliases.get_mut(la).unwrap().range_conds.entry(field_str).or_default();
    if entry.is_empty() {
        entry.push(vec![(op.to_string(), bv)]);
    } else {
        entry[0].push((op.to_string(), bv));
    }
    Ok(())
}

fn process_in(left: &RustFieldRef, values: &[RustConditionRight], params: &[Value], aliases: &mut HashMap<String, AliasState>) -> Result<(), String> {
    let (la, lf) = (left.alias.as_str(), left.field.as_str());
    if matches!(lf, "attr" | "val" | "tx") { return Ok(()); }
    ensure_alias(aliases, la);
    let target = if lf == "eid" {
        aliases.get(la).unwrap().e_var.clone()
    } else {
        validate_attr_name(lf)?;
        let field_str = lf.to_string();
        if !aliases.get(la).unwrap().attrs.contains(&field_str) { aliases.get_mut(la).unwrap().attrs.push(field_str.clone()); }
        field_str
    };
    let conds: Vec<(String, BoundValue)> = values.iter().map(|v| ("in".to_string(), extract_right(v, params))).collect();
    aliases.get_mut(la).unwrap().range_conds.entry(target).or_default().push(conds);
    Ok(())
}

fn process_or(left: &RustFieldRef, branches: &[Vec<RustOrBranchItem>], params: &[Value], aliases: &mut HashMap<String, AliasState>) -> Result<(), String> {
    let (alias, field) = (left.alias.clone(), left.field.clone());
    if matches!(field.as_str(), "attr" | "val" | "tx") { return Err(format!("OR not supported on {}", field)); }
    ensure_alias(aliases, &alias);
    let target = if field == "eid" { aliases.get(&alias).unwrap().e_var.clone() } else { validate_attr_name(&field)?; field.clone() };
    for branch in branches {
        for inner in branch {
            if inner.left.alias != alias || inner.left.field != field {
                return Err(format!("OR requires same (alias, field), got {}.{} vs {}.{}", inner.left.alias, inner.left.field, alias, field));
            }
            if let RustConditionRight::Field(_) = &inner.value {
                return Err("OR with join conditions (= other.field) is not supported".into());
            }
        }
    }
    if field != "eid" {
        if !aliases.get(&alias).unwrap().attrs.contains(&field) { aliases.get_mut(&alias).unwrap().attrs.push(field.clone()); }
    }
    for branch in branches {
        let mut conds = Vec::new();
        for inner in branch {
            match &inner.value {
                RustConditionRight::In(values) => { for v in values { conds.push(("in".to_string(), extract_right(v, params))); } }
                RustConditionRight::Field(_) => { return Err("OR with join conditions (= other.field) is not supported".into()); }
                other => { let bv = extract_right(other, params); let op = if inner.op == "=" { "in".to_string() } else { inner.op.clone() }; conds.push((op, bv)); }
            }
        }
        aliases.get_mut(&alias).unwrap().range_conds.entry(target.clone()).or_default().push(conds);
    }
    Ok(())
}

fn validate_attr_name(field: &str) -> Result<(), String> {
    if !field.contains('.') {
        return Err(format!(
            "attribute name must include namespace (e.g. 'company.name'), got {:?}",
            field
        ));
    }
    Ok(())
}

fn process_projections(stmt: &RustSelectStmt, aliases: &mut HashMap<String, AliasState>) -> Result<Vec<Option<(String, String)>>, String> {
    let mut projections = Vec::new();
    if stmt.star { return Ok(projections); }
    for proj in &stmt.projections {
        if let Some(ref fr) = proj.field {
            ensure_alias(aliases, &fr.alias);
            let st = aliases.get_mut(&fr.alias).unwrap();
            match fr.field.as_str() {
                "attr" => st.has_attr_wild = true,
                "val" => st.has_val_wild = true,
                "tx" => st.tx_requested = true,
                "added" => st.added_requested = true,
                "eid" => {}
                _ => { validate_attr_name(&fr.field)?; if !st.attrs.contains(&fr.field) { st.attrs.push(fr.field.clone()); } }
            }
            projections.push(Some((fr.alias.clone(), fr.field.clone())));
        } else { projections.push(None); }
    }
    Ok(projections)
}

fn build_find_vars(stmt: &RustSelectStmt, aliases: &HashMap<String, AliasState>, alias_e_vars: &HashMap<String, String>, projections: &[Option<(String, String)>]) -> Vec<FindVar> {
    if stmt.star {
        if let Some(first_alias) = aliases.keys().min() {
            let st = aliases.get(first_alias).unwrap();
            let mut star_fvs = Vec::new();

            match &st.e_bound_value {
                Some(bv) if !matches!(bv, BoundValue::Var(_)) => {
                    star_fvs.push(FindVar::Const(st.e_var.clone(), bv.clone()));
                }
                _ => {
                    star_fvs.push(FindVar::Var(st.e_var.clone()));
                }
            }

            match &st.attr_bound_value {
                Some(bv) => {
                    star_fvs.push(FindVar::Const(st.a_var(), bv.clone()));
                }
                None => {
                    star_fvs.push(FindVar::Var(st.a_var()));
                }
            }

            match &st.val_bound_value {
                Some(bv) if !matches!(bv, BoundValue::Var(_)) => {
                    star_fvs.push(FindVar::Const(st.val_var(), bv.clone()));
                }
                _ => {
                    star_fvs.push(FindVar::Var(st.val_var()));
                }
            }

            return star_fvs;
        }
        return vec![];
    }

    let mut find_vars = Vec::new();
    for (i, proj) in projections.iter().enumerate() {
        if let Some((alias, field)) = proj {
            let st = aliases.get(alias);
            match field.as_str() {
                "eid" => {
                    let var_name = alias_e_vars
                        .get(alias)
                        .cloned()
                        .unwrap_or_else(|| format!("_e_{}", alias));
                    if let Some(s) = st {
                        if let Some(ref bv) = s.e_bound_value {
                            if !matches!(bv, BoundValue::Var(_)) {
                                find_vars.push(FindVar::Const(var_name, bv.clone()));
                                continue;
                            }
                        }
                    }
                    find_vars.push(FindVar::Var(var_name));
                }
                "tx" => find_vars.push(FindVar::Var(format!("_t_{}", alias))),
                "added" => find_vars.push(FindVar::Var(format!("_added_{}", alias))),
                "attr" => {
                    let var_name = format!("_a_{}", alias);
                    if let Some(s) = st {
                        if let Some(ref bv) = s.attr_bound_value {
                            find_vars.push(FindVar::Const(var_name, bv.clone()));
                            continue;
                        }
                    }
                    find_vars.push(FindVar::Var(var_name));
                }
                "val" => {
                    let var_name = format!("_vv_{}", alias);
                    if let Some(s) = st {
                        if let Some(ref bv) = s.val_bound_value {
                            if !matches!(bv, BoundValue::Var(_)) {
                                find_vars.push(FindVar::Const(var_name, bv.clone()));
                                continue;
                            }
                        }
                    }
                    find_vars.push(FindVar::Var(var_name));
                }
                _ => {
                    let var_name = format!("_v_{}_{}", alias, safe_attr_name(field));
                    if let Some(s) = st {
                        if let Some(bv) = s.attr_values.get(field) {
                            if !matches!(bv, BoundValue::Var(_)) {
                                find_vars.push(FindVar::Const(var_name, bv.clone()));
                                continue;
                            }
                        }
                    }
                    find_vars.push(FindVar::Var(var_name));
                }
            }
        } else {
            let bv = stmt.projections.get(i)
                .and_then(|p| p.literal.as_ref())
                .map(|lit| match lit {
                    RustLiteral::Int(n) => BoundValue::Int(*n),
                    RustLiteral::Float(f) => BoundValue::Float(*f),
                    RustLiteral::Str(s) => BoundValue::Str(s.clone()),
                    _ => BoundValue::Int(1),
                })
                .unwrap_or(BoundValue::Int(1));
            find_vars.push(FindVar::Const(format!("_lit_{i}"), bv));
        }
    }
    find_vars
}

// ── Star expansion ──────────────────────────────────────────────────

fn expand_star(mut sel: RustSelectStmt) -> RustSelectStmt {
    if !sel.star {
        return sel;
    }

    let alias = sel
        .conditions
        .first()
        .map(|c| c.left.alias.to_lowercase())
        .unwrap_or_else(|| "d1".to_string());

    if sel.history {
        sel.projections = vec![
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "eid".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "attr".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "val".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "tx".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias, field: "added".to_string() }), literal: None },
        ];
    } else {
        sel.projections = vec![
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "eid".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias: alias.clone(), field: "attr".to_string() }), literal: None },
            RustProjection { field: Some(RustFieldRef { alias, field: "val".to_string() }), literal: None },
        ];
    }
    sel.star = false;
    sel
}

// ── Public entry point ──────────────────────────────────────────────

fn eliminate_dead_e_vars(
    patterns: &mut [DatalogPattern],
    find_vars: &[FindVar],
    range_bounds: &HashMap<String, Vec<Vec<(String, BoundValue)>>>,
) {
    let mut e_count: HashMap<String, usize> = HashMap::new();
    let mut other_count: HashMap<String, usize> = HashMap::new();

    for fv in find_vars {
        let name = match fv {
            FindVar::Var(n) | FindVar::Const(n, _) => n,
        };
        *other_count.entry(name.clone()).or_default() += 1;
    }
    for name in range_bounds.keys() {
        *other_count.entry(name.clone()).or_default() += 1;
    }
    for p in patterns.iter() {
        if let DatalogSlot::Var(name) = &p.e {
            *e_count.entry(name.clone()).or_default() += 1;
        }
        for slot in [&p.a, &p.v, &p.t, &p.added] {
            if let DatalogSlot::Var(name) = slot {
                *other_count.entry(name.clone()).or_default() += 1;
            }
        }
    }

    for p in patterns.iter_mut() {
        let dead = match &p.e {
            DatalogSlot::Var(name) => {
                let has_other_var = p.a.is_var() || p.v.is_var() || p.t.is_var() || p.added.is_var();
                e_count.get(name).copied().unwrap_or(0) == 1
                    && other_count.get(name).copied().unwrap_or(0) == 0
                    && has_other_var
            }
            _ => false,
        };
        if dead {
            p.e = DatalogSlot::Missing;
        }
    }
}

pub fn build_datalog_ir(stmt: RustStmt, params: &[Value]) -> Result<DatalogIR, String> {
    let sel = match stmt {
        RustStmt::Select(s) | RustStmt::DatalogSelect(s) => s,
        _ => return Err("Datalog IR only supports SELECT".into()),
    };
    let sel = expand_star(sel);
    let ir = build_plan_ir(&sel, params)?;
    let mut patterns = build_where_patterns(&ir.aliases, ir.star, ir.has_conditions);
    let find_vars = ir.find_vars;

    let mut range_bounds: HashMap<String, Vec<Vec<(String, BoundValue)>>> = HashMap::new();
    for (_, st) in &ir.aliases {
        for (attr, branches) in &st.range_conds {
            let var_name = if *attr == st.e_var { st.e_var.clone() } else { st.v_var(attr) };
            range_bounds.insert(var_name, branches.clone());
        }
    }

    eliminate_dead_e_vars(&mut patterns, &find_vars, &range_bounds);

    Ok(DatalogIR {
        patterns,
        find_vars,
        range_bounds,
        star: ir.star,
        exists_mode: ir.exists_mode,
        has_conditions: ir.has_conditions,
        history: ir.history,
    })
}
