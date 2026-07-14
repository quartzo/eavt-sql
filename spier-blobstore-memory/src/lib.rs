use std::collections::{BTreeMap, HashMap};
use std::sync::RwLock;

use dynspire_commons::blobstore::BlobStoreEngine;

fn new_uuid() -> [u8; 16] {
    *uuid::Uuid::new_v4().as_bytes()
}

struct MemInner {
    blobs: HashMap<[u8; 16], Vec<u8>>,
    roots: BTreeMap<String, Vec<u8>>,
}

/// Pure Rust in-memory blob store. No dynspire/FFI — just implements [`BlobStoreEngine`].
pub struct MemoryBlobStore {
    inner: RwLock<MemInner>,
}

impl MemoryBlobStore {
    pub fn new() -> Self {
        Self {
            inner: RwLock::new(MemInner {
                blobs: HashMap::new(),
                roots: BTreeMap::new(),
            }),
        }
    }
}

impl Default for MemoryBlobStore {
    fn default() -> Self {
        Self::new()
    }
}

impl BlobStoreEngine for MemoryBlobStore {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
        let id = new_uuid();
        self.inner.write().unwrap().blobs.insert(id, data.to_vec());
        Ok(id)
    }

    fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
        self.inner.write().unwrap().blobs.insert(id, data.to_vec());
        Ok(())
    }

    fn delete(&self, id: [u8; 16]) -> Result<(), String> {
        self.inner.write().unwrap().blobs.remove(&id);
        Ok(())
    }

    fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
        Ok(self.inner.read().unwrap().blobs.get(&id).cloned())
    }

    fn list(&self) -> Result<Vec<[u8; 16]>, String> {
        Ok(self.inner.read().unwrap().blobs.keys().copied().collect())
    }

    fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
        self.inner.write().unwrap().roots.insert(name.to_string(), data.to_vec());
        Ok(())
    }

    fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        Ok(self.inner.read().unwrap().roots.get(name).cloned())
    }

    fn list_roots(&self) -> Result<Vec<String>, String> {
        Ok(self.inner.read().unwrap().roots.keys().cloned().collect())
    }

    fn delete_root(&self, name: &str) -> Result<(), String> {
        self.inner.write().unwrap().roots.remove(name);
        Ok(())
    }
}
