//! `NimPageStore`: a Rust FFI wrapper for the Nim-compiled B-tree page store
//! (`libnim_page_store.a`). Exposes `NimPageStore` with methods that call
//! through a C-ABI vtable.

pub mod storage_traits;
pub mod kvstore;
pub mod transactor;

pub use kvstore::KVState;

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::Once;

const ERR_OK: c_int = 0;
const ERR_INVALID_HANDLE: c_int = 1;
const ERR_INVALID_ARG: c_int = 2;
const ERR_IO: c_int = 3;
const ERR_READ_ONLY: c_int = 4;
const ERR_NO_MEM: c_int = 5;
const ERR_NOT_FOUND: c_int = 6;
const ERR_CONFLICT: c_int = 7;
const ERR_CONFIG: c_int = 8;

pub fn err_to_string(code: c_int) -> &'static str {
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

pub fn check_err(rc: c_int, err: c_int) -> Result<(), String> {
    if rc == 0 {
        Ok(())
    } else {
        Err(err_to_string(err).to_string())
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// C ABI mirror of Nim's `NimPageStoreVtableObj`
// ═══════════════════════════════════════════════════════════════════════════════

#[repr(C)]
pub struct NimPageStoreVtable {
    pub handle: *mut c_void,

    pub get_keys_in_prefix: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub key_exists: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        key: *const u8,
        klen: usize,
        out_present: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,

    pub page_count: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        out_count: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,

    pub page_count_in_range: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        start: *const u8,
        slen: usize,
        endp: *const u8,
        elen: usize,
        out_count: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,

    pub commit_merge: extern "C" fn(
        h: *mut c_void,
        data: *const u8,
        dlen: usize,
        clear_journal: c_int,
        err_out: *mut c_int,
    ) -> c_int,

    pub commit: extern "C" fn(
        h: *mut c_void,
        data: *const u8,
        dlen: usize,
        clear_journal: c_int,
        err_out: *mut c_int,
    ) -> c_int,

    pub journal_put: extern "C" fn(
        h: *mut c_void,
        key: *const u8,
        klen: usize,
        val: *const u8,
        vlen: usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub journal_scan: extern "C" fn(
        h: *mut c_void,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub journal_size: extern "C" fn(
        h: *mut c_void,
        out_size: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,

    pub gc_full: extern "C" fn(
        h: *mut c_void,
        max_age_secs: u64,
        max_root_count: u32,
        dry_run: c_int,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub cf_stats: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub db_stats: extern "C" fn(
        h: *mut c_void,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub internal_status: extern "C" fn(
        h: *mut c_void,
        target: *const c_char,
        out_str: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub collect_live_uuids: extern "C" fn(
        h: *mut c_void,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub has_old_roots: extern "C" fn(
        h: *mut c_void,
        max_age_secs: u64,
        max_root_count: u32,
        out_result: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,

    pub root_count: extern "C" fn(
        h: *mut c_void,
        out_count: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,

    pub current_root: extern "C" fn(
        h: *mut c_void,
        out_str: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub close: extern "C" fn(h: *mut c_void),
    pub free_buf: extern "C" fn(p: *mut c_void),
}

// ═══════════════════════════════════════════════════════════════════════════════
// Nim runtime init
// ═══════════════════════════════════════════════════════════════════════════════

static NIM_INIT: Once = Once::new();

extern "C" {
    fn NimMain();
}

fn ensure_nim_init() {
    NIM_INIT.call_once(|| unsafe { NimMain(); });
}

// ═══════════════════════════════════════════════════════════════════════════════
// External C function from libnim_page_store.a
// ═══════════════════════════════════════════════════════════════════════════════

extern "C" {
    fn nim_page_store_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        count: c_int,
        err_out: *mut c_int,
    ) -> *mut NimPageStoreVtable;

    fn nim_page_store_commit_merge(
        handle: *mut c_void,
        data: *const u8,
        dlen: usize,
        clear_journal: c_int,
        err_out: *mut c_int,
    ) -> c_int;
}

// ═══════════════════════════════════════════════════════════════════════════════
// NimPageStore — Rust wrapper
// ═══════════════════════════════════════════════════════════════════════════════

pub struct NimPageStore {
    vt: *mut NimPageStoreVtable,
}

unsafe impl Send for NimPageStore {}
unsafe impl Sync for NimPageStore {}

impl Drop for NimPageStore {
    fn drop(&mut self) {
        if !self.vt.is_null() {
            unsafe {
                let close_fn = (*self.vt).close;
                close_fn((*self.vt).handle);
            }
        }
    }
}

fn pack_config(config: &HashMap<String, String>) -> (Vec<CString>, Vec<CString>) {
    let mut keys = Vec::with_capacity(config.len());
    let mut vals = Vec::with_capacity(config.len());
    for (k, v) in config {
        keys.push(CString::new(k.as_str()).unwrap());
        vals.push(CString::new(v.as_str()).unwrap());
    }
    (keys, vals)
}

impl NimPageStore {
    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        ensure_nim_init();
        let (keys, vals) = pack_config(config);
        let key_ptrs: Vec<*const c_char> = keys.iter().map(|k| k.as_ptr()).collect();
        let val_ptrs: Vec<*const c_char> = vals.iter().map(|v| v.as_ptr()).collect();

        let mut err: c_int = 0;
        let vt = unsafe {
            nim_page_store_open(
                key_ptrs.as_ptr(),
                val_ptrs.as_ptr(),
                keys.len() as c_int,
                &mut err,
            )
        };

        if vt.is_null() {
            return Err(format!(
                "failed to open page store: {}",
                err_to_string(err)
            ));
        }

        Ok(Self { vt })
    }

    // ── Key operations ──

    pub fn get_keys_in_prefix(
        &self,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<Vec<u8>>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).get_keys_in_prefix)(
                (*self.vt).handle,
                cf,
                prefix.as_ptr(),
                prefix.len(),
                &mut out_buf,
                &mut out_len,
                &mut err,
            )
        };
        check_err(rc, err)?;

        let mut result = Vec::new();
        let mut pos = 0;
        while pos + 4 <= out_len {
            let klen = u32::from_be_bytes([
                unsafe { *out_buf.add(pos) },
                unsafe { *out_buf.add(pos + 1) },
                unsafe { *out_buf.add(pos + 2) },
                unsafe { *out_buf.add(pos + 3) },
            ]) as usize;
            pos += 4;
            if pos + klen > out_len {
                break;
            }
            let key = unsafe { std::slice::from_raw_parts(out_buf.add(pos), klen) }.to_vec();
            pos += klen;
            result.push(key);
        }

        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn key_exists(&self, cf: u32, key: &[u8]) -> Result<bool, String> {
        let mut present: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).key_exists)(
                (*self.vt).handle,
                cf,
                key.as_ptr(),
                key.len(),
                &mut present,
                &mut err,
            )
        };
        check_err(rc, err)?;
        Ok(present != 0)
    }

    // ── Page count ──

    pub fn page_count(&self, cf: u32) -> Result<u64, String> {
        let mut out_count: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).page_count)((*self.vt).handle, cf, &mut out_count, &mut err) };
        check_err(rc, err)?;
        Ok(out_count)
    }

    pub fn page_count_in_range(
        &self,
        cf: u32,
        start: &[u8],
        end: &[u8],
    ) -> Result<u64, String> {
        let mut out_count: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).page_count_in_range)(
                (*self.vt).handle,
                cf,
                start.as_ptr(),
                start.len(),
                end.as_ptr(),
                end.len(),
                &mut out_count,
                &mut err,
            )
        };
        check_err(rc, err)?;
        Ok(out_count)
    }

    // ── Commit / Merge ──

    /// Pack (cf, Vec<Vec<u8>>) into a binary buffer:
    /// For each CF: [u32 num_keys][for each key: u32 klen][key bytes]
    fn pack_commit_merge(data: &[(usize, Vec<Vec<u8>>)]) -> Vec<u8> {
        let mut buf = Vec::new();
        for (cf, keys) in data {
            buf.push(*cf as u8);
            let nk = keys.len() as u32;
            buf.extend_from_slice(&nk.to_be_bytes());
            for k in keys {
                let kl = k.len() as u32;
                buf.extend_from_slice(&kl.to_be_bytes());
                buf.extend_from_slice(k);
            }
        }
        buf
    }

    pub fn commit_merge(
        &self,
        keys_by_cf: &[(usize, Vec<Vec<u8>>)],
        clear_journal: bool,
    ) -> Result<(), String> {
        if keys_by_cf.is_empty() {
            return Ok(());
        }
        let packed = Self::pack_commit_merge(keys_by_cf);
        let mut err: c_int = 0;
        let rc = unsafe {
            nim_page_store_commit_merge(
                (*self.vt).handle,
                packed.as_ptr(),
                packed.len(),
                if clear_journal { 1 } else { 0 },
                &mut err,
            )
        };
        check_err(rc, err)
    }

    pub fn commit(
        &self,
        keys_by_cf: &[(usize, Vec<Vec<u8>>)],
        clear_journal: bool,
    ) -> Result<(), String> {
        self.commit_merge(keys_by_cf, clear_journal)
    }

    // ── Journal ──

    pub fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).journal_put)(
                (*self.vt).handle,
                key.as_ptr(),
                key.len(),
                value.as_ptr(),
                value.len(),
                &mut err,
            )
        };
        check_err(rc, err)
    }

    pub fn journal_scan(&self) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).journal_scan)((*self.vt).handle, &mut out_buf, &mut out_len, &mut err)
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn journal_size(&self) -> Result<u64, String> {
        let mut out_size: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).journal_size)((*self.vt).handle, &mut out_size, &mut err)
        };
        check_err(rc, err)?;
        Ok(out_size)
    }

    // ── GC ──

    pub fn gc_full(
        &self,
        max_age_secs: u64,
        max_root_count: u32,
        dry_run: bool,
    ) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).gc_full)(
                (*self.vt).handle,
                max_age_secs,
                max_root_count,
                if dry_run { 1 } else { 0 },
                &mut out_buf,
                &mut out_len,
                &mut err,
            )
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn has_old_roots(&self, max_age_secs: u64, max_root_count: u32) -> Result<bool, String> {
        let mut out_result: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).has_old_roots)(
                (*self.vt).handle,
                max_age_secs,
                max_root_count,
                &mut out_result,
                &mut err,
            )
        };
        check_err(rc, err)?;
        Ok(out_result != 0)
    }

    pub fn root_count(&self) -> Result<u64, String> {
        let mut out_count: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).root_count)((*self.vt).handle, &mut out_count, &mut err) };
        check_err(rc, err)?;
        Ok(out_count)
    }

    // ── Stats ──

    pub fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).cf_stats)((*self.vt).handle, cf, &mut out_buf, &mut out_len, &mut err)
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn db_stats(&self) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).db_stats)((*self.vt).handle, &mut out_buf, &mut out_len, &mut err)
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    // ── Close ──

    pub fn close(self) {
        // Drop handles cleanup
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// NimKVStoreVtable — unified KVStore C-ABI (mirrors NimKVStoreVtableObj)
// ═══════════════════════════════════════════════════════════════════════════════

#[repr(C)]
pub struct NimKVStoreVtable {
    pub handle: *mut c_void,

    pub put: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        key: *const u8,
        klen: usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub batch_write: extern "C" fn(
        h: *mut c_void,
        ops: *const u8,
        olen: usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub replay: extern "C" fn(
        h: *mut c_void,
        ops: *const u8,
        olen: usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub get: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        key: *const u8,
        klen: usize,
        out_present: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,

    pub scan: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub scan_reverse: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub flush: extern "C" fn(
        h: *mut c_void,
        err_out: *mut c_int,
    ) -> c_int,

    pub gc_full: extern "C" fn(
        h: *mut c_void,
        max_age_secs: u64,
        max_root_count: u32,
        dry_run: c_int,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,

    pub memtable_size: extern "C" fn(
        h: *mut c_void,
        out_size: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,

    pub close: extern "C" fn(
        h: *mut c_void,
        err_out: *mut c_int,
    ) -> c_int,

    pub free_buf: extern "C" fn(p: *mut c_void),
}

// ═══════════════════════════════════════════════════════════════════════════════
// NimKVStore — Rust wrapper
// ═══════════════════════════════════════════════════════════════════════════════

extern "C" {
    fn nim_kvstore_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        count: c_int,
        err_out: *mut c_int,
    ) -> *mut NimKVStoreVtable;
}

pub struct NimKVStore {
    vt: *mut NimKVStoreVtable,
}

unsafe impl Send for NimKVStore {}
unsafe impl Sync for NimKVStore {}

impl Drop for NimKVStore {
    fn drop(&mut self) {
        if !self.vt.is_null() {
            unsafe {
                let mut err: c_int = 0;
                ((*self.vt).close)((*self.vt).handle, &mut err);
            }
        }
    }
}

impl NimKVStore {
    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        ensure_nim_init();
        let (keys, vals) = pack_config(config);
        let key_ptrs: Vec<*const c_char> = keys.iter().map(|k| k.as_ptr()).collect();
        let val_ptrs: Vec<*const c_char> = vals.iter().map(|v| v.as_ptr()).collect();

        let mut err: c_int = 0;
        let vt = unsafe {
            nim_kvstore_open(
                key_ptrs.as_ptr(),
                val_ptrs.as_ptr(),
                keys.len() as c_int,
                &mut err,
            )
        };

        if vt.is_null() {
            return Err(format!("failed to open kvstore: {}", err_to_string(err)));
        }

        Ok(Self { vt })
    }

    // ── Writes ──

    pub fn put(&self, cf: u32, key: &[u8]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).put)((*self.vt).handle, cf, key.as_ptr(), key.len(), &mut err)
        };
        check_err(rc, err)
    }

    pub fn batch_write(&self, ops: &[u8]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).batch_write)((*self.vt).handle, ops.as_ptr(), ops.len(), &mut err)
        };
        check_err(rc, err)
    }

    pub fn replay(&self, ops: &[u8]) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).replay)((*self.vt).handle, ops.as_ptr(), ops.len(), &mut err)
        };
        check_err(rc, err)
    }

    // ── Reads ──

    pub fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String> {
        let mut present: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).get)((*self.vt).handle, cf, key.as_ptr(), key.len(), &mut present, &mut err)
        };
        check_err(rc, err)?;
        Ok(present != 0)
    }

    pub fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).scan)(
                (*self.vt).handle, cf,
                prefix.as_ptr(), prefix.len(),
                &mut out_buf, &mut out_len, &mut err,
            )
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).scan_reverse)(
                (*self.vt).handle, cf,
                prefix.as_ptr(), prefix.len(),
                &mut out_buf, &mut out_len, &mut err,
            )
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    // ── Flush / GC / Admin ──

    pub fn flush(&self) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).flush)((*self.vt).handle, &mut err) };
        check_err(rc, err)
    }

    pub fn gc_full(
        &self,
        max_age_secs: u64,
        max_root_count: u32,
        dry_run: bool,
    ) -> Result<Vec<u8>, String> {
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).gc_full)(
                (*self.vt).handle,
                max_age_secs,
                max_root_count,
                if dry_run { 1 } else { 0 },
                &mut out_buf,
                &mut out_len,
                &mut err,
            )
        };
        check_err(rc, err)?;
        let result = unsafe { std::slice::from_raw_parts(out_buf, out_len) }.to_vec();
        unsafe { ((*self.vt).free_buf)(out_buf as *mut c_void) };
        Ok(result)
    }

    pub fn memtable_size(&self) -> Result<u64, String> {
        let mut out_size: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).memtable_size)((*self.vt).handle, &mut out_size, &mut err) };
        check_err(rc, err)?;
        Ok(out_size)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Nim Query Engine — C-ABI wrappers for nim-page-store/query/api.nim
