use spier_scheme::{SchemeProgram, SExpr};
use spier_sql_parse::{RustLiteral, RustUpsertStmt, RustValue, UpsertEntityRef};

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
