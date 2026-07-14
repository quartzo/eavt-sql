use super::cursor::CursorHandle;

pub trait KVStoreEngine: Send + Sync {
    fn put(&self, cf: u32, key: &[u8]) -> Result<(), String>;
    fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
    fn batch_write(&self, ops: &[u8]) -> Result<(), String>;
    fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
    fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String>;
    fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
    fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
    fn items(&self, cf: u32) -> Result<Vec<u8>, String>;
    fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
    fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
    fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String>;
    fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String>;
    fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String>;
    fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String>;
    fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String>;
    fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String>;
    fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn journal_scan(&self) -> Result<Vec<u8>, String>;
    fn journal_size(&self) -> Result<u64, String>;
    fn memtable_size(&self) -> Result<u64, String>;
    fn memtable_count(&self, cf: u32) -> Result<u64, String>;
    fn path(&self) -> Result<String, String>;
    fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String>;
    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
    fn db_stats(&self) -> Result<Vec<u8>, String>;
    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
    fn internal_status(&self, target: &str) -> Result<String, String>;
    fn flush(&self) -> Result<(), String>;
    fn close(&self) -> Result<(), String>;
}
