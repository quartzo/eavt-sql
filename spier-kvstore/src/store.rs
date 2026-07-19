use std::sync::{Arc, Mutex, RwLock};

use crate::error::{TransactorError, TransactorResult};
use crate::memtable::{MemTableEngine, MemTableSnapshot};
use crate::merge_iter::{ReverseSourceKind, SourceKind};
use crate::page_store::{self};
use spier_page_store_nim::NimPageStore;
use spier_storage_traits::GcFullResult;

fn unpack_keys(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut keys = Vec::new();
    let mut pos = 0;
    while pos + 4 <= buf.len() {
        let len = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        keys.push(buf[pos..pos + len].to_vec());
        pos += len;
    }
    keys
}

#[cfg(test)]
pub(crate) fn unpack_kv(buf: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    let mut entries = Vec::new();
    let mut pos = 0;
    while pos + 4 <= buf.len() {
        let klen =
            u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        let key = buf[pos..pos + klen].to_vec();
        pos += klen;
        let vlen =
            u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        let val = buf[pos..pos + vlen].to_vec();
        pos += vlen;
        entries.push((key, val));
    }
    entries
}
#[derive(Clone)]
pub struct TransactorConfig {
    pub num_cf: usize,
    pub flush_threshold: usize,
    pub hard_flush_threshold: usize,
    pub restart_interval: u32,
    pub gc_max_age_secs: u64,
    pub gc_max_root_count: usize,
    pub page_cache_size: usize,
}

pub use spier_storage_traits::{CfStats, DbStats};

impl Default for TransactorConfig {
    fn default() -> Self {
        Self {
            num_cf: 4,
            flush_threshold: 64 << 20,
            hard_flush_threshold: 500 << 20,
            restart_interval: 256,
            gc_max_age_secs: 12 * 3600,
            gc_max_root_count: 10,
            page_cache_size: 64 * 1024 * 1024,
        }
    }
}

struct StoreInner {
    store: Option<Arc<NimPageStore>>,
    // flush_snap MUST be dropped before mt — snapshot_free needs the memtable alive.
    // Rust drops fields in declaration order, so flush_snap comes before mt.
    flush_snap: Option<MemTableSnapshot>,
    mt: Arc<spier_memtable::MemTable>,
    mt_size: u64,
    config: TransactorConfig,
    path: String,
    read_only: bool,
}

impl StoreInner {
    fn load_page_keys(store: &NimPageStore, cf_id: usize, prefix: &[u8]) -> Vec<Vec<u8>> {
        match store.get_keys_in_prefix(cf_id as u32, prefix) {
            Ok(keys) => keys,
            Err(_) => Vec::new(),
        }
    }

    fn scan_sources(&self, cf_id: usize, prefix: &[u8]) -> Vec<SourceKind> {
        let mut sources = Vec::new();
        if let Some(ref store) = self.store {
            let keys = Self::load_page_keys(store.as_ref(), cf_id, prefix);
            if !keys.is_empty() {
                sources.push(SourceKind::PageStore(
                    crate::merge_iter::PageStoreIter::new(keys, prefix),
                ));
            }
        }
        if let Some(ref snap) = self.flush_snap {
            if let Ok(cursor) = self.mt.open_scan_source(snap.clone(), cf_id as u32, prefix, false) {
                sources.push(SourceKind::MemTable(
                    crate::merge_iter::ChunkedMemTableSource::new(cursor, prefix),
                ));
            }
        }
        let live_snap = self.mt.snapshot().unwrap();
        if let Ok(cursor) = self.mt.open_scan_source(live_snap, cf_id as u32, prefix, false) {
            sources.push(SourceKind::MemTable(
                crate::merge_iter::ChunkedMemTableSource::new(cursor, prefix),
            ));
        }
        sources
    }

