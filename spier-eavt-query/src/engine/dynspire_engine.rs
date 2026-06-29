use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use dynspire_commons::transactor::cursor::invalid_cursor_handle;
use dynspire_commons::transactor::keys::{self, BoundValue, EncodeMode};
use dynspire_commons::transactor::resolver_consts as resolver;
use dynspire_commons::transactor::DynSpireTransactor;
use dynspire_commons::transactor::TransactorEngine;
use dynspire_commons::value::Value;

use crate::engine::scanner::ValueScanner;
use crate::engine::vm::{EngineError, QueryContext, RawDatomView, VMEngine, BoundPart};

fn cf_name_to_id() -> HashMap<String, usize> {
    dynspire_libs::cf_name_map()
}

pub struct DynSpireEngine {
    tx: Arc<DynSpireTransactor>,
    cf_map: HashMap<String, usize>,
    vt_cache: RwLock<HashMap<u32, Option<u32>>>,
    attr_id_cache: RwLock<HashMap<String, Option<u32>>>,
    path: String,
}

impl DynSpireEngine {
    pub fn load(name: &str, config: &HashMap<String, String>) -> Result<Self, String> {
        let tx = DynSpireTransactor::connect(name, config)?;
        let path = config.get("path").cloned().unwrap_or_default();
        Ok(Self {
            tx: Arc::new(tx),
            cf_map: cf_name_to_id(),
            vt_cache: RwLock::new(HashMap::new()),
            attr_id_cache: RwLock::new(HashMap::new()),
            path,
        })
    }

    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        Self::load("spier_transactor", config)
    }

    pub fn open_read_only(config: &HashMap<String, String>) -> Result<Self, String> {
        let mut config = config.clone();
        config.insert("read_only".into(), "true".into());
        Self::load("spier_transactor", &config)
    }

    pub fn open_in_memory(config: &HashMap<String, String>) -> Result<Self, String> {
        let mut config = config.clone();
        config.insert("backend".into(), "memory".into());
        config.remove("path");
        let mut engine = Self::load("spier_transactor", &config)?;
        engine.path = ":memory:".to_string();
        Ok(engine)
    }

    pub fn open_s3(config: &HashMap<String, String>) -> Result<Self, String> {
        let s3_url = config
            .get("path")
            .or_else(|| config.get("url"))
            .ok_or("path/url required for s3 backend")?;
        let parsed: Vec<&str> = s3_url.trim_start_matches("s3://").splitn(2, '/').collect();
        let bucket = parsed.first()
            .ok_or("S3 URL missing bucket")?
            .to_string();
        let prefix = parsed.get(1).unwrap_or(&"").to_string();
        let prefix = if prefix.is_empty() { "eavt".to_string() } else { prefix };

        let access_key = std::env::var("AWS_ACCESS_KEY_ID")
            .map_err(|_| "AWS_ACCESS_KEY_ID not set")?;
        let secret_key = std::env::var("AWS_SECRET_ACCESS_KEY")
            .map_err(|_| "AWS_SECRET_ACCESS_KEY not set")?;
        let endpoint = std::env::var("AWS_ENDPOINT_URL_S3")
            .or_else(|_| std::env::var("AWS_ENDPOINT_URL"))
            .map_err(|_| "AWS_ENDPOINT_URL_S3 or AWS_ENDPOINT_URL not set")?;
        let region = std::env::var("AWS_REGION")
            .or_else(|_| std::env::var("AWS_DEFAULT_REGION"))
            .unwrap_or_else(|_| "us-east-1".into());

        let journal_dir = format!("/tmp/eavt-journal/{}/{}", bucket, prefix);
        std::fs::create_dir_all(&journal_dir)
            .map_err(|e| format!("journal dir: {e}"))?;

        let mut config = config.clone();
        config.insert("backend".into(), "s3".into());
        config.insert("path".into(), journal_dir);
        config.insert("endpoint".into(), endpoint);
        config.insert("bucket_name".into(), bucket);
        config.insert("region".into(), region);
        config.insert("access_key".into(), access_key);
        config.insert("secret_key".into(), secret_key);
        config.insert("prefix".into(), prefix);

        let mut engine = Self::load("spier_transactor", &config)?;
        engine.path = s3_url.to_string();
        Ok(engine)
    }

    pub fn tx(&self) -> &Arc<DynSpireTransactor> {
        &self.tx
    }

    fn cf_id(&self, cf: &str) -> usize {
        *self.cf_map.get(cf).unwrap_or(&0)
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn flush(&self) -> Result<(), String> {
        self.tx.flush()
    }

    pub fn close(&self) -> Result<(), String> {
        self.tx.close()
    }

    pub fn memtable_size(&self) -> u64 {
        self.tx.memtable_size().unwrap_or(0)
    }

    pub fn memtable_count(&self, cf: u32) -> u64 {
        self.tx.memtable_count(cf).unwrap_or(0)
    }

    pub fn wal_size(&self) -> u64 {
        self.tx.journal_size().unwrap_or(0)
    }

    pub fn collect_active_deduped(&self, cf: &str, prefix: &[u8], as_of_us: Option<u64>) -> Vec<RawDatomView> {
        let cf_id = self.cf_id(cf);
        let prefix = prefix.to_vec();
        let attr_type = self.attr_type_from_prefix(cf, &prefix);
        let cursor = match self.tx.open_cursor_direct(cf_id as u32, &prefix) {
            Ok(h) => h.cursor,
            Err(_) => invalid_cursor_handle().cursor,
        };
        let mut scanner = ValueScanner::new(cursor, prefix.clone(), cf, "v", as_of_us, attr_type);

        let mut prev_eav_key: Option<Vec<u8>> = None;
        let mut best: Option<RawDatomView> = None;
        let mut results = Vec::new();
        while !scanner.at_end() {
            if let Some(key) = scanner.current_key() {
                let eav_key = key[..key.len() - 8].to_vec();
                let raw = keys::unpack_key_with_vt(cf, key, |aid| self.value_type_for_cached(aid));
                if Some(&eav_key) != prev_eav_key.as_ref() {
                    if let Some(b) = best.take() {
                        if !b.retracted {
                            results.push(b);
                        }
                    }
                    prev_eav_key = Some(eav_key);
                    best = Some(RawDatomView {
                        e: raw.e,
                        a: raw.a,
                        v: raw.v,
                        t: raw.t,
                        retracted: raw.retracted,
                    });
                } else if let Some(ref mut b) = best {
                    if raw.t > b.t {
                        b.t = raw.t;
                        b.retracted = raw.retracted;
                    }
                }
            }
            scanner.next();
        }
        if let Some(b) = best {
            if !b.retracted {
                results.push(b);
            }
        }
        results
    }

    fn value_type_for_cached(&self, aid: u32) -> Option<u32> {
        if let Ok(cache) = self.vt_cache.read() {
            if let Some(vt) = cache.get(&aid) {
                return *vt;
            }
        }
        let vt = self.tx.value_type_for(aid).ok().flatten().map(|v| v as u32);
        if let Ok(mut cache) = self.vt_cache.write() {
            cache.insert(aid, vt);
        }
        vt
    }

    fn lookup_attr_cached(&self, name: &str) -> Option<u32> {
        if let Ok(cache) = self.attr_id_cache.read() {
            if let Some(aid) = cache.get(name) {
                return *aid;
            }
        }
        let aid = self.tx.lookup_attr(name).ok().flatten();
        if let Ok(mut cache) = self.attr_id_cache.write() {
            cache.insert(name.to_string(), aid);
        }
        aid
    }

    fn attr_type_from_prefix(&self, cf: &str, prefix: &[u8]) -> Option<u32> {
        let a_off = match cf {
            "eavt" | "vaet" => 8,
            "aevt" | "avet" => 0,
            _ => return None,
        };
        if prefix.len() >= a_off + 4 {
            let a_id = u32::from_be_bytes(prefix[a_off..a_off + 4].try_into().ok()?);
            self.value_type_for_cached(a_id)
        } else {
            None
        }
    }

    fn resolve_bound_prefix(
        &self,
        index: &str,
        bound: &[BoundPart],
    ) -> (String, usize, Vec<u8>, Option<u32>) {
        let cf = keys::cf_for_index(index).to_string();
        let cf_id = self.cf_id(&cf);
        let idx_order = keys::index_order(index);

        let bound_attr_id: Option<u32> = bound.iter().enumerate().find_map(|(i, b)| {
            let pos = idx_order.get(i).copied().unwrap_or("");
            if pos == "a" {
                match b {
                    BoundPart::Attr(a) => Some(*a),
                    BoundPart::Val(v) => {
                        if let Value::Text(ref s) = v {
                            self.lookup_attr_cached(s)
                        } else {
                            Some(v.raw_int() as u32)
                        }
                    }
                    _ => None,
                }
            } else {
                None
            }
        });

        let value_attr_type = bound_attr_id.and_then(|a| self.value_type_for_cached(a));
        let mode = keys::encode_mode_for(value_attr_type);
        let is_ref_attr = mode == EncodeMode::Ref;

        let bound_vals: Vec<BoundValue> = bound
            .iter()
            .enumerate()
            .map(|(i, b)| match b {
                BoundPart::Int(n) => BoundValue::Int(*n),
                BoundPart::Attr(a) => BoundValue::Attr(*a),
                BoundPart::Val(v) => {
                    let pos = idx_order.get(i).copied().unwrap_or("v");
                    match pos {
                        "v" => {
                            if is_ref_attr {
                                BoundValue::Ref(v.raw_int() as u64)
                            } else {
                                BoundValue::Val(v.clone())
                            }
                        }
                        "a" => {
                            if let Value::Text(ref s) = v {
                                BoundValue::Attr(self.lookup_attr_cached(s).unwrap_or(0))
                            } else {
                                BoundValue::Attr(v.raw_int() as u32)
                            }
                        }
                        _ => BoundValue::Int(v.raw_int() as u64),
                    }
                }
            })
            .collect();

        let prefix = keys::build_prefix(index, &bound_vals, mode);
        (cf, cf_id, prefix, value_attr_type)
    }

    pub fn run_vm(
        self: &Arc<Self>,
        program: Arc<crate::engine::opcodes::VMProgram>,
        params: Vec<Value>,
        limit: Option<usize>,
        as_of_us: Option<u64>,
    ) -> Result<Vec<Vec<Value>>, EngineError> {
        let t = self.allocate_t_and_write_tx();

        if std::env::var("EAVT_DEBUG_TIMING").is_ok() {
            crate::engine::opcodes::set_debug_timing(true);
        }
        crate::engine::opcodes::reset_scanner_stats();

        let mut vm = crate::engine::vm::VM::new(program, Arc::clone(self) as Arc<dyn VMEngine + Send + Sync>, params, limit, t, as_of_us);
        let results = vm.run()?;
        Ok(results)
    }
}

