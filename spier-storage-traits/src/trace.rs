use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

static TRACE_CURSOR: AtomicBool = AtomicBool::new(false);
static TRACE_INIT_CURSOR: OnceLock<()> = OnceLock::new();

fn ensure_trace_init_cursor() {
    TRACE_INIT_CURSOR.get_or_init(|| {
        if let Ok(v) = std::env::var("EAVT_TRACE") {
            let all = v == "all" || v == "1";
            let parts: Vec<&str> = v.split(',').map(|s| s.trim()).collect();
            TRACE_CURSOR.store(all || parts.contains(&"cursor"), Ordering::Relaxed);
        }
    });
}

pub fn trace_cursor() -> bool {
    ensure_trace_init_cursor();
    TRACE_CURSOR.load(Ordering::Relaxed)
}
