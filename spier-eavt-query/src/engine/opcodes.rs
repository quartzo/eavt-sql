use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

static DEBUG_TIMING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

static DEBUG_TIMING_INIT: std::sync::OnceLock<()> = std::sync::OnceLock::new();

fn init_debug_timing() {
    DEBUG_TIMING_INIT.get_or_init(|| {
        let v = std::env::var("EAVT_TIMING").unwrap_or_default();
        let enabled = v == "1" || v == "true";
        if enabled {
            eprintln!("[EAVT] timing enabled via EAVT_TIMING={}", v);
            std::fs::write("/tmp/eavt_timing_debug.txt", format!("enabled v={}", v)).ok();
        } else {
            std::fs::write("/tmp/eavt_timing_debug.txt", format!("disabled v={:?}", v)).ok();
        }
        DEBUG_TIMING.store(enabled, AtomicOrdering::Relaxed);
    });
}

pub fn debug_timing_enabled() -> bool {
    init_debug_timing();
    DEBUG_TIMING.load(AtomicOrdering::Relaxed)
}

static SCANNER_ADVANCE_NS: AtomicU64 = AtomicU64::new(0);
static SCANNER_SEEK_NS: AtomicU64 = AtomicU64::new(0);
static SCANNER_ADVANCE_COUNT: AtomicU64 = AtomicU64::new(0);
static SCANNER_SEEK_COUNT: AtomicU64 = AtomicU64::new(0);

pub fn scanner_advance_elapsed(nanos: u64) {
    SCANNER_ADVANCE_NS.fetch_add(nanos, AtomicOrdering::Relaxed);
    SCANNER_ADVANCE_COUNT.fetch_add(1, AtomicOrdering::Relaxed);
}

#[allow(dead_code)]
pub fn scanner_seek_elapsed(nanos: u64) {
    SCANNER_SEEK_NS.fetch_add(nanos, AtomicOrdering::Relaxed);
    SCANNER_SEEK_COUNT.fetch_add(1, AtomicOrdering::Relaxed);
}

static SKIP_GROUP_COUNT: AtomicU64 = AtomicU64::new(0);

pub fn skip_group_call() {
    SKIP_GROUP_COUNT.fetch_add(1, AtomicOrdering::Relaxed);
}
