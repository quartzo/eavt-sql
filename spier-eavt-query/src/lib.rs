use std::collections::HashMap;
use std::sync::{Arc, RwLock};

mod engine;

use dynspire_commons::query_engine::SessionHandle;
use dynspire_commons::transactor::{TransactorEngine, Value, ValueType};
use dynspire_commons::compiler::{CompileResultSt, CompilerEngine};
use dynspire_commons::sql_frontend::{DynSpireSqlFrontend, SqlFrontendEngine};
use dynspire_commons::datalog::{DatalogNumIRSt, DatalogIR, resolve::resolve_ir};
use dynspire_commons::sql_parse::RustStmt;
use dynspire_commons::query_ir::{InstructionData, VMProgram};
use engine::dynspire_engine::DynSpireEngine;
use engine::vm::VMEngine;
use engine::opcodes::ProgramHandle;
use dynspire_commons::transactor::query_codec;

include!(concat!(env!("OUT_DIR"), "/query_spier.rs"));

struct QueryInner {
    engine: Option<Arc<DynSpireEngine>>,
    frontend: Option<DynSpireSqlFrontend>,
    compiler: Option<dynspire_commons::compiler::DynSpireCompiler>,
}

struct QueryState {
    inner: RwLock<QueryInner>,
}

fn open_engine(config: &HashMap<String, String>) -> Result<DynSpireEngine, String> {
    let backend = config
        .get("backend")
        .map(|s| s.as_str())
        .unwrap_or("memory");
    match backend {
        "memory" => DynSpireEngine::open_in_memory(config),
        "file" => {
            config
                .get("path")
                .ok_or("path required for file backend")?;
            let read_only = config
                .get("read_only")
                .map(|v| v == "true")
                .unwrap_or(false);
            if read_only {
                DynSpireEngine::open_read_only(config)
            } else {
                DynSpireEngine::open(config)
            }
        }
        "s3" => DynSpireEngine::open_s3(config),
        other => Err(format!("unknown backend: {other}")),
    }
}

fn init(config: &HashMap<String, String>) -> Result<QueryState, String> {
    let engine = open_engine(config)?;
    let frontend = DynSpireSqlFrontend::connect("spier_sql_frontend", config)?;
    let compiler = dynspire_commons::compiler::DynSpireCompiler::connect("spier_compiler", config)?;
    Ok(QueryState {
        inner: RwLock::new(QueryInner{
            engine: Some(Arc::new(engine)),
            frontend: Some(frontend),
            compiler: Some(compiler),
        }),
    })
}

fn disassemble(program: &VMProgram) -> String {
    let mut lines = Vec::new();
    for (i, inst) in program.instructions.iter().enumerate() {
        let op_name = format!("{:?}", inst.op)
            .chars()
            .fold(String::new(), |mut acc, c| {
                if c.is_uppercase() && !acc.is_empty() {
                    acc.push('_');
                }
                acc.push(c.to_ascii_uppercase());
                acc
            });
        let p4_str = match &inst.p4 {
            InstructionData::None => String::new(),
            InstructionData::Int(n) => format!(" p4=int({})", n),
            InstructionData::Float(f) => format!(" p4=float({})", f),
            InstructionData::Str(s) => format!(" p4=str({:?})", s),
            InstructionData::RangeFlags(f) => format!(" flags={}", f),
            InstructionData::CursorPlan(_) => String::new(),
        };
        lines.push(format!(
            "{:3}  {:<20} p1={} p2={} p3={}{}",
            i, op_name, inst.p1, inst.p2, inst.p3, p4_str
        ));
    }
    lines.join("\n")
}

