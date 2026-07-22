// KVStore stub — C-ABI removed.

pub mod page_store;
pub use crate::storage_traits::CursorHandle;
pub use crate::storage_traits::KVStoreEngine;

use std::collections::HashMap;

pub struct KVState;

impl KVState {
    pub fn open(_config: &HashMap<String, String>) -> Result<Self, String> { todo!() }
}

impl KVStoreEngine for KVState {
    fn put(&self, _cf: u32, _key: &[u8]) -> Result<(), String> { todo!() }
    fn batch_put(&self, _cf: u32, _keys: &[u8]) -> Result<(), String> { todo!() }
    fn batch_write(&self, _ops: &[u8]) -> Result<(), String> { todo!() }
    fn replay(&self, _cf: u32, _keys: &[u8]) -> Result<(), String> { todo!() }
    fn get(&self, _cf: u32, _key: &[u8]) -> Result<bool, String> { todo!() }
    fn scan(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> { todo!() }
    fn scan_reverse(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> { todo!() }
    fn items(&self, _cf: u32) -> Result<Vec<u8>, String> { todo!() }
    fn open_cursor_direct(&self, _cf: u32, _prefix: &[u8]) -> Result<CursorHandle, String> { todo!() }
    fn open_cursor_reverse_direct(&self, _cf: u32, _prefix: &[u8]) -> Result<CursorHandle, String> { todo!() }
    fn cursor_valid(&self, _cursor: CursorHandle) -> Result<bool, String> { todo!() }
    fn cursor_current_key(&self, _cursor: CursorHandle, _buf: &mut Vec<u8>) -> Result<bool, String> { todo!() }
    fn cursor_step(&self, _cursor: CursorHandle) -> Result<(), String> { todo!() }
    fn cursor_seek(&self, _cursor: CursorHandle, _target: &[u8]) -> Result<(), String> { todo!() }
    fn cursor_skip_group(&self, _cursor: CursorHandle, _group_end: u32) -> Result<(), String> { todo!() }
    fn cursor_update_end(&self, _cursor: CursorHandle, _end: &[u8]) -> Result<(), String> { todo!() }
    fn journal_put(&self, _key: &[u8], _value: &[u8]) -> Result<(), String> { todo!() }
    fn journal_scan(&self) -> Result<Vec<u8>, String> { todo!() }
    fn journal_size(&self) -> Result<u64, String> { todo!() }
    fn memtable_size(&self) -> Result<u64, String> { todo!() }
    fn memtable_count(&self, _cf: u32) -> Result<u64, String> { todo!() }
    fn path(&self) -> Result<String, String> { todo!() }
    fn approximate_sizes(&self, _cf: u32, _start: &[u8], _end: &[u8]) -> Result<u64, String> { todo!() }
    fn cf_stats(&self, _cf: u32) -> Result<Vec<u8>, String> { todo!() }
    fn db_stats(&self) -> Result<Vec<u8>, String> { todo!() }
    fn gc_full(&self, _dry_run: bool, _nowait: bool) -> Result<Vec<u8>, String> { todo!() }
    fn internal_status(&self, _target: &str) -> Result<String, String> { todo!() }
    fn flush(&self) -> Result<(), String> { todo!() }
    fn close(&self) -> Result<(), String> { todo!() }
}
