use super::resolver_consts::{DB_TYPE_BOOLEAN, DB_TYPE_BYTES, DB_TYPE_BLOB, DB_TYPE_FLOAT, DB_TYPE_INSTANT, DB_TYPE_REF, DB_TYPE_STRING, DB_TYPE_KEYWORD};
use crate::value::{Value, TAG_BOOL, TAG_BYTES, TAG_STR, TAG_INT64, TAG_FLOAT64};

// ---------------------------------------------------------------------------
// Sortable bit encoding — converte i64/f64 para u64 ordenável por bytes
// ---------------------------------------------------------------------------

const SIGN_FLIP: u64 = 0x8000_0000_0000_0000;

pub fn encode_int64(n: i64) -> u64 {
    (n as u64) ^ SIGN_FLIP
}

pub fn decode_int64(bits: u64) -> i64 {
    (bits ^ SIGN_FLIP) as i64
}

pub fn encode_float64(f: f64) -> u64 {
    let raw = f.to_bits();
    if raw & SIGN_FLIP != 0 {
        !raw
    } else {
        raw | SIGN_FLIP
    }
}

pub fn decode_float64(bits: u64) -> f64 {
    let raw = if bits & SIGN_FLIP != 0 {
        bits & !SIGN_FLIP
    } else {
        !bits
    };
    f64::from_bits(raw)
}

// ---------------------------------------------------------------------------
// EncodeMode — determines how a value is serialized into key bytes
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum EncodeMode {
    Fixed,
    Variable,
    Blob,
    Ref,
}

pub fn encode_mode_for(value_type: Option<u32>) -> EncodeMode {
    match value_type {
        Some(DB_TYPE_REF) => EncodeMode::Ref,
        Some(DB_TYPE_BLOB) => EncodeMode::Blob,
        Some(DB_TYPE_STRING) | Some(DB_TYPE_KEYWORD) | Some(DB_TYPE_BYTES) => EncodeMode::Variable,
        _ => EncodeMode::Fixed,
    }
}

// ---------------------------------------------------------------------------
// Key encoding — serializa Value em bytes para chaves do KV store
// ---------------------------------------------------------------------------

pub fn encode_fixed(v: &Value) -> Vec<u8> {
    match v {
        Value::Bool(b) => (*b as u64).to_be_bytes().to_vec(),
        Value::Int64(n) => encode_int64(*n).to_be_bytes().to_vec(),
        Value::Float64(f) => encode_float64(*f).to_be_bytes().to_vec(),
        Value::Unknown(_, bits) => bits.to_be_bytes().to_vec(),
        Value::Timestamp(n) => encode_int64(*n).to_be_bytes().to_vec(),
        _ => panic!("cannot encode tag {} as fixed", v.tag()),
    }
}

pub fn encode_variable(v: &Value) -> Vec<u8> {
    let raw: &[u8] = match v {
        Value::Text(s) => s.as_bytes(),
        Value::Bytes(b) => b,
        _ => panic!("cannot encode tag {} as variable", v.tag()),
    };
    let mut out = Vec::with_capacity(((raw.len() + 7) / 8) * 9);
    let full_blocks = raw.len() / 8;
    for i in 0..full_blocks {
        let chunk = &raw[i * 8..i * 8 + 8];
        out.extend_from_slice(chunk);
        if i * 8 + 8 == raw.len() {
            out.push(8);
        } else {
            out.push(0xFF);
        }
    }
    let remainder = raw.len() % 8;
    if remainder > 0 || raw.is_empty() {
        let start = full_blocks * 8;
        let mut block = [0u8; 8];
        block[..remainder].copy_from_slice(&raw[start..start + remainder]);
        out.extend_from_slice(&block);
        out.push(remainder as u8);
    }
    out
}

pub fn encode_variable_unordered(v: &Value) -> Vec<u8> {
    let raw: &[u8] = match v {
        Value::Bytes(b) => b,
        _ => panic!("cannot encode tag {} as unordered bytes", v.tag()),
    };
    let mut out = Vec::with_capacity(4 + raw.len());
    out.extend_from_slice(&(raw.len() as u32).to_be_bytes());
    out.extend_from_slice(raw);
    out
}