impl VMEngine for DynSpireEngine {
    fn resolve_entity(&self, name_or_id: &Value) -> u64 {
        match name_or_id {
            Value::Int64(n) => *n as u64,
            _ => name_or_id.raw_int() as u64,
        }
    }

    fn lookup_attr(&self, name: &str) -> Option<u32> {
        self.lookup_attr_cached(name)
    }

    fn attr_name(&self, aid: u32) -> String {
        self.tx.attr_name(aid).unwrap_or_default()
    }

    fn open_raw_cursor(
        &self,
        cf_id: u32,
        prefix: &[u8],
    ) -> Result<std::sync::Arc<std::cell::RefCell<dyn dynspire_commons::transactor::cursor::Cursor>>, String> {
        let h = self.tx.open_cursor_direct(cf_id, prefix)?;
        Ok(h.cursor)
    }

    fn collect_active(&self, cf: &str, prefix: &[u8], ctx: &QueryContext) -> Vec<RawDatomView> {        let cf_id = self.cf_id(cf);
        let prefix = prefix.to_vec();
        let attr_type = self.attr_type_from_prefix(cf, &prefix);
        let cursor = match self.tx.open_cursor_direct(cf_id as u32, &prefix) {
            Ok(h) => h.cursor,
            Err(_) => invalid_cursor_handle().cursor,
        };
        let mut scanner = ValueScanner::new(cursor, prefix.clone(), cf, "v", ctx.as_of_us, attr_type);
        let mut results = Vec::new();
        while !scanner.at_end() {
            if let Some(key) = scanner.current_key() {
                let raw = keys::unpack_key_with_vt(cf, key, |aid| self.value_type_for_cached(aid));
                if !raw.retracted {
                    results.push(RawDatomView {
                        e: raw.e,
                        a: raw.a,
                        v: raw.v,
                        t: raw.t,
                        retracted: raw.retracted,
                    });
                }
            }
            scanner.next();
        }
        results
    }