    fn scan_reverse_sources(&self, cf_id: usize, prefix: &[u8]) -> Vec<ReverseSourceKind> {
        let mut sources = Vec::new();
        if let Some(ref store) = self.store {
            let mut keys = Self::load_page_keys(store.as_ref(), cf_id, prefix);
            keys.reverse();
            sources.push(ReverseSourceKind::PageStore(
                crate::merge_iter::ReversePageStoreIter::new(keys, prefix),
            ));
        }
        if let Some(ref snap) = self.flush_snap {
            let packed = self
                .mt
                .scan_prefix_reverse(snap.clone(), cf_id as u32, prefix)
                .unwrap_or_default();
            let snap_keys = unpack_keys(&packed);
            sources.push(ReverseSourceKind::MemTable(
                crate::merge_iter::ReversePageStoreIter::new(snap_keys, prefix),
            ));
        }
        let live_snap = self.mt.snapshot().unwrap();
        let packed = self
            .mt
            .scan_prefix_reverse(live_snap, cf_id as u32, prefix)
            .unwrap_or_default();
        let mt_keys = unpack_keys(&packed);
        sources.push(ReverseSourceKind::MemTable(
            crate::merge_iter::ReversePageStoreIter::new(mt_keys, prefix),
        ));
        sources
    }

    fn flush_snapshot(
        store: &NimPageStore,
        mt: &dyn MemTableEngine,
        snap: &MemTableSnapshot,
        num_cf: usize,
    ) -> TransactorResult<()> {
        let mut keys_by_cf: Vec<(usize, Vec<Vec<u8>>)> = Vec::new();

        for cf_id in 0..num_cf {
            let packed = mt
                .scan_prefix(snap.clone(), cf_id as u32, b"")
                .map_err(|e| TransactorError::Internal(format!("snapshot scan_prefix: {e}")))?;
            let new_keys = unpack_keys(&packed);
            if new_keys.is_empty() {
                continue;
            }
            keys_by_cf.push((cf_id, new_keys));
        }

        store.commit_merge(&keys_by_cf, true).map_err(|e| {
            TransactorError::Internal(format!("commit_merge: {e}"))
        })?;
        Ok(())
    }
}

pub struct Transactor {
    inner: RwLock<StoreInner>,
    flush_lock: Mutex<()>,
}

impl Transactor {
    pub fn open(
        store: Arc<NimPageStore>,
        mt: spier_memtable::MemTable,
        path: &str,
        config: TransactorConfig,
    ) -> TransactorResult<Self> {
        let inner = StoreInner {
            store: Some(store),
            mt: Arc::from(mt),
            mt_size: 0,
            flush_snap: None,
            config,
            path: path.to_string(),
            read_only: false,
        };
        Ok(Self {
            inner: RwLock::new(inner),
            flush_lock: Mutex::new(()),
        })
    }

    pub fn open_read_only(
        store: Arc<NimPageStore>,
        mt: spier_memtable::MemTable,
        path: &str,
        config: TransactorConfig,
    ) -> TransactorResult<Self> {
        let inner = StoreInner {
            store: Some(store),
            mt: Arc::from(mt),
            mt_size: 0,
            flush_snap: None,
            config,
            path: path.to_string(),
            read_only: true,
        };
        Ok(Self {
            inner: RwLock::new(inner),
            flush_lock: Mutex::new(()),
        })
    }

    fn swap_memtable(&self) {
        let mut inner = self.inner.write().unwrap();
        if inner.flush_snap.is_some() {
            return;
        }
        inner.flush_snap = inner.mt.snapshot().ok();
        let _ = inner.mt.clear();
        inner.mt_size = 0;
    }

    pub fn put(&self, cf_id: usize, key: &[u8]) -> TransactorResult<()> {
        if key.len() > u32::MAX as usize {
            return Err(TransactorError::InvalidArg(format!(
                "key too large: {} bytes (max {})",
                key.len(),
                u32::MAX
            )));
        }
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let total = inner
            .mt
            .put(cf_id as u32, key)
            .map_err(|e| TransactorError::Internal(format!("memtable put: {e}")))?;
        inner.mt_size = total;
        Ok(())
    }

    pub fn batch_write_raw(&self, ops: &[u8]) -> TransactorResult<()> {
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let total = inner
            .mt
            .batch_write(ops)
            .map_err(|e| TransactorError::Internal(format!("memtable batch_write: {e}")))?;
        inner.mt_size = total;
        Ok(())
    }

    pub fn replay_to_memtable_raw(&self, ops: &[u8]) {
        let inner = self.inner.write().unwrap();
        let _ = inner.mt.batch_write(ops);
    }

