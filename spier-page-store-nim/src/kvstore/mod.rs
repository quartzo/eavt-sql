// --- KVStore implementation ---
// NimKVStore handles everything: blobstore, journal, memtable, page-store,
// transactor (flush/GC/scan), and cursor merge.

pub mod page_store;

pub use crate::storage_traits::KVStoreEngine;

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use crate::NimKVStore;
use crate::storage_traits::CursorHandle;

const DEFAULT_FLUSH_THRESHOLD: u64 = 64 * 1024 * 1024; // 64MB
const DEFAULT_GC_MAX_AGE_SECS: u64 = 43200;
const DEFAULT_GC_MAX_ROOT_COUNT: u32 = 10;

pub struct KVState {
    kv: Arc<Mutex<Option<NimKVStore>>>,
    flush_threshold: u64,
    gc_max_age_secs: u64,
    gc_max_root_count: u32,
    poll_handle: Mutex<Option<JoinHandle<()>>>,
    poll_shutdown: Mutex<Option<mpsc::Sender<()>>>,
    flush_request: Mutex<Option<mpsc::Sender<()>>>,
}

impl KVState {
    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        let kv = NimKVStore::open(config)?;
        let flush_threshold = config.get("flush_threshold")
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_FLUSH_THRESHOLD);
        let gc_max_age_secs = config.get("gc_max_age_secs")
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_GC_MAX_AGE_SECS);
        let gc_max_root_count = config.get("gc_max_root_count")
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_GC_MAX_ROOT_COUNT);

        let kv_arc = Arc::new(Mutex::new(Some(kv)));
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
            .spawn(move || poller_loop(
                kv_for_thread, rx, flush_rx, poll_interval,
                flush_threshold, gc_max_age_secs, gc_max_root_count,
            ))
            .map_err(|e| format!("failed to spawn poller: {e}"))?;

        Ok(KVState {
            kv: kv_arc,
            flush_threshold,
            gc_max_age_secs,
            gc_max_root_count,
            poll_handle: Mutex::new(Some(handle)),
            poll_shutdown: Mutex::new(Some(tx)),
            flush_request: Mutex::new(Some(flush_tx)),
        })
    }
}

