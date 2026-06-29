// --- KVStore implementation modules ---
pub mod blob_store;
pub mod error;
pub mod generic_page_store;
pub mod keys;
pub mod merge_iter;
pub mod page_store;
pub mod pages;
pub mod store;

pub use error::{TransactorError, TransactorResult};
pub use generic_page_store::GenericPageStore;
pub use blob_store::make_root_name;
pub use merge_iter::{
    Cursor, ScanSource, ReverseScanSource, SourceKind, ReverseSourceKind,
    PageStoreIter, ReversePageStoreIter,
    MergedInner, ReverseMergedInner, merge_collect,
};
pub use page_store::PageStore;
pub use store::{Transactor, TransactorConfig};

// --- Generated storage-layer host code (BlobStore, Journal, MemTable) ---
// These traits and tower clients are generated locally — no other crate
// outside spier-kvstore needs them.

pub mod blobstore {
    include!(concat!(env!("OUT_DIR"), "/blobstore_host.rs"));
}

pub mod journal {
    include!(concat!(env!("OUT_DIR"), "/journal_host.rs"));
}

pub mod memtable {
    use std::sync::Arc;

    #[derive(Clone)]
    pub struct MemTableSnapshot {
        pub data: Arc<dyn std::any::Any + Send + Sync>,
    }

    include!(concat!(env!("OUT_DIR"), "/memtable_host.rs"));
}

pub use blobstore::{BlobStoreEngine, DynSpireBlobStore};
pub use journal::{DynSpireJournal as DynSpireJournalStore, JournalEngine};
pub use memtable::{DynSpireMemTable, MemTableEngine, MemTableSnapshot};

// --- Spier FFI layer ---

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use dynspire_commons::transactor::cursor::CursorHandle;

include!(concat!(env!("OUT_DIR"), "/kvstore_spier.rs"));

struct KVState {
    kv: Arc<RwLock<Option<Transactor>>>,
    poll_handle: Mutex<Option<JoinHandle<()>>>,
    poll_shutdown: Mutex<Option<mpsc::Sender<()>>>,
    flush_request: Mutex<Option<mpsc::Sender<()>>>,
}

fn load_memtable() -> Result<Box<dyn crate::memtable::MemTableEngine>, String> {
    let mut mt_config = HashMap::new();
    mt_config.insert("num_cf".to_string(), "4".to_string());
    let mt = DynSpireMemTable::connect("spier_memtable", &mt_config)?;
    Ok(Box::new(mt))
}

fn make_transactor_config(config: &HashMap<String, String>) -> TransactorConfig {
    let mut tc = TransactorConfig::default();
    if let Some(s) = config.get("flush_threshold") {
        if let Ok(v) = s.parse() {
            tc.flush_threshold = v;
        }
    }
    if let Some(s) = config.get("hard_flush_threshold") {
        if let Ok(v) = s.parse() {
            tc.hard_flush_threshold = v;
        }
    }
    if let Some(s) = config.get("gc_max_age_secs") {
        if let Ok(v) = s.parse() {
            tc.gc_max_age_secs = v;
        }
    }
    if let Some(s) = config.get("gc_max_root_count") {
        if let Ok(v) = s.parse() {
            tc.gc_max_root_count = v;
        }
    }
    if let Some(s) = config.get("page_cache_size") {
        if let Ok(v) = s.parse() {
            tc.page_cache_size = v;
        }
    }
    tc
}

fn open_memory(read_only: bool) -> Result<Transactor, String> {
    let config = HashMap::new();
    let blobs = DynSpireBlobStore::connect("spier_blobstore_memory", &config)?;
    let mt = load_memtable()?;
    let config = TransactorConfig::default();
    if read_only {
        Transactor::open_read_only(Box::new(blobs), None, mt, ":memory:", config)
    } else {
        Transactor::open(Box::new(blobs), None, mt, ":memory:", config)
    }.map_err(|e| format!("open memory: {e}"))
}