    fn probe_collect(&self, index: &str, bound: &[BoundPart], ctx: &QueryContext) -> Vec<RawDatomView> {
        let (cf, _, prefix, _) = self.resolve_bound_prefix(index, bound);
        self.collect_active(&cf, &prefix, ctx)
    }

    fn save_with_t(
        &self,
        e: &Value,
        attr: &str,
        v: &Value,
        ctx: &QueryContext,
    ) -> Result<(), EngineError> {
        let e_id = self.resolve_entity(e);
        let as_of = ctx.as_of_us.unwrap_or(u64::MAX);
        self.tx.eavt_save(e_id, attr, v.clone(), ctx.current_t, as_of).map_err(EngineError)
    }

    fn retract(&self, e: &Value, attr: &str, v: &Value, ctx: &QueryContext) {
        let e_id = self.resolve_entity(e);
        let as_of = ctx.as_of_us.unwrap_or(u64::MAX);
        let _ = self.tx.eavt_retract(e_id, attr, v.clone(), ctx.current_t, as_of);
    }

    fn declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        ctx: &QueryContext,
    ) -> Result<(), EngineError> {
        let result = self.tx
            .eavt_declare_attr_from_sql(attr, type_name, many, unique, ctx.current_t)
            .map_err(EngineError);
        if result.is_ok() {
            if let Ok(mut cache) = self.attr_id_cache.write() {
                cache.remove(attr);
            }
        }
        result
    }

    fn allocate_in_partition(&self, partition_id: u64) -> u64 {
        self.tx.allocate_in_partition(partition_id).unwrap_or(0)
    }

    fn default_user_partition(&self) -> u64 {
        self.tx.default_user_partition().unwrap_or(resolver::PART_USER)
    }

    fn allocate_t_and_write_tx(&self) -> u64 {
        self.tx.eavt_allocate_tx().unwrap_or(0)
    }

    fn declare_partition(&self, name: &str, ctx: &QueryContext) -> Result<u64, EngineError> {
        self.tx.eavt_declare_partition(name, ctx.current_t).map_err(EngineError)
    }

    fn lookup_entity(&self, attr_name: &str, value: &Value, _ctx: &QueryContext) -> Option<u64> {
        self.tx.lookup_entity(attr_name, value.clone()).ok().flatten()
    }

    fn lookup_value(&self, eid: u64, attr_name: &str, ctx: &QueryContext) -> Option<Value> {
        let aid = self.lookup_attr_cached(attr_name)?;
        let prefix: Vec<u8> = eid.to_be_bytes().iter().chain(aid.to_be_bytes().iter()).copied().collect();
        self.collect_active("eavt", &prefix, ctx).into_iter().next().map(|d| d.v)
    }

    fn is_unique_attr(&self, attr_name: &str) -> bool {
        self.tx.is_unique_attr(attr_name).unwrap_or(false)
    }

    fn value_type_for(&self, aid: u32) -> Option<u32> {
        self.value_type_for_cached(aid)
    }
}
