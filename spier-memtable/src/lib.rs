use std::sync::Arc;

use spier_memtable_nim::NimMemTableStore;
use spier_storage_traits::memtable::{MemTableEngine, MemTableSnapshot};

pub use spier_memtable_nim::{MemTableCursor, NimSnap};

/// MemTable write buffer. Thin adapter over the Nim-backed memtable
/// (`spier_memtable_nim::NimMemTableStore`), reached through the same C-ABI
/// cursor/FFI the other Nim backends use. The ordered structure and its COW
/// snapshots live entirely inside Nim; Rust holds only opaque u64 ids. Cursors
/// own an `Arc` to the Nim store, so they outlive this `MemTable` if needed.
pub struct MemTable {
    inner: Arc<NimMemTableStore>,
}

impl MemTable {
    pub fn new(num_cf: usize) -> Self {
        Self {
            inner: Arc::new(NimMemTableStore::open(num_cf).expect("memtable open")),
        }
    }

    /// Open a lazy cursor-backed scan source over a snapshot/CF/prefix.
    /// Returns a `MemTableCursor` (opaque id) that yields one key per `next()`.
    pub fn open_scan_source(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
        reverse: bool,
    ) -> Result<MemTableCursor, String> {
        self.inner.open_scan_source(snap, cf, prefix, reverse)
    }

    /// Count keys with a prefix without materializing (used by approximate_sizes).
    pub fn count_prefix(&self, snap: &MemTableSnapshot, cf: u32, prefix: &[u8]) -> usize {
        self.inner.count_prefix(snap, cf, prefix) as usize
    }
}

impl MemTableEngine for MemTable {
    fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String> {
        self.inner.put(cf, key)
    }

    fn batch_write(&self, ops: &[u8]) -> Result<u64, String> {
        self.inner.batch_write(ops)
    }

    fn clear(&self) -> Result<(), String> {
        self.inner.clear()
    }

    fn snapshot(&self) -> Result<MemTableSnapshot, String> {
        self.inner.snapshot()
    }

    fn scan_prefix(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String> {
        self.inner.scan_prefix(snap, cf, prefix)
    }

    fn scan_prefix_reverse(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String> {
        self.inner.scan_prefix_reverse(snap, cf, prefix)
    }

    fn contains(&self, snap: MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String> {
        self.inner.contains(snap, cf, key)
    }
}