fn open_file(config: &HashMap<String, String>) -> Result<Transactor, String> {
    let path = config.get("path").map(|s| s.as_str()).ok_or("path required for file backend")?;
    let read_only = config.get("read_only").map(|v| v == "true").unwrap_or(false);

    let blobs = DynSpireBlobStore::connect("spier_blobstore_file", config)?;

    let j = DynSpireJournalStore::connect("spier_journal_file", config)?;
    let journal = Some(Box::new(j) as Box<dyn crate::journal::JournalEngine + Send + Sync>);

    let mt = load_memtable()?;
    let tc = make_transactor_config(config);
    if read_only {
        Transactor::open_read_only(Box::new(blobs), journal, mt, path, tc)
    } else {
        Transactor::open(Box::new(blobs), journal, mt, path, tc)
    }.map_err(|e| format!("open file: {e}"))
}

fn open_s3(config: &HashMap<String, String>) -> Result<Transactor, String> {
    let read_only = config.get("read_only").map(|v| v == "true").unwrap_or(false);

    let blobs = DynSpireBlobStore::connect("spier_blobstore_s3", config)?;

    if config.get("endpoint").is_none() || config.get("bucket_name").is_none() {
        return Err("s3 backend requires endpoint and bucket_name in config".into());
    }

    let local_path = config.get("path").map(|s| s.as_str()).unwrap_or(".");

    let j = DynSpireJournalStore::connect("spier_journal_file", config)?;
    let journal = Some(Box::new(j) as Box<dyn crate::journal::JournalEngine + Send + Sync>);

    let mt = load_memtable()?;
    let tc = make_transactor_config(config);
    if read_only {
        Transactor::open_read_only(Box::new(blobs), journal, mt, local_path, tc)
    } else {
        Transactor::open(Box::new(blobs), journal, mt, local_path, tc)
    }.map_err(|e| format!("open s3: {e}"))
}