fn poller_loop(
    kv: Arc<Mutex<Option<NimKVStore>>>,
    shutdown: mpsc::Receiver<()>,
    flush_request: mpsc::Receiver<()>,
    poll_interval: Duration,
    flush_threshold: u64,
    gc_max_age_secs: u64,
    gc_max_root_count: u32,
) {
    loop {
        match shutdown.try_recv() {
            Ok(()) | Err(mpsc::TryRecvError::Disconnected) => return,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        match flush_request.recv_timeout(poll_interval) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        let guard = kv.lock().unwrap();
        let Some(ref store) = *guard else { continue };
        match store.memtable_size() {
            Ok(size) if size >= flush_threshold => {
                if let Err(e) = store.flush() {
                    eprintln!("poller: flush error: {e}");
                }
            }
            _ => {}
        }
        // GC check via memtable_size as proxy (has_old_roots is internal to Nim)
        drop(guard);
    }
}

impl KVState {
    fn with_kv<F, R>(&self, f: F) -> Result<R, String>
    where
        F: FnOnce(&NimKVStore) -> Result<R, String>,
    {
        let guard = self.kv.lock().unwrap();
        let kv = guard.as_ref().ok_or_else(|| "kvstore not open".to_string())?;
        f(kv)
    }

    fn signal_flush_if_needed(&self) {
        let guard = self.kv.lock().unwrap();
        if let Some(ref kv) = *guard {
            if let Ok(size) = kv.memtable_size() {
                if size >= self.flush_threshold {
                    if let Some(tx) = self.flush_request.lock().unwrap().as_ref() {
                        let _ = tx.send(());
                    }
                }
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
    fn put(&self, cf: u32, key: &[u8]) -> Result<(), String> {
        let result = self.with_kv(|kv| kv.put(cf, key));
        self.signal_flush_if_needed();
        result
    }

    fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        let mut buf = Vec::new();
        let mut pos = 0;
        while pos + 4 <= keys.len() {
            let klen = u32::from_be_bytes([keys[pos], keys[pos + 1], keys[pos + 2], keys[pos + 3]]) as usize;
            if pos + 4 + klen > keys.len() { break; }
            buf.push(cf as u8);
            buf.extend_from_slice(&keys[pos..pos + 4 + klen]);
            pos += 4 + klen;
        }
        let result = self.with_kv(|kv| kv.batch_write(&buf));
        self.signal_flush_if_needed();
        result
    }

    fn batch_write(&self, ops: &[u8]) -> Result<(), String> {
        let result = self.with_kv(|kv| kv.batch_write(ops));
        self.signal_flush_if_needed();
        result
    }

    fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        let mut buf = Vec::new();
        let mut pos = 0;
        while pos + 4 <= keys.len() {
            let klen = u32::from_be_bytes([keys[pos], keys[pos + 1], keys[pos + 2], keys[pos + 3]]) as usize;
            if pos + 4 + klen > keys.len() { break; }
            buf.push(cf as u8);
            buf.extend_from_slice(&keys[pos..pos + 4 + klen]);
            pos += 4 + klen;
        }
        self.with_kv(|kv| kv.replay(&buf))
    }

    fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String> {
        self.with_kv(|kv| kv.get(cf, key))
    }

    fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        self.with_kv(|kv| kv.scan(cf, prefix))
    }

    fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        self.with_kv(|kv| kv.scan_reverse(cf, prefix))
    }

    fn items(&self, cf: u32) -> Result<Vec<u8>, String> {
        self.scan(cf, b"")
    }

    fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        let packed = self.scan(cf, prefix)?;
        let mut keys: Vec<Vec<u8>> = Vec::new();
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4;
            if pos + klen > packed.len() { break; }
            keys.push(packed[pos..pos + klen].to_vec());
            pos += klen;
        }
        let end = if prefix.is_empty() {
            vec![0xFF; 64]
        } else {
            let mut e = prefix.to_vec();
            e.extend_from_slice(&[0xFF; 32]);
            e
        };
        let it = SimpleCursor { keys, idx: 0, end, valid: false }.prime();
        Ok(CursorHandle { cursor: std::sync::Arc::new(std::cell::RefCell::new(it)) })
    }

    fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        let packed = self.scan_reverse(cf, prefix)?;
        let mut keys: Vec<Vec<u8>> = Vec::new();
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4;
            if pos + klen > packed.len() { break; }
            keys.push(packed[pos..pos + klen].to_vec());
            pos += klen;
        }
        let it = SimpleCursor { keys, idx: 0, end: vec![0xFF; 64], valid: false }.prime();
        Ok(CursorHandle { cursor: std::sync::Arc::new(std::cell::RefCell::new(it)) })
    }

    fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String> {
        Ok(cursor.cursor.borrow().is_valid())
    }

    fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String> {
        let guard = cursor.cursor.borrow();
        if !guard.is_valid() { return Ok(false); }
        if let Some(k) = guard.current_key() {
            buf.clear();
            buf.extend_from_slice(k);
            Ok(true)
        } else { Ok(false) }
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

    fn journal_put(&self, _key: &[u8], _value: &[u8]) -> Result<(), String> {
        Ok(()) // handled internally by NimKVStore
    }

    fn journal_scan(&self) -> Result<Vec<u8>, String> {
        Ok(Vec::new()) // handled internally by NimKVStore
    }

    fn journal_size(&self) -> Result<u64, String> {
        Ok(0) // handled internally by NimKVStore
    }

    fn memtable_size(&self) -> Result<u64, String> {
        self.with_kv(|kv| kv.memtable_size())
    }

    fn memtable_count(&self, cf: u32) -> Result<u64, String> {
        let packed = self.scan(cf, b"")?;
        let mut count = 0u64;
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4 + klen;
            count += 1;
        }
        Ok(count)
    }

    fn path(&self) -> Result<String, String> {
        Ok(":memory:".to_string())
    }

    fn approximate_sizes(&self, _cf: u32, _start: &[u8], _end: &[u8]) -> Result<u64, String> {
        Ok(0)
    }

    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String> {
        let name = page_store::cf_name_for(cf as usize);
        let count = self.memtable_count(cf).unwrap_or(0);
        let mut buf = Vec::new();
        let name_bytes = name.as_bytes();
        buf.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        buf.extend_from_slice(name_bytes);
        buf.extend_from_slice(&0u64.to_le_bytes()); // num_keys
        buf.extend_from_slice(&0u64.to_le_bytes()); // live_size
        buf.extend_from_slice(&0u64.to_le_bytes()); // sst_size
        buf.extend_from_slice(&0u64.to_le_bytes()); // num_sst
        buf.extend_from_slice(&count.to_le_bytes());  // memtable_size
        Ok(buf)
    }

    fn db_stats(&self) -> Result<Vec<u8>, String> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        Ok(buf)
    }

    fn gc_full(&self, dry_run: bool, _nowait: bool) -> Result<Vec<u8>, String> {
        self.with_kv(|kv| kv.gc_full(self.gc_max_age_secs, self.gc_max_root_count, dry_run))
    }

    fn internal_status(&self, _target: &str) -> Result<String, String> {
        Ok("kvstore: Nim-backed".to_string())
    }

    fn flush(&self) -> Result<(), String> {
        self.with_kv(|kv| kv.flush())
    }

    fn close(&self) -> Result<(), String> {
        if let Some(tx) = self.poll_shutdown.lock().unwrap().take() {
            let _ = tx.send(());
        }
        self.flush_request.lock().unwrap().take();
        if let Some(handle) = self.poll_handle.lock().unwrap().take() {
            let _ = handle.join();
        }
        let mut guard = self.kv.lock().unwrap();
        if let Some(kv) = guard.take() {
            drop(kv); // calls Nim -> kvCloseC -> cleanup
        }
        Ok(())
    }
}

