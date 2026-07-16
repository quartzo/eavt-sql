use std::sync::Arc;

use spier_scheme::{Environment, SchemeProgram, SExpr, eval};
use spier_value::query_codec;
use spier_value::Value;

use crate::engine::query_engine_inner::QueryEngineInner;
use crate::engine::vm::{QueryContext, VMEngine};
use crate::VMResultStream;

pub struct SchemeSession {
    program: SchemeProgram,
    engine: Arc<QueryEngineInner>,
    params: Vec<Value>,
    tx: u64,
    as_of_tx: Option<u64>,
    done: bool,
}

impl SchemeSession {
    pub fn new(
        program: SchemeProgram,
        engine: Arc<QueryEngineInner>,
        params: Vec<Value>,
        tx: u64,
        as_of_tx: Option<u64>,
    ) -> Self {
        Self {
            program,
            engine,
            params,
            tx,
            as_of_tx,
            done: false,
        }
    }
}

impl VMResultStream for SchemeSession {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String> {
        if self.done || max_rows == 0 {
            return Ok(false);
        }

        let as_of_u64 = self.as_of_tx.unwrap_or(u64::MAX);
        let mut host = SchemeHostFns {
            engine: Arc::clone(&self.engine),
            params: &self.params,
            tx: self.tx,
            as_of_tx: as_of_u64,
        };
        let mut env = Environment::new();
        let tracer = spier_scheme::NullTracer;

        let result = eval(&self.program.body, &mut env, &mut host, &tracer)
            .map_err(|e| format!("scheme eval error: {e}"))?;

        match result {
            SExpr::List(items)
                if items.len() >= 3
                    && matches!(items[0], SExpr::Symbol(ref s) if s == "result") =>
            {
                let eid = sexpr_to_value(&items[1])?;
                let total = sexpr_to_value(&items[2])?;
                out.extend_from_slice(&2u32.to_be_bytes());
                query_codec::encode_one(out, &eid);
                query_codec::encode_one(out, &total);
            }
            _ => {}
        }

        self.done = true;
        Ok(false)
    }
}

fn sexpr_to_value(expr: &SExpr) -> Result<Value, String> {
    match expr {
        SExpr::Int(n) => Ok(Value::Int64(*n)),
        SExpr::Float(f) => Ok(Value::Float64(*f)),
        SExpr::Str(s) => Ok(Value::Text(s.clone())),
        SExpr::Bool(b) => Ok(Value::Bool(*b as u8)),
        SExpr::Bytes(b) => Ok(Value::Bytes(b.clone())),
        SExpr::Void => Ok(Value::Timestamp(0)),
        other => Err(format!(
            "scheme: cannot convert {} to storage value",
            spier_scheme::write_scheme(other)
        )),
    }
}

struct SchemeHostFns<'a> {
    engine: Arc<QueryEngineInner>,
    params: &'a [Value],
    tx: u64,
    as_of_tx: u64,
}

impl<'a> spier_scheme::HostFns for SchemeHostFns<'a> {
    fn is_native(&self, name: &str) -> bool {
        matches!(
            name,
            "alloc-entity"
                | "tx-entity"
                | "param"
                | "lookup-entity"
                | "lookup-value"
                | "save"
                | "result"
        )
    }

