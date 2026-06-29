use std::collections::{BTreeMap, HashMap};
use std::sync::RwLock;

use dynspire::*;

include!(concat!(env!("OUT_DIR"), "/blobstore_spier.rs"));

struct MemInner {
    blobs: HashMap<[u8; 16], Vec<u8>>,
    roots: BTreeMap<String, Vec<u8>>,
}

struct MemState {
    inner: RwLock<MemInner>,
}

fn init(_config: &std::collections::HashMap<String, String>) -> Result<MemState, String> {
    Ok(MemState {
        inner: RwLock::new(MemInner {
            blobs: HashMap::new(),
            roots: BTreeMap::new(),
        }),
    })
}

impl BlobStoreEngine for MemState {
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

impl_blobstore_spier!(MemState, init, "spier_blobstore_memory");
