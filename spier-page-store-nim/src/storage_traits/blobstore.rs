pub trait BlobStoreEngine: Send + Sync {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String>;
    fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String>;
    fn delete(&self, id: [u8; 16]) -> Result<(), String>;
    fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String>;
    fn list(&self) -> Result<Vec<[u8; 16]>, String>;
    fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String>;
    fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String>;
    fn list_roots(&self) -> Result<Vec<String>, String>;
    fn delete_root(&self, name: &str) -> Result<(), String>;
}