pub fn decode_variable_unordered(data: &[u8]) -> Value {
    if data.len() < 4 {
        return Value::Bytes(Vec::new());
    }
    let len = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
    let end = (4 + len).min(data.len());
    Value::Bytes(data[4..end].to_vec())
}

pub fn decode_fixed(tag: i8, bits: u64) -> Value {
    match tag {
        TAG_BOOL => Value::Bool(bits as u8),
        TAG_INT64 => Value::Int64(decode_int64(bits)),
        TAG_FLOAT64 => Value::Float64(decode_float64(bits)),
        _ => Value::Unknown(tag, bits),
    }
}

pub fn decode_variable(tag: i8, data: &[u8]) -> Value {
    let mut raw = Vec::new();
    let mut pos = 0;
    while pos + 9 <= data.len() {
        let ctrl = data[pos + 8];
        if ctrl == 0xFF {
            raw.extend_from_slice(&data[pos..pos + 8]);
            pos += 9;
        } else {
            let valid = ctrl as usize;
            if valid > 8 || pos + valid > data.len() {
                break;
            }
            raw.extend_from_slice(&data[pos..pos + valid]);
            break;
        }
    }
    match tag {
        TAG_STR => {
            if let Ok(s) = String::from_utf8(raw.clone()) {
                Value::Text(s)
            } else {
                Value::Bytes(raw)
            }
        }
        TAG_BYTES => Value::Bytes(raw),
        _ => Value::Bytes(raw),
    }
}

// ---------------------------------------------------------------------------
// Index layout
// ---------------------------------------------------------------------------

const CF_EAVT: &str = "eavt";
const CF_AEVT: &str = "aevt";
const CF_AVET: &str = "avet";
const CF_VAET: &str = "vaet";
pub const CF_ATTRS: &str = "attrs";

const FIXED_KEY_LEN: usize = 28;

pub const INDEX_ORDER: &[(&str, &[&str])] = &[
    ("EAVT", &["e", "a", "v"]),
    ("AEVT", &["a", "e", "v"]),
    ("AVET", &["a", "v", "e"]),
    ("VAET", &["v", "a", "e"]),
];

pub const INDEX_CF: &[(&str, &str)] = &[
    ("EAVT", CF_EAVT),
    ("AEVT", CF_AEVT),
    ("AVET", CF_AVET),
    ("VAET", CF_VAET),
];

pub fn cf_for_index(index: &str) -> &'static str {
    let upper = index.to_ascii_uppercase();
    INDEX_CF.iter().find(|(name, _)| *name == upper).map(|(_, cf)| *cf).unwrap_or(CF_EAVT)
}

pub fn cf_name_to_id(name: &str) -> u32 {
    INDEX_CF.iter().position(|(_, cf)| *cf == name).map(|i| i as u32).unwrap_or(0)
}

pub fn index_order(index: &str) -> &'static [&'static str] {
    let upper = index.to_ascii_uppercase();
    INDEX_ORDER.iter().find(|(name, _)| *name == upper).map(|(_, order)| *order).unwrap_or(&["e", "a", "v"])
}

pub fn encode_suffix(t: u64, retracted: bool) -> u64 {
    !((t << 1) | (if retracted { 1u64 } else { 0 }))
}

pub fn decode_suffix(bits: u64) -> (u64, bool) {
    let orig = !bits;
    (orig >> 1, orig & 1 != 0)
}

fn encode_entity(e: u64) -> [u8; 8] {
    e.to_be_bytes()
}

fn decode_entity(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes[..8].try_into().unwrap())
}

pub enum BoundValue {
    Int(u64),
    Attr(u32),
    Val(Value),
    Ref(u64),
}

