//! `NimMemTableStore`: a `MemTableEngine` adapter for the Nim-implemented
//! memtable backend (persistent treap with COW snapshots). Compiled to
//! `libnim_memtable.a` (see `build.rs`); exposes
//! `nim_memtable_open(errOut) -> *mut NimMemTableVtable` and
//! `nim_memtable_close(vt)`.
//!
//! Error protocol (POSIX-style): every method returns `0` on success or `-1`
//! on failure; the caller-provided `errOut: ptr cint` receives one of the
//! `ERR_*` codes. Rust maps the code to a static message — no string
//! allocation crosses the FFI boundary.
//!
//! Snapshots/cursors are opaque `u64` ids. Rust never holds a reference to the
//! Nim-resident ordered structure: it only carries ids and iterates lazily via
//! the cursor FFI (one key per `cursor_next`), so no mass materialization.

use std::any::Any;
use std::ffi::{c_int, c_void};
use std::sync::Arc;

use spier_storage_traits::memtable::MemTableSnapshot;
// ---------------------------------------------------------------------------
// Error codes — mirror nim-memtable/abi.nim
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
// C ABI mirror of Nim's `NimMemTableVtableObj` (abi.nim).
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct NimMemTableVtable {
    pub handle: *mut c_void,
    pub put: extern "C" fn(
        h: *mut c_void,
        cf: u32,
        key: *const u8,
        klen: usize,
        out_size: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,
    pub batch: extern "C" fn(
        h: *mut c_void,
        ops: *const u8,
        olen: usize,
        out_size: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,
    pub clear: extern "C" fn(h: *mut c_void, err_out: *mut c_int) -> c_int,
    pub snapshot: extern "C" fn(h: *mut c_void, out_id: *mut u64, err_out: *mut c_int) -> c_int,
    pub snapshot_free: extern "C" fn(h: *mut c_void, id: u64),
    pub scan: extern "C" fn(
        h: *mut c_void,
        id: u64,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        reverse: c_int,
        out_cursor: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_next: extern "C" fn(
        h: *mut c_void,
        cursor: u64,
        out_key: *mut *mut u8,
        out_len: *mut usize,
        out_valid: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_seek: extern "C" fn(
        h: *mut c_void,
        cursor: u64,
        target: *const u8,
        tlen: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_advance_to: extern "C" fn(
        h: *mut c_void,
        cursor: u64,
        target: *const u8,
        tlen: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_skip_group: extern "C" fn(
        h: *mut c_void,
        cursor: u64,
        group: *const u8,
        glen: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_update_end: extern "C" fn(
        h: *mut c_void,
        cursor: u64,
        endp: *const u8,
        elen: usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub cursor_free: extern "C" fn(h: *mut c_void, cursor: u64),
    pub contains: extern "C" fn(
        h: *mut c_void,
        id: u64,
        cf: u32,
        key: *const u8,
        klen: usize,
        out_present: *mut c_int,
        err_out: *mut c_int,
    ) -> c_int,
    pub count_prefix: extern "C" fn(
        h: *mut c_void,
        id: u64,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        out_count: *mut u64,
        err_out: *mut c_int,
    ) -> c_int,
    pub scan_prefix: extern "C" fn(
        h: *mut c_void,
        id: u64,
        cf: u32,
        prefix: *const u8,
        plen: usize,
        reverse: c_int,
        out_buf: *mut *mut u8,
        out_len: *mut usize,
        err_out: *mut c_int,
    ) -> c_int,
    pub debug_count_nodes: extern "C" fn(h: *mut c_void, out_count: *mut u64) -> c_int,
    pub free_buf: extern "C" fn(p: *mut c_void),
}

extern "C" {
    fn nim_memtable_open(num_cf: u32, err_out: *mut c_int) -> *mut NimMemTableVtable;
    fn nim_memtable_close(vt: *mut NimMemTableVtable);
}

// ---------------------------------------------------------------------------
// Nim runtime init (one-shot).
// ---------------------------------------------------------------------------

static NIM_INIT: std::sync::Once = std::sync::Once::new();

extern "C" {
    fn NimMain();
}

fn ensure_nim_init() {
    NIM_INIT.call_once(|| unsafe {
        NimMain();
    });
}

// ---------------------------------------------------------------------------
// Snapshot id carrier. Lives inside `MemTableSnapshot.data` as `dyn Any`.
// ---------------------------------------------------------------------------

/// Opaque snapshot id returned by the Nim backend. Wrapped in
/// `MemTableSnapshot.data` so the Rust side can recover it via `downcast_ref`.
///
/// **GC contract:** holds an `Arc<NimMemTableStore>` so the Nim vtable/handle
/// stay alive until the snapshot is dropped. `Drop` calls `snapshot_free(id)`
/// on the Nim side, which clears the snapshot's root pointers and lets Nim's
/// ARC release the now-unreachable COW treap nodes. Without this Drop the old
/// treap versions would leak forever (the "immutable reference" lives inside
/// Nim; Rust signals release via this Drop → FFI call).
pub struct NimSnap {
    pub id: u64,
    store: Arc<NimMemTableStore>,
}

impl Drop for NimSnap {
    fn drop(&mut self) {
        let vt = self.store.vt;
        if !vt.is_null() {
            unsafe { ((*vt).snapshot_free)((*vt).handle, self.id) };
        }
    }
}

// ---------------------------------------------------------------------------
// NimMemTableStore
// ---------------------------------------------------------------------------

pub struct NimMemTableStore {
    vt: *mut NimMemTableVtable,
}

impl std::fmt::Debug for NimMemTableStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NimMemTableStore").field("vt", &self.vt).finish()
    }
}

// SAFETY: the Nim handle is guarded by a pthread_mutex on the Nim side.
unsafe impl Send for NimMemTableStore {}
unsafe impl Sync for NimMemTableStore {}

impl Drop for NimMemTableStore {
    fn drop(&mut self) {
        if !self.vt.is_null() {
            unsafe { nim_memtable_close(self.vt) };
            self.vt = std::ptr::null_mut();
        }
    }
}

impl NimMemTableStore {
    pub fn open(num_cf: usize) -> Result<Self, String> {
        ensure_nim_init();
        let mut err: c_int = 0;
        let vt = unsafe { nim_memtable_open(num_cf as u32, &mut err) };
        if vt.is_null() {
            return Err(format!("memtable open failed: {}", err_to_string(err)));
        }
        Ok(Self { vt })
    }

    fn snap_id(snap: &MemTableSnapshot) -> Result<u64, String> {
        snap.data
            .downcast_ref::<NimSnap>()
            .map(|s| s.id)
            .ok_or_else(|| "invalid memtable snapshot type".to_string())
    }

    /// Open a lazy cursor over a snapshot/CF/prefix. Returns an opaque
    /// `MemTableCursor` that yields one key per `next()` call — no
    /// materialization of the whole prefix. The cursor holds an `Arc` to the
    /// store so it stays self-contained (the Nim handle outlives the cursor
    /// even if the parent `MemTable` is dropped before the cursor is).
    pub fn open_scan_source(
        self: &Arc<Self>,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
        reverse: bool,
    ) -> Result<MemTableCursor, String> {
        let id = Self::snap_id(&snap)?;
        let mut cursor_id: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).scan)(
                (*self.vt).handle,
                id,
                cf,
                prefix.as_ptr(),
                prefix.len(),
                if reverse { 1 } else { 0 },
                &mut cursor_id,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(MemTableCursor {
            store: Arc::clone(self),
            cursor_id,
        })
    }

    /// Inherent helper (used by `approximate_sizes`): count keys with a prefix
    /// without materializing them.
    pub fn count_prefix(&self, snap: &MemTableSnapshot, cf: u32, prefix: &[u8]) -> u64 {
        match Self::snap_id(snap) {
            Ok(id) => {
                let mut out: u64 = 0;
                let mut err: c_int = 0;
                let rc = unsafe {
                    ((*self.vt).count_prefix)(
                        (*self.vt).handle,
                        id,
                        cf,
                        prefix.as_ptr(),
                        prefix.len(),
                        &mut out,
                        &mut err,
                    )
                };
                if rc != 0 {
                    0
                } else {
                    out
                }
            }
            Err(_) => 0,
        }
    }

    /// Debug-only: total number of UNIQUE treap nodes reachable from any live
    /// root or any in-use snapshot root. Used by GC tests to assert that
    /// releasing snapshots actually lets ARC collect old COW nodes.
    pub fn debug_count_nodes(&self) -> u64 {
        let mut out: u64 = 0;
        let rc = unsafe { ((*self.vt).debug_count_nodes)((*self.vt).handle, &mut out) };
        if rc != 0 {
            u64::MAX
        } else {
            out
        }
    }
}

// ---------------------------------------------------------------------------
// Lazy cursor returned to the scan path.
// ---------------------------------------------------------------------------

/// Opaque handle to a Nim-side cursor. Iterating calls `cursor_next` one key at
/// a time. Dropping frees the Nim cursor. Holds an `Arc<NimMemTableStore>` so
/// the Nim vtable/handle stay alive for the cursor's lifetime even if the
/// parent `MemTable` is dropped first.
pub struct MemTableCursor {
    store: Arc<NimMemTableStore>,
    cursor_id: u64,
}

impl Drop for MemTableCursor {
    fn drop(&mut self) {
        let vt = self.store.vt;
        if !vt.is_null() {
            unsafe { ((*vt).cursor_free)((*vt).handle, self.cursor_id) };
        }
    }
}

impl MemTableCursor {
    fn vt(&self) -> *mut NimMemTableVtable {
        self.store.vt
    }

    /// Advance the cursor and return the next key (None when exhausted).
    pub fn next(&self) -> Option<Vec<u8>> {
        let mut out_key: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut out_valid: c_int = 0;
        let mut err: c_int = 0;
        let vt = self.vt();
        let rc = unsafe {
            ((*vt).cursor_next)(
                (*vt).handle,
                self.cursor_id,
                &mut out_key,
                &mut out_len,
                &mut out_valid,
                &mut err,
            )
        };
        if rc != 0 || out_valid == 0 || out_key.is_null() {
            return None;
        }
        let mut out = Vec::with_capacity(out_len);
        unsafe {
            std::ptr::copy_nonoverlapping(out_key, out.as_mut_ptr(), out_len);
            out.set_len(out_len);
            ((*vt).free_buf)(out_key as *mut c_void);
        }
        Some(out)
    }

    pub fn seek(&self, target: &[u8]) {
        let mut err: c_int = 0;
        let vt = self.vt();
        unsafe {
            ((*vt).cursor_seek)((*vt).handle, self.cursor_id, target.as_ptr(), target.len(), &mut err);
        }
    }

    pub fn advance_to(&self, target: &[u8]) {
        let mut err: c_int = 0;
        let vt = self.vt();
        unsafe {
            ((*vt).cursor_advance_to)(
                (*vt).handle,
                self.cursor_id,
                target.as_ptr(),
                target.len(),
                &mut err,
            );
        }
    }

    pub fn skip_group(&self, group: &[u8]) {
        let mut err: c_int = 0;
        let vt = self.vt();
        unsafe {
            ((*vt).cursor_skip_group)(
                (*vt).handle,
                self.cursor_id,
                group.as_ptr(),
                group.len(),
                &mut err,
            );
        }
    }

    pub fn update_end(&self, end: &[u8]) {
        let mut err: c_int = 0;
        let vt = self.vt();
        unsafe {
            ((*vt).cursor_update_end)(
                (*vt).handle,
                self.cursor_id,
                end.as_ptr(),
                end.len(),
                &mut err,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// MemTableEngine-equivalent inherent methods. The trait itself is impl'd on the
// adapter `MemTable` (spier-memtable), which holds an `Arc<NimMemTableStore>`
// and can therefore produce a properly-GC'd `NimSnap` (see `snapshot_arc`).
// ---------------------------------------------------------------------------

impl NimMemTableStore {
    pub fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String> {
        let mut err: c_int = 0;
        let mut out_size: u64 = 0;
        let rc = unsafe {
            ((*self.vt).put)(
                (*self.vt).handle,
                cf,
                key.as_ptr(),
                key.len(),
                &mut out_size,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(out_size)
    }

    pub fn batch_write(&self, ops: &[u8]) -> Result<u64, String> {
        let mut err: c_int = 0;
        let mut out_size: u64 = 0;
        let rc = unsafe {
            ((*self.vt).batch)((*self.vt).handle, ops.as_ptr(), ops.len(), &mut out_size, &mut err)
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(out_size)
    }

    pub fn clear(&self) -> Result<(), String> {
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).clear)((*self.vt).handle, &mut err) };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(())
    }

    pub fn scan_prefix(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String> {
        self.scan_prefix_impl(&snap, cf, prefix, false)
    }

    pub fn scan_prefix_reverse(
        &self,
        snap: MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
    ) -> Result<Vec<u8>, String> {
        self.scan_prefix_impl(&snap, cf, prefix, true)
    }

    pub fn contains(&self, snap: MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String> {
        let id = Self::snap_id(&snap)?;
        let mut present: c_int = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).contains)(
                (*self.vt).handle,
                id,
                cf,
                key.as_ptr(),
                key.len(),
                &mut present,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(present != 0)
    }
}

impl NimMemTableStore {
    /// Snapshot that wires up proper GC: the returned `NimSnap` holds an
    /// `Arc<NimMemTableStore>`, and its `Drop` calls `snapshot_free(id)` so the
    /// Nim side releases the captured treap roots and ARC can collect COW nodes
    /// that are no longer reachable.
    pub fn snapshot_arc(self: &Arc<Self>) -> Result<MemTableSnapshot, String> {
        let mut id: u64 = 0;
        let mut err: c_int = 0;
        let rc = unsafe { ((*self.vt).snapshot)((*self.vt).handle, &mut id, &mut err) };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        Ok(MemTableSnapshot {
            data: Arc::new(NimSnap {
                id,
                store: Arc::clone(self),
            }) as Arc<dyn Any + Send + Sync>,
        })
    }

    fn scan_prefix_impl(
        &self,
        snap: &MemTableSnapshot,
        cf: u32,
        prefix: &[u8],
        reverse: bool,
    ) -> Result<Vec<u8>, String> {
        let id = Self::snap_id(snap)?;
        let mut out_buf: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut err: c_int = 0;
        let rc = unsafe {
            ((*self.vt).scan_prefix)(
                (*self.vt).handle,
                id,
                cf,
                prefix.as_ptr(),
                prefix.len(),
                if reverse { 1 } else { 0 },
                &mut out_buf,
                &mut out_len,
                &mut err,
            )
        };
        if rc != 0 {
            return Err(err_to_string(err).to_string());
        }
        if out_buf.is_null() || out_len == 0 {
            return Ok(Vec::new());
        }
        let mut out = Vec::with_capacity(out_len);
        unsafe {
            std::ptr::copy_nonoverlapping(out_buf, out.as_mut_ptr(), out_len);
            out.set_len(out_len);
            ((*self.vt).free_buf)(out_buf as *mut c_void);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unpack_kv(buf: &[u8]) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut pos = 0;
        while pos + 4 <= buf.len() {
            let klen =
                u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
            pos += 4;
            let key = buf[pos..pos + klen].to_vec();
            pos += klen;
            out.push(key);
        }
        out
    }

    #[test]
    fn put_scan_roundtrip_sorted_dedup() {
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        for s in ["banana", "apple", "cherry", "date", "apple"] {
            mt.put(0, s.as_bytes()).expect("put");
        }
        let snap = mt.snapshot_arc().expect("snapshot");
        let packed = mt.scan_prefix(snap, 0, b"").expect("scan");
        let keys = unpack_kv(&packed);
        assert_eq!(keys, vec![
            b"apple".to_vec(),
            b"banana".to_vec(),
            b"cherry".to_vec(),
            b"date".to_vec(),
        ]);
    }

    #[test]
    fn snapshot_survives_clear() {
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        mt.put(0, b"k1").expect("put");
        mt.put(0, b"k2").expect("put");
        let snap = mt.snapshot_arc().expect("snapshot");
        mt.clear().expect("clear");
        // live scan now empty
        let live = mt.snapshot_arc().expect("live");
        assert!(mt.scan_prefix(live, 0, b"").expect("scan").is_empty());
        // snapshot still holds pre-clear data
        let packed = mt.scan_prefix(snap, 0, b"").expect("scan");
        assert_eq!(unpack_kv(&packed), vec![b"k1".to_vec(), b"k2".to_vec()]);
    }

    #[test]
    fn cursor_lazy_forward() {
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        for i in 0..100u32 {
            mt.put(0, &i.to_be_bytes()).expect("put");
        }
        let snap = mt.snapshot_arc().expect("snap");
        let cursor = mt.open_scan_source(snap, 0, b"", false).expect("cursor");
        let mut count = 0;
        let mut prev: Option<Vec<u8>> = None;
        while let Some(k) = cursor.next() {
            if let Some(ref p) = prev {
                assert!(k.as_slice() > p.as_slice(), "cursor must ascend");
            }
            prev = Some(k);
            count += 1;
        }
        assert_eq!(count, 100);
    }

    #[test]
    fn count_prefix_works() {
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        for s in ["ax", "ay", "bz", "bx"] {
            mt.put(0, s.as_bytes()).expect("put");
        }
        let snap = mt.snapshot_arc().expect("snap");
        assert_eq!(mt.count_prefix(&snap, 0, b"a"), 2);
        assert_eq!(mt.count_prefix(&snap, 0, b""), 4);
    }

    // -----------------------------------------------------------------------
    // GC tests (ARC-driven collection of COW treap nodes)
    // -----------------------------------------------------------------------

    #[test]
    fn gc_snapshot_drop_releases_nodes() {
        // put 50 keys -> 50 nodes live. Snapshot, then clear live.
        // While the snapshot is alive, the nodes stay (shared via the snapshot
        // roots). After the snapshot drops, ARC must collect all of them.
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        for i in 0..50u32 {
            mt.put(0, &i.to_be_bytes()).expect("put");
        }
        let before = mt.debug_count_nodes();
        assert_eq!(before, 50, "50 keys => 50 nodes");

        let snap = mt.snapshot_arc().expect("snap");
        mt.clear().expect("clear");
        // snapshot still holds the old roots -> nodes still alive
        assert_eq!(
            mt.debug_count_nodes(),
            50,
            "snapshot keeps nodes alive after clear"
        );
        drop(snap);
        // Now nothing references the old nodes -> ARC must collect them all.
        assert_eq!(
            mt.debug_count_nodes(),
            0,
            "snapshot drop must release all COW nodes"
        );
    }

    #[test]
    fn gc_live_survives_when_snapshot_dropped() {
        // put k1, snapshot (holds v1), put k2 (path-copy -> new nodes).
        // After dropping the snapshot, the v1-only nodes go away but the live
        // tree (k1+k2) stays. The shared k1 node is NOT double-freed.
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        mt.put(0, b"k1").expect("put");
        let snap = mt.snapshot_arc().expect("snap"); // holds v1 (just k1)
        mt.put(0, b"k2").expect("put"); // path-copy: live now has k1+k2 (>=2 new nodes)
        let with_snap = mt.debug_count_nodes();
        assert!(
            with_snap >= 2,
            "expected at least 2 nodes with snapshot alive, got {with_snap}"
        );
        drop(snap);
        let after = mt.debug_count_nodes();
        // Live still has k1+k2 — at least 2 nodes. The old v1-only node (the
        // pre-insert root) must have been collected, so `after` <= `with_snap`.
        assert!(
            after >= 2 && after < with_snap,
            "expected 2 <= after < {with_snap}, got {after}"
        );
    }

    #[test]
    fn gc_many_snapshots_no_leak() {
        // Repeatedly snapshot+drop should NOT grow the live node set.
        let mt = Arc::new(NimMemTableStore::open(4).expect("open"));
        for i in 0..10u32 {
            mt.put(0, &i.to_be_bytes()).expect("put");
        }
        let baseline = mt.debug_count_nodes();
        for _ in 0..1000 {
            let s = mt.snapshot_arc().expect("snap");
            drop(s);
        }
        assert_eq!(
            mt.debug_count_nodes(),
            baseline,
            "1000 snapshot/drop cycles must not leak nodes"
        );
    }
}
