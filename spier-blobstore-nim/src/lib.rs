//! `NimBlobStore`: a `BlobStoreEngine` adapter for the Nim-implemented
//! backends (memory / file / s3). The Nim side is compiled to 3 independent
//! static libraries (see `build.rs`); each exports
//! `nim_blob_<name>_open(keys, vals, n, err_out) -> *mut NimBlobVtable` and
//! `nim_blob_<name>_close(vt)`. The vtable carries the 9 trait-method function
//! pointers plus `free_buf` / `free_strs` for releasing shared-heap buffers
//! returned by `get` / `list` / `get_root` / `list_roots`.
//!
//! Error protocol (POSIX-style): every method returns `0` on success or `-1`
//! on failure; the caller-provided `err_out: *mut c_int` receives one of the
//! `ERR_*` codes below. Rust maps the code to a static message — no string
//! allocation crosses the FFI boundary, so no `free_str` is needed.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::Once;

use spier_storage_traits::blobstore::BlobStoreEngine;

// ---------------------------------------------------------------------------
// Error codes — mirror nim-blobstore/<backend>/abi.nim
// ---------------------------------------------------------------------------

const ERR_OK: c_int = 0;
const ERR_INVALID_HANDLE: c_int = 1;
const ERR_INVALID_ARG: c_int = 2;
const ERR_IO: c_int = 3;
const ERR_READ_ONLY: c_int = 4;
const ERR_NO_MEM: c_int = 5;
const ERR_NOT_FOUND: c_int = 6;
const ERR_CONFLICT: c_int = 7;
const ERR_CONFIG: c_int = 8;

fn err_to_string(code: c_int) -> &'static str {
    match code {
        ERR_OK => "ok",
        ERR_INVALID_HANDLE => "invalid handle",
        ERR_INVALID_ARG => "invalid argument",
        ERR_IO => "I/O error",
        ERR_READ_ONLY => "backend is read-only",
        ERR_NO_MEM => "out of memory",
        ERR_NOT_FOUND => "not found",
        ERR_CONFLICT => "unique constraint violation",
        ERR_CONFIG => "invalid or missing config",
        _ => "unknown error",
    }
}