    pub fn get(&self, cf_id: usize, key: &[u8]) -> TransactorResult<Option<Vec<u8>>> {
        let inner = self.inner.read().unwrap();
        let live_snap = inner
            .mt
            .snapshot()
            .map_err(|e| TransactorError::Internal(format!("memtable snapshot: {e}")))?;
        let exists = inner
            .mt
            .contains(live_snap, cf_id as u32, key)
            .map_err(|e| TransactorError::Internal(format!("memtable contains: {e}")))?;
        if exists {
            return Ok(Some(vec![]));
        }
        if let Some(ref snap) = inner.flush_snap {
            let exists = inner
                .mt
                .contains(snap.clone(), cf_id as u32, key)
                .map_err(|e| TransactorError::Internal(format!("snapshot contains: {e}")))?;
            if exists {
                return Ok(Some(vec![]));
            }
        }
        if let Some(ref store) = inner.store {
            let exists = store.key_exists(cf_id as u32, key)?;
            if exists {
                return Ok(Some(vec![]));
            }
        }
        Ok(None)
    }

    pub fn items(&self, cf_id: usize) -> TransactorResult<Vec<(Vec<u8>, Vec<u8>)>> {
        self.scan(cf_id, b"")
    }

    pub fn scan_sources(&self, cf_id: usize, prefix: &[u8]) -> Vec<SourceKind> {
        let inner = self.inner.read().unwrap();
        inner.scan_sources(cf_id, prefix)
    }

    pub fn scan_reverse_sources(&self, cf_id: usize, prefix: &[u8]) -> Vec<ReverseSourceKind> {
        let inner = self.inner.read().unwrap();
        inner.scan_reverse_sources(cf_id, prefix)
    }

    pub fn scan(&self, cf_id: usize, prefix: &[u8]) -> TransactorResult<Vec<(Vec<u8>, Vec<u8>)>> {
        let sources = self.scan_sources(cf_id, prefix);
        Ok(crate::merge_iter::merge_collect(sources))
    }

    pub fn scan_reverse(
        &self,
        cf_id: usize,
        prefix: &[u8],
    ) -> TransactorResult<Vec<(Vec<u8>, Vec<u8>)>> {
        let sources = self.scan_reverse_sources(cf_id, prefix);
        let mut merged = crate::merge_iter::ReverseMergedInner::new(sources, prefix);
        let mut result = Vec::new();
        while merged.valid {
            result.push((merged.cur_key.clone().unwrap(), merged.cur_val.clone()));
            merged.step();
        }
        Ok(result)
    }

    pub fn flush(&self) -> TransactorResult<()> {
        let _guard = self
            .flush_lock
            .try_lock()
            .map_err(|_| TransactorError::Busy)?;
        self.flush_unlocked()
    }

    fn flush_unlocked(&self) -> TransactorResult<()> {
        {
            let inner = self.inner.read().unwrap();
            if inner.read_only {
                return Err(TransactorError::ReadOnly);
            }
        }

        let (snap, store, mt, num_cf) = {
            self.swap_memtable();
            let inner = self.inner.write().unwrap();
            let snap = inner.flush_snap.clone().ok_or(TransactorError::Internal(
                "flush called without flush snapshot".into(),
            ))?;
            let store = inner.store.clone().ok_or(TransactorError::Closed)?;
            let mt = Arc::clone(&inner.mt);
            let num_cf = inner.config.num_cf;
            (snap, store, mt, num_cf)
        };

        let result = StoreInner::flush_snapshot(store.as_ref(), mt.as_ref(), &snap, num_cf);

        if result.is_ok() {
            let mut inner = self.inner.write().unwrap();
            inner.flush_snap = None;
        }
        result
    }

    pub fn approximate_sizes(
        &self,
        cf_id: usize,
        start: &[u8],
        end: &[u8],
    ) -> TransactorResult<usize> {
        let inner = self.inner.read().unwrap();
        let mut total = 0usize;

        // PageStore: O(log P) page count estimation via tree
        if let Some(ref store) = inner.store {
            let pages_in_range = store.page_count_in_range(cf_id as u32, start, end).unwrap_or(0) as usize;
            total += pages_in_range * 700;
        }

        // MemTable + flush_snap — count keys without materializing
        if start.is_empty() {
            total += (inner.mt_size as usize) / 40;
        } else {
            if let Some(ref snap) = inner.flush_snap {
                total += inner.mt.count_prefix(snap, cf_id as u32, start);
            }
            let live_snap = inner.mt.snapshot().unwrap();
            total += inner.mt.count_prefix(&live_snap, cf_id as u32, start);
        }

        Ok(total)
    }

