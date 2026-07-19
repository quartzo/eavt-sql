use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use spier_storage_traits::invalid_cursor_handle;
use spier_kvstore::transactor::keys::{self};
use spier_kvstore::transactor::resolver_consts as resolver;
use spier_kvstore::transactor::TransactorEngine;
use spier_kvstore::transactor::TransactorState;
use spier_value::Value;

use crate::engine::types::{EngineError, EngineOps, QueryContext, RawDatomView};

fn cf_name_to_id() -> HashMap<String, usize> {
    spier_kvstore::transactor::constants::cf_name_map()
}

/// TTL cache for cardinality estimates. Keyed by (cf_id, prefix_bytes).
/// Entries expire after STATS_TTL. Prevents repeated MemTable scans during
/// compile — estimates only feed join-variable ordering, never correctness,
/// so short staleness is safe.
pub(crate) struct StatsCache {
    entries: RwLock<HashMap<(u32, Vec<u8>), (Instant, f64)>>,
}

const STATS_TTL: Duration = Duration::from_secs(30);
const STATS_MAX_ENTRIES: usize = 512;

impl StatsCache {
    fn new() -> Self {
        Self {
            entries: RwLock::new(HashMap::new()),
        }
    }

    /// Returns cached estimate if fresh (< STATS_TTL old).
    pub(crate) fn get(&self, key: &(u32, Vec<u8>)) -> Option<f64> {
        let entries = self.entries.read().unwrap();
        let (ts, val) = entries.get(key)?;
        if ts.elapsed() < STATS_TTL {
            Some(*val)
        } else {
            None
        }
    }

    pub(crate) fn put(&self, key: (u32, Vec<u8>), val: f64) {
        let mut entries = self.entries.write().unwrap();
        if entries.len() >= STATS_MAX_ENTRIES {
            entries.clear();
        }
        entries.insert(key, (Instant::now(), val));
    }

    /// Invalidate all entries (called after flush/schema changes if needed).
    #[allow(dead_code)]
    fn invalidate(&self) {
        self.entries.write().unwrap().clear();
    }
}

pub struct QueryEngineInner {
    tx: Arc<TransactorState>,
    cf_map: HashMap<String, usize>,
    vt_cache: RwLock<HashMap<u32, Option<u32>>>,
    attr_id_cache: RwLock<HashMap<String, Option<u32>>>,
    stats_cache: StatsCache,
    path: String,
}

