use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

pub use dynspire_commons::query_ir::{InstructionData, OpCode, ProgramHandle, VMProgram};

static DEBUG_TIMING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn debug_timing_enabled() -> bool {
    DEBUG_TIMING.load(AtomicOrdering::Relaxed)
}

pub fn set_debug_timing(enabled: bool) {
    DEBUG_TIMING.store(enabled, AtomicOrdering::Relaxed);
    SCANNER_ADVANCE_NS.store(0, AtomicOrdering::Relaxed);
    SCANNER_SEEK_NS.store(0, AtomicOrdering::Relaxed);
    SCANNER_ADVANCE_COUNT.store(0, AtomicOrdering::Relaxed);
    SCANNER_SEEK_COUNT.store(0, AtomicOrdering::Relaxed);
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

pub fn reset_scanner_stats() {
    SCANNER_ADVANCE_NS.store(0, AtomicOrdering::Relaxed);
    SCANNER_SEEK_NS.store(0, AtomicOrdering::Relaxed);
    SCANNER_ADVANCE_COUNT.store(0, AtomicOrdering::Relaxed);
    SCANNER_SEEK_COUNT.store(0, AtomicOrdering::Relaxed);
}

pub(crate) fn get_scanner_stats() -> (u64, u64, u64, u64) {
    (
        SCANNER_ADVANCE_NS.load(AtomicOrdering::Relaxed),
        SCANNER_ADVANCE_COUNT.load(AtomicOrdering::Relaxed),
        SCANNER_SEEK_NS.load(AtomicOrdering::Relaxed),
        SCANNER_SEEK_COUNT.load(AtomicOrdering::Relaxed),
    )
}

#[derive(Default)]
pub(crate) struct TimingCounter {
    pub nanos: u64,
    pub count: u64,
}

impl TimingCounter {
    pub fn add(&mut self, duration: std::time::Duration) {
        self.nanos += duration.as_nanos() as u64;
        self.count += 1;
    }
}

#[derive(Default)]
pub(crate) struct TimingStats {
    pub leap_init: TimingCounter,
    pub leap_next: TimingCounter,
    pub depth_up: TimingCounter,
    pub result_row: TimingCounter,
    pub bind_get: TimingCounter,
    pub resolve_val: TimingCounter,
}

impl TimingStats {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn print(&self, total: std::time::Duration) {
        let total_ns = total.as_nanos() as u64;
        eprintln!("=== EAVT TIMING ===");
        let mut entries: Vec<(&str, &TimingCounter)> = vec![
            ("leap_init", &self.leap_init),
            ("leap_next", &self.leap_next),
            ("depth_up", &self.depth_up),
            ("result_row", &self.result_row),
            ("bind_get", &self.bind_get),
            ("resolve_val", &self.resolve_val),
        ];
        entries.sort_by(|a, b| b.1.nanos.cmp(&a.1.nanos));
        for (name, tc) in &entries {
            if tc.count == 0 {
                continue;
            }
            let ms = tc.nanos as f64 / 1_000_000.0;
            let pct = if total_ns > 0 { tc.nanos as f64 / total_ns as f64 * 100.0 } else { 0.0 };
            let avg_us = if tc.count > 0 { tc.nanos as f64 / tc.count as f64 / 1_000.0 } else { 0.0 };
            eprintln!(
                "  {:20} {:8.3}s ({:5.1}%) {:>6} calls  avg={:.1}us",
                name, ms / 1000.0, pct, tc.count, avg_us,
            );
        }

        let (adv_ns, adv_cnt, seek_ns, seek_cnt) = get_scanner_stats();
        eprintln!("  --- scanner ---");
        if adv_cnt > 0 {
            eprintln!(
                "  {:20} {:8.3}s  {:>6} calls  avg={:.1}us",
                "advance_to_active",
                adv_ns as f64 / 1_000_000_000.0,
                adv_cnt,
                adv_ns as f64 / adv_cnt as f64 / 1_000.0,
            );
        }
        if seek_cnt > 0 {
            eprintln!(
                "  {:20} {:8.3}s  {:>6} calls  avg={:.1}us",
                "scanner_seek",
                seek_ns as f64 / 1_000_000_000.0,
                seek_cnt,
                seek_ns as f64 / seek_cnt as f64 / 1_000.0,
            );
        }
        let total_s = total_ns as f64 / 1_000_000_000.0;
        eprintln!("  TOTAL: {:.3}s", total_s);
    }
}