// ---------------------------------------------------------------------------
// C ABI mirror of Nim's `NimBlobVtableObj` (abi.nim).
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct NimBlobVtable {
    pub handle: *mut c_void,
    pub put: extern "C" fn(
        h: *mut c_void,
        data: *const u8,
        len: usize,
        id_out: *mut u8,
        err_out: *mut c_int,
    ) -> c_int,
    pub put_at: extern "C" fn(
        h: *mut c_void,
        id: *const u8,
        data: *const u8,
        len: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub delete: extern "C" fn(
        h: *mut c_void,
        id: *const u8,
        err_out: *mut c_int,
    ) -> c_int,
    pub get: extern "C" fn(
        h: *mut c_void,
        id: *const u8,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        out_present: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,
    pub list: extern "C" fn(
        h: *mut c_void,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub put_root: extern "C" fn(
        h: *mut c_void,
        name: *const c_char,
        data: *const u8,
        len: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub get_root: extern "C" fn(
        h: *mut c_void,
        name: *const c_char,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        out_present: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,
    pub list_roots: extern "C" fn(
        h: *mut c_void,
        out_arr: *mut *mut *mut c_char,
        out_count: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub delete_root: extern "C" fn(
        h: *mut c_void,
        name: *const c_char,
        err_out: *mut c_int,
    ) -> c_int,
    pub free_buf: extern "C" fn(p: *mut c_void),
    pub free_strs: extern "C" fn(arr: *mut *mut c_char, count: usize),
}

// ---------------------------------------------------------------------------
// Per-backend open/close extern declarations. Each backend lives in its own
// static lib; names are specialized (memory / file / s3) to avoid collisions.
// ---------------------------------------------------------------------------

extern "C" {
    fn nim_blob_memory_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        n: usize,
        err_out: *mut c_int,
    ) -> *mut NimBlobVtable;
    fn nim_blob_memory_close(vt: *mut NimBlobVtable);

    fn nim_blob_file_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        n: usize,
        err_out: *mut c_int,
    ) -> *mut NimBlobVtable;
    fn nim_blob_file_close(vt: *mut NimBlobVtable);

    fn nim_blob_s3_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        n: usize,
        err_out: *mut c_int,
    ) -> *mut NimBlobVtable;
    fn nim_blob_s3_close(vt: *mut NimBlobVtable);
}

// ---------------------------------------------------------------------------
// Nim runtime init (one-shot).
// ---------------------------------------------------------------------------

static NIM_INIT: Once = Once::new();

extern "C" {
    fn NimMain();
}

fn ensure_nim_init() {
    NIM_INIT.call_once(|| unsafe {
        NimMain();
    });
}

// ---------------------------------------------------------------------------
// NimBlobStore — owns a vtable pointer + the matching close function.
// ---------------------------------------------------------------------------

pub struct NimBlobStore {
    vt: *mut NimBlobVtable,
    close_fn: unsafe extern "C" fn(*mut NimBlobVtable),
}

impl std::fmt::Debug for NimBlobStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NimBlobStore")
            .field("vt", &self.vt)
            .finish()
    }
}

// SAFETY: The Nim handle's internal state is protected by pthread_mutex on the
// Nim side; the vtable pointer is effectively const after `open`. We expose
// `&self` access to all trait methods, mirroring the trait's `&self`.
unsafe impl Send for NimBlobStore {}
unsafe impl Sync for NimBlobStore {}

impl Drop for NimBlobStore {
    fn drop(&mut self) {
        if !self.vt.is_null() {
            unsafe { (self.close_fn)(self.vt) };
            self.vt = std::ptr::null_mut();
        }
    }
}

// ---------------------------------------------------------------------------
// Constructors — one per backend.
// ---------------------------------------------------------------------------

impl NimBlobStore {
    /// Open the in-memory backend. Config is ignored (matches Rust's
    /// `MemoryBlobStore::new()`).
    pub fn open_memory(config: &HashMap<String, String>) -> Result<Self, String> {
        ensure_nim_init();
        let (keys_c, vals_c) = pack_config(config);
        let keys: Vec<*const c_char> = keys_c.iter().map(|c| c.as_ptr()).collect();
        let vals: Vec<*const c_char> = vals_c.iter().map(|c| c.as_ptr()).collect();
        let mut err: c_int = 0;
        let vt = unsafe {
            nim_blob_memory_open(
                keys.as_ptr(),
                vals.as_ptr(),
                keys.len(),
                &mut err,
            )
        };
        if vt.is_null() {
            return Err(format!("memory open failed: {}", err_to_string(err)));
        }
        Ok(Self {
            vt,
            close_fn: nim_blob_memory_close,
        })
    }

    /// Open the file backend. Required config key: `path`. Optional: `read_only`
    /// ("true" / "false"). Reads `{path}/blobs/` for blob storage and
    /// `{path}/blobs/<root_name>` for named roots.
    pub fn open_file(config: &HashMap<String, String>) -> Result<Self, String> {
        ensure_nim_init();
        let (keys_c, vals_c) = pack_config(config);
        let keys: Vec<*const c_char> = keys_c.iter().map(|c| c.as_ptr()).collect();
        let vals: Vec<*const c_char> = vals_c.iter().map(|c| c.as_ptr()).collect();
        let mut err: c_int = 0;
        let vt = unsafe {
            nim_blob_file_open(
                keys.as_ptr(),
                vals.as_ptr(),
                keys.len(),
                &mut err,
            )
        };
        if vt.is_null() {
            return Err(format!("file open failed: {}", err_to_string(err)));
        }
        Ok(Self {
            vt,
            close_fn: nim_blob_file_close,
        })
    }

    /// Open the S3 backend. Required config keys: `endpoint`, `bucket_name`,
    /// `region`, `access_key`, `secret_key`. Optional: `prefix`, `path_style`
    /// ("true" → vhost-style URLs). Uses hand-rolled SigV4 + std/httpclient
    /// on the Nim side.
    pub fn open_s3(config: &HashMap<String, String>) -> Result<Self, String> {
        ensure_nim_init();
        let (keys_c, vals_c) = pack_config(config);
        let keys: Vec<*const c_char> = keys_c.iter().map(|c| c.as_ptr()).collect();
        let vals: Vec<*const c_char> = vals_c.iter().map(|c| c.as_ptr()).collect();
        let mut err: c_int = 0;
        let vt = unsafe {
            nim_blob_s3_open(
                keys.as_ptr(),
                vals.as_ptr(),
                keys.len(),
                &mut err,
            )
        };
        if vt.is_null() {
            return Err(format!("s3 open failed: {}", err_to_string(err)));
        }
        Ok(Self {
            vt,
            close_fn: nim_blob_s3_close,
        })
    }
}

// ---------------------------------------------------------------------------
// BlobStoreEngine impl — single dispatch through the vtable.
// ---------------------------------------------------------------------------

impl BlobStoreEngine for NimBlobStore {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
        let mut id = [0u8; 16];
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).put)(
                (*self.vt).handle,
                data.as_ptr(),
                data.len(),
                id.as_mut_ptr(),
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(id)
    }

    fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).put_at)(
                (*self.vt).handle,
                id.as_ptr(),
                data.as_ptr(),
                data.len(),
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(())
    }

    fn delete(&self, id: [u8; 16]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).delete)((*self.vt).handle, id.as_ptr(), &mut err)
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(())
    }

    fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
        let mut buf: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let mut present: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).get)(
                (*self.vt).handle,
                id.as_ptr(),
                &mut buf,
                &mut len,
                &mut present,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        if present == 0 {
            return Ok(None);
        }
        let data = unsafe { std::slice::from_raw_parts(buf, len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(buf as *mut c_void) };
        Ok(Some(data))
    }

    fn list(&self) -> Result<Vec<[u8; 16]>, String> {
        let mut buf: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).list)((*self.vt).handle, &mut buf, &mut len, &mut err)
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        let count = len / 16;
        let mut ids = Vec::with_capacity(count);
        for i in 0..count {
            let mut id = [0u8; 16];
            unsafe {
                std::ptr::copy_nonoverlapping(buf.add(i * 16), id.as_mut_ptr(), 16);
            }
            ids.push(id);
        }
        unsafe { ((*self.vt).free_buf)(buf as *mut c_void) };
        Ok(ids)
    }

    fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
        let cname = CString::new(name).map_err(|e| format!("invalid name: {e}"))?;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).put_root)(
                (*self.vt).handle,
                cname.as_ptr(),
                data.as_ptr(),
                data.len(),
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(())
    }

    fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        let cname = CString::new(name).map_err(|e| format!("invalid name: {e}"))?;
        let mut buf: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let mut present: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).get_root)(
                (*self.vt).handle,
                cname.as_ptr(),
                &mut buf,
                &mut len,
                &mut present,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        if present == 0 {
            return Ok(None);
        }
        let data = unsafe { std::slice::from_raw_parts(buf, len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(buf as *mut c_void) };
        Ok(Some(data))
    }

    fn list_roots(&self) -> Result<Vec<String>, String> {
        let mut arr: *mut *mut c_char = std::ptr::null_mut();
        let mut count: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).list_roots)((*self.vt).handle, &mut arr, &mut count, &mut err)
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        let mut names = Vec::with_capacity(count);
        for i in 0..count {
            let s = unsafe { CStr::from_ptr(*arr.add(i)) }
                .to_string_lossy()
                .into_owned();
            names.push(s);
        }
        unsafe { ((*self.vt).free_strs)(arr, count) };
        Ok(names)
    }

    fn delete_root(&self, name: &str) -> Result<(), String> {
        let cname = CString::new(name).map_err(|e| format!("invalid name: {e}"))?;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).delete_root)((*self.vt).handle, cname.as_ptr(), &mut err)
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pack a Rust `HashMap<String,String>` into parallel arrays of NUL-terminated
/// C strings. Returned `CString`s own their storage; their `as_ptr()` is valid
/// for the lifetime of the Vec, which is sufficient for the synchronous `open`
/// call.
fn pack_config(config: &HashMap<String, String>) -> (Vec<CString>, Vec<CString>) {
    let mut keys = Vec::with_capacity(config.len());
    let mut vals = Vec::with_capacity(config.len());
    for (k, v) in config {
        if let (Ok(ck), Ok(cv)) = (CString::new(k.as_str()), CString::new(v.as_str())) {
            keys.push(ck);
            vals.push(cv);
        }
    }
    (keys, vals)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_config() -> HashMap<String, String> {
        HashMap::new()
    }

    #[test]
    fn memory_put_get_roundtrip() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        let payload = b"hello world, this is a test blob";
        let id = bs.put(payload).expect("put");
        let got = bs.get(id).expect("get");
        assert_eq!(got, Some(payload.to_vec()));
    }

    #[test]
    fn memory_get_missing_returns_none() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        let missing = [0u8; 16];
        assert_eq!(bs.get(missing).expect("get"), None);
    }

    #[test]
    fn memory_put_at_overwrites() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        let id = [0xAA; 16];
        bs.put_at(id, b"v1").expect("put_at");
        bs.put_at(id, b"version-2").expect("put_at overwrite");
        assert_eq!(bs.get(id).expect("get"), Some(b"version-2".to_vec()));
    }

    #[test]
    fn memory_delete() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        let id = bs.put(b"x").expect("put");
        bs.delete(id).expect("delete");
        assert_eq!(bs.get(id).expect("get"), None);
    }

    #[test]
    fn memory_list_returns_all_ids() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        let id1 = bs.put(b"a").expect("put");
        let id2 = bs.put(b"b").expect("put");
        let mut ids = bs.list().expect("list");
        ids.sort();
        let mut expected = [id1, id2];
        expected.sort();
        assert_eq!(ids, expected.to_vec());
    }

    #[test]
    fn memory_roots_lifecycle() {
        let bs = NimBlobStore::open_memory(&empty_config()).expect("open");
        bs.put_root("root_1", b"first").expect("put_root");
        bs.put_root("root_2", b"second").expect("put_root");
        let roots = bs.list_roots().expect("list_roots");
        assert_eq!(roots, vec!["root_1".to_string(), "root_2".to_string()]);
        assert_eq!(bs.get_root("root_1").expect("get_root"), Some(b"first".to_vec()));
        bs.delete_root("root_1").expect("delete_root");
        let roots2 = bs.list_roots().expect("list_roots2");
        assert_eq!(roots2, vec!["root_2".to_string()]);
    }

    #[test]
    fn memory_send_sync_across_threads() {
        let bs = std::sync::Arc::new(NimBlobStore::open_memory(&empty_config()).expect("open"));
        let id = bs.put(b"shared").expect("put");

        let bs2 = std::sync::Arc::clone(&bs);
        let t1 = std::thread::spawn(move || bs2.get(id).expect("get"));
        let t2 = std::thread::spawn(move || bs.list().expect("list"));
        assert_eq!(t1.join().unwrap(), Some(b"shared".to_vec()));
        assert!(t2.join().unwrap().contains(&id));
    }

    // -----------------------------------------------------------------------
    // File backend tests
    // -----------------------------------------------------------------------

    fn file_config(dir: &std::path::Path) -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("path".to_string(), dir.to_string_lossy().into_owned());
        m
    }

    #[test]
    fn file_put_get_roundtrip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        let payload = b"file payload bytes";
        let id = bs.put(payload).expect("put");
        assert_eq!(bs.get(id).expect("get"), Some(payload.to_vec()));
    }

    #[test]
    fn file_put_at_overwrites_same_id() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        let id = [0xBB; 16];
        bs.put_at(id, b"v1").expect("put_at");
        bs.put_at(id, b"v2").expect("put_at overwrite");
        assert_eq!(bs.get(id).expect("get"), Some(b"v2".to_vec()));
    }

    #[test]
    fn file_get_missing_returns_none() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        assert_eq!(bs.get([0xFF; 16]).expect("get"), None);
    }

    #[test]
    fn file_delete_missing_is_success() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        bs.delete([0x11; 16]).expect("delete missing");
    }

    #[test]
    fn file_list_returns_all_ids() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        let id1 = bs.put(b"a").expect("put");
        let id2 = bs.put(b"b").expect("put");
        let mut ids = bs.list().expect("list");
        ids.sort();
        let mut expected = [id1, id2];
        expected.sort();
        assert_eq!(ids, expected.to_vec());
    }

    #[test]
    fn file_roots_lifecycle_and_sort() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
        bs.put_root("root_002", b"second").expect("put_root");
        bs.put_root("root_001", b"first").expect("put_root");
        // list_roots only returns names with `root_` prefix; both match.
        let roots = bs.list_roots().expect("list_roots");
        assert_eq!(roots, vec!["root_001".to_string(), "root_002".to_string()]);
        bs.delete_root("root_001").expect("delete_root");
        let roots2 = bs.list_roots().expect("list_roots2");
        assert_eq!(roots2, vec!["root_002".to_string()]);
    }

    #[test]
    fn file_read_only_rejects_writes() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut cfg = file_config(dir.path());
        cfg.insert("read_only".to_string(), "true".to_string());
        let bs = NimBlobStore::open_file(&cfg).expect("open");
        let err = bs.put(b"x").expect_err("expected read-only rejection");
        assert!(err.contains("read-only"), "unexpected error: {}", err);
    }

    #[test]
    fn file_persists_across_reopen() {
        let dir = tempfile::tempdir().expect("tempdir");
        let id = {
            let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("open");
            bs.put(b"persistent").expect("put")
        };
        // Reopen a fresh backend pointed at the same dir; the blob must survive.
        let bs = NimBlobStore::open_file(&file_config(dir.path())).expect("reopen");
        assert_eq!(bs.get(id).expect("get"), Some(b"persistent".to_vec()));
        assert!(bs.list().expect("list").contains(&id));
    }

    // -----------------------------------------------------------------------
    // S3 backend tests
    // -----------------------------------------------------------------------
    //
    // We can't exercise live S3 in unit tests (needs credentials + a real
    // bucket). The minimal coverage here is the config-validation path:
    // open_s3 must reject incomplete config with a descriptive error rather
    // than segfaulting. End-to-end behavior is verified manually against a
    // MinIO container (see AGENTS.md).

    fn s3_config_missing_endpoint() -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("bucket_name".to_string(), "test".to_string());
        m
    }

    #[test]
    fn s3_open_rejects_missing_endpoint() {
        let err = NimBlobStore::open_s3(&s3_config_missing_endpoint())
            .expect_err("expected missing-endpoint rejection");
        assert!(err.contains("config"), "unexpected error: {}", err);
    }

    #[test]
    fn s3_open_rejects_missing_credentials() {
        let mut m = HashMap::new();
        m.insert("endpoint".to_string(), "http://localhost:9000".to_string());
        m.insert("bucket_name".to_string(), "test".to_string());
        m.insert("region".to_string(), "us-east-1".to_string());
        let err = NimBlobStore::open_s3(&m)
            .expect_err("expected missing-credentials rejection");
        assert!(err.contains("config"), "unexpected error: {}", err);
    }

    #[test]
    fn s3_open_accepts_full_config() {
        // Validates the *constructor* path; we don't actually issue HTTP here.
        let mut m = HashMap::new();
        m.insert("endpoint".to_string(), "http://localhost:9000".to_string());
        m.insert("bucket_name".to_string(), "test".to_string());
        m.insert("region".to_string(), "us-east-1".to_string());
        m.insert("access_key".to_string(), "minioadmin".to_string());
        m.insert("secret_key".to_string(), "minioadmin".to_string());
        let bs = NimBlobStore::open_s3(&m).expect("open_s3 with full config");
        drop(bs);  // exercises Drop -> nim_blob_s3_close
    }
}