pub fn build_prefix(index: &str, bound: &[BoundValue], mode: EncodeMode) -> Vec<u8> {
    if bound.is_empty() {
        return Vec::new();
    }
    let order = index_order(index);
    let mut buf = Vec::new();
    for (i, pos) in order.iter().enumerate() {
        if i >= bound.len() {
            break;
        }
        match (&bound[i], *pos) {
            (BoundValue::Attr(a), "a") => buf.extend_from_slice(&a.to_be_bytes()),
            (BoundValue::Int(n), "a") => buf.extend_from_slice(&(*n as u32).to_be_bytes()),
            (BoundValue::Val(v), "a") => buf.extend_from_slice(&(v.raw_int() as u32).to_be_bytes()),
            (BoundValue::Ref(n), "v") => buf.extend_from_slice(&encode_entity(*n)),
            (BoundValue::Val(v), "v") => {
                buf.extend_from_slice(&match mode {
                    EncodeMode::Ref => encode_entity(v.raw_int() as u64).to_vec(),
                    EncodeMode::Variable => encode_variable(v),
                    EncodeMode::Blob => encode_variable_unordered(v),
                    EncodeMode::Fixed => encode_fixed(v),
                });
            }
            (BoundValue::Int(n), "v") => {
                buf.extend_from_slice(&encode_int64(*n as i64).to_be_bytes());
            }
            (BoundValue::Attr(a), "v") => {
                buf.extend_from_slice(&encode_int64(*a as i64).to_be_bytes());
            }
            (BoundValue::Ref(n), _) => {
                buf.extend_from_slice(&encode_entity(*n));
            }
            (BoundValue::Val(v), _) => {
                buf.extend_from_slice(&encode_entity(v.raw_int() as u64));
            }
            (BoundValue::Int(n), _) => {
                buf.extend_from_slice(&encode_entity(*n));
            }
            (BoundValue::Attr(a), _) => {
                buf.extend_from_slice(&encode_entity(*a as u64));
            }
        }
    }
    buf
}

#[derive(Debug, Clone, PartialEq)]
pub struct RawDatom {
    pub e: u64,
    pub a: u32,
    pub v: Value,
    pub t: u64,
    pub retracted: bool,
}

fn find_v_end(key: &[u8], start: usize, is_unordered: bool) -> usize {
    if is_unordered {
        if start + 4 > key.len() {
            return key.len();
        }
        let len = u32::from_be_bytes(key[start..start + 4].try_into().unwrap()) as usize;
        return start + 4 + len;
    }
    let mut pos = start;
    while pos + 9 <= key.len() {
        let ctrl = key[pos + 8];
        if ctrl == 0xFF {
            pos += 9;
        } else {
            return pos + 9;
        }
    }
    key.len()
}

fn decode_value_fixed_vt(a_id: u32, bits: u64, vt_for: &mut impl FnMut(u32) -> Option<u32>) -> Value {
    match vt_for(a_id) {
        Some(DB_TYPE_FLOAT) => Value::Float64(decode_float64(bits)),
        Some(DB_TYPE_BOOLEAN) => Value::Bool(bits as u8),
        Some(DB_TYPE_REF) => Value::entity_id(bits),
        Some(DB_TYPE_INSTANT) => Value::Timestamp(decode_int64(bits)),
        _ => Value::Int64(decode_int64(bits)),
    }
}

fn decode_value_var_vt(a_id: u32, data: &[u8], vt_for: &mut impl FnMut(u32) -> Option<u32>) -> Value {
    match vt_for(a_id) {
        Some(DB_TYPE_BYTES) => decode_variable(TAG_BYTES, data),
        Some(DB_TYPE_BLOB) => decode_variable_unordered(data),
        _ => decode_variable(TAG_STR, data),
    }
}

