use std::sync::Arc;

#[derive(Clone)]
pub struct MemTableSnapshot {
    pub data: Arc<dyn std::any::Any + Send + Sync>,
}

pub trait MemTableEngine: Send + Sync {
    fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String>;
    fn batch_write(&self, ops: &[u8]) -> Result<u64, String>;
    fn clear(&self) -> Result<(), String>;
    fn snapshot(&self) -> Result<MemTableSnapshot, String>;
    fn scan_prefix(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String>;
    fn scan_prefix_reverse(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String>;
    fn contains(&self, snap: MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String>;
}