fn poller_loop(
    kv: Arc<RwLock<Option<Transactor>>>,
    shutdown: mpsc::Receiver<()>,
    flush_request: mpsc::Receiver<()>,
    poll_interval: Duration,
) {
    loop {
        // Check shutdown first — non-blocking
        match shutdown.try_recv() {
            Ok(()) | Err(mpsc::TryRecvError::Disconnected) => return,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        // Wait for flush request or timeout
        match flush_request.recv_timeout(poll_interval) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        let kv_guard = kv.read().unwrap();
        let Some(ref txn) = *kv_guard else { continue };
        if txn.is_read_only() {
            continue;
        }
        if txn.memtable_size() >= txn.flush_threshold() {
            if let Err(e) = txn.flush() {
                if !matches!(e, crate::error::TransactorError::Busy) {
                    eprintln!("poller: flush error: {e}");
                }
            }
        }
        if txn.has_gc_candidates() {
            if let Err(e) = txn.gc_full(false, true) {
                if !matches!(e, crate::error::TransactorError::Busy) {
                    eprintln!("poller: gc error: {e}");
                }
            }
        }
    }
}


fn init(config: &HashMap<String, String>) -> Result<KVState, String> {
    let backend = config.get("backend").map(|s| s.as_str()).unwrap_or("memory");
    let read_only = config.get("read_only").map(|v| v == "true").unwrap_or(false);

    let kv = match backend {
        "memory" => open_memory(read_only)?,
        "file" => open_file(config)?,
        "s3" => open_s3(config)?,
        other => return Err(format!("unknown storage backend: {other}")),
    };

    let kv_arc = Arc::new(RwLock::new(Some(kv)));
    let (tx, rx) = mpsc::channel();
    let (flush_tx, flush_rx) = mpsc::channel();

    let poll_interval_secs: u64 = config
        .get("poll_interval_secs")
        .and_then(|s| s.parse().ok())
        .unwrap_or(300);
    let poll_interval = Duration::from_secs(poll_interval_secs);

    let kv_for_thread = Arc::clone(&kv_arc);
    let handle = std::thread::Builder::new()
        .name("kvstore-poller".into())
        .spawn(move || poller_loop(kv_for_thread, rx, flush_rx, poll_interval))
        .map_err(|e| format!("failed to spawn poller: {e}"))?;

    Ok(KVState {
        kv: kv_arc,
        poll_handle: Mutex::new(Some(handle)),
        poll_shutdown: Mutex::new(Some(tx)),
        flush_request: Mutex::new(Some(flush_tx)),
    })
}

impl KVState {
    fn signal_flush_if_needed(&self, kv: &Transactor) {
        if kv.memtable_size() >= kv.flush_threshold() {
            if let Some(tx) = self.flush_request.lock().unwrap().as_ref() {
                let _ = tx.send(());
            }
        }
    }
}

impl Drop for KVState {
    fn drop(&mut self) {
        if let Some(tx) = self.poll_shutdown.lock().unwrap().take() {
            let _ = tx.send(());
        }
        self.flush_request.lock().unwrap().take();
        if let Some(handle) = self.poll_handle.lock().unwrap().take() {
            let _ = handle.join();
        }
    }
}

impl KVStoreEngine for KVState {
    // ------------------------------------------------------------------
    // 1. WRITES — signal poller for async auto-flush
    // ------------------------------------------------------------------

    fn put(&self, cf: u32, key: &[u8]) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "kvstore not open".to_string())?;
        kv.put(cf as usize, key).map_err(|e| e.to_string())?;
        self.signal_flush_if_needed(kv);
        Ok(())
    }

    fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "kvstore not open".to_string())?;
        let mut buf = Vec::new();
        let mut pos = 0;
        while pos + 4 <= keys.len() {
            let klen = u32::from_be_bytes([keys[pos], keys[pos + 1], keys[pos + 2], keys[pos + 3]]) as usize;
            if pos + 4 + klen > keys.len() {
                break;
            }
            buf.push(cf as u8);
            buf.extend_from_slice(&keys[pos..pos + 4 + klen]);
            pos += 4 + klen;
        }
        kv.batch_write_raw(&buf).map_err(|e| e.to_string())?;
        self.signal_flush_if_needed(kv);
        Ok(())
    }

    fn batch_write(&self, ops: &[u8]) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "kvstore not open".to_string())?;
        kv.batch_write_raw(ops).map_err(|e| e.to_string())?;
        self.signal_flush_if_needed(kv);
        Ok(())
    }

    fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let mut buf = Vec::new();
        let mut pos = 0;
        while pos + 4 <= keys.len() {
            let klen = u32::from_be_bytes([keys[pos], keys[pos + 1], keys[pos + 2], keys[pos + 3]]) as usize;
            if pos + 4 + klen > keys.len() {
                break;
            }
            buf.push(cf as u8);
            buf.extend_from_slice(&keys[pos..pos + 4 + klen]);
            pos += 4 + klen;
        }
        kv.replay_to_memtable_raw(&buf);
        Ok(())
    }

    // ------------------------------------------------------------------
    // 3. POINT READS
    // ------------------------------------------------------------------

    fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.get(cf as usize, key).map_err(|e| e.to_string())?.is_some())
    }

    // ------------------------------------------------------------------
    // 4. BULK READS (materializam resultado)
    // ------------------------------------------------------------------

    fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let pairs = kv.scan(cf as usize, prefix).map_err(|e| e.to_string())?;
        let mut buf = Vec::new();
        for (k, _) in pairs {
            buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
            buf.extend(k);
        }
        Ok(buf)
    }

    fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let pairs = kv.scan_reverse(cf as usize, prefix).map_err(|e| e.to_string())?;
        let mut buf = Vec::new();
        for (k, _) in pairs {
            buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
            buf.extend(k);
        }
        Ok(buf)
    }

    fn items(&self, cf: u32) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let pairs = kv.items(cf as usize).map_err(|e| e.to_string())?;
        let mut buf = Vec::new();
        for (k, _) in pairs {
            buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
            buf.extend(k);
        }
        Ok(buf)
    }

    // ------------------------------------------------------------------
    // 5. CURSORS — CursorHandle via #[slot_struct] pointer transport
    // ------------------------------------------------------------------

    fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let sources = kv.scan_sources(cf as usize, prefix);
        let merged = MergedInner::new(sources, prefix);
        Ok(CursorHandle {
            cursor: std::sync::Arc::new(std::cell::RefCell::new(merged)),
        })
    }

    fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let sources = kv.scan_reverse_sources(cf as usize, prefix);
        let merged = ReverseMergedInner::new(sources, prefix);
        Ok(CursorHandle {
            cursor: std::sync::Arc::new(std::cell::RefCell::new(merged)),
        })
    }

    fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String> {
        Ok(cursor.cursor.borrow().is_valid())
    }

    fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String> {
        let guard = cursor.cursor.borrow();
        if !guard.is_valid() {
            return Ok(false);
        }
        if let Some(k) = guard.current_key() {
            buf.clear();
            buf.extend_from_slice(k);
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String> {
        cursor.cursor.borrow_mut().step();
        Ok(())
    }

    fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String> {
        cursor.cursor.borrow_mut().seek(target);
        Ok(())
    }

    fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String> {
        cursor.cursor.borrow_mut().skip_group(group_end as usize);
        Ok(())
    }

    fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String> {
        cursor.cursor.borrow_mut().update_end(end);
        Ok(())
    }

    // ------------------------------------------------------------------
    // 8. JOURNAL
    // ------------------------------------------------------------------

    fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        kv.journal_put(key, value).map_err(|e| e.to_string())
    }

    fn journal_scan(&self) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        kv.journal_scan().map_err(|e| e.to_string())
    }

    fn journal_size(&self) -> Result<u64, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.journal_size())
    }

    // ------------------------------------------------------------------
    // 9. STATS / ADMIN
    // ------------------------------------------------------------------

    fn memtable_size(&self) -> Result<u64, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.memtable_size() as u64)
    }

    fn memtable_count(&self, cf: u32) -> Result<u64, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.memtable_count(cf as usize) as u64)
    }

    fn path(&self) -> Result<String, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.path())
    }

    fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        Ok(kv.approximate_sizes(cf as usize, start, end).map_err(|e| e.to_string())? as u64)
    }

    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let stats = kv.cf_stats(cf as usize).map_err(|e| e.to_string())?;
        let name_bytes = stats.name.as_bytes();
        let mut buf = Vec::new();
        buf.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        buf.extend_from_slice(name_bytes);
        buf.extend_from_slice(&stats.num_keys.to_le_bytes());
        buf.extend_from_slice(&stats.live_size.to_le_bytes());
        buf.extend_from_slice(&stats.sst_size.to_le_bytes());
        buf.extend_from_slice(&stats.num_sst.to_le_bytes());
        buf.extend_from_slice(&stats.memtable_size.to_le_bytes());
        Ok(buf)
    }

    fn db_stats(&self) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let stats = kv.db_stats().map_err(|e| e.to_string())?;
        let mut buf = Vec::new();
        buf.extend_from_slice(&stats.total_sst_size.to_le_bytes());
        buf.extend_from_slice(&stats.total_live_size.to_le_bytes());
        Ok(buf)
    }

    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        let result = kv.gc_full(dry_run, nowait).map_err(|e| e.to_string())?;
        let mut buf = Vec::new();
        buf.extend_from_slice(&(result.roots_scanned as u64).to_le_bytes());
        buf.extend_from_slice(&(result.roots_removed as u64).to_le_bytes());
        buf.extend_from_slice(&(result.blobs_scanned as u64).to_le_bytes());
        buf.extend_from_slice(&(result.blobs_removed as u64).to_le_bytes());
        buf.extend_from_slice(&(result.live_uuids as u64).to_le_bytes());
        buf.push(if result.dry_run { 1 } else { 0 });
        Ok(buf)
    }

    fn internal_status(&self, target: &str) -> Result<String, String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        kv.internal_status(target).map_err(|e| e.to_string())
    }

    // ------------------------------------------------------------------
    // 10. FLUSH / CLOSE
    // ------------------------------------------------------------------

    fn flush(&self) -> Result<(), String> {
        let kv_guard = self.kv.read().unwrap();
        let kv = kv_guard.as_ref().ok_or_else(|| "transactor not open".to_string())?;
        kv.flush().map_err(|e| e.to_string())
    }

    fn close(&self) -> Result<(), String> {
        // Signal shutdown and drop flush_request to wake poller
        if let Some(tx) = self.poll_shutdown.lock().unwrap().take() {
            let _ = tx.send(());
        }
        self.flush_request.lock().unwrap().take();
        if let Some(handle) = self.poll_handle.lock().unwrap().take() {
            let _ = handle.join();
        }
        let mut kv_guard = self.kv.write().unwrap();
        if let Some(kv) = kv_guard.take() {
            kv.close().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

impl_kvstore_spier!(KVState, init, "spier_kvstore");
