pub fn cf_name_for(cf: usize) -> &'static str {
    match cf {
        0 => "eavt",
        1 => "aevt",
        2 => "avet",
        3 => "vaet",
        _ => "eavt",
    }
}

pub fn cf_id_for_name(name: &str) -> Option<usize> {
    match name {
        "eavt" => Some(0),
        "aevt" => Some(1),
        "avet" => Some(2),
        "vaet" => Some(3),
        _ => None,
    }
}