pub fn unpack_key_with_vt(cf: &str, key: &[u8], mut vt_for: impl FnMut(u32) -> Option<u32>) -> RawDatom {
    let cf_lower = cf.to_ascii_lowercase();
    let suffix = u64::from_be_bytes(key[key.len() - 8..].try_into().unwrap());
    let (t, retracted) = decode_suffix(suffix);

    if cf_lower == CF_EAVT {
        let e = decode_entity(&key[0..8]);
        let a = u32::from_be_bytes(key[8..12].try_into().unwrap());
        let v_start = 12usize;
        let is_unordered = vt_for(a) == Some(DB_TYPE_BLOB);
        let is_var = key.len() != FIXED_KEY_LEN || is_unordered;
        let v = if is_var {
            let v_end = find_v_end(key, v_start, is_unordered);
            decode_value_var_vt(a, &key[v_start..v_end], &mut vt_for)
        } else {
            let bits = u64::from_be_bytes(key[v_start..v_start + 8].try_into().unwrap());
            decode_value_fixed_vt(a, bits, &mut vt_for)
        };
        RawDatom { e, a, v, t, retracted }
    } else if cf_lower == CF_AEVT {
        let a = u32::from_be_bytes(key[0..4].try_into().unwrap());
        let e = decode_entity(&key[4..12]);
        let v_start = 12usize;
        let is_unordered = vt_for(a) == Some(DB_TYPE_BLOB);
        let is_var = key.len() != FIXED_KEY_LEN || is_unordered;
        let v = if is_var {
            let v_end = find_v_end(key, v_start, is_unordered);
            decode_value_var_vt(a, &key[v_start..v_end], &mut vt_for)
        } else {
            let bits = u64::from_be_bytes(key[v_start..v_start + 8].try_into().unwrap());
            decode_value_fixed_vt(a, bits, &mut vt_for)
        };
        RawDatom { e, a, v, t, retracted }
    } else if cf_lower == CF_AVET {
        let a = u32::from_be_bytes(key[0..4].try_into().unwrap());
        let v_start = 4usize;
        let is_unordered = vt_for(a) == Some(DB_TYPE_BLOB);
        let is_var = key.len() != FIXED_KEY_LEN || is_unordered;
        let (v, e) = if is_var {
            let v_end = find_v_end(key, v_start, is_unordered);
            let val = decode_value_var_vt(a, &key[v_start..v_end], &mut vt_for);
            let ent = decode_entity(&key[v_end..v_end + 8]);
            (val, ent)
        } else {
            let bits = u64::from_be_bytes(key[v_start..v_start + 8].try_into().unwrap());
            let val = decode_value_fixed_vt(a, bits, &mut vt_for);
            let ent = decode_entity(&key[v_start + 8..v_start + 16]);
            (val, ent)
        };
        RawDatom { e, a, v, t, retracted }
    } else if cf_lower == CF_VAET {
        let v_bits = u64::from_be_bytes(key[0..8].try_into().unwrap());
        let a = u32::from_be_bytes(key[8..12].try_into().unwrap());
        let e = decode_entity(&key[12..20]);
        let val = Value::entity_id(v_bits);
        RawDatom { e, a, v: val, t, retracted }
    } else {
        panic!("unknown CF: {}", cf)
    }
}

