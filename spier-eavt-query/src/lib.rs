use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

mod engine;
pub mod trace;

pub use spier_query_ir::ProgramHandle;
pub use spier_storage_traits::CursorHandle;

use spier_compiler::{CompileResultSt, CompilerEngine};
use spier_datalog::CompileStats;
use spier_datalog::{
    resolve::{compute_plan_stats, resolve_ir},
    DatalogIR, DatalogNumIR, DatalogNumIRSt,
};
use spier_query_ir::{InstructionData, VMProgram};
use spier_sql_frontend::SqlFrontendEngine;
use spier_sql_parse::RustStmt;
use spier_transactor::{TransactorEngine, ValueType};
use spier_value::{query_codec, Value};

pub trait VMResultStream {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String>;
}

#[derive(Clone)]
pub struct SessionHandle {
    pub session: Arc<RefCell<dyn VMResultStream>>,
}

// Concrete VMResultStream implementations are thread-local-free; this lets
// PyO3 bindings release the GIL around streaming operations.
unsafe impl Send for SessionHandle {}

pub trait QueryEngine: Send + Sync {
    fn compile_sql(&self, sql: &str, sql_params: &[u8]) -> Result<ProgramHandle, String>;
    fn run_vm(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<Vec<u8>, String>;
    fn run_vm_cursor(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<SessionHandle, String>;
    fn session_next_batch(&self, session: SessionHandle, max_rows: u64) -> Result<Vec<u8>, String>;
    fn explain(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
    fn explain_plan(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
    fn compile_sql_json(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
    fn scan_datoms(&self, as_of_us: u64) -> Result<Vec<u8>, String>;
    fn declare_attr(&self, name: &str, value_type: ValueType, many: bool) -> Result<u32, String>;
    fn declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
    ) -> Result<(), String>;
    fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String>;
    fn attr_name(&self, aid: u32) -> Result<String, String>;
    fn is_declared(&self, aid: u32) -> Result<bool, String>;
    fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String>;
    fn is_many(&self, aid: u32) -> Result<bool, String>;
    fn is_unique_attr(&self, name: &str) -> Result<bool, String>;
    fn declare_partition(&self, name: &str) -> Result<u64, String>;
    fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String>;
    fn save(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String>;
    fn retract(&self, e: u64, attr: &str, v: Value, t: u64) -> Result<(), String>;
    fn allocate_entity_id(&self) -> Result<u64, String>;
    fn allocate_tx(&self) -> Result<u64, String>;
    fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String>;
    fn flush(&self) -> Result<(), String>;
    fn close(&self) -> Result<(), String>;
    fn path(&self) -> Result<String, String>;
    fn memtable_size(&self) -> Result<u64, String>;
    fn memtable_count(&self, cf: u32) -> Result<u64, String>;
    fn journal_size(&self) -> Result<u64, String>;
    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
    fn db_stats(&self) -> Result<Vec<u8>, String>;
    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
    fn internal_status(&self, target: &str) -> Result<String, String>;
}
use engine::query_engine_inner::QueryEngineInner;
use engine::vm::VMEngine;
use spier_compiler::Compiler;
use spier_sql_frontend::SqlFrontend;

struct QueryInner {
    engine: Option<Arc<QueryEngineInner>>,
    frontend: Option<SqlFrontend>,
    compiler: Option<Compiler>,
}

pub struct QueryState {
    inner: RwLock<QueryInner>,
}

impl QueryState {
    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        let engine = open_engine(config)?;
        let frontend = SqlFrontend::new();
        let compiler = Compiler::new();
        Ok(QueryState {
            inner: RwLock::new(QueryInner {
                engine: Some(Arc::new(engine)),
                frontend: Some(frontend),
                compiler: Some(compiler),
            }),
        })
    }
}

fn open_engine(config: &HashMap<String, String>) -> Result<QueryEngineInner, String> {
    let backend = config
        .get("backend")
        .map(|s| s.as_str())
        .unwrap_or("memory");
    match backend {
        "memory" => QueryEngineInner::open_in_memory(config),
        "file" => {
            config.get("path").ok_or("path required for file backend")?;
            let read_only = config
                .get("read_only")
                .map(|v| v == "true")
                .unwrap_or(false);
            if read_only {
                QueryEngineInner::open_read_only(config)
            } else {
                QueryEngineInner::open(config)
            }
        }
        "s3" => QueryEngineInner::open_s3(config),
        other => Err(format!("unknown backend: {other}")),
    }
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

/// Local bridge: TransactorEngine → CompileStats. Keeps every other crate
/// free of direct transactor references.
struct TxStats<'a> {
    tx: &'a dyn TransactorEngine,
    stats_cache: &'a engine::query_engine_inner::StatsCache,
}

impl<'a> TxStats<'a> {
    fn new(tx: &'a dyn TransactorEngine, stats_cache: &'a engine::query_engine_inner::StatsCache) -> Self {
        Self { tx, stats_cache }
    }
}

impl<'a> CompileStats for TxStats<'a> {
    fn lookup_attr(&self, name: &str) -> Option<u32> {
        TransactorEngine::lookup_attr(self.tx, name).ok().flatten()
    }

    fn estimate_index_size(&self, index: &str, bound: &[u64]) -> f64 {
        use spier_transactor::keys;
        let cf = keys::cf_for_index(index);
        let cf_id = keys::cf_name_to_id(cf) as u32;
        let idx_order = keys::index_order(index);
        let mut prefix = Vec::new();
        for (i, pos) in idx_order.iter().enumerate() {
            if i >= bound.len() {
                break;
            }
            let val = bound[i];
            if *pos == "a" {
                prefix.extend_from_slice(&(val as u32).to_be_bytes());
            } else {
                prefix.extend_from_slice(&val.to_be_bytes());
            }
        }

        let cache_key = (cf_id, prefix.clone());
        if let Some(cached) = self.stats_cache.get(&cache_key) {
            return cached;
        }

        let end = if prefix.is_empty() {
            vec![0xFF; 64]
        } else {
            let mut e = prefix.clone();
            e.extend_from_slice(&[0xFF; 32]);
            e
        };
        let val = TransactorEngine::approximate_sizes(self.tx, cf_id, &prefix, &end)
            .unwrap_or(0) as f64;

        self.stats_cache.put(cache_key, val);
        val
    }

    fn partition_id_for(&self, name: &str) -> Option<u64> {
        TransactorEngine::partition_id_for(self.tx, name)
            .ok()
            .flatten()
    }

    fn is_ref_attr(&self, name: &str) -> bool {
        use spier_transactor::resolver_consts::DB_TYPE_REF;
        if let Some(aid) = TransactorEngine::lookup_attr(self.tx, name).ok().flatten() {
            TransactorEngine::value_type_for(self.tx, aid)
                .ok()
                .flatten()
                .map(|vt| spier_transactor::value_type_to_eid(vt) == DB_TYPE_REF)
                .unwrap_or(false)
        } else {
            false
        }
    }
}

/// Build a DatalogNumIR from a DatalogIR by resolving attributes and
/// computing cardinality stats. Kept as one helper because both operations
/// share the same CompileStats source.
fn resolve_and_stats(ir: DatalogIR, tx_stats: &TxStats<'_>) -> Result<DatalogNumIR, String> {
    let ir = resolve_ir(ir, tx_stats)?;
    let stats = compute_plan_stats(&ir, tx_stats);
    Ok(DatalogNumIR { ir, stats })
}

/// Orchestrate two-stage compilation: frontend → resolve → compiler.
/// Returns (CompileResult, Option<DatalogIR>) — the num_ir is for explain_plan.
fn do_compile(
    frontend: &SqlFrontend,
    compiler: &Compiler,
    engine: &QueryEngineInner,
    sql: &str,
    sql_params: &[u8],
) -> Result<(CompileResultSt, Option<DatalogIR>), String> {
    let stmt_st = SqlFrontendEngine::parse(frontend, sql)?;

    match &stmt_st.stmt {
        RustStmt::Select(_) | RustStmt::DatalogSelect(_) => {
            let ir = SqlFrontendEngine::build_datalog(frontend, stmt_st, sql_params)?;
            let tx_stats = TxStats::new(engine.tx(), engine.stats_cache());
            let num_ir = resolve_and_stats(ir.ir, &tx_stats)?;
            let result = compiler.compile_select(DatalogNumIRSt {
                num_ir: num_ir.clone(),
            })?;
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
                let tx_stats = TxStats::new(engine.tx(), engine.stats_cache());
                let num_ir = resolve_and_stats(ir.ir, &tx_stats)?;
                let result = compiler.compile_dml_scan(
                    stmt_for_compiler,
                    DatalogNumIRSt {
                        num_ir: num_ir.clone(),
                    },
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

        let (result, _) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;

        Ok(ProgramHandle {
            program: Arc::new(result.program),
        })
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

        let limit_opt = if limit == u64::MAX {
            None
        } else {
            Some(limit as usize)
        };
        let as_of_opt = if as_of_us == u64::MAX {
            None
        } else {
            Some(as_of_us)
        };

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
            Err(e) => Err(e.0),
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
        let limit_opt = if limit == u64::MAX {
            None
        } else {
            Some(limit as usize)
        };
        let as_of_us_opt = if as_of_us == u64::MAX {
            None
        } else {
            Some(as_of_us)
        };

        let t = engine.allocate_t_and_write_tx();
        let as_of_tx = as_of_us_opt.and_then(|us| engine.tx().resolve_as_of(us).ok().flatten());
        crate::engine::opcodes::reset_scanner_stats();

        let session = engine::session::VMSession::new(
            program.program,
            Arc::clone(engine) as Arc<dyn engine::vm::VMEngine + Send + Sync>,
            vm_params,
            limit_opt,
            t,
            as_of_tx,
        );

        Ok(SessionHandle {
            session: Arc::new(std::cell::RefCell::new(session)),
        })
    }

    fn session_next_batch(&self, session: SessionHandle, max_rows: u64) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        session
            .session
            .borrow_mut()
            .next_batch(&mut out, max_rows as usize)?;
        Ok(out)
    }

    fn explain(&self, sql: &str, sql_params: &[u8]) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, _) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;

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

        let (result, num_ir) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;

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

        let (result, _) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;
        Ok(result.program.to_json())
    }

    fn scan_datoms(&self, as_of_us: u64) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;

        let as_of_tx = if as_of_us == u64::MAX {
            None
        } else {
            engine.tx().resolve_as_of(as_of_us)?
        };

        // Read raw EAVT keys and decode values using the attribute's own value type,
        // so Ref/Boolean/Instant/etc. are decoded correctly instead of as raw Int64 bits.
        let eavt_keys = engine.tx().scan(0, b"").unwrap_or_default();
        let mut pos = 0;
        let mut all: Vec<spier_transactor::keys::RawDatom> = Vec::new();
        while pos + 4 <= eavt_keys.len() {
            let klen = u32::from_be_bytes([
                eavt_keys[pos],
                eavt_keys[pos + 1],
                eavt_keys[pos + 2],
                eavt_keys[pos + 3],
            ]) as usize;
            pos += 4;
            if pos + klen > eavt_keys.len() {
                break;
            }
            let key = &eavt_keys[pos..pos + klen];
            pos += klen;

            let raw = spier_transactor::keys::unpack_key_with_vt("eavt", key, |aid| {
                engine
                    .tx()
                    .value_type_for(aid)
                    .ok()
                    .flatten()
                    .map(spier_transactor::value_type_to_eid)
            });
            all.push(raw);
        }

        // Keep only active (non-retracted) datoms, applying as-of if requested.
        // Group by (e, a, v) and take the latest t.
        use std::collections::HashMap;
        let mut groups: HashMap<(u64, u32, Value), spier_transactor::keys::RawDatom> =
            HashMap::new();
        for raw in all {
            if let Some(as_of) = as_of_tx {
                if raw.t > as_of {
                    continue;
                }
            }
            let group_key = (raw.e, raw.a, raw.v.clone());
            match groups.get(&group_key) {
                Some(existing) if existing.t > raw.t => {}
                _ => {
                    groups.insert(group_key, raw);
                }
            }
        }

        let mut active: Vec<&spier_transactor::keys::RawDatom> =
            groups.values().filter(|d| !d.retracted).collect();
        active.sort_by(|a, b| a.e.cmp(&b.e).then_with(|| a.a.cmp(&b.a)).then_with(|| format!("{:?}", a.v).cmp(&format!("{:?}", b.v))));

        let mut values: Vec<Value> = Vec::with_capacity(active.len() * 5);
        for d in active {
            let tx = engine.tx();
            let attr_name = tx.attr_name(d.a)?;

            // Decorar refs cujo alvo seja uma entidade de schema (PART_DB) com
            // seu db.ident quando disponível no Resolver, exibindo "name(eid)".
            // Refs a partições de usuário/tx permanecem como número puro.
            let v_out = match (&d.v, tx.value_type_for(d.a)?) {
                (Value::Int64(eid), Some(ValueType::Ref))
                    if spier_transactor::resolver_consts::partition_of(*eid as u64)
                        == spier_transactor::resolver::PART_DB =>
                {
                    match tx.attr_name_opt(*eid as u32)? {
                        Some(name) => Value::Text(format!("{}({})", name, eid)),
                        None => d.v.clone(),
                    }
                }
                _ => d.v.clone(),
            };

            values.push(Value::Int64(d.e as i64));
            values.push(Value::Int64(d.a as i64));
            values.push(Value::Text(attr_name.into()));
            values.push(v_out);
            values.push(Value::Int64(d.t as i64));
        }

        let mut out = Vec::new();
        out.extend_from_slice(&(5u32).to_be_bytes());
        out.extend(query_codec::encode_values(&values));
        Ok(out)
    }

    // ------------------------------------------------------------------
    // 2. SCHEMA — delegates to TransactorEngine
    // ------------------------------------------------------------------

    fn declare_attr(&self, name: &str, value_type: ValueType, many: bool) -> Result<u32, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine
            .tx()
            .eavt_declare_attr(name, value_type, many, u64::MAX)
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
