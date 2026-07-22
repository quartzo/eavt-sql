//! Types-only crate — C-ABI stubbed after Nim migration.

pub mod storage_traits;
pub mod kvstore;
pub mod transactor;

pub use kvstore::KVState;

use std::collections::HashMap;

pub struct NimKVStore;

pub struct NimPageStore;
impl NimPageStore {
    pub fn open(_config: &HashMap<String, String>) -> Result<Self, String> { todo!() }
    pub fn get_keys_in_prefix(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<Vec<u8>>, String> { todo!() }
    pub fn key_exists(&self, _cf: u32, _key: &[u8]) -> Result<bool, String> { todo!() }
    pub fn page_count(&self, _cf: u32) -> Result<u64, String> { todo!() }
    pub fn page_count_in_range(&self, _cf: u32, _start: &[u8], _end: &[u8]) -> Result<u64, String> { todo!() }
    pub fn commit_merge(&self, _keys_by_cf: &[(usize, Vec<Vec<u8>>)], _clear_journal: bool) -> Result<(), String> { todo!() }
    pub fn commit(&self, keys_by_cf: &[(usize, Vec<Vec<u8>>)], clear_journal: bool) -> Result<(), String> { self.commit_merge(keys_by_cf, clear_journal) }
    pub fn journal_put(&self, _key: &[u8], _value: &[u8]) -> Result<(), String> { todo!() }
    pub fn journal_scan(&self) -> Result<Vec<u8>, String> { todo!() }
    pub fn journal_size(&self) -> Result<u64, String> { todo!() }
    pub fn gc_full(&self, _max_age_secs: u64, _max_root_count: u32, _dry_run: bool) -> Result<Vec<u8>, String> { todo!() }
    pub fn has_old_roots(&self, _max_age_secs: u64, _max_root_count: u32) -> Result<bool, String> { todo!() }
    pub fn root_count(&self) -> Result<u64, String> { todo!() }
    pub fn cf_stats(&self, _cf: u32) -> Result<Vec<u8>, String> { todo!() }
    pub fn db_stats(&self) -> Result<Vec<u8>, String> { todo!() }
    pub fn close(self) {}
}

impl NimKVStore {
    pub fn open(_config: &HashMap<String, String>) -> Result<Self, String> { todo!() }
    pub fn put(&self, _cf: u32, _key: &[u8]) -> Result<(), String> { todo!() }
    pub fn batch_put(&self, _cf: u32, _keys: &[u8]) -> Result<(), String> { todo!() }
    pub fn batch_write(&self, _ops: &[u8]) -> Result<(), String> { todo!() }
    pub fn replay(&self, _ops: &[u8]) -> Result<(), String> { todo!() }
    pub fn get(&self, _cf: u32, _key: &[u8]) -> Result<bool, String> { todo!() }
    pub fn scan(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> { todo!() }
    pub fn scan_reverse(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> { todo!() }
    pub fn memtable_size(&self) -> Result<u64, String> { todo!() }
    pub fn flush(&self) -> Result<(), String> { todo!() }
    pub fn journal_append(&self, _key: &[u8], _value: &[u8]) -> Result<(), String> { todo!() }
    pub fn journal_read(&self) -> Result<Vec<u8>, String> { todo!() }
    pub fn journal_truncate(&self) -> Result<(), String> { todo!() }
    pub fn gc_full(&self, _max_age_secs: u64, _max_root_count: u32, _dry_run: bool) -> Result<Vec<u8>, String> { todo!() }
}

impl Drop for NimKVStore { fn drop(&mut self) {} }
unsafe impl Send for NimKVStore {}
unsafe impl Sync for NimKVStore {}

unsafe impl Send for NimPageStore {}
unsafe impl Sync for NimPageStore {}
