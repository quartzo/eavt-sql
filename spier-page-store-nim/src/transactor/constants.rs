//! Physical column-family layout for the EAVT index stack.
//!
//! These names/IDs are specific to the spier-transactor EAVT implementation;
//! they live here instead of a shared library so the storage layout is owned by
//! the crate that defines it.

pub const CF_NAMES: &[&str] = &["eavt", "aevt", "avet", "vaet"];
pub const NUM_CF: usize = CF_NAMES.len();
pub const DEFAULT_FLUSH_THRESHOLD: usize = 4 << 20;
pub const DEFAULT_RESTART_INTERVAL: u32 = 256;

pub fn cf_name_to_id(name: &str) -> Option<usize> {
    CF_NAMES.iter().position(|&n| n == name)
}

pub fn cf_name_map() -> std::collections::HashMap<String, usize> {
    CF_NAMES
        .iter()
        .enumerate()
        .map(|(i, &name)| (name.to_string(), i))
        .collect()
}