    fn call(&mut self, name: &str, args: &[SExpr]) -> Result<SExpr, spier_scheme::EvalError> {
        match name {
            "alloc-entity" => {
                let partition = if args.is_empty() {
                    4u64
                } else {
                    expect_int(&args[0])? as u64
                };
                let eid = self
                    .engine
                    .tx()
                    .allocate_in_partition(partition)
                    .map_err(spier_scheme::EvalError::Host)?;
                Ok(SExpr::Int(eid as i64))
            }
            "tx-entity" => Ok(SExpr::Int(self.tx as i64)),
            "param" => {
                if args.len() != 1 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "param".into(),
                        expected: "(param idx)",
                    });
                }
                let idx = expect_int(&args[0])? as usize;
                if idx == 0 || idx > self.params.len() {
                    return Err(spier_scheme::EvalError::Host(format!(
                        "param index {} out of range (1..{})",
                        idx,
                        self.params.len()
                    )));
                }
                value_to_sexpr(&self.params[idx - 1])
            }
            "lookup-entity" => {
                if args.len() != 2 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "lookup-entity".into(),
                        expected: "(lookup-entity attr value)",
                    });
                }
                let attr = expect_str(&args[0])?;
                let val = sexpr_to_value(&args[1]).map_err(spier_scheme::EvalError::Host)?;
                let is_unique = self.engine
                    .tx()
                    .is_unique_attr(&attr)
                    .unwrap_or(false);
                if !is_unique {
                    return Err(spier_scheme::EvalError::Host(format!(
                        "UPSERT WHERE requires a UNIQUE attribute: '{attr}'"
                    )));
                }
                match self.engine.tx().lookup_entity(&attr, val) {
                    Ok(Some(eid)) => Ok(SExpr::Int(eid as i64)),
                    Ok(None) => Ok(SExpr::Void),
                    Err(e) => Err(spier_scheme::EvalError::Host(e)),
                }
            }
            "lookup-value" => {
                if args.len() != 2 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "lookup-value".into(),
                        expected: "(lookup-value eid attr)",
                    });
                }
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let ctx = QueryContext {
                    as_of_tx: if self.as_of_tx == u64::MAX {
                        None
                    } else {
                        Some(self.as_of_tx)
                    },
                    current_t: self.tx,
                };
                match self.engine.lookup_value(eid, &attr, &ctx) {
                    Some(v) => value_to_sexpr(&v),
                    None => Ok(SExpr::Void),
                }
            }
            "save" => {
                if args.len() != 3 {
                    return Err(spier_scheme::EvalError::Arity {
                        name: "save".into(),
                        expected: "(save eid attr value)",
                    });
                }
                let eid = expect_int(&args[0])? as u64;
                let attr = expect_str(&args[1])?;
                let val = sexpr_to_value(&args[2]).map_err(spier_scheme::EvalError::Host)?;
                self.engine
                    .tx()
                    .eavt_save(eid, &attr, val, self.tx, self.as_of_tx)
                    .map_err(spier_scheme::EvalError::Host)?;
                Ok(SExpr::Void)
            }
            "result" => {
                let mut items = vec![SExpr::Symbol("result".into())];
                items.extend_from_slice(args);
                Ok(SExpr::List(items))
            }
            _ => Err(spier_scheme::EvalError::NotFound(name.into())),
        }
    }
}

fn expect_int(expr: &SExpr) -> Result<i64, spier_scheme::EvalError> {
    match expr {
        SExpr::Int(n) => Ok(*n),
        SExpr::Float(f) => Ok(*f as i64),
        other => Err(spier_scheme::EvalError::Type {
            expected: "int",
            got: spier_scheme::write_scheme(other),
        }),
    }
}

fn expect_str(expr: &SExpr) -> Result<String, spier_scheme::EvalError> {
    match expr {
        SExpr::Str(s) => Ok(s.clone()),
        SExpr::Symbol(s) => Ok(s.clone()),
        other => Err(spier_scheme::EvalError::Type {
            expected: "string",
            got: spier_scheme::write_scheme(other),
        }),
    }
}

fn value_to_sexpr(val: &Value) -> Result<SExpr, spier_scheme::EvalError> {
    match val {
        Value::Int64(n) => Ok(SExpr::Int(*n)),
        Value::Float64(f) => Ok(SExpr::Float(*f)),
        Value::Text(s) => Ok(SExpr::Str(s.clone())),
        Value::Bool(b) => Ok(SExpr::Bool(*b != 0)),
        Value::Timestamp(ts) => Ok(SExpr::Int(*ts)),
        Value::Bytes(b) => Ok(SExpr::Bytes(b.clone())),
        Value::Unknown(tag, _) => Err(spier_scheme::EvalError::Type {
            expected: "concrete value",
            got: format!("unknown(tag={tag})"),
        }),
    }
}
