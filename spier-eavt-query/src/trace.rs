use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

static TRACE_VM: AtomicBool = AtomicBool::new(false);
static TRACE_INIT_VM: OnceLock<()> = OnceLock::new();

fn ensure_trace_init_vm() {
    TRACE_INIT_VM.get_or_init(|| {
        if let Ok(v) = std::env::var("EAVT_TRACE") {
            let all = v == "all" || v == "1";
            let parts: Vec<&str> = v.split(',').map(|s| s.trim()).collect();
            TRACE_VM.store(all || parts.contains(&"vm"), Ordering::Relaxed);
        }
    });
}

pub fn trace_vm() -> bool {
    ensure_trace_init_vm();
    TRACE_VM.load(Ordering::Relaxed)
}