impl QueryEngineInner {
    pub fn load(_name: &str, config: &HashMap<String, String>) -> Result<Self, String> {
        let tx = Arc::new(TransactorState::open(config)?);
        let path = config.get("path").cloned().unwrap_or_default();
        Ok(Self {
            tx,
            cf_map: cf_name_to_id(),
            vt_cache: RwLock::new(HashMap::new()),
            attr_id_cache: RwLock::new(HashMap::new()),
            stats_cache: StatsCache::new(),
            path,
        })
    }

    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        Self::load("spier_kvstore", config)
    }

    pub fn open_read_only(config: &HashMap<String, String>) -> Result<Self, String> {
        let mut config = config.clone();
        config.insert("read_only".into(), "true".into());
        Self::load("spier_kvstore", &config)
    }

    pub fn open_in_memory(config: &HashMap<String, String>) -> Result<Self, String> {
        let mut config = config.clone();
        config.insert("backend".into(), "memory".into());
        config.remove("path");
        let mut engine = Self::load("spier_kvstore", &config)?;
        engine.path = ":memory:".to_string();
        Ok(engine)
    }

    pub fn open_s3(config: &HashMap<String, String>) -> Result<Self, String> {
        let s3_url = config
            .get("path")
            .or_else(|| config.get("url"))
            .ok_or("path/url required for s3 backend")?;
        let parsed: Vec<&str> = s3_url.trim_start_matches("s3://").splitn(2, '/').collect();
        let bucket = parsed.first().ok_or("S3 URL missing bucket")?.to_string();
        let prefix = parsed.get(1).unwrap_or(&"").to_string();
        let prefix = if prefix.is_empty() {
            "eavt".to_string()
        } else {
            prefix
        };

        let access_key =
            std::env::var("AWS_ACCESS_KEY_ID").map_err(|_| "AWS_ACCESS_KEY_ID not set")?;
        let secret_key =
            std::env::var("AWS_SECRET_ACCESS_KEY").map_err(|_| "AWS_SECRET_ACCESS_KEY not set")?;
        let endpoint = std::env::var("AWS_ENDPOINT_URL_S3")
            .or_else(|_| std::env::var("AWS_ENDPOINT_URL"))
            .map_err(|_| "AWS_ENDPOINT_URL_S3 or AWS_ENDPOINT_URL not set")?;
        let region = std::env::var("AWS_REGION")
            .or_else(|_| std::env::var("AWS_DEFAULT_REGION"))
            .unwrap_or_else(|_| "us-east-1".into());

        let journal_dir = format!("/tmp/eavt-journal/{}/{}", bucket, prefix);
        std::fs::create_dir_all(&journal_dir).map_err(|e| format!("journal dir: {e}"))?;

        let mut config = config.clone();
        config.insert("backend".into(), "s3".into());
        config.insert("path".into(), journal_dir);
        config.insert("endpoint".into(), endpoint);
        config.insert("bucket_name".into(), bucket);
        config.insert("region".into(), region);
        config.insert("access_key".into(), access_key);
        config.insert("secret_key".into(), secret_key);
        config.insert("prefix".into(), prefix);

        let mut engine = Self::load("spier_kvstore", &config)?;
        engine.path = s3_url.to_string();
        Ok(engine)
    }

    pub fn tx(&self) -> &dyn TransactorEngine {
        self.tx.as_ref()
    }

    pub(crate) fn stats_cache(&self) -> &StatsCache {
        &self.stats_cache
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

    fn value_type_for_cached(&self, aid: u32) -> Option<u32> {
        if let Ok(cache) = self.vt_cache.read() {
            if let Some(vt) = cache.get(&aid) {
                return *vt;
            }
        }
        let vt = self
            .tx
            .value_type_for(aid)
            .ok()
            .flatten()
            .map(spier_kvstore::transactor::value_type_to_eid);
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

}

impl EngineOps for QueryEngineInner {
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
    ) -> Result<std::sync::Arc<std::cell::RefCell<dyn spier_storage_traits::Cursor>>, String> {
        let h = self.tx.open_cursor_direct(cf_id, prefix)?;
        Ok(h.cursor)
    }

    fn collect_active(&self, cf: &str, prefix: &[u8], ctx: &QueryContext) -> Vec<RawDatomView> {
        // Direct cursor iteration mirroring `TransactorEngine::collect_active_raw`
        // (spier-transactor/src/eavt.rs). One datom per group is returned — the
        // one with the greatest `t` not exceeding `as_of_tx` — and only if that
        // latest datom is non-retracted. The cursor is prefix-bounded by
        // `MergedInner`, so no explicit prefix check is needed here.
        let cf_id = self.cf_id(cf) as u32;
        let prefix = prefix.to_vec();
        let cursor = match self.tx.open_cursor_direct(cf_id, &prefix) {
            Ok(h) => h.cursor,
            Err(_) => invalid_cursor_handle().cursor,
        };
        let as_of_tx = ctx.as_of_tx;
        let mut results: Vec<RawDatomView> = Vec::new();
        let mut prev_group: Option<Vec<u8>> = None;
        let mut best: Option<RawDatomView> = None;
        while cursor.borrow().is_valid() {
            let key = cursor.borrow().current_key().unwrap().to_vec();
            if key.len() < 8 {
                cursor.borrow_mut().step();
                continue;
            }
            let raw = keys::unpack_key_with_vt(cf, &key, |aid| self.value_type_for_cached(aid));
            if let Some(as_of) = as_of_tx {
                if raw.t > as_of {
                    cursor.borrow_mut().step();
                    continue;
                }
            }
            let group_end = key.len() - 8;
            let group = key[..group_end].to_vec();
            if Some(&group) != prev_group.as_ref() {
                if let Some(b) = best.take() {
                    if !b.retracted {
                        results.push(b);
                    }
                }
                prev_group = Some(group);
                best = Some(RawDatomView {
                    v: raw.v,
                    t: raw.t,
                    retracted: raw.retracted,
                });
            } else if let Some(ref mut b) = best {
                if raw.t > b.t {
                    *b = RawDatomView {
                        v: raw.v,
                        t: raw.t,
                        retracted: raw.retracted,
                    };
                }
            }
            cursor.borrow_mut().step();
        }
        if let Some(b) = best {
            if !b.retracted {
                results.push(b);
            }
        }
        results
    }

    fn save_with_t(
        &self,
        e: &Value,
        attr: &str,
        v: &Value,
        ctx: &QueryContext,
    ) -> Result<(), EngineError> {
        let e_id = self.resolve_entity(e);
        let as_of = ctx.as_of_tx.unwrap_or(u64::MAX);
        self.tx
            .eavt_save(e_id, attr, v.clone(), ctx.current_t, as_of)
            .map_err(EngineError)
    }

    fn retract(&self, e: &Value, attr: &str, v: &Value, ctx: &QueryContext) {
        let e_id = self.resolve_entity(e);
        let as_of = ctx.as_of_tx.unwrap_or(u64::MAX);
        let _ = self
            .tx
            .eavt_retract(e_id, attr, v.clone(), ctx.current_t, as_of);
    }

    fn declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        ctx: &QueryContext,
    ) -> Result<(), EngineError> {
        let result = self
            .tx
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
        self.tx
            .default_user_partition()
            .unwrap_or(resolver::PART_USER)
    }

    fn allocate_t_and_write_tx(&self) -> u64 {
        self.tx.eavt_allocate_tx().unwrap_or(0)
    }

    fn declare_partition(&self, name: &str, ctx: &QueryContext) -> Result<u64, EngineError> {
        self.tx
            .eavt_declare_partition(name, ctx.current_t)
            .map_err(EngineError)
    }

    fn lookup_entity(&self, attr_name: &str, value: &Value, _ctx: &QueryContext) -> Option<u64> {
        self.tx
            .lookup_entity(attr_name, value.clone())
            .ok()
            .flatten()
    }

    fn lookup_value(&self, eid: u64, attr_name: &str, ctx: &QueryContext) -> Option<Value> {
        let aid = self.lookup_attr_cached(attr_name)?;
        let prefix: Vec<u8> = spier_kvstore::transactor::keys::encode_int64(eid as i64)
            .to_be_bytes()
            .iter()
            .chain(aid.to_be_bytes().iter())
            .copied()
            .collect();
        self.collect_active("eavt", &prefix, ctx)
            .into_iter()
            .next()
            .map(|d| d.v)
    }

    fn is_unique_attr(&self, attr_name: &str) -> bool {
        self.tx.is_unique_attr(attr_name).unwrap_or(false)
    }

    fn value_type_for(&self, aid: u32) -> Option<u32> {
        self.value_type_for_cached(aid)
    }
}
