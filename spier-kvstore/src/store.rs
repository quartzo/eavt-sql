use std::sync::{Arc, Mutex, RwLock};

use crate::blobstore::BlobStoreEngine;
use crate::journal::JournalEngine;
use crate::memtable::{MemTableEngine, MemTableSnapshot};
use crate::error::{TransactorError, TransactorResult};
use crate::generic_page_store::{GenericPageStore, GcFullResult};
use crate::merge_iter::{SourceKind, ReverseSourceKind};
use crate::page_store::{self, PageStore};

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
        let klen = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        let key = buf[pos..pos + klen].to_vec();
        pos += klen;
        let vlen = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
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

pub use dynspire_commons::transactor::types::{CfStats, DbStats};

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
    store: Option<Arc<dyn PageStore>>,
    mt: Arc<dyn MemTableEngine>,
    mt_size: u64,
    flush_snap: Option<MemTableSnapshot>,
    config: TransactorConfig,
    path: String,
    read_only: bool,
}

impl StoreInner {
    fn load_page_keys(store: &dyn PageStore, cf_id: usize, prefix: &[u8]) -> Vec<Vec<u8>> {
        match store.get_keys_in_prefix(cf_id, prefix) {
            Ok(keys) => keys,
            Err(_) => Vec::new(),
        }
    }

    fn scan_sources(&self, cf_id: usize, prefix: &[u8]) -> Vec<SourceKind> {
        let mut sources = Vec::new();
        if let Some(ref store) = self.store {
            let keys = Self::load_page_keys(store.as_ref(), cf_id, prefix);
            sources.push(SourceKind::PageStore(
                crate::merge_iter::PageStoreIter::new(keys, prefix),
            ));
        }
        if let Some(ref snap) = self.flush_snap {
            let packed = self.mt.scan_prefix(snap.clone(), cf_id as u32, prefix).unwrap_or_default();
            let snap_keys = unpack_keys(&packed);
            sources.push(SourceKind::MemTable(
                crate::merge_iter::PageStoreIter::new(snap_keys, prefix),
            ));
        }
        let live_snap = self.mt.snapshot().unwrap();
        let packed = self.mt.scan_prefix(live_snap, cf_id as u32, prefix).unwrap_or_default();
        let mt_keys = unpack_keys(&packed);
        sources.push(SourceKind::MemTable(
            crate::merge_iter::PageStoreIter::new(mt_keys, prefix),
        ));
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
            let packed = self.mt.scan_prefix_reverse(snap.clone(), cf_id as u32, prefix).unwrap_or_default();
            let snap_keys = unpack_keys(&packed);
            sources.push(ReverseSourceKind::MemTable(
                crate::merge_iter::ReversePageStoreIter::new(snap_keys, prefix),
            ));
        }
        let live_snap = self.mt.snapshot().unwrap();
        let packed = self.mt.scan_prefix_reverse(live_snap, cf_id as u32, prefix).unwrap_or_default();
        let mt_keys = unpack_keys(&packed);
        sources.push(ReverseSourceKind::MemTable(
            crate::merge_iter::ReversePageStoreIter::new(mt_keys, prefix),
        ));
        sources
    }

    fn flush_snapshot(
        store: &dyn PageStore,
        mt: &dyn MemTableEngine,
        snap: &MemTableSnapshot,
        num_cf: usize,
    ) -> TransactorResult<()> {
        let mut keys_by_cf: Vec<(usize, Vec<Vec<u8>>)> = Vec::new();

        for cf_id in 0..num_cf {
            let packed = mt.scan_prefix(snap.clone(), cf_id as u32, b"")
                .map_err(|e| TransactorError::Internal(format!("snapshot scan_prefix: {e}")))?;
            let new_keys = unpack_keys(&packed);
            if new_keys.is_empty() {
                continue;
            }
            keys_by_cf.push((cf_id, new_keys));
        }

        store.commit_merge(&keys_by_cf, true)?;
        Ok(())
    }
}

pub struct Transactor {
    inner: RwLock<StoreInner>,
    flush_lock: Mutex<()>,
}

