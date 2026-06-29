use dynspire_commons::sql_parse::*;
use crate::lexer::{tokenize, LexToken, TT, TT_NAMES};

pub fn parse(source: &str) -> Result<RustStmt, String> {
    let tokens = tokenize(source).map_err(|e| e.to_string())?;
    let mut parser = Parser::new(tokens);
    parser.parse()
}

struct Parser {
    tokens: Vec<LexToken>,
    pos: usize,
}

impl Parser {
    fn new(tokens: Vec<LexToken>) -> Self {
        Self { tokens, pos: 0 }
    }

    fn peek(&self) -> &LexToken {
        &self.tokens[self.pos]
    }

    fn advance(&mut self) -> &LexToken {
        let tok = &self.tokens[self.pos];
        self.pos += 1;
        tok
    }

    fn expect(&mut self, tt: TT) -> Result<&LexToken, String> {
        let tok = self.peek();
        if tok.tt != tt {
            return Err(format!(
                "expected {} at position {} (got {} {:?})",
                TT_NAMES[tt as usize],
                tok.pos,
                TT_NAMES[tok.tt as usize],
                tok.value,
            ));
        }
        Ok(self.advance())
    }

    fn expect_oneof(&mut self, tts: &[TT]) -> Result<&LexToken, String> {
        let tok = self.peek();
        if !tts.contains(&tok.tt) {
            let names: Vec<&str> = tts.iter().map(|t| TT_NAMES[*t as usize]).collect();
            return Err(format!(
                "expected {} at position {} (got {} {:?})",
                names.join(" or "),
                tok.pos,
                TT_NAMES[tok.tt as usize],
                tok.value,
            ));
        }
        Ok(self.advance())
    }

    fn parse(&mut self) -> Result<RustStmt, String> {
        let tt = self.peek().tt;
        match tt {
            TT::SELECT => self.parse_select(),
            TT::UPSERT => self.parse_upsert(),
            TT::UPDATE => self.parse_update_stmt(),
            TT::DELETE => self.parse_delete(),
            TT::ATTRIBUTE => self.parse_attribute(),
            TT::PARTITION => self.parse_partition_stmt(),
            TT::EXPLAIN => self.parse_explain(),
            TT::DATALOG => {
                self.expect(TT::DATALOG)?;
                let inner = self.parse()?;
                if let RustStmt::Select(s) = inner {
                    Ok(RustStmt::DatalogSelect(s))
                } else {
                    Err("expected SELECT after DATALOG".into())
                }
            }
            _ => Err(format!(
                "expected SELECT, UPSERT, UPDATE, DELETE, ATTRIBUTE, PARTITION, or EXPLAIN, got {} at position {}",
                TT_NAMES[tt as usize],
                self.peek().pos,
            )),
        }
    }