// ═══════════════════════════════════════════════════════════════════════════════

extern "C" {
    fn nim_query_open(
        keys: *const *const c_char,
        vals: *const *const c_char,
        count: c_int,
        errOut: *mut c_int,
    ) -> *mut c_void;

    fn nim_query_close(handle: *mut c_void);

    fn nim_query_save(
        handle: *mut c_void,
        eid: u64,
        attr: *const c_char,
        val: *const c_char,
        t: u64,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_retract(
        handle: *mut c_void,
        eid: u64,
        attr: *const c_char,
        val: *const c_char,
        t: u64,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_flush(
        handle: *mut c_void,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_declare_attr(
        handle: *mut c_void,
        name: *const c_char,
        vt_name: *const c_char,
        many: c_int,
        errOut: *mut c_int,
    ) -> u32;

    fn nim_query_lookup_attr(
        handle: *mut c_void,
        name: *const c_char,
        outAid: *mut u32,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_attr_name(
        handle: *mut c_void,
        aid: u32,
        outName: *mut *const c_char,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_value_type_for(
        handle: *mut c_void,
        aid: u32,
        outVt: *mut u32,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_is_declared(
        handle: *mut c_void,
        aid: u32,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_is_many(
        handle: *mut c_void,
        aid: u32,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_allocate_entity(
        handle: *mut c_void,
        errOut: *mut c_int,
    ) -> u64;

    fn nim_query_allocate_in_partition(
        handle: *mut c_void,
        partition_id: u64,
        errOut: *mut c_int,
    ) -> u64;

    fn nim_query_declare_partition(
        handle: *mut c_void,
        name: *const c_char,
        errOut: *mut c_int,
    ) -> u64;

    fn nim_query_partition_id_for(
        handle: *mut c_void,
        name: *const c_char,
        outPid: *mut u64,
        errOut: *mut c_int,
    ) -> c_int;

    fn nim_query_memtable_size(
        handle: *mut c_void,
        errOut: *mut c_int,
    ) -> u64;

    fn nim_query_path(
        handle: *mut c_void,
        outPath: *mut *const c_char,
        errOut: *mut c_int,
    ) -> c_int;
}

/// Rust wrapper for the Nim query engine (api.nim).
/// Only storage operations; SQL compilation still uses spier-eavt-query.
pub struct NimQueryHandle {
    handle: *mut c_void,
}

impl NimQueryHandle {
    pub fn open(config: &HashMap<String, String>) -> Result<Self, String> {
        let n = config.len() as c_int;
        let mut keys: Vec<CString> = Vec::with_capacity(config.len());
        let mut vals: Vec<CString> = Vec::with_capacity(config.len());
        for (k, v) in config {
            keys.push(CString::new(k.as_str()).map_err(|e| format!("CString: {e}"))?);
            vals.push(CString::new(v.as_str()).map_err(|e| format!("CString: {e}"))?);
        }
        let mut key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
        let mut val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();

        let mut err: c_int = 0;
        let handle = unsafe {
            nim_query_open(
                key_ptrs.as_ptr(),
                val_ptrs.as_ptr(),
                n,
                &mut err,
            )
        };
        if handle.is_null() {
            return Err(format!("nim_query_open failed: {}", err_to_string(err)));
        }
        Ok(Self { handle })
    }

    pub fn save(&self, eid: u64, attr: &str, val: &str, t: u64) -> Result<(), String> {
        let c_attr = CString::new(attr).map_err(|e| format!("{e}"))?;
        let c_val = CString::new(val).map_err(|e| format!("{e}"))?;
        let mut err: c_int = 0;
        let rc = unsafe {
            nim_query_save(self.handle, eid, c_attr.as_ptr(), c_val.as_ptr(), t, &mut err)
        };
        check_err(rc, err)
    }

    pub fn retract(&self, eid: u64, attr: &str, val: &str, t: u64) -> Result<(), String> {
        let c_attr = CString::new(attr).map_err(|e| format!("{e}"))?;
        let c_val = CString::new(val).map_err(|e| format!("{e}"))?;
        let mut err: c_int = 0;
        let rc = unsafe {
            nim_query_retract(self.handle, eid, c_attr.as_ptr(), c_val.as_ptr(), t, &mut err)
        };
        check_err(rc, err)
    }

    pub fn flush(&self) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe { nim_query_flush(self.handle, &mut err) };
        check_err(rc, err)
    }

    pub fn declare_attr(&self, name: &str, vt_name: &str, many: bool) -> Result<u32, String> {
        let c_name = CString::new(name).map_err(|e| format!("{e}"))?;
        let c_vt = CString::new(vt_name).map_err(|e| format!("{e}"))?;
        let mut err: c_int = 0;
        let aid = unsafe {
            nim_query_declare_attr(self.handle, c_name.as_ptr(), c_vt.as_ptr(), many as c_int, &mut err)
        };
        check_err(0, err)?;
        Ok(aid)
    }

    pub fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String> {
        let c_name = CString::new(name).map_err(|e| format!("{e}"))?;
        let mut out_aid: u32 = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            nim_query_lookup_attr(self.handle, c_name.as_ptr(), &mut out_aid, &mut err)
        };
        if rc != 0 {
            if err == ERR_NOT_FOUND { return Ok(None); }
            return Err(err_to_string(err).to_string());
        }
        Ok(Some(out_aid))
    }

    pub fn value_type_for(&self, aid: u32) -> Result<Option<u32>, String> {
        let mut out_vt: u32 = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            nim_query_value_type_for(self.handle, aid, &mut out_vt, &mut err)
        };
        if rc != 0 { return Ok(None); }
        Ok(Some(out_vt))
    }

    pub fn allocate_entity_id(&self) -> u64 {
        let mut err: c_int = 0;
        unsafe { nim_query_allocate_entity(self.handle, &mut err) }
    }

    pub fn allocate_in_partition(&self, partition_id: u64) -> u64 {
        let mut err: c_int = 0;
        unsafe { nim_query_allocate_in_partition(self.handle, partition_id, &mut err) }
    }

    pub fn declare_partition(&self, name: &str) -> Result<u64, String> {
        let c_name = CString::new(name).map_err(|e| format!("{e}"))?;
        let mut err: c_int = 0;
        let pid = unsafe { nim_query_declare_partition(self.handle, c_name.as_ptr(), &mut err) };
        check_err(0, err)?;
        Ok(pid)
    }

    pub fn memtable_size(&self) -> u64 {
        let mut err: c_int = 0;
        unsafe { nim_query_memtable_size(self.handle, &mut err) }
    }
}

impl Drop for NimQueryHandle {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { nim_query_close(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}
