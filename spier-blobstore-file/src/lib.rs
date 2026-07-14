use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use spier_storage_traits::blobstore::BlobStoreEngine;

fn new_uuid() -> [u8; 16] {
    *uuid::Uuid::new_v4().as_bytes()
}

fn uuid_to_hex(id: &[u8; 16]) -> String {
    id.iter().map(|b| format!("{b:02x}")).collect()
}

fn uuid_from_hex(s: &str) -> Option<[u8; 16]> {
    if s.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for i in 0..16 {
        bytes[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(bytes)
}

fn uuid_path(base: &PathBuf, id: &[u8; 16]) -> PathBuf {
    let hex = uuid_to_hex(id);
    base.join(&hex[0..2]).join(&hex[2..4]).join(&hex)
}

fn write_file_atomic(path: &PathBuf, data: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(())
}

/// Pure Rust file-backed blob store. No dynspire/FFI — just implements [`BlobStoreEngine`].
pub struct FileBlobStore {
    base: Mutex<Option<PathBuf>>,
    read_only: Mutex<bool>,
}

impl FileBlobStore {
    pub fn new(config: &HashMap<String, String>) -> Result<Self, String> {
        let base = config
            .get("path")
            .map(|p| PathBuf::from(format!("{p}/blobs")));
        let read_only = config
            .get("read_only")
            .map(|v| v == "true")
            .unwrap_or(false);
        if let Some(ref path) = base {
            if !read_only {
                fs::create_dir_all(path).map_err(|e| e.to_string())?;
            }
        }
        Ok(Self {
            base: Mutex::new(base),
            read_only: Mutex::new(read_only),
        })
    }

    fn base(&self) -> Result<PathBuf, String> {
        self.base
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| "no base path configured".into())
    }
}

impl BlobStoreEngine for FileBlobStore {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
        if *self.read_only.lock().unwrap() {
            return Err("read-only".into());
        }
        let base = self.base()?;
        let id = new_uuid();
        write_file_atomic(&uuid_path(&base, &id), data)?;
        Ok(id)
    }

    fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
        if *self.read_only.lock().unwrap() {
            return Err("read-only".into());
        }
        let base = self.base()?;
        write_file_atomic(&uuid_path(&base, &id), data)
    }

    fn delete(&self, id: [u8; 16]) -> Result<(), String> {
        if *self.read_only.lock().unwrap() {
            return Err("read-only".into());
        }
        let base = self.base()?;
        let path = uuid_path(&base, &id);
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }

    fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
        let base = self.base()?;
        let path = uuid_path(&base, &id);
        match fs::read(&path) {
            Ok(data) => Ok(Some(data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn list(&self) -> Result<Vec<[u8; 16]>, String> {
        let mut ids = Vec::new();
        let base = self.base()?;
        if !base.exists() {
            return Ok(ids);
        }
        for e1 in fs::read_dir(&base).map_err(|e| e.to_string())?.flatten() {
            if !e1.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                continue;
            }
            for e2 in fs::read_dir(e1.path())
                .map_err(|e| e.to_string())?
                .flatten()
            {
                if !e2.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }
                for e3 in fs::read_dir(e2.path())
                    .map_err(|e| e.to_string())?
                    .flat_map(|e| e)
                {
                    if let Some(name) = e3.file_name().to_str() {
                        if !name.ends_with(".tmp") {
                            if let Some(id) = uuid_from_hex(name) {
                                ids.push(id);
                            }
                        }
                    }
                }
            }
        }
        Ok(ids)
    }

    fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
        if *self.read_only.lock().unwrap() {
            return Err("read-only".into());
        }
        let base = self.base()?;
        write_file_atomic(&base.join(name), data)
    }

    fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        let base = self.base()?;
        let path = base.join(name);
        match fs::read(&path) {
            Ok(data) => Ok(Some(data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn list_roots(&self) -> Result<Vec<String>, String> {
        let mut roots = Vec::new();
        let base = self.base()?;
        if !base.exists() {
            return Ok(roots);
        }
        for entry in fs::read_dir(&base).map_err(|e| e.to_string())?.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if name.starts_with("root_") && !name.ends_with(".tmp") {
                    roots.push(name.to_string());
                }
            }
        }
        roots.sort();
        Ok(roots)
    }

    fn delete_root(&self, name: &str) -> Result<(), String> {
        if *self.read_only.lock().unwrap() {
            return Err("read-only".into());
        }
        let base = self.base()?;
        let path = base.join(name);
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}