/// Orchestrate two-stage compilation: frontend → resolve → compiler.
/// Returns (CompileResult, Option<DatalogNumIR>) — the num_ir is for explain_plan.
fn do_compile(
    frontend: &DynSpireSqlFrontend,
    compiler: &dynspire_commons::compiler::DynSpireCompiler,
    tx: &dynspire_commons::transactor::DynSpireTransactor,
    sql: &str,
    sql_params: &[u8],
) -> Result<(CompileResultSt, Option<DatalogIR>), String> {
    let stmt_st = SqlFrontendEngine::parse(frontend, sql)?;

    match &stmt_st.stmt {
        RustStmt::Select(_) | RustStmt::DatalogSelect(_) => {
            let ir = SqlFrontendEngine::build_datalog(frontend, stmt_st, sql_params)?;
            let num_ir = resolve_ir(ir.ir, tx)?;
            let result = compiler.compile_select(DatalogNumIRSt { num_ir: num_ir.clone() })?;
            Ok((result, Some(num_ir.ir)))
        }
        RustStmt::Update(_) | RustStmt::Delete(_) => {
            // Check if DELETE has eid (direct) or needs scan
            let needs_scan = match &stmt_st.stmt {
                RustStmt::Delete(d) => !d.conditions.iter().any(|c| c.left.field == "eid"),
                RustStmt::Update(_) => true,
                _ => false,
            };

            if needs_scan {
                let stmt_for_compiler = stmt_st.clone();
                let ir = SqlFrontendEngine::build_datalog(frontend, stmt_st, sql_params)?;
                let num_ir = resolve_ir(ir.ir, tx)?;
                let result = compiler.compile_dml_scan(
                    stmt_for_compiler,
                    DatalogNumIRSt { num_ir: num_ir.clone() },
                    sql_params,
                )?;
                Ok((result, Some(num_ir.ir)))
            } else {
                // Direct DELETE with eid
                let result = compiler.compile_dml_direct(stmt_st, sql_params)?;
                Ok((result, None))
            }
        }
        _ => {
            let result = compiler.compile_dml_direct(stmt_st, sql_params)?;
            Ok((result, None))
        }
    }
}

impl QueryEngine for QueryState {
    // ------------------------------------------------------------------
    // 1. QUERY
    // ------------------------------------------------------------------

