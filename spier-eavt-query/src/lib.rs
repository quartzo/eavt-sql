use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

mod engine;

pub use spier_query_ir::ProgramHandle;
pub use spier_storage_traits::CursorHandle;

use spier_compiler::{CompileResultSt, CompilerEngine};
use spier_datalog::CompileStats;
use spier_datalog::{
    resolve::{compute_plan_stats, resolve_ir},
    DatalogIR, DatalogNumIR, DatalogNumIRSt,
};
use spier_query_ir::SpecKind;
use spier_sql_frontend::SqlFrontendEngine;
use spier_sql_parse::RustStmt;
use spier_transactor::TransactorEngine;
pub use spier_transactor::ValueType;
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
    fn execute(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<Vec<u8>, String>;
    fn open_cursor(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<SessionHandle, String>;
    fn session_next_batch(&self, session: SessionHandle, max_rows: u64) -> Result<Vec<u8>, String>;
    fn explain(&self, sql: &str, sql_params: &[u8]) -> Result<String, String>;
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
    fn attr_name_opt(&self, eid: u32) -> Result<Option<String>, String>;
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
use engine::types::EngineOps;
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
                prefix.extend_from_slice(&keys::encode_int64(val as i64).to_be_bytes());
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

    fn is_indexed_attr(&self, name: &str) -> bool {
        if let Some(aid) = TransactorEngine::lookup_attr(self.tx, name)
            .ok()
            .flatten()
        {
            TransactorEngine::is_unique(self.tx, aid).unwrap_or(false)
                || TransactorEngine::is_indexed(self.tx, aid).unwrap_or(false)
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
/// Returns (CompileResult, Option<DatalogIR>) — the num_ir is for explain.
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

// Additional KVStore-adjacent methods for PyO3 (not part of QueryEngine trait)
impl QueryState {
    pub fn allocate_in_partition(&self, partition_id: u64) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().allocate_in_partition(partition_id)
    }

    pub fn is_unique(&self, aid: u32) -> Result<bool, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().is_unique(aid)
    }

    pub fn default_user_partition(&self) -> Result<u64, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().default_user_partition()
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

    fn execute(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> Result<Vec<u8>, String> {
        let inner = self.inner.read().unwrap();

        let engine = inner.engine.as_ref().ok_or("engine not open")?;

        let vm_params = query_codec::decode_values(sql_params)?;

        let _limit_opt = if limit == u64::MAX {
            None
        } else {
            Some(limit as usize)
        };
        let as_of_opt = if as_of_us == u64::MAX {
            None
        } else {
            Some(as_of_us)
        };

        let t = engine.allocate_t_and_write_tx();
        let as_of_tx = as_of_opt.and_then(|us| engine.tx().resolve_as_of(us).ok().flatten());

        match &*program.program {
            spier_query_ir::Program::Scheme(scheme_prog) => {
                let mut session = engine::scheme::SchemeSession::new(
                    scheme_prog.clone(),
                    Arc::clone(engine),
                    vm_params,
                    t,
                    as_of_tx,
                );
                let mut out = Vec::new();
                session.next_batch(&mut out, 1)?;
                Ok(out)
            }
            spier_query_ir::Program::SelectScheme(scheme_prog, meta) => {
                let mut session = build_select_scheme_session(
                    engine, scheme_prog, meta, vm_params, t, as_of_tx,
                );
                let mut out = Vec::new();
                session.next_batch(&mut out, usize::MAX)?;
                Ok(out)
            }
        }
    }

    fn open_cursor(
        &self,
        program: ProgramHandle,
        sql_params: &[u8],
        _limit: u64,
        as_of_us: u64,
    ) -> Result<SessionHandle, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let vm_params = query_codec::decode_values(sql_params)?;
        let as_of_us_opt = if as_of_us == u64::MAX {
            None
        } else {
            Some(as_of_us)
        };

        let t = engine.allocate_t_and_write_tx();
        let as_of_tx = as_of_us_opt.and_then(|us| engine.tx().resolve_as_of(us).ok().flatten());

        let session: Arc<RefCell<dyn VMResultStream>> = match &*program.program {
            spier_query_ir::Program::Scheme(scheme_prog) => {
                Arc::new(RefCell::new(engine::scheme::SchemeSession::new(
                    scheme_prog.clone(),
                    Arc::clone(engine),
                    vm_params,
                    t,
                    as_of_tx,
                )))
            }
            spier_query_ir::Program::SelectScheme(scheme_prog, meta) => {
                Arc::new(RefCell::new(build_select_scheme_session(
                    engine, scheme_prog, meta, vm_params, t, as_of_tx,
                )))
            }
        };

        Ok(SessionHandle { session })
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

        let (result, num_ir) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;

        let mut out = String::new();
        if let Some(ir) = num_ir {
            out.push_str(&format!("{}\n", ir));
        }
        if !result.iter_plans.is_empty() {
            out.push_str("Plan:\n");
            let hist_tag = if result.history { " (history)" } else { "" };
            let exists_tag = if result.exists_mode { " (exists)" } else { "" };
            out.push_str(&format!(
                "  Join order: [{}]{}{}\n",
                result.ordered_vars.join(", "),
                hist_tag,
                exists_tag,
            ));
            for (i, ip) in result.iter_plans.iter().enumerate() {
                let idx_order = &ip.idx_order;
                out.push_str(&format!("  p{i} @ {}\n", ip.index_name));
                for (pos, slot) in idx_order.iter().enumerate() {
                    let datalog_pos = match slot.as_str() {
                        "e" => 0, "a" => 1, "v" => 2, "t" => 3, "added" => 4,
                        _ => pos,
                    };
                    let spec = &ip.specs[datalog_pos];
                    let bound_val = ip.bound_ints.get(slot);
                    // Para descobrir se esta posição é synthetic, olhar a SpecKind
                    // (var_depths guarda position_name, não var_name).
                    let var_at_pos = match spec {
                        SpecKind::Var(name) => Some(name.clone()),
                        _ => None,
                    };
                    let var_label = ip.var_depths
                        .iter()
                        .find(|(_, ref p)| p == slot)
                        .map(|(d, _)| {
                            if let Some(ref name) = var_at_pos {
                                if let Some(at) = name.find("@p") {
                                    let source = &name[..at];
                                    return format!(" [depth {d} - confirmation: range [{source}, {source}]]");
                                }
                            }
                            format!(" [depth {d}]")
                        });
                        match spec {
                            SpecKind::Var(name) => {
                                // Para synthetics, mostrar source_var em vez do nome synthetic.
                                let display_name = match name.find("@p") {
                                    Some(at) => &name[..at],
                                    None => name.as_str(),
                                };
                                out.push_str(&format!("    {} = ?{}{}\n",
                                    slot, display_name, var_label.as_deref().unwrap_or("")));
                            }
                            SpecKind::Bound(0) => {
                                out.push_str(&format!("    {} = _\n", slot));
                            }
                            SpecKind::BoundAttr(aid) => {
                                out.push_str(&format!("    {} = attr(id={})\n", slot, aid));
                            }
                            SpecKind::BoundParam(idx) => {
                                out.push_str(&format!("    {} = %{}\n", slot, idx));
                            }
                            _ => {
                                out.push_str(&format!("    {} = {}\n", slot,
                                    match spec {
                                        SpecKind::Bound(n) => format!("#{n}"),
                                        SpecKind::BoundValue(v) => format!("{v:?}"),
                                        _ => format!("{:?}", spec),
                                    }));
                            }
                    }
                }
            }
            out.push_str("\n");
        }
        for t in &result.traces {
            out.push_str(&format!("{t}\n"));
        }
        out.push_str(&format!(
            "\n{}",
            match &result.program {
                spier_query_ir::Program::Scheme(p)
                | spier_query_ir::Program::SelectScheme(p, _) => {
                    spier_scheme::write_scheme_pretty(&p.body)
                }
            }
        ));
        Ok(out)
    }

    fn compile_sql_json(&self, sql: &str, sql_params: &[u8]) -> Result<String, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        let frontend = inner.frontend.as_ref().ok_or("frontend not loaded")?;
        let compiler = inner.compiler.as_ref().ok_or("compiler not loaded")?;

        let (result, _) = do_compile(frontend, compiler, engine.as_ref(), sql, sql_params)?;
        Ok(match result.program {
            spier_query_ir::Program::Scheme(p)
            | spier_query_ir::Program::SelectScheme(p, _) => {
                spier_scheme::write_scheme(&p.body)
            }
        })
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

            values.push(Value::Int64(d.e as i64));
            values.push(Value::Int64(d.a as i64));
            values.push(Value::Text(attr_name.into()));
            values.push(d.v.clone());
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

    fn attr_name_opt(&self, eid: u32) -> Result<Option<String>, String> {
        let inner = self.inner.read().unwrap();
        let engine = inner.engine.as_ref().ok_or("engine not open")?;
        engine.tx().attr_name_opt(eid)
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

impl QueryState {
    /// Parse raw Scheme text and wrap as a `ProgramHandle` for debugging.
    pub fn compile_scheme(&self, scheme_text: &str) -> Result<ProgramHandle, String> {
        let parsed = spier_scheme::parse(scheme_text)
            .map_err(|e| format!("scheme parse error: {e}"))?;
        let prog = spier_scheme::SchemeProgram::new(parsed);
        let meta = spier_query_ir::SelectSchemeMeta {
            num_vars: 0,
            depth_var_pairs: vec![],
            same_var_constraints: vec![],
        };
        Ok(ProgramHandle {
            program: Arc::new(spier_query_ir::Program::SelectScheme(prog, meta)),
        })
    }

    /// Parse raw Scheme text and wrap as a `Program::Scheme` (DML host fns:
    /// `declare-attr`, `save`, `retract`, `alloc-entity`, `lookup-entity`,
    /// `lookup-value`, `tx-entity`, `param`, `declare-partition`, `result`).
    pub fn compile_scheme_dml(&self, scheme_text: &str) -> Result<ProgramHandle, String> {
        let parsed = spier_scheme::parse(scheme_text)
            .map_err(|e| format!("scheme parse error: {e}"))?;
        let prog = spier_scheme::SchemeProgram::new(parsed);
        Ok(ProgramHandle {
            program: Arc::new(spier_query_ir::Program::Scheme(prog)),
        })
    }

    /// Run Scheme text and return rows as `Vec<Vec<Value>>` for debugging.
    pub fn compile_scheme_debug(&self, scheme_text: &str) -> Result<Vec<Vec<spier_value::Value>>, String> {
        let parsed = spier_scheme::parse(scheme_text)
            .map_err(|e| format!("scheme parse error: {e}"))?;
        let prog = spier_scheme::SchemeProgram::new(parsed);
        let meta = spier_query_ir::SelectSchemeMeta {
            num_vars: 0,
            depth_var_pairs: vec![],
            same_var_constraints: vec![],
        };

        let (mut session, engine) = {
            let inner = self.inner.read().unwrap();
            let eng = inner.engine.as_ref().ok_or("engine not open")?.clone();
            let t = eng.allocate_t_and_write_tx();
            (build_select_scheme_session(&eng, &prog, &meta, vec![], t, None), eng)
        };

        let mut rows = Vec::new();
        let mut buf = Vec::new();
        loop {
            buf.clear();
            let more = session.next_batch(&mut buf, 1).map_err(|e| format!("scheme error: {e}"))?;
            if buf.is_empty() {
                break;
            }
            let mut pos = 0usize;
            if pos + 4 <= buf.len() {
                let _num_cols = u32::from_be_bytes(buf[pos..pos+4].try_into().unwrap()) as usize;
                pos += 4;
            }
            let mut row = Vec::new();
            while pos < buf.len() {
                let (val, n) = spier_value::query_codec::decode_one(&buf[pos..], 0)
                    .map_err(|e| format!("decode error: {e}"))?;
                row.push(val);
                pos += n;
            }
            rows.push(row);
            if !more {
                break;
            }
        }

        // keep engine alive until session is done
        drop(engine);
        Ok(rows)
    }
}

fn build_select_scheme_session(
    engine: &Arc<engine::query_engine_inner::QueryEngineInner>,
    scheme_prog: &spier_scheme::SchemeProgram,
    _meta: &spier_query_ir::SelectSchemeMeta,
    vm_params: Vec<spier_value::Value>,
    t: u64,
    as_of_tx: Option<u64>,
) -> engine::scheme::SelectSchemeSession {
    let host = engine::scheme::SchemeHostFns::new(
        Arc::clone(engine),
        vm_params,
        t,
        as_of_tx,
    );
    engine::scheme::SelectSchemeSession::new(scheme_prog.clone(), host)
}