    fn parse_explain(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::EXPLAIN)?;
        let tt = self.peek().tt;
        match tt {
            TT::SELECT => self.parse_select(),
            TT::UPSERT => self.parse_upsert(),
            TT::UPDATE => self.parse_update_stmt(),
            TT::DELETE => self.parse_delete(),
            TT::ATTRIBUTE => self.parse_attribute(),
            _ => Err(String::from("expected SELECT, UPSERT, UPDATE, DELETE, or ATTRIBUTE after EXPLAIN")),
        }
    }

    fn parse_select(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::SELECT)?;
        let history = if self.peek().tt == TT::HISTORY {
            self.advance();
            true
        } else {
            false
        };
        let tt = self.peek().tt;
        let mut star = false;
        let projections: Vec<RustProjection>;
        let conditions: Vec<RustCondition>;

        if tt == TT::STAR {
            self.advance();
            star = true;
            projections = Vec::new();
            if self.peek().tt == TT::WHERE {
                self.advance();
                conditions = self.parse_condition_list()?;
            } else {
                conditions = Vec::new();
            }
            self.expect(TT::EOF)?;
        } else {
            projections = self.parse_projection_list()?;
            if self.peek().tt == TT::WHERE {
                self.advance();
                conditions = self.parse_condition_list()?;
            } else {
                conditions = Vec::new();
            }
            self.expect(TT::EOF)?;
        }

        let exists_mode = !star && !history
            && projections.iter().all(|p| p.field.is_none() && p.literal.is_some());

        Ok(RustStmt::Select(RustSelectStmt {
            projections, conditions, exists_mode, star, history,
        }))
    }

    fn parse_projection_list(&mut self) -> Result<Vec<RustProjection>, String> {
        let mut projs = vec![self.parse_projection()?];
        while self.peek().tt == TT::COMMA {
            self.advance();
            projs.push(self.parse_projection()?);
        }
        Ok(projs)
    }

    fn parse_projection(&mut self) -> Result<RustProjection, String> {
        let tt = self.peek().tt;
        match tt {
            TT::INTEGER => {
                let tok = self.advance();
                let val: i64 = tok.value.parse::<i64>().map_err(|e: std::num::ParseIntError| e.to_string())?;
                Ok(RustProjection {
                    field: None,
                    literal: Some(RustLiteral::Int(val)),
                })
            }
            TT::FLOAT => {
                let tok = self.advance();
                let val: f64 = tok.value.parse::<f64>().map_err(|e: std::num::ParseFloatError| e.to_string())?;
                Ok(RustProjection {
                    field: None,
                    literal: Some(RustLiteral::Float(val)),
                })
            }
            TT::STRING => {
                let tok = self.advance();
                Ok(RustProjection {
                    field: None,
                    literal: Some(RustLiteral::Str(tok.value.clone())),
                })
            }
            TT::ALIAS => {
                let fr = self.parse_field_ref()?;
                Ok(RustProjection {
                    field: Some(fr),
                    literal: None,
                })
            }
            _ => Err(format!("expected field reference or literal in SELECT at {}", self.peek().pos))
        }
    }

    fn parse_upsert(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::UPSERT)?;
        let mut clauses: Vec<RustUpsertClause> = Vec::new();

        loop {
            let (alias, entity_ref) = self.parse_upsert_alias()?;

            if self.peek().tt == TT::SET {
                self.advance();
                let values = self.parse_set_value_list()?;
                clauses.push(RustUpsertClause { alias, entity_ref, values });
            } else {
                clauses.push(RustUpsertClause { alias, entity_ref, values: Vec::new() });
            }

            if self.peek().tt != TT::COMMA { break; }
            self.advance();
        }

        self.expect(TT::EOF)?;
        Ok(RustStmt::Upsert(RustUpsertStmt { clauses }))
    }

    fn parse_upsert_alias(&mut self) -> Result<(Option<String>, UpsertEntityRef), String> {
        if self.peek().tt != TT::AS {
            return Ok((None, UpsertEntityRef::New));
        }
        self.advance();

        let alias = self.advance();
        if alias.tt != TT::ALIAS && alias.tt != TT::IDENT {
            return Err(format!("expected alias after AS at position {}", alias.pos));
        }
        let alias_name = alias.value.to_uppercase();

        if alias_name == "TX" {
            return Ok((Some(alias_name), UpsertEntityRef::Tx));
        }

        // AS D1 = eid(attr, value)
        if self.peek().tt == TT::EQ {
            self.advance();

            // Check for eid() function
            let tok = self.peek();
            if tok.tt == TT::IDENT && tok.value.eq_ignore_ascii_case("eid") {
                self.advance();
                self.expect(TT::LPAREN)?;
                let attr = self.parse_eid_attr_arg()?;
                self.expect(TT::COMMA)?;
                let value = self.parse_literal_or_param()?;
                self.expect(TT::RPAREN)?;

                return Ok((Some(alias_name), UpsertEntityRef::Lookup {
                    attr: Box::new(attr),
                    value: Box::new(value),
                }));
            }

            // AS D1 = %N  (explicit eid)
            let param_idx = self.parse_param()?;
            return Ok((Some(alias_name), UpsertEntityRef::ExplicitEid(param_idx)));
        }

        Ok((Some(alias_name), UpsertEntityRef::New))
    }

    fn parse_update_stmt(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::UPDATE)?;

        let mut clauses: Vec<RustUpdateClause> = Vec::new();

        let (first_alias, first_values) = self.parse_update_clause()?;
        clauses.push(RustUpdateClause { alias: first_alias, values: first_values });

        while self.peek().tt == TT::COMMA {
            let save = self.pos;
            self.advance();
            if self.peek().tt == TT::AS {
                let (alias, values) = self.parse_update_clause()?;
                clauses.push(RustUpdateClause { alias, values });
            } else {
                self.pos = save;
                break;
            }
        }

        self.expect(TT::WHERE)?;
        let conditions = self.parse_condition_list()?;

        self.expect(TT::EOF)?;
        Ok(RustStmt::Update(RustUpdateStmt { clauses, conditions }))
    }

    fn parse_update_clause(&mut self) -> Result<(String, Vec<RustInsertValue>), String> {
        let alias = if self.peek().tt == TT::AS {
            self.advance();
            let tok = self.advance();
            if tok.tt != TT::ALIAS && tok.tt != TT::IDENT {
                return Err(format!("expected alias after AS at position {}", tok.pos));
            }
            tok.value.to_uppercase()
        } else {
            "D1".to_string()
        };

        self.expect(TT::SET)?;
        let values = self.parse_set_value_list()?;
        Ok((alias, values))
    }

    fn parse_set_value_list(&mut self) -> Result<Vec<RustInsertValue>, String> {
        let mut values = Vec::new();
        values.push(self.parse_set_value()?);
        while self.peek().tt == TT::COMMA {
            let save = self.pos;
            self.advance();
            if self.peek().tt == TT::AS || self.peek().tt == TT::EOF {
                self.pos = save;
                break;
            }
            values.push(self.parse_set_value()?);
        }
        Ok(values)
    }

    fn parse_set_value(&mut self) -> Result<RustInsertValue, String> {
        let attr = self.parse_attr_ref()?;
        self.expect(TT::EQ)?;
        let value = self.parse_value_or_alias()?;
        Ok(RustInsertValue { attr, value })
    }

    fn parse_value_or_alias(&mut self) -> Result<RustValue, String> {
        let tt = self.peek().tt;
        match tt {
            TT::ALIAS => {
                let alias_val = self.advance().value.clone();
                if self.peek().tt == TT::DOT {
                    return Err(format!("dotted alias not allowed in value position at {}", self.peek().pos));
                }
                Ok(RustValue::AliasRef(alias_val.to_uppercase()))
            }
            TT::PARAM => Ok(RustValue::Param(self.parse_param()?)),
            TT::STRING => {
                let tok = self.advance();
                Ok(RustValue::Literal(RustLiteral::Str(tok.value.clone())))
            }
            TT::INTEGER => {
                let tok = self.advance();
                let val: i64 = tok.value.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
                Ok(RustValue::Literal(RustLiteral::Int(val)))
            }
            TT::FLOAT => {
                let tok = self.advance();
                let val: f64 = tok.value.parse().map_err(|e: std::num::ParseFloatError| e.to_string())?;
                Ok(RustValue::Literal(RustLiteral::Float(val)))
            }
            TT::IDENT if self.peek().value == "true" => { self.advance(); Ok(RustValue::Literal(RustLiteral::Bool(true))) }
            TT::IDENT if self.peek().value == "false" => { self.advance(); Ok(RustValue::Literal(RustLiteral::Bool(false))) }
            TT::IDENT if self.peek().value.eq_ignore_ascii_case("eid") => {
                self.advance();
                self.expect(TT::LPAREN)?;
                let attr = self.parse_eid_attr_arg()?;
                self.expect(TT::COMMA)?;
                let value = self.parse_literal_or_param()?;
                self.expect(TT::RPAREN)?;
                Ok(RustValue::EidLookup {
                    attr: Box::new(attr),
                    value: Box::new(value),
                })
            }
            TT::IDENT if self.peek().value.eq_ignore_ascii_case("val") => {
                self.advance();
                self.expect(TT::LPAREN)?;
                let entity = self.parse_value_or_alias()?;
                self.expect(TT::COMMA)?;
                let attr = self.parse_eid_attr_arg()?;
                self.expect(TT::RPAREN)?;
                Ok(RustValue::ValLookup {
                    entity: Box::new(entity),
                    attr: Box::new(attr),
                })
            }
            _ => Err(format!("expected value after = at position {}", self.peek().pos)),
        }
    }

    fn parse_eid_attr_arg(&mut self) -> Result<RustValue, String> {
        let tt = self.peek().tt;
        match tt {
            TT::STRING => {
                let tok = self.advance();
                Ok(RustValue::Literal(RustLiteral::Str(tok.value.clone())))
            }
            TT::PARAM => Ok(RustValue::Param(self.parse_param()?)),
            TT::IDENT => {
                let attr = self.parse_attr_ref()?;
                Ok(RustValue::Literal(RustLiteral::Str(attr)))
            }
            _ => Err(format!("expected attribute name (quoted or dotted) at position {}", self.peek().pos)),
        }
    }

    fn parse_literal_or_param(&mut self) -> Result<RustValue, String> {
        let tt = self.peek().tt;
        match tt {
            TT::PARAM => Ok(RustValue::Param(self.parse_param()?)),
            TT::STRING => {
                let tok = self.advance();
                Ok(RustValue::Literal(RustLiteral::Str(tok.value.clone())))
            }
            TT::INTEGER => {
                let tok = self.advance();
                let val: i64 = tok.value.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
                Ok(RustValue::Literal(RustLiteral::Int(val)))
            }
            TT::FLOAT => {
                let tok = self.advance();
                let val: f64 = tok.value.parse().map_err(|e: std::num::ParseFloatError| e.to_string())?;
                Ok(RustValue::Literal(RustLiteral::Float(val)))
            }
            _ => Err(format!("expected literal or parameter at position {}", self.peek().pos)),
        }
    }

    fn parse_delete(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::DELETE)?;
        self.expect(TT::WHERE)?;
        let conditions = self.parse_condition_list()?;
        self.expect(TT::EOF)?;
        Ok(RustStmt::Delete(RustDeleteWhereStmt { conditions }))
    }

    fn parse_attribute(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::ATTRIBUTE)?;
        let attr = self.parse_attr_ref()?;
        let type_names = ["STRING", "LONG", "REF", "BOOLEAN", "INSTANT", "BYTES", "BLOB", "KEYWORD", "FLOAT"];
        let tt = self.peek().tt;
        let upper = self.peek().value.to_uppercase();
        if matches!(tt, TT::IDENT | TT::REF | TT::BYTES) && type_names.contains(&upper.as_str()) {
            self.advance();
        } else {
            return Err(format!("expected type name at {}", self.peek().pos));
        }
        let many = if self.peek().tt == TT::MANY { self.advance(); true }
                    else if self.peek().tt == TT::ONE { self.advance(); false }
                    else { false };
        let unique = self.peek().tt == TT::UNIQUE && { self.advance(); true };
        self.expect(TT::EOF)?;
        Ok(RustStmt::Attribute(RustAttributeStmt {
            attr, value_type: upper, many, unique,
        }))
    }

    fn parse_partition_stmt(&mut self) -> Result<RustStmt, String> {
        self.expect(TT::PARTITION)?;
        let name = self.expect(TT::IDENT)?.value.clone();
        self.expect(TT::EOF)?;
        Ok(RustStmt::Partition(RustPartitionStmt { name }))
    }

    fn parse_attr_ref(&mut self) -> Result<String, String> {
        let ns = self.expect_oneof(&[TT::IDENT, TT::ALIAS])?.value.clone();
        self.expect(TT::DOT)?;
        let name = self.expect_oneof(&[TT::IDENT, TT::ALIAS])?.value.clone();
        Ok(format!("{}.{}", ns, name))
    }

    fn parse_field_ref(&mut self) -> Result<RustFieldRef, String> {
        let alias = self.expect(TT::ALIAS)?.value.clone();
        self.expect(TT::DOT)?;
        let mut field = self.expect_oneof(&[TT::IDENT, TT::ALIAS])?.value.clone();
        while self.peek().tt == TT::DOT {
            self.advance();
            let sub = self.expect_oneof(&[TT::IDENT, TT::ALIAS])?.value.clone();
            field.push('.');
            field.push_str(&sub);
        }
        Ok(RustFieldRef { alias, field })
    }

    fn parse_param(&mut self) -> Result<u32, String> {
        let tok = self.expect(TT::PARAM)?;
        let n: u32 = tok.value[1..].parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(n)
    }

    fn parse_condition_list(&mut self) -> Result<Vec<RustCondition>, String> {
        self.parse_or_expr()
    }

    fn parse_or_expr(&mut self) -> Result<Vec<RustCondition>, String> {
        let first_and = self.parse_and_group()?;
        if self.peek().tt != TT::OR {
            return Ok(first_and);
        }
        let mut branches: Vec<Vec<RustOrBranchItem>> = Vec::new();
        let left = first_and[0].left.clone();
        branches.push(first_and.into_iter().map(|c| RustOrBranchItem { left: c.left.clone(), op: c.op, value: c.right }).collect());
        while self.peek().tt == TT::OR {
            self.advance();
            let group = self.parse_and_group()?;
            branches.push(group.into_iter().map(|c| RustOrBranchItem { left: c.left.clone(), op: c.op, value: c.right }).collect());
        }
        Ok(vec![RustCondition {
            left,
            op: "or".to_string(),
            right: RustConditionRight::Or(branches),
        }])
    }

    fn parse_and_group(&mut self) -> Result<Vec<RustCondition>, String> {
        let mut conds = Vec::new();
        conds.extend(self.parse_primary()?);
        while self.peek().tt == TT::AND {
            self.advance();
            conds.extend(self.parse_primary()?);
        }
        Ok(conds)
    }

    fn parse_primary(&mut self) -> Result<Vec<RustCondition>, String> {
        if self.peek().tt == TT::LPAREN {
            self.advance();
            let inner = self.parse_or_expr()?;
            self.expect(TT::RPAREN)?;
            Ok(inner)
        } else {
            Ok(vec![self.parse_condition()?])
        }
    }

    fn parse_condition(&mut self) -> Result<RustCondition, String> {
        let left = self.parse_field_ref()?;
        if self.peek().tt == TT::IN {
            self.advance();
            self.expect(TT::LPAREN)?;
            let mut vals = vec![self.parse_condition_value()?];
            while self.peek().tt == TT::COMMA {
                self.advance();
                vals.push(self.parse_condition_value()?);
            }
            self.expect(TT::RPAREN)?;
            return Ok(RustCondition {
                left,
                op: "in".to_string(),
                right: RustConditionRight::In(vals),
            });
        }
        let op = self.parse_op()?;
        let tt = self.peek().tt;
        let right = match tt {
            TT::ALIAS => {
                let save = self.pos;
                let alias_val = self.advance().value.clone();
                if self.peek().tt == TT::DOT {
                    self.pos = save;
                    let fr = self.parse_field_ref()?;
                    RustConditionRight::Field(fr)
                } else {
                    RustConditionRight::Field(RustFieldRef {
                        alias: alias_val,
                        field: "eid".to_string(),
                    })
                }
            }
            TT::PARAM => RustConditionRight::Param(self.parse_param()?),
            TT::INTEGER => {
                let tok = self.advance();
                let val: i64 = tok.value.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
                RustConditionRight::Literal(RustLiteral::Int(val))
            }
            TT::FLOAT => {
                let tok = self.advance();
                let val: f64 = tok.value.parse().map_err(|e: std::num::ParseFloatError| e.to_string())?;
                RustConditionRight::Literal(RustLiteral::Float(val))
            }
            TT::STRING => {
                let tok = self.advance();
                RustConditionRight::Literal(RustLiteral::Str(tok.value.clone()))
            }
            TT::IDENT if self.peek().value == "true" => { self.advance(); RustConditionRight::Literal(RustLiteral::Bool(true)) }
            TT::IDENT if self.peek().value == "false" => { self.advance(); RustConditionRight::Literal(RustLiteral::Bool(false)) }
            TT::LPAREN => {
                self.advance();
                if self.peek().tt == TT::SELECT {
                    let inner_vals: Vec<RustConditionRight> = vec![];
                    self.expect(TT::RPAREN)?;
                    RustConditionRight::In(inner_vals)
                } else {
                    let mut vals = vec![self.parse_condition_value()?];
                    while self.peek().tt == TT::COMMA {
                        self.advance();
                        vals.push(self.parse_condition_value()?);
                    }
                    self.expect(TT::RPAREN)?;
                    RustConditionRight::In(vals)
                }
            }
            _ => return Err(format!("expected value in condition at {}", self.peek().pos)),
        };
        Ok(RustCondition { left, op, right })
    }

    fn parse_condition_value(&mut self) -> Result<RustConditionRight, String> {
        let tt = self.peek().tt;
        match tt {
            TT::PARAM => Ok(RustConditionRight::Param(self.parse_param()?)),
            TT::INTEGER => {
                let tok = self.advance();
                let val: i64 = tok.value.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
                Ok(RustConditionRight::Literal(RustLiteral::Int(val)))
            }
            TT::STRING => {
                let tok = self.advance();
                Ok(RustConditionRight::Literal(RustLiteral::Str(tok.value.clone())))
            }
            _ => Err(format!("expected value in IN list at {}", self.peek().pos)),
        }
    }

    fn parse_op(&mut self) -> Result<String, String> {
        let tt = self.peek().tt;
        match tt {
            TT::EQ => { self.advance(); Ok("=".to_string()) }
            TT::GT => { self.advance(); Ok(">".to_string()) }
            TT::LT => { self.advance(); Ok("<".to_string()) }
            TT::GTE => { self.advance(); Ok(">=".to_string()) }
            TT::LTE => { self.advance(); Ok("<=".to_string()) }
            TT::NEQ => { self.advance(); Ok("!=".to_string()) }
            _ => Err(format!("expected comparison operator at {}", self.peek().pos)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_select() {
        let stmt = parse("SELECT d1.name WHERE d1.eid = %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.projections.len(), 1);
                assert_eq!(s.projections[0].field.as_ref().unwrap().alias, "d1");
                assert_eq!(s.projections[0].field.as_ref().unwrap().field, "name");
                assert_eq!(s.conditions.len(), 1);
                assert_eq!(s.conditions[0].left.alias, "d1");
                assert_eq!(s.conditions[0].left.field, "eid");
                assert_eq!(s.conditions[0].op, "=");
                assert!(matches!(s.conditions[0].right, RustConditionRight::Param(1)));
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_with_join() {
        let stmt = parse("SELECT d2.name WHERE d1.eid = %1 AND d1.partner = d2.eid").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.conditions.len(), 2);
                assert_eq!(s.conditions[1].left.field, "partner");
                match &s.conditions[1].right {
                    RustConditionRight::Field(fr) => {
                        assert_eq!(fr.alias, "d2");
                        assert_eq!(fr.field, "eid");
                    }
                    _ => panic!("expected Field"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_range_operator() {
        let stmt = parse("SELECT d1.name WHERE d1.price > %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.conditions[0].op, ">");
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_exists_mode() {
        let stmt = parse("SELECT 1 WHERE d1.eid = %1 AND d1.partner = %2").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert!(s.exists_mode);
                assert!(s.projections[0].field.is_none());
                assert!(s.projections[0].literal.is_some());
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn multiple_projections() {
        let stmt = parse("SELECT d1.eid, d1.name, d1.tx WHERE d1.eid = %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.projections.len(), 3);
                assert_eq!(s.projections[0].field.as_ref().unwrap().field, "eid");
                assert_eq!(s.projections[1].field.as_ref().unwrap().field, "name");
                assert_eq!(s.projections[2].field.as_ref().unwrap().field, "tx");
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn string_literal_in_where() {
        let stmt = parse("SELECT 1 WHERE d1.name = 'hello'").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::Literal(RustLiteral::Str(v)) => assert_eq!(v, "hello"),
                    _ => panic!("expected string literal"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn integer_literal_in_where() {
        let stmt = parse("SELECT 1 WHERE d1.price > 1000").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::Literal(RustLiteral::Int(v)) => assert_eq!(*v, 1000),
                    _ => panic!("expected int literal"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn float_literal_in_where() {
        let stmt = parse("SELECT 1 WHERE d1.price > 3.14").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::Literal(RustLiteral::Float(v)) => assert!((v - 3.14).abs() < f64::EPSILON),
                    _ => panic!("expected float literal"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn namespaced_attributes() {
        let stmt = parse("SELECT d1.company.name WHERE d1.company.hq = %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.projections[0].field.as_ref().unwrap().field, "company.name");
                assert_eq!(s.conditions[0].left.field, "company.hq");
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn range_operators() {
        for op in &[" > ", " < ", " >= ", " <= "] {
            let sql = format!("SELECT d1.name WHERE d1.price{}%1", op);
            let stmt = parse(&sql).unwrap();
            match stmt {
                RustStmt::Select(s) => {
                    let op_str = op.trim();
                    let expected = if op_str == ">" { ">" }
                        else if op_str == "<" { "<" }
                        else if op_str == ">=" { ">=" }
                        else { "<=" };
                    assert_eq!(s.conditions[0].op, expected);
                }
                _ => panic!("expected Select"),
            }
        }
    }

    #[test]
    fn select_without_where() {
        let stmt = parse("SELECT d1.name").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert!(!s.star);
                assert_eq!(s.projections.len(), 1);
                assert_eq!(s.conditions.len(), 0);
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_star() {
        let stmt = parse("SELECT *").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert!(s.star);
                assert_eq!(s.projections.len(), 0);
                assert_eq!(s.conditions.len(), 0);
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_star_with_where() {
        let stmt = parse("SELECT * WHERE d1.active = true").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert!(s.star);
                assert_eq!(s.conditions.len(), 1);
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn error_expected_eof() {
        let err = parse("SELECT d1.name WHERE d1.eid = %1 garbage").unwrap_err();
        assert!(err.contains("expected EOF") || err.contains("position"));
    }

    #[test]
    fn error_invalid_operator() {
        let err = parse("SELECT d1.name WHERE d1.eid = %1 AND d1.eid").unwrap_err();
        assert!(err.contains("comparison operator") || err.contains("expected"));
    }

    #[test]
    fn attribute_many() {
        let stmt = parse("ATTRIBUTE company.partner REF MANY").unwrap();
        match stmt {
            RustStmt::Attribute(a) => {
                assert_eq!(a.attr, "company.partner");
                assert_eq!(a.value_type, "REF");
                assert!(a.many);
            }
            _ => panic!("expected Attribute"),
        }
    }

    #[test]
    fn attribute_one() {
        let stmt = parse("ATTRIBUTE company.name STRING ONE").unwrap();
        match stmt {
            RustStmt::Attribute(a) => {
                assert_eq!(a.attr, "company.name");
                assert_eq!(a.value_type, "STRING");
                assert!(!a.many);
            }
            _ => panic!("expected Attribute"),
        }
    }

    #[test]
    fn attribute_unique() {
        let stmt = parse("ATTRIBUTE company.name STRING UNIQUE").unwrap();
        match stmt {
            RustStmt::Attribute(a) => {
                assert!(a.unique);
            }
            _ => panic!("expected Attribute"),
        }
    }

    #[test]
    fn attribute_error_missing_type() {
        let err = parse("ATTRIBUTE company.name").unwrap_err();
        assert!(err.contains("type name"));
    }

    #[test]
    fn attribute_error_no_dot() {
        let err = parse("ATTRIBUTE nodot STRING MANY").unwrap_err();
        assert!(err.contains("expected"));
    }

    #[test]
    fn delete_where_simple() {
        let stmt = parse("DELETE WHERE d1.eid = 42 AND d1.ns.attr = 'hello'").unwrap();
        match stmt {
            RustStmt::Delete(d) => {
                assert_eq!(d.conditions.len(), 2);
                assert_eq!(d.conditions[0].left.field, "eid");
                match &d.conditions[0].right {
                    RustConditionRight::Literal(RustLiteral::Int(42)) => {}
                    _ => panic!("expected int 42"),
                }
            }
            _ => panic!("expected Delete"),
        }
    }

    #[test]
    fn delete_where_with_param() {
        let stmt = parse("DELETE WHERE d1.eid = %1 AND d1.ns.attr = %2").unwrap();
        match stmt {
            RustStmt::Delete(d) => {
                assert!(matches!(d.conditions[0].right, RustConditionRight::Param(1)));
            }
            _ => panic!("expected Delete"),
        }
    }

    #[test]
    fn partition_stmt() {
        let stmt = parse("PARTITION my-partition").unwrap();
        match stmt {
            RustStmt::Partition(p) => {
                assert_eq!(p.name, "my-partition");
            }
            _ => panic!("expected Partition"),
        }
    }

    #[test]
    fn explain_select() {
        let stmt = parse("EXPLAIN SELECT d1.name WHERE d1.eid = %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.projections.len(), 1);
            }
            _ => panic!("expected Select (from EXPLAIN)"),
        }
    }

    #[test]
    fn explain_attribute() {
        let stmt = parse("EXPLAIN ATTRIBUTE ns.attr STRING MANY").unwrap();
        match stmt {
            RustStmt::Attribute(_) => {}
            _ => panic!("expected Attribute (from EXPLAIN)"),
        }
    }

    #[test]
    fn explain_error_no_stmt() {
        let err = parse("EXPLAIN").unwrap_err();
        assert!(err.contains("SELECT") || err.contains("expected"));
    }

    #[test]
    fn neq_operator() {
        let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val != %1").unwrap();
        match stmt {
            RustStmt::Select(s) => assert_eq!(s.conditions[0].op, "!="),
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn neq_angle_bracket() {
        let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val <> %1").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::Param(1) => {}
                    _ => panic!("expected Param(1)"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn in_condition_params() {
        let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val IN (%1, %2, %3)").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::In(vals) => {
                        assert_eq!(vals.len(), 3);
                        assert!(matches!(vals[0], RustConditionRight::Param(1)));
                        assert!(matches!(vals[1], RustConditionRight::Param(2)));
                        assert!(matches!(vals[2], RustConditionRight::Param(3)));
                    }
                    _ => panic!("expected In"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn in_condition_literals() {
        let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val IN (10, 20, 30)").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::In(vals) => {
                        assert_eq!(vals.len(), 3);
                    }
                    _ => panic!("expected In"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn in_condition_mixed() {
        let stmt = parse("SELECT d1.ns.attr WHERE d1.ns.val IN (10, %1, 'hello')").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                match &s.conditions[0].right {
                    RustConditionRight::In(vals) => {
                        assert_eq!(vals.len(), 3);
                        assert!(matches!(vals[0], RustConditionRight::Literal(RustLiteral::Int(10))));
                        assert!(matches!(vals[1], RustConditionRight::Param(1)));
                        assert!(matches!(vals[2], RustConditionRight::Literal(RustLiteral::Str(_))));
                    }
                    _ => panic!("expected In"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn or_condition() {
        let stmt = parse("SELECT d1.name WHERE d1.eid = %1 OR d1.eid = %2").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert_eq!(s.conditions.len(), 1);
                assert_eq!(s.conditions[0].op, "or");
                match &s.conditions[0].right {
                    RustConditionRight::Or(branches) => assert_eq!(branches.len(), 2),
                    _ => panic!("expected Or"),
                }
            }
            _ => panic!("expected Select"),
        }
    }

    #[test]
    fn select_star_no_where() {
        let stmt = parse("SELECT *").unwrap();
        match stmt {
            RustStmt::Select(s) => {
                assert!(s.star);
                assert_eq!(s.projections.len(), 0);
                assert_eq!(s.conditions.len(), 0);
                assert!(!s.exists_mode);
            }
            _ => panic!("expected Select"),
        }
    }
}