    pub fn path(&self) -> String {
        self.inner.read().unwrap().path.clone()
    }

    pub fn cf_stats(&self, cf_id: usize) -> TransactorResult<CfStats> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        let data = store.cf_stats(cf_id as u32).map_err(|e| {
            TransactorError::Internal(format!("cf_stats: {e}"))
        })?;
        if data.len() < 40 {
            return Err(TransactorError::Internal("cf_stats: short data".into()));
        }
        let num_keys = u64::from_le_bytes(data[0..8].try_into().unwrap());
        let live_size = u64::from_le_bytes(data[8..16].try_into().unwrap());
        let sst_size = u64::from_le_bytes(data[16..24].try_into().unwrap());
        let num_sst = u64::from_le_bytes(data[24..32].try_into().unwrap());
        let memtable_size = u64::from_le_bytes(data[32..40].try_into().unwrap());
        Ok(CfStats {
            name: page_store::cf_name_for(cf_id).to_string(),
            num_keys,
            live_size,
            sst_size,
            num_sst,
            memtable_size,
        })
    }

    pub fn db_stats(&self) -> TransactorResult<DbStats> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        let data = store.db_stats().map_err(|e| {
            TransactorError::Internal(format!("db_stats: {e}"))
        })?;
        if data.len() < 16 {
            return Err(TransactorError::Internal("db_stats: short data".into()));
        }
        let total_sst_size = u64::from_le_bytes(data[0..8].try_into().unwrap());
        let total_live_size = u64::from_le_bytes(data[8..16].try_into().unwrap());
        Ok(DbStats {
            total_sst_size,
            total_live_size,
        })
    }

    pub fn memtable_size(&self) -> u64 {
        self.inner.read().unwrap().mt_size
    }

    pub fn memtable_count(&self, cf_id: usize) -> u64 {
        let inner = self.inner.read().unwrap();
        let snap = match inner.mt.snapshot() {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let packed = inner
            .mt
            .scan_prefix(snap, cf_id as u32, b"")
            .unwrap_or_default();
        unpack_keys(&packed).len() as u64
    }

    pub fn journal_put(&self, key: &[u8], value: &[u8]) -> TransactorResult<()> {
        let inner = self.inner.read().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        store.journal_put(key, value).map_err(|e| TransactorError::Internal(e))
    }

    pub fn journal_scan(&self) -> TransactorResult<Vec<u8>> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        store.journal_scan().map_err(|e| TransactorError::Internal(e))
    }

    pub fn journal_size(&self) -> u64 {
        let inner = self.inner.read().unwrap();
        if let Some(ref store) = inner.store {
            return store.journal_size().unwrap_or(0);
        }
        0
    }

    pub fn wal_size(&self) -> u64 {
        self.journal_size()
    }

    pub fn internal_status(&self, target: &str) -> TransactorResult<String> {
        let inner = self.inner.read().unwrap();
        let _store = inner.store.as_ref().ok_or(TransactorError::Closed)?;

        if target.is_empty() || target == "all" {
            let mut out = String::new();
            out.push_str(&format!("path: {}\n", inner.path));
            out.push_str(&format!("memtable_size: {} bytes\n", inner.mt_size));
            out.push_str(&format!(
                "flush_snap: {}\n",
                if inner.flush_snap.is_some() {
                    "active"
                } else {
                    "none"
                }
            ));
            for cf in 0..inner.config.num_cf {
                let name = page_store::cf_name_for(cf);
                let mt_count = {
                    let snap = match inner.mt.snapshot() {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let packed = inner
                        .mt
                        .scan_prefix(snap, cf as u32, b"")
                        .unwrap_or_default();
                    unpack_keys(&packed).len()
                };
                out.push_str(&format!("CF {cf} ({name}): mt_keys={mt_count}\n"));
            }
            return Ok(out);
        }

        if target == "memtable" {
            let mut out = String::new();
            for cf in 0..inner.config.num_cf {
                let name = page_store::cf_name_for(cf);
                let snap = match inner.mt.snapshot() {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let packed = inner
                    .mt
                    .scan_prefix(snap, cf as u32, b"")
                    .unwrap_or_default();
                let keys = unpack_keys(&packed);
                let n = keys.len();
                let first = keys
                    .first()
                    .map(|k| {
                        let mut s = String::new();
                        for &b in k.iter().take(16) {
                            s.push_str(&format!("{:02x}", b));
                        }
                        s
                    })
                    .unwrap_or_default();
                let last = keys
                    .last()
                    .map(|k| {
                        let mut s = String::new();
                        for &b in k.iter().take(16) {
                            s.push_str(&format!("{:02x}", b));
                        }
                        s
                    })
                    .unwrap_or_default();
                out.push_str(&format!(
                    "CF {cf} ({name}): keys={n} range={first}..{last}\n"
                ));
            }
            return Ok(out);
        }

        if target.starts_with("btree") {
            // NimPageStore doesn't yet expose internal_status — return stub
            return Ok(format!(
                "btree: page store backed by Nim (num_cf={})",
                inner.config.num_cf
            ));
        }

        Err(TransactorError::InvalidArg(format!(
            "unknown target: {target}"
        )))
    }

    pub fn close(&self) -> TransactorResult<()> {
        let _guard = self
            .flush_lock
            .try_lock()
            .map_err(|_| TransactorError::Busy)?;
        let needs_flush = {
            let inner = self.inner.read().unwrap();
            !inner.read_only
        };
        if needs_flush {
            if let Err(e) = self.flush_unlocked() {
                eprintln!("warning: flush on close failed: {e}");
            }
        }
        let mut inner = self.inner.write().unwrap();
        inner.store = None;
        Ok(())
    }

    pub fn gc_full(&self, dry_run: bool, _nowait: bool) -> TransactorResult<GcFullResult> {
        let _guard = self
            .flush_lock
            .try_lock()
            .map_err(|_| TransactorError::Busy)?;
        let (store, max_age_secs, max_root_count) = {
            let inner = self.inner.read().unwrap();
            let store = inner.store.clone().ok_or(TransactorError::Closed)?;
            (
                store,
                inner.config.gc_max_age_secs,
                inner.config.gc_max_root_count,
            )
        };
        let data = store
            .gc_full(max_age_secs, max_root_count as u32, dry_run)
            .map_err(|e| TransactorError::Internal(format!("gc_full: {e}")))?;
        if data.len() < 41 {
            return Ok(GcFullResult {
                roots_scanned: 0,
                roots_removed: 0,
                blobs_scanned: 0,
                blobs_removed: 0,
                live_uuids: 0,
                dry_run,
            });
        }
        Ok(GcFullResult {
            roots_scanned: u64::from_le_bytes(data[0..8].try_into().unwrap()) as usize,
            roots_removed: u64::from_le_bytes(data[8..16].try_into().unwrap()) as usize,
            blobs_scanned: u64::from_le_bytes(data[16..24].try_into().unwrap()) as usize,
            blobs_removed: u64::from_le_bytes(data[24..32].try_into().unwrap()) as usize,
            live_uuids: u64::from_le_bytes(data[32..40].try_into().unwrap()) as usize,
            dry_run: data[40] == 1,
        })
    }

    pub fn flush_threshold(&self) -> u64 {
        self.inner.read().unwrap().config.flush_threshold as u64
    }

    pub fn gc_max_age_secs(&self) -> u64 {
        self.inner.read().unwrap().config.gc_max_age_secs
    }

    pub fn is_read_only(&self) -> bool {
        self.inner.read().unwrap().read_only
    }

    pub fn has_gc_candidates(&self) -> bool {
        let inner = self.inner.read().unwrap();
        if let Some(ref store) = inner.store {
            return store
                .has_old_roots(
                    inner.config.gc_max_age_secs,
                    inner.config.gc_max_root_count as u32,
                )
                .unwrap_or(false);
        }
        false
    }
}

