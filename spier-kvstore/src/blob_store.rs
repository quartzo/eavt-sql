pub fn make_root_name() -> String {
    let us = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_micros() as i64;
    format!("root_{:016x}", -us)
}