impl Transactor {
    pub fn open(
        blobs: Box<dyn BlobStoreEngine + Send + Sync>,
        journal: Option<Box<dyn JournalEngine + Send + Sync>>,
        mt: Box<dyn MemTableEngine>,
        path: &str,
        config: TransactorConfig,
    ) -> TransactorResult<Self> {
        let store = GenericPageStore::open(blobs, journal, config.num_cf, config.page_cache_size)?;
        let inner = StoreInner {
            store: Some(Arc::new(store)),
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
        blobs: Box<dyn BlobStoreEngine + Send + Sync>,
        journal: Option<Box<dyn JournalEngine + Send + Sync>>,
        mt: Box<dyn MemTableEngine>,
        path: &str,
        config: TransactorConfig,
    ) -> TransactorResult<Self> {
        let store = GenericPageStore::open_read_only(blobs, journal, config.num_cf, config.page_cache_size)?;
        let inner = StoreInner {
            store: Some(Arc::new(store)),
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
                "key too large: {} bytes (max {})", key.len(), u32::MAX
            )));
        }
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let total = inner.mt.put(cf_id as u32, key)
            .map_err(|e| TransactorError::Internal(format!("memtable put: {e}")))?;
        inner.mt_size = total;
        Ok(())
    }

    pub fn batch_write_raw(&self, ops: &[u8]) -> TransactorResult<()> {
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let total = inner.mt.batch_write(ops)
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
        let live_snap = inner.mt.snapshot()
            .map_err(|e| TransactorError::Internal(format!("memtable snapshot: {e}")))?;
        let exists = inner.mt.contains(live_snap, cf_id as u32, key)
            .map_err(|e| TransactorError::Internal(format!("memtable contains: {e}")))?;
        if exists {
            return Ok(Some(vec![]));
        }
        if let Some(ref snap) = inner.flush_snap {
            let exists = inner.mt.contains(snap.clone(), cf_id as u32, key)
                .map_err(|e| TransactorError::Internal(format!("snapshot contains: {e}")))?;
            if exists {
                return Ok(Some(vec![]));
            }
        }
        if let Some(ref store) = inner.store {
            let exists = store.key_exists(cf_id, key)?;
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

    pub fn scan_reverse_sources(
        &self,
        cf_id: usize,
        prefix: &[u8],
    ) -> Vec<ReverseSourceKind> {
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
        let _guard = self.flush_lock.try_lock().map_err(|_| TransactorError::Busy)?;
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
                "flush called without flush snapshot".into()
            ))?;
            let store = inner.store.clone().ok_or(TransactorError::Closed)?;
            let mt = Arc::clone(&inner.mt);
            let num_cf = inner.config.num_cf;
            (snap, store, mt, num_cf)
        };

        let result = StoreInner::flush_snapshot(
            store.as_ref(),
            mt.as_ref(),
            &snap,
            num_cf,
        );

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
            let pages_in_range = store.page_count_in_range(cf_id, start, end).unwrap_or(0);
            total += pages_in_range * 700;
        }

        // MemTable + flush_snap
        if start.is_empty() {
            total += (inner.mt_size as usize) / 40;
        } else {
            if let Some(ref snap) = inner.flush_snap {
                let packed = inner.mt.scan_prefix(snap.clone(), cf_id as u32, start).unwrap_or_default();
                total += unpack_keys(&packed).len();
            }
            let live_snap = inner.mt.snapshot().unwrap();
            let packed = inner.mt.scan_prefix(live_snap, cf_id as u32, start).unwrap_or_default();
            total += unpack_keys(&packed).len();
        }

        Ok(total)
    }

    pub fn path(&self) -> String {
        self.inner.read().unwrap().path.clone()
    }

    pub fn cf_stats(&self, cf_id: usize) -> TransactorResult<CfStats> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        let data = store.cf_stats(cf_id)?;
        Ok(CfStats {
            name: page_store::cf_name_for(cf_id).to_string(),
            num_keys: data.num_keys,
            live_size: data.live_size,
            sst_size: data.sst_size,
            num_sst: data.num_sst,
            memtable_size: data.memtable_size,
        })
    }

    pub fn db_stats(&self) -> TransactorResult<DbStats> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        let data = store.db_stats()?;
        Ok(DbStats {
            total_sst_size: data.total_sst_size,
            total_live_size: data.total_live_size,
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
        let packed = inner.mt.scan_prefix(snap, cf_id as u32, b"").unwrap_or_default();
        unpack_keys(&packed).len() as u64
    }

    pub fn journal_put(&self, key: &[u8], value: &[u8]) -> TransactorResult<()> {
        let inner = self.inner.read().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        store.journal_put(key, value)
    }

    pub fn journal_scan(&self) -> TransactorResult<Vec<u8>> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;
        store.journal_scan()
    }

    pub fn journal_size(&self) -> u64 {
        let inner = self.inner.read().unwrap();
        if let Some(ref store) = inner.store {
            let sst = store.cf_stats(4).map(|s| s.sst_size).unwrap_or(0);
            let mem = store.cf_stats(4).map(|s| s.memtable_size).unwrap_or(0);
            return sst + mem;
        }
        0
    }

    pub fn wal_size(&self) -> u64 {
        self.journal_size()
    }

    pub fn internal_status(&self, target: &str) -> TransactorResult<String> {
        let inner = self.inner.read().unwrap();
        let store = inner.store.as_ref().ok_or(TransactorError::Closed)?;

        if target.is_empty() || target == "all" {
            let mut out = String::new();
            out.push_str(&format!("path: {}\n", inner.path));
            out.push_str(&format!("memtable_size: {} bytes\n", inner.mt_size));
            out.push_str(&format!("flush_snap: {}\n", if inner.flush_snap.is_some() { "active" } else { "none" }));
            for cf in 0..inner.config.num_cf {
                let name = page_store::cf_name_for(cf);
                let mt_count = {
                    let snap = match inner.mt.snapshot() {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let packed = inner.mt.scan_prefix(snap, cf as u32, b"").unwrap_or_default();
                    unpack_keys(&packed).len()
                };
                out.push_str(&format!("CF {cf} ({name}): mt_keys={mt_count}\n"));
            }
            out.push('\n');
            out.push_str(&store.internal_status("btree")?);
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
                let packed = inner.mt.scan_prefix(snap, cf as u32, b"").unwrap_or_default();
                let keys = unpack_keys(&packed);
                let n = keys.len();
                let first = keys.first().map(|k| {
                    let mut s = String::new();
                    for &b in k.iter().take(16) { s.push_str(&format!("{:02x}", b)); }
                    s
                }).unwrap_or_default();
                let last = keys.last().map(|k| {
                    let mut s = String::new();
                    for &b in k.iter().take(16) { s.push_str(&format!("{:02x}", b)); }
                    s
                }).unwrap_or_default();
                out.push_str(&format!("CF {cf} ({name}): keys={n} range={first}..{last}\n"));
            }
            return Ok(out);
        }

        if target.starts_with("btree") {
            return store.internal_status(target);
        }

        Err(TransactorError::InvalidArg(format!("unknown target: {target}")))
    }

    pub fn close(&self) -> TransactorResult<()> {
        let _guard = self.flush_lock.try_lock().map_err(|_| TransactorError::Busy)?;
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
        let _guard = self.flush_lock.try_lock().map_err(|_| TransactorError::Busy)?;
        let (store, max_age_secs, max_root_count) = {
            let inner = self.inner.read().unwrap();
            let store = inner.store.clone().ok_or(TransactorError::Closed)?;
            (store, inner.config.gc_max_age_secs, inner.config.gc_max_root_count)
        }; // read lock released — GC runs without blocking reads or writes

        let store_ref = store.as_ref();
        if let Some(gps) = store_ref.as_any().downcast_ref::<GenericPageStore>() {
            gps.gc_full_with_age(dry_run, max_age_secs, max_root_count)
        } else {
            Ok(GcFullResult {
                roots_scanned: 0,
                roots_removed: 0,
                blobs_scanned: 0,
                blobs_removed: 0,
                live_uuids: 0,
                dry_run,
            })
        }
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
            if let Some(gps) = store.as_any().downcast_ref::<GenericPageStore>() {
                return gps.has_old_roots(inner.config.gc_max_age_secs, inner.config.gc_max_root_count);
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet, HashMap};
    use std::sync::Mutex;

    use super::*;
    use crate::blobstore::BlobStoreEngine;
    use crate::journal::JournalEngine;
    use crate::memtable::MemTableEngine;
    use tempfile::TempDir;

    struct LocalMemTable {
        cfs: Vec<Mutex<BTreeSet<Vec<u8>>>>,
    }

    impl LocalMemTable {
        fn new(num_cf: usize) -> Self {
            Self { cfs: (0..num_cf).map(|_| Mutex::new(BTreeSet::new())).collect() }
        }
    }

    impl MemTableEngine for LocalMemTable {
        fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String> {
            self.cfs[cf as usize].lock().unwrap().insert(key.to_vec());
            let mut total = 0u64;
            for c in &self.cfs {
                for k in c.lock().unwrap().iter() {
                    total += k.len() as u64;
                }
            }
            Ok(total)
        }
        fn batch_write(&self, ops: &[u8]) -> Result<u64, String> {
            let mut pos = 0;
            while pos + 5 <= ops.len() {
                let cf = ops[pos] as usize;
                let klen = u32::from_be_bytes([ops[pos + 1], ops[pos + 2], ops[pos + 3], ops[pos + 4]]) as usize;
                if pos + 5 + klen > ops.len() { break; }
                self.cfs[cf].lock().unwrap().insert(ops[pos + 5..pos + 5 + klen].to_vec());
                pos += 5 + klen;
            }
            let mut total = 0u64;
            for c in &self.cfs {
                for k in c.lock().unwrap().iter() {
                    total += k.len() as u64;
                }
            }
            Ok(total)
        }
        fn clear(&self) -> Result<(), String> {
            for c in &self.cfs {
                c.lock().unwrap().clear();
            }
            Ok(())
        }
        fn snapshot(&self) -> Result<crate::memtable::MemTableSnapshot, String> {
            let cfs: Vec<std::collections::BTreeSet<Vec<u8>>> = self.cfs.iter()
                .map(|c| c.lock().unwrap().clone())
                .collect();
            Ok(crate::memtable::MemTableSnapshot {
                data: std::sync::Arc::new(cfs),
            })
        }
        fn scan_prefix(&self, snap: crate::memtable::MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
            let cfs = snap.data.downcast_ref::<Vec<std::collections::BTreeSet<Vec<u8>>>>()
                .ok_or("invalid snapshot type")?;
            let set = match cfs.get(cf as usize) {
                Some(s) => s,
                None => return Ok(Vec::new()),
            };
            let keys: Vec<Vec<u8>> = set.range::<[u8], _>((std::ops::Bound::Included(prefix), std::ops::Bound::Unbounded))
                .filter(|k| k.starts_with(prefix))
                .cloned()
                .collect();
            let mut buf = Vec::new();
            for k in &keys {
                buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
                buf.extend_from_slice(k);
            }
            Ok(buf)
        }
        fn scan_prefix_reverse(&self, snap: crate::memtable::MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
            let buf = self.scan_prefix(snap, cf, prefix)?;
            let keys = unpack_keys(&buf);
            let mut packed = Vec::new();
            for k in keys.iter().rev() {
                packed.extend_from_slice(&(k.len() as u32).to_be_bytes());
                packed.extend_from_slice(k);
            }
            Ok(packed)
        }
        fn contains(&self, snap: crate::memtable::MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String> {
            let cfs = snap.data.downcast_ref::<Vec<std::collections::BTreeSet<Vec<u8>>>>()
                .ok_or("invalid snapshot type")?;
            Ok(cfs.get(cf as usize).map(|s| s.contains(key)).unwrap_or(false))
        }
    }

    fn make_mt() -> Box<dyn MemTableEngine> {
        Box::new(LocalMemTable::new(4))
    }

    struct TestBlobStore {
        blobs: Mutex<HashMap<[u8; 16], Vec<u8>>>,
        roots: Mutex<BTreeMap<String, Vec<u8>>>,
    }

    impl TestBlobStore {
        fn new() -> Self {
            Self {
                blobs: Mutex::new(HashMap::new()),
                roots: Mutex::new(BTreeMap::new()),
            }
        }
    }

    impl BlobStoreEngine for TestBlobStore {
        fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
            let id = uuid::Uuid::new_v4().into_bytes();
            self.blobs.lock().unwrap().insert(id, data.to_vec());
            Ok(id)
        }
        fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
            self.blobs.lock().unwrap().insert(id, data.to_vec());
            Ok(())
        }
        fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
            Ok(self.blobs.lock().unwrap().get(&id).cloned())
        }
        fn delete(&self, id: [u8; 16]) -> Result<(), String> {
            self.blobs.lock().unwrap().remove(&id);
            Ok(())
        }
        fn list(&self) -> Result<Vec<[u8; 16]>, String> {
            Ok(self.blobs.lock().unwrap().keys().copied().collect())
        }
        fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
            self.roots.lock().unwrap().insert(name.to_string(), data.to_vec());
            Ok(())
        }
        fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
            Ok(self.roots.lock().unwrap().get(name).cloned())
        }
        fn list_roots(&self) -> Result<Vec<String>, String> {
            Ok(self.roots.lock().unwrap().keys().cloned().collect())
        }
        fn delete_root(&self, name: &str) -> Result<(), String> {
            self.roots.lock().unwrap().remove(name);
            Ok(())
        }
    }

    struct TestJournalStore {
        journal: Mutex<Vec<(Vec<u8>, Vec<u8>)>>,
    }

    impl TestJournalStore {
        fn new() -> Self {
            Self { journal: Mutex::new(Vec::new()) }
        }
    }

    impl JournalEngine for TestJournalStore {
        fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
            self.journal.lock().unwrap().push((key.to_vec(), value.to_vec()));
            Ok(())
        }
        fn journal_read(&self) -> Result<Vec<u8>, String> {
            let entries = self.journal.lock().unwrap();
            let mut buf = Vec::new();
            for (k, v) in entries.iter() {
                buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
                buf.extend_from_slice(k);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                buf.extend_from_slice(v);
            }
            Ok(buf)
        }
        fn journal_truncate(&self) -> Result<(), String> {
            self.journal.lock().unwrap().clear();
            Ok(())
        }
    }

    fn open_test_db() -> (TempDir, Transactor) {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test").to_str().unwrap().to_string();
        let config = TransactorConfig::default();
        let journal: Option<Box<dyn JournalEngine + Send + Sync>> = Some(Box::new(TestJournalStore::new()));
        let db = Transactor::open(Box::new(TestBlobStore::new()), journal, make_mt(), &path, config).unwrap();
        (dir, db)
    }

    fn make_key(prefix: &str, i: u32) -> Vec<u8> {
        format!("{}{:04}", prefix, i).into_bytes()
    }

    #[test]
    fn open_close_roundtrip() {
        let (_dir, db) = open_test_db();
        db.put(0, b"key1").unwrap();
        db.close().unwrap();
    }

    #[test]
    fn in_memory_mode() {
        let config = TransactorConfig {
            num_cf: 4,
            flush_threshold: usize::MAX,
            ..Default::default()
        };
        let db = Transactor::open(Box::new(TestBlobStore::new()), None, make_mt(), ":memory:", config).unwrap();
        db.put(0, b"key1").unwrap();
        assert!(db.get(0, b"key1").unwrap().is_some());
    }

    #[test]
    fn open_read_only_requires_data() {
        let config = TransactorConfig::default();
        let result = Transactor::open_read_only(Box::new(TestBlobStore::new()), None, make_mt(), "test", config);
        assert!(result.is_err(), "open_read_only should fail with empty blob store");
    }

    #[test]
    fn flush_gap_merge() {
        let config = TransactorConfig {
            flush_threshold: 4 << 20,
            ..Default::default()
        };
        let db = Transactor::open(Box::new(TestBlobStore::new()), None, make_mt(), "test", config).unwrap();

        let mut expected_keys = Vec::new();

        for i in 0..50u32 {
            let k = make_key("a", i);
            db.put(0, &k).unwrap();
            expected_keys.push(k);
        }
        db.flush().unwrap();

        for i in 100..150u32 {
            let k = make_key("a", i);
            db.put(0, &k).unwrap();
            expected_keys.push(k);
        }
        db.flush().unwrap();

        let gap_key = make_key("a", 75);
        db.put(0, &gap_key).unwrap();
        expected_keys.push(gap_key.clone());
        db.flush().unwrap();

        expected_keys.sort();

        let results = db.items(0).unwrap();
        let mut result_keys: Vec<Vec<u8>> = results.into_iter().map(|(k, _)| k).collect();
        result_keys.sort();

        assert_eq!(result_keys, expected_keys,
            "gap key must be merged into existing pages, not lost");

        db.close().unwrap();
    }

    #[test]
    fn flush_key_before_all_pages() {
        let config = TransactorConfig {
            flush_threshold: 4 << 20,
            ..Default::default()
        };
        let db = Transactor::open(Box::new(TestBlobStore::new()), None, make_mt(), "test", config).unwrap();

        for i in 100..150u32 {
            let k = make_key("a", i);
            db.put(0, &k).unwrap();
        }
        db.flush().unwrap();

        let before_key = make_key("a", 50);
        db.put(0, &before_key).unwrap();
        db.flush().unwrap();

        let results = db.items(0).unwrap();
        assert_eq!(results.len(), 51, "key before all pages must be preserved");
        db.close().unwrap();
    }

    #[test]
    fn flush_key_after_all_pages() {
        let config = TransactorConfig {
            flush_threshold: 4 << 20,
            ..Default::default()
        };
        let db = Transactor::open(Box::new(TestBlobStore::new()), None, make_mt(), "test", config).unwrap();

        for i in 0..50u32 {
            let k = make_key("a", i);
            db.put(0, &k).unwrap();
        }
        db.flush().unwrap();

        let after_key = make_key("a", 200);
        db.put(0, &after_key).unwrap();
        db.flush().unwrap();

        let results = db.items(0).unwrap();
        assert_eq!(results.len(), 51, "key after all pages must merge into last page");
        db.close().unwrap();
    }

    #[test]
    fn journal_put_scan_roundtrip() {
        let (_dir, db) = open_test_db();
        db.journal_put(b"key1", b"\x00").unwrap();
        db.journal_put(b"key2", b"\x01").unwrap();

        let entries = unpack_kv(&db.journal_scan().unwrap());
        assert_eq!(entries.len(), 2);
        let keys: Vec<&[u8]> = entries.iter().map(|(k, _)| k.as_slice()).collect();
        assert!(keys.contains(&b"key1"[..].into()));
        assert!(keys.contains(&b"key2"[..].into()));
        assert_eq!(entries.iter().find(|(k, _)| k == b"key2").unwrap().1, b"\x01");
        db.close().unwrap();
    }

    #[test]
    fn journal_cleared_after_flush() {
        let (_dir, db) = open_test_db();
        db.put(0, b"key1").unwrap();
        db.journal_put(b"key1", b"\x00").unwrap();

        assert_eq!(unpack_kv(&db.journal_scan().unwrap()).len(), 1);
        db.flush().unwrap();
        assert_eq!(unpack_kv(&db.journal_scan().unwrap()).len(), 0, "journal must be empty after flush");
        db.close().unwrap();
    }

    #[test]
    fn cursor_returns_all_keys_multi_attr() {
        let config = TransactorConfig {
            num_cf: 4,
            flush_threshold: usize::MAX,
            ..Default::default()
        };
        let db = Transactor::open(
            Box::new(TestBlobStore::new()),
            None,
            make_mt(),
            "test",
            config,
        )
        .unwrap();

        // Simulate AVET keys: [attr_id(4), v_encoded(18), eid(8), suffix(8)]
        // Two attributes (attr_id=1 and attr_id=2), 20K keys each
        let suffix = 0x8000000000000001u64; // t=1, not retracted
        let sf = suffix.to_be_bytes();

        let mut expected_a1 = Vec::new();
        for i in 0..20000u64 {
            let eid = i + 1;
            let e_bytes = eid.to_be_bytes();

            // attr_id=1 keys
            let name = format!("company_{:06}", i);
            let raw = name.as_bytes();
            // Encode as variable (8-byte blocks)
            let mut v_encoded = Vec::new();
            let full = raw.len() / 8;
            for j in 0..full {
                v_encoded.extend_from_slice(&raw[j*8..j*8+8]);
                v_encoded.push(0xFF);
            }
            let rem = raw.len() % 8;
            let mut block = [0u8; 8];
            block[..rem].copy_from_slice(&raw[full*8..]);
            v_encoded.extend_from_slice(&block);
            v_encoded.push(rem as u8);

            let a1_bytes = 1u32.to_be_bytes();
            let key_a1: Vec<u8> = [&a1_bytes[..], &v_encoded[..], &e_bytes[..], &sf[..]].concat();
            db.put(2, &key_a1).unwrap(); // CF 2 = AVET
            expected_a1.push(key_a1);

            // attr_id=2 keys (different value format)
            let a2_bytes = 2u32.to_be_bytes();
            let rev = (i as f64) * 100.0;
            let rev_bits = rev.to_bits();
            let v2_bytes = rev_bits.to_be_bytes();
            let key_a2: Vec<u8> = [&a2_bytes[..], &v2_bytes[..], &e_bytes[..], &sf[..]].concat();
            db.put(2, &key_a2).unwrap();
        }

        expected_a1.sort();

        // Now scan with prefix for attr_id=1
        let prefix = 1u32.to_be_bytes().to_vec();
        let sources = db.scan_sources(2, &prefix);

        // Count keys across all sources via cursor stepping
        let merged = crate::merge_iter::MergedInner::new(sources, &prefix);
        let cursor = std::sync::Arc::new(std::cell::RefCell::new(merged));
        let mut count = 0;
        let mut prev: Option<Vec<u8>> = None;
        while cursor.borrow().is_valid() {
            let k = cursor.borrow().current_key().unwrap().to_vec();
            if let Some(ref p) = prev {
                assert_ne!(&k, p, "duplicate key at count={}", count);
            }
            prev = Some(k.clone());
            count += 1;
            cursor.borrow_mut().step();
        }

        assert_eq!(count, 20000, "cursor should return all 20K keys");

        db.close().unwrap();
    }

    #[test]
    fn flush_multi_cf_multi_flush_integrity() {
        // Simulate repro_flush5: 20K "companies" + 10K "persons" across 4 CFs
        // Each entity writes to CF0 (eavt), CF1 (aevt), CF2 (avet) — 3 keys per attr
        // Two attrs per entity = 6 keys per entity
        // Use a SMALL threshold to trigger multiple auto-flushes
        let threshold = 512 * 1024; // 512KB — triggers flush after ~5K entities
        let config = TransactorConfig {
            num_cf: 4,
            flush_threshold: threshold,
            ..Default::default()
        };
        let db = Transactor::open(
            Box::new(TestBlobStore::new()),
            None,
            make_mt(),
            "test",
            config,
        )
        .unwrap();


        let name_aid: u32 = 100;
        let rev_aid: u32 = 101;
        let pname_aid: u32 = 200;
        let age_aid: u32 = 201;

        let mut expected_cf0: BTreeSet<Vec<u8>> = BTreeSet::new();

        // Write 20K "companies" — 2 attrs each
        for i in 0..20000u64 {
            let eid = i + 1;
            let e_bytes = eid.to_be_bytes();
            let t = eid;
            let sfx = !((t << 1) | 0);
            let sfx = sfx.to_be_bytes();

            for &(aid, ref val_bytes) in &[
                (name_aid, format!("company_{:06}", i).into_bytes()),
                (rev_aid, {
                    let f = (i as f64) * 100.0;
                    f.to_bits().to_be_bytes().to_vec()
                }),
            ] {
                let a_bytes = aid.to_be_bytes();
                // CF0 (EAVT): [e(8), a(4), v(variable), suffix(8)]
                let k0: Vec<u8> = e_bytes.iter().chain(a_bytes.iter())
                    .chain(val_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(0, &k0).unwrap();
                expected_cf0.insert(k0);
                // CF1 (AEVT): [a(4), e(8), v(variable), suffix(8)]
                let k1: Vec<u8> = a_bytes.iter().chain(e_bytes.iter())
                    .chain(val_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(1, &k1).unwrap();
                // CF2 (AVET): [a(4), v(variable), e(8), suffix(8)]
                let k2: Vec<u8> = a_bytes.iter().chain(val_bytes.iter())
                    .chain(e_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(2, &k2).unwrap();
            }

            // Auto-flush check: if mt_size >= threshold, flush
            if db.memtable_size() >= threshold as u64 {
                db.flush().unwrap();
            }
        }

        // Write 10K "persons" — 2 attrs each
        for i in 0..10000u64 {
            let eid = 20001 + i;
            let e_bytes = eid.to_be_bytes();
            let t = eid;
            let sfx = !((t << 1) | 0);
            let sfx = sfx.to_be_bytes();

            for &(aid, ref val_bytes) in &[
                (pname_aid, format!("person_{:06}", i).into_bytes()),
                (age_aid, {
                    let v = 20 + (i % 50);
                    v.to_be_bytes().to_vec()
                }),
            ] {
                let a_bytes = aid.to_be_bytes();
                let k0: Vec<u8> = e_bytes.iter().chain(a_bytes.iter())
                    .chain(val_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(0, &k0).unwrap();
                expected_cf0.insert(k0);
                let k1: Vec<u8> = a_bytes.iter().chain(e_bytes.iter())
                    .chain(val_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(1, &k1).unwrap();
                let k2: Vec<u8> = a_bytes.iter().chain(val_bytes.iter())
                    .chain(e_bytes.iter()).chain(sfx.iter()).copied().collect();
                db.put(2, &k2).unwrap();
            }

            if db.memtable_size() >= threshold as u64 {
                db.flush().unwrap();
            }
        }

        // Final flush for any remaining data
        db.flush().unwrap();

        // Now verify: scan CF0 and compare with expected
        let results = db.items(0).unwrap();
        let result_keys: BTreeSet<Vec<u8>> = results.into_iter().map(|(k, _)| k).collect();

        let expected_count = expected_cf0.len();
        let result_count = result_keys.len();

        assert_eq!(result_count, expected_count,
            "CF0 data loss: expected {} keys, got {} (missing {})",
            expected_count, result_count, expected_count - result_count);

        // Also test CF2 (AVET) prefix scan — this is what the query engine uses
        // AVET keys: [attr_id(4), value(variable), entity_id(8), suffix(8)]
        // Prefix scan by attr_id should return all keys for that attr
        let name_aid_bytes = name_aid.to_be_bytes();
        let cf2_all = db.items(2).unwrap();
        let cf2_name_keys: Vec<_> = cf2_all.iter()
            .filter(|(k, _)| k.starts_with(&name_aid_bytes[..]))
            .map(|(k, _)| k.clone())
            .collect();
        assert_eq!(cf2_name_keys.len(), 20000,
            "CF2 prefix scan: expected 20000 company.name keys, got {}", cf2_name_keys.len());

        // Also test via cursor (prefix scan like the query engine does)
        let prefix = name_aid_bytes.to_vec();
        let sources = db.scan_sources(2, &prefix);
        let merged = crate::merge_iter::MergedInner::new(sources, &prefix);
        let cursor = std::sync::Arc::new(std::cell::RefCell::new(merged));
        let mut cursor_count = 0;
        while cursor.borrow().is_valid() {
            cursor_count += 1;
            cursor.borrow_mut().step();
        }
        assert_eq!(cursor_count, 20000,
            "CF2 cursor prefix scan: expected 20000, got {}", cursor_count);

        db.close().unwrap();
    }

    #[test]
    fn scan_reverse_after_flush() {
        let config = TransactorConfig {
            flush_threshold: 4 << 20,
            ..Default::default()
        };
        let db = Transactor::open(Box::new(TestBlobStore::new()), None, make_mt(), "test", config).unwrap();
        for i in 0..5u8 {
            let k = format!("key_{:04}", i);
            db.put(0, k.as_bytes()).unwrap();
        }
        db.flush().unwrap();
        let fwd: Vec<Vec<u8>> = db.items(0).unwrap().into_iter().map(|(k, _)| k).collect();
        let rev: Vec<Vec<u8>> = db.scan_reverse(0, b"").unwrap().into_iter().map(|(k, _)| k).collect();
        assert_eq!(fwd.len(), 5);
        assert_eq!(rev.len(), 5);
        assert_eq!(rev[0], *b"key_0004", "reverse scan first should be largest, got {:?}", rev);
        assert_eq!(&fwd, &rev.iter().rev().cloned().collect::<Vec<_>>(), "reverse of reverse must equal forward");
        db.close().unwrap();
    }
}