    fn compile_sql(&self, sql: &str, sql_params: &[u8]) -> Result<ProgramHandle, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, _) = do_compile(frontend, compiler, engine.tx().as_ref(), sql, sql_params)?;

        Ok(ProgramHandle { program: Arc::new(result.program) })
    }

    fn run_vm(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();

        let engine = inner.engine.as_ref().ok_or("engine not open")?;

        let vm_params = query_codec::decode_values(sql_params)?;

        let limit_opt = if limit == u64::MAX { None } else { Some(limit as usize) };
        let as_of_opt = if as_of_us == u64::MAX { None } else { Some(as_of_us) };

        let rows = engine.run_vm(program.program, vm_params, limit_opt, as_of_opt);
        match rows {
            Ok(rows) => {
                let num_cols = rows.first().map(|r| r.len()).unwrap_or(0);
                let total_values: usize = rows.iter().map(|r| r.len()).sum();
                let mut out = Vec::with_capacity(total_values * 12 + 8);
                out.extend_from_slice(&(num_cols as u32).to_be_bytes());
                out.extend_from_slice(&(total_values as u32).to_be_bytes());
                for row in &rows {
                    for v in row {
                        query_codec::encode_one(&mut out, v);
                    }
                }
                Ok(out)
            }
            Err(e) => {
                Err(e.0)
            }
        }
    }

    fn run_vm_cursor(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<SessionHandle, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;

        let vm_params = query_codec::decode_values(sql_params)?;
        let limit_opt = if limit == u64::MAX { None } else { Some(limit as usize) };
        let as_of_opt = if as_of_us == u64::MAX { None } else { Some(as_of_us) };

        let t = engine.allocate_t_and_write_tx();
        crate::engine::opcodes::reset_scanner_stats();

        let session = engine::session::VMSession::new(
            program.program,
            Arc::clone(engine) as Arc<dyn engine::vm::VMEngine + Send + Sync>,
            vm_params,
            limit_opt,
            t,
            as_of_opt,
        );

        Ok(SessionHandle {
            session: Arc::new(std::cell::RefCell::new(session)),
        })
    }

    fn session_next_batch(
        &self,
        session: SessionHandle,
        max_rows: u64,
    ) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        session.session.borrow_mut().next_batch(&mut out, max_rows as usize)?;
        Ok(out)
    }

    fn explain(&self, sql: &str, sql_params: &[u8]) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, _) = do_compile(frontend, compiler, engine.tx().as_ref(), sql, sql_params)?;

        let mut out = String::new();
        for t in &result.traces {
            out.push_str(&format!("{t}\n"));
        }
        out.push_str(&format!("\n{}", disassemble(&result.program)));
        Ok(out)
    }

    fn explain_plan(&self, sql: &str, sql_params: &[u8]) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, num_ir) = do_compile(frontend, compiler, engine.tx().as_ref(), sql, sql_params)?;

        let mut out = String::new();
        if let Some(ir) = num_ir {
            out.push_str(&format!("{}\n", ir));
        }
        for t in &result.traces {
            out.push_str(&format!("{t}\n"));
        }
        Ok(out)
    }

    fn compile_sql_json(&self, sql: &str, sql_params: &[u8]) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, _) = do_compile(frontend, compiler, engine.tx().as_ref(), sql, sql_params)?;
        Ok(result.program.to_json())
    }

    fn scan_datoms(&self, as_of_us: u64) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;

        let as_of_opt = if as_of_us == u64::MAX { None } else { Some(as_of_us) };

        let datoms = engine.collect_active_deduped("eavt", b"", as_of_opt);

        let mut values: Vec<Value> = Vec::with_capacity(datoms.len() * 5);
        for d in &datoms {
            let attr_name = engine.tx().attr_name(d.a)?;
            values.push(Value::Int64(d.e as i64));
            values.push(Value::Int64(d.a as i64));
            values.push(Value::Text(attr_name));
            values.push(d.v.clone());
            values.push(Value::Int64(d.t as i64));
        }

        let mut out = Vec::new();
        out.extend_from_slice(&(5u32).to_be_bytes());
        out.extend(query_codec::encode_values(&values));
        Ok(out)
    }

    // ------------------------------------------------------------------
    // 2. SCHEMA — delegates to TransactorEngine via DynSpireTransactor
    // ------------------------------------------------------------------

    fn declare_attr(&self, name: &str, value_type: ValueType, many: bool) -> Result<u32, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().eavt_declare_attr(name, value_type, many, u64::MAX)
    }

    fn declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
    ) -> Result<(), String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine
            .tx()
            .eavt_declare_attr_from_sql(attr, type_name, many, unique, u64::MAX)
    }

    fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().lookup_attr(name)
    }

    fn attr_name(&self, aid: u32) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().attr_name(aid)
    }

    fn is_declared(&self, aid: u32) -> Result<bool, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().is_declared(aid)
    }

    fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().value_type_for(aid)
    }

    fn is_many(&self, aid: u32) -> Result<bool, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().is_many(aid)
    }

    fn is_unique_attr(&self, name: &str) -> Result<bool, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().is_unique_attr(name)
    }

    fn declare_partition(&self, name: &str) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().eavt_declare_partition(name, u64::MAX)
    }

    fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().partition_id_for(name)
    }

    // ------------------------------------------------------------------
    // 3. WRITES — delegates
    // ------------------------------------------------------------------

    fn save(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().eavt_save(e, attr, v, t, u64::MAX)
    }

    fn retract(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().eavt_retract(e, attr, v, t, u64::MAX)
    }

    fn allocate_entity_id(&self) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().allocate_entity_id()
    }

    fn allocate_tx(&self) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().eavt_allocate_tx()
    }

    fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().lookup_entity(attr_name, value)
    }

    // ------------------------------------------------------------------
    // 4. ADMIN — delegates
    // ------------------------------------------------------------------

    fn flush(&self) -> Result<(), String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.flush()
    }

    fn close(&self) -> Result<(), String> {
        let mut inner = self.inner.write().unwrap();
        if let Some(engine) = inner.engine.take() {
            engine.close()?;
        }
        Ok(())
    }

    fn path(&self) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        Ok(engine.path().to_string())
    }

    fn memtable_size(&self) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        Ok(engine.memtable_size())
    }

    fn memtable_count(&self, cf: u32) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        Ok(engine.memtable_count(cf))
    }

    fn journal_size(&self) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        Ok(engine.wal_size())
    }

    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().cf_stats(cf)
    }

    fn db_stats(&self) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().db_stats()
    }

    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().gc_full(dry_run, nowait)
    }

    fn internal_status(&self, target: &str) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().internal_status(target)
    }
}

impl_query_spier!(QueryState, init, "spier_eavt_query");