pub struct IndexEntries {
    pub entries: Vec<(&'static str, Vec<u8>, Vec<u8>)>,
}

pub fn avet_value_prefix(a: u32, v: &Value, mode: EncodeMode) -> Vec<u8> {
    let v_bytes: Vec<u8> = match mode {
        EncodeMode::Ref => encode_entity(v.raw_int() as u64).to_vec(),
        EncodeMode::Variable => encode_variable(v),
        EncodeMode::Blob => encode_variable_unordered(v),
        EncodeMode::Fixed => encode_fixed(v),
    };
    [&a.to_be_bytes()[..], &v_bytes[..]].concat()
}

pub fn build_entries(e: u64, a: u32, v: &Value, t: u64, retracted: bool, mode: EncodeMode) -> IndexEntries {
    let suffix = encode_suffix(t, retracted);
    let sf = suffix.to_be_bytes();
    let e_bytes = encode_entity(e);
    let a_bytes = a.to_be_bytes();

    let v_bytes: Vec<u8> = match mode {
        EncodeMode::Ref => encode_entity(v.raw_int() as u64).to_vec(),
        EncodeMode::Variable => encode_variable(v),
        EncodeMode::Blob => encode_variable_unordered(v),
        EncodeMode::Fixed => encode_fixed(v),
    };

    if mode == EncodeMode::Ref {
        IndexEntries {
            entries: vec![
                (CF_EAVT, [&e_bytes[..], &a_bytes[..], &v_bytes[..], &sf[..]].concat(), Vec::new()),
                (CF_AEVT, [&a_bytes[..], &e_bytes[..], &v_bytes[..], &sf[..]].concat(), Vec::new()),
                (CF_AVET, [&a_bytes[..], &v_bytes[..], &e_bytes[..], &sf[..]].concat(), Vec::new()),
                (CF_VAET, [&v_bytes[..], &a_bytes[..], &e_bytes[..], &sf[..]].concat(), Vec::new()),
            ],
        }
    } else {
        IndexEntries {
            entries: vec![
                (CF_EAVT, [&e_bytes[..], &a_bytes[..], &v_bytes[..], &sf[..]].concat(), Vec::new()),
                (CF_AEVT, [&a_bytes[..], &e_bytes[..], &v_bytes[..], &sf[..]].concat(), Vec::new()),
                (CF_AVET, [&a_bytes[..], &v_bytes[..], &e_bytes[..], &sf[..]].concat(), Vec::new()),
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transactor::resolver_consts::DB_TYPE_LONG;

    #[test]
    fn test_encode_decode_int64() {
        for n in [0i64, 1, -1, i64::MAX, i64::MIN, 42, -42] {
            assert_eq!(decode_int64(encode_int64(n)), n);
        }
    }

    #[test]
    fn test_int64_ordering_preserved() {
        let pairs: Vec<(i64, i64)> = vec![
            (0, 1),
            (-1, 0),
            (-1, 1),
            (i64::MIN, i64::MAX),
            (-100, 100),
        ];
        for (a, b) in pairs {
            assert!(
                encode_int64(a) < encode_int64(b),
                "encode_int64({}) should be < encode_int64({})",
                a,
                b
            );
        }
    }

    #[test]
    fn test_encode_decode_float64() {
        for f in [0.0f64, 1.0, -1.0, 42.5, -42.5, f64::MAX, f64::MIN] {
            let bits = encode_float64(f);
            assert_eq!(decode_float64(bits), f, "roundtrip failed for {}", f);
        }
    }

    #[test]
    fn test_float64_ordering() {
        let pairs: Vec<(f64, f64)> = vec![
            (-1.0, 0.0),
            (0.0, 1.0),
            (-100.0, 100.0),
            (f64::MIN, f64::MAX),
        ];
        for (a, b) in pairs {
            assert!(
                encode_float64(a) < encode_float64(b),
                "encode_float64({}) should be < encode_float64({})",
                a,
                b
            );
        }
    }

    #[test]
    fn test_encode_decode_suffix() {
        let cases = [(1000u64, false), (0u64, true), ((1u64 << 63) - 1, true), (12345u64, false)];
        for (t, retracted) in cases {
            let bits = encode_suffix(t, retracted);
            let (r, x) = decode_suffix(bits);
            assert_eq!(r, t);
            assert_eq!(x, retracted);
        }
    }

    #[test]
    fn test_build_entries_ref() {
        let v = Value::Int64(55);
        let ie = build_entries(42, 5, &v, 1000, false, EncodeMode::Ref);
        assert_eq!(ie.entries.len(), 4);
        assert_eq!(ie.entries[0].0, "eavt");
        assert_eq!(ie.entries[1].0, "aevt");
        assert_eq!(ie.entries[2].0, "avet");
        assert_eq!(ie.entries[3].0, "vaet");
    }

    #[test]
    fn test_build_entries_fixed() {
        let v = Value::Int64(100);
        let ie = build_entries(42, 5, &v, 1000, false, EncodeMode::Fixed);
        assert_eq!(ie.entries.len(), 3);
        assert_eq!(ie.entries[0].0, "eavt");
    }

    #[test]
    fn test_build_entries_variable() {
        let v = Value::Text("hello".into());
        let ie = build_entries(42, 5, &v, 1000, false, EncodeMode::Variable);
        assert_eq!(ie.entries.len(), 3);
        for (cf, key, _) in &ie.entries {
            assert!(key.contains(&0), "variable entry for {} should have null separator", cf);
        }
    }

    #[test]
    fn test_build_entries_unordered_bytes() {
        let v = Value::Bytes(vec![0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]);
        let ie = build_entries(42, 5, &v, 1000, false, EncodeMode::Blob);
        assert_eq!(ie.entries.len(), 3);
        assert_eq!(ie.entries[0].0, "eavt");
        for (cf, key, _) in &ie.entries {
            assert!(key.len() > 28, "unordered bytes entry for {} should be variable-length", cf);
        }
    }

    #[test]
    fn test_encode_decode_variable_unordered() {
        let v = Value::Bytes(vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let encoded = encode_variable_unordered(&v);
        assert_eq!(encoded, vec![0, 0, 0, 4, 0xDE, 0xAD, 0xBE, 0xEF]);
        let decoded = decode_variable_unordered(&encoded);
        assert_eq!(decoded, v);
    }

    #[test]
    fn test_encode_decode_variable_unordered_large() {
        let raw: Vec<u8> = (0..1000).map(|i| (i % 256) as u8).collect();
        let v = Value::Bytes(raw.clone());
        let encoded = encode_variable_unordered(&v);
        assert_eq!(encoded.len(), 4 + 1000);
        let decoded = decode_variable_unordered(&encoded);
        assert_eq!(decoded, v);
    }

    #[test]
    fn test_encode_decode_variable_unordered_empty() {
        let v = Value::Bytes(Vec::new());
        let encoded = encode_variable_unordered(&v);
        assert_eq!(encoded, vec![0, 0, 0, 0]);
        let decoded = decode_variable_unordered(&encoded);
        assert_eq!(decoded, v);
    }

    #[test]
    fn test_encode_mode_for_types() {
        assert_eq!(encode_mode_for(Some(DB_TYPE_REF)), EncodeMode::Ref);
        assert_eq!(encode_mode_for(Some(DB_TYPE_BLOB)), EncodeMode::Blob);
        assert_eq!(encode_mode_for(Some(DB_TYPE_STRING)), EncodeMode::Variable);
        assert_eq!(encode_mode_for(Some(DB_TYPE_KEYWORD)), EncodeMode::Variable);
        assert_eq!(encode_mode_for(Some(DB_TYPE_BYTES)), EncodeMode::Variable);
        assert_eq!(encode_mode_for(Some(DB_TYPE_LONG)), EncodeMode::Fixed);
        assert_eq!(encode_mode_for(None), EncodeMode::Fixed);
    }

    #[test]
    fn test_build_prefix_empty() {
        let result = build_prefix("EAVT", &[], EncodeMode::Fixed);
        assert!(result.is_empty());
    }

    #[test]
    fn test_build_prefix_eavt_entity() {
        let result = build_prefix("EAVT", &[BoundValue::Int(42)], EncodeMode::Fixed);
        assert_eq!(result, encode_entity(42).to_vec());
    }

    #[test]
    fn test_build_prefix_eavt_entity_attr() {
        let result = build_prefix("EAVT", &[BoundValue::Int(42), BoundValue::Attr(5)], EncodeMode::Fixed);
        let mut expected = Vec::new();
        expected.extend_from_slice(&encode_entity(42));
        expected.extend_from_slice(&5u32.to_be_bytes());
        assert_eq!(result, expected);
    }

    #[test]
    fn test_build_prefix_vaet_ref() {
        let result = build_prefix("VAET", &[BoundValue::Ref(100)], EncodeMode::Ref);
        assert_eq!(result, encode_entity(100).to_vec());
    }

    #[test]
    fn test_entity_roundtrip() {
        for e in [0u64, 1, 100, 999, 1000, u64::MAX] {
            let encoded = encode_entity(e);
            let decoded = decode_entity(&encoded);
            assert_eq!(decoded, e, "entity roundtrip failed for {}", e);
        }
    }

    #[test]
    fn test_encode_fixed_int64() {
        let v = Value::Int64(42);
        let bytes = encode_fixed(&v);
        assert_eq!(bytes.len(), 8);
        let bits = u64::from_be_bytes(bytes.try_into().unwrap());
        let decoded = decode_fixed(TAG_INT64, bits);
        assert_eq!(decoded, Value::Int64(42));
    }

    #[test]
    fn test_encode_fixed_negative() {
        let v = Value::Int64(-1);
        let bytes = encode_fixed(&v);
        let bits = u64::from_be_bytes(bytes.try_into().unwrap());
        let decoded = decode_fixed(TAG_INT64, bits);
        assert_eq!(decoded, Value::Int64(-1));
    }

    #[test]
    fn test_encode_fixed_float64() {
        let v = Value::float64(3.14);
        let bytes = encode_fixed(&v);
        assert_eq!(bytes.len(), 8);
        let bits = u64::from_be_bytes(bytes.try_into().unwrap());
        let decoded = decode_fixed(TAG_FLOAT64, bits);
        assert_eq!(decoded, Value::Float64(3.14));
    }

    #[test]
    fn test_encode_variable_text() {
        let v = Value::Text("hello".into());
        let bytes = encode_variable(&v);
        assert_eq!(bytes, b"\x68\x65\x6c\x6c\x6f\x00\x00\x00\x05");
        let decoded = decode_variable(TAG_STR, &bytes);
        assert_eq!(decoded, Value::Text("hello".into()));
    }

    #[test]
    fn test_encode_variable_text_8bytes() {
        let v = Value::Text("abcdefgh".into());
        let bytes = encode_variable(&v);
        assert_eq!(bytes, b"abcdefgh\x08");
        let decoded = decode_variable(TAG_STR, &bytes);
        assert_eq!(decoded, Value::Text("abcdefgh".into()));
    }

    #[test]
    fn test_encode_variable_text_16bytes() {
        let v = Value::Text("abcdefghijklmnop".into());
        let bytes = encode_variable(&v);
        assert_eq!(bytes, b"abcdefgh\xFFijklmnop\x08");
        let decoded = decode_variable(TAG_STR, &bytes);
        assert_eq!(decoded, Value::Text("abcdefghijklmnop".into()));
    }

    #[test]
    fn test_encode_variable_empty() {
        let v = Value::Text(String::new());
        let bytes = encode_variable(&v);
        assert_eq!(bytes, b"\x00\x00\x00\x00\x00\x00\x00\x00\x00");
        let decoded = decode_variable(TAG_STR, &bytes);
        assert_eq!(decoded, Value::Text(String::new()));
    }

    #[test]
    fn test_encode_variable_bytes() {
        let v = Value::Bytes(vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let bytes = encode_variable(&v);
        assert_eq!(bytes[0..4], [0xDE, 0xAD, 0xBE, 0xEF]);
        assert_eq!(bytes[4..8], [0x00, 0x00, 0x00, 0x00]);
        assert_eq!(bytes[8], 4);
        let decoded = decode_variable(TAG_BYTES, &bytes);
        assert_eq!(decoded, Value::Bytes(vec![0xDE, 0xAD, 0xBE, 0xEF]));
    }

    #[test]
    fn test_8plus1_ordering() {
        let abc = encode_variable(&Value::Text("abc".into()));
        let abcd = encode_variable(&Value::Text("abcd".into()));
        let abcde = encode_variable(&Value::Text("abcde".into()));
        let abcdefgh = encode_variable(&Value::Text("abcdefgh".into()));
        let abcdefghi = encode_variable(&Value::Text("abcdefghi".into()));
        assert!(abc.as_slice() < abcd.as_slice());
        assert!(abcd.as_slice() < abcde.as_slice());
        assert!(abcde.as_slice() < abcdefgh.as_slice());
        assert!(abcdefgh.as_slice() < abcdefghi.as_slice());
    }

    #[test]
    fn test_float64_special_values() {
        let zero = encode_float64(0.0);
        let neg_zero = encode_float64(-0.0);
        assert!(zero > neg_zero, "0.0 should sort after -0.0");

        let inf = encode_float64(f64::INFINITY);
        let neg_inf = encode_float64(f64::NEG_INFINITY);
        assert!(neg_inf < encode_float64(0.0));
        assert!(encode_float64(0.0) < inf);
    }

    #[test]
    fn test_float64_roundtrip_large() {
        let f = 1e300;
        let bits = encode_float64(f);
        assert_eq!(decode_float64(bits), f);
    }
}