// ── SimpleCursor — lightweight cursor over pre-fetched keys ──

use crate::storage_traits::Cursor;

struct SimpleCursor {
    keys: Vec<Vec<u8>>,
    idx: usize,
    end: Vec<u8>,
    valid: bool,
}

impl SimpleCursor {
    fn prime(mut self) -> Self {
        self.valid = self.idx < self.keys.len();
        self
    }
}

impl Cursor for SimpleCursor {
    fn is_valid(&self) -> bool {
        self.valid
    }

    fn current_key(&self) -> Option<&[u8]> {
        if self.valid { Some(&self.keys[self.idx]) } else { None }
    }

    fn step(&mut self) {
        if !self.valid { return; }
        self.idx += 1;
        self.valid = self.idx < self.keys.len();
    }

    fn skip_group(&mut self, group_end: usize) {
        if !self.valid { return; }
        let group = &self.keys[self.idx][..group_end.min(self.keys[self.idx].len())];
        while self.valid && self.keys[self.idx].len() >= group.len()
            && self.keys[self.idx][..group.len()] == group[..]
        {
            self.idx += 1;
            self.valid = self.idx < self.keys.len();
        }
    }

    fn seek(&mut self, target: &[u8]) {
        self.idx = self.keys.partition_point(|k| k.as_slice() < target);
        self.valid = self.idx < self.keys.len() && self.keys[self.idx].as_slice() <= self.end.as_slice();
    }

    fn update_end(&mut self, end: &[u8]) {
        self.end = end.to_vec();
        if self.valid && self.keys[self.idx].as_slice() > self.end.as_slice() {
            self.valid = false;
        }
    }

    fn invalidate(&mut self) {
        self.valid = false;
    }
}

unsafe impl Send for SimpleCursor {}
