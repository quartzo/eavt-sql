use super::Value;

/// Serialize a flat `Vec<Value>` to bytes.
///
/// Format:
/// ```text
/// [u32 BE num_values]
/// for each value:
///   [u8 tag]
///   [tag-specific data]
/// ```
///
/// Tags: 0=Null, 1=Text, 2=Int64, 3=Float64, 4=Bool, 5=Bytes, 6=Timestamp, 7=EntityId
pub fn encode_values(values: &[Value]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(values.len() * 12 + 4);
    buf.extend_from_slice(&(values.len() as u32).to_be_bytes());
    for v in values {
        encode_one(&mut buf, v);
    }
    buf
}

/// Deserialize a flat `Vec<Value>` from bytes produced by [`encode_values`].
pub fn decode_values(buf: &[u8]) -> Result<Vec<Value>, String> {
    if buf.len() < 4 {
        return Err("decode_values: buffer too short".into());
    }
    let n = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    let mut pos = 4;
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let (v, np) = decode_one(buf, pos)?;
        out.push(v);
        pos = np;
    }
    Ok(out)
}

/// Decode cursor batch format: `[u32 ncols][values]...` per row.
/// Returns rows as `Vec<Vec<Value>>`. Rows with ncols==0 are skipped.
pub fn decode_rows(buf: &[u8]) -> Result<Vec<Vec<Value>>, String> {
    let mut rows = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        if pos + 4 > buf.len() {
            return Err("decode_rows: truncated ncols".into());
        }
        let ncols = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        let mut row = Vec::with_capacity(ncols);
        for _ in 0..ncols {
            let (v, np) = decode_one(buf, pos)?;
            row.push(v);
            pos = np;
        }
        if ncols > 0 {
            rows.push(row);
        }
    }
    Ok(rows)
}

pub fn encode_one(buf: &mut Vec<u8>, v: &Value) {
    match v {
        Value::Text(s) => {
            buf.push(1);
            let bytes = s.as_bytes();
            buf.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
            buf.extend_from_slice(bytes);
        }
        Value::Int64(n) => {
            buf.push(2);
            buf.extend_from_slice(&n.to_be_bytes());
        }
        Value::Float64(f) => {
            buf.push(3);
            buf.extend_from_slice(&f.to_be_bytes());
        }
        Value::Bool(b) => {
            buf.push(4);
            buf.push(*b);
        }
        Value::Bytes(b) => {
            buf.push(5);
            buf.extend_from_slice(&(b.len() as u32).to_be_bytes());
            buf.extend_from_slice(b);
        }
        Value::Timestamp(us) => {
            buf.push(6);
            buf.extend_from_slice(&us.to_be_bytes());
        }
        Value::Unknown(tag, payload) => {
            buf.push(99);
            buf.push(*tag as u8);
            buf.extend_from_slice(&payload.to_be_bytes());
        }
    }
}

fn decode_one(buf: &[u8], pos: usize) -> Result<(Value, usize), String> {
    if pos >= buf.len() {
        return Err("decode_one: unexpected end".into());
    }
    let tag = buf[pos];
    let pos = pos + 1;
    match tag {
        1 => {
            let (s, np) = read_str(buf, pos)?;
            Ok((Value::Text(s), np))
        }
        2 => {
            if pos + 8 > buf.len() {
                return Err("decode_one: truncated Int64".into());
            }
            let n = i64::from_be_bytes(buf[pos..pos + 8].try_into().unwrap());
            Ok((Value::Int64(n), pos + 8))
        }
        3 => {
            if pos + 8 > buf.len() {
                return Err("decode_one: truncated Float64".into());
            }
            let f = f64::from_be_bytes(buf[pos..pos + 8].try_into().unwrap());
            Ok((Value::Float64(f), pos + 8))
        }
        4 => {
            if pos >= buf.len() {
                return Err("decode_one: truncated Bool".into());
            }
            Ok((Value::Bool(buf[pos]), pos + 1))
        }
        5 => {
            let (b, np) = read_bytes(buf, pos)?;
            Ok((Value::Bytes(b), np))
        }
        6 => {
            if pos + 8 > buf.len() {
                return Err("decode_one: truncated Timestamp".into());
            }
            let us = i64::from_be_bytes(buf[pos..pos + 8].try_into().unwrap());
            Ok((Value::Timestamp(us), pos + 8))
        }
        99 => {
            if pos + 1 + 8 > buf.len() {
                return Err("decode_one: truncated Unknown".into());
            }
            let tag = buf[pos] as i8;
            let payload = u64::from_be_bytes(buf[pos + 1..pos + 9].try_into().unwrap());
            Ok((Value::Unknown(tag, payload), pos + 9))
        }
        _ => Err(format!("decode_one: unknown tag {tag}")),
    }
}

fn read_str(buf: &[u8], pos: usize) -> Result<(String, usize), String> {
    let (bytes, np) = read_bytes(buf, pos)?;
    let s = String::from_utf8(bytes).map_err(|e| format!("invalid utf8: {e}"))?;
    Ok((s, np))
}

fn read_bytes(buf: &[u8], pos: usize) -> Result<(Vec<u8>, usize), String> {
    if pos + 4 > buf.len() {
        return Err("read_bytes: truncated length".into());
    }
    let len = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
    let start = pos + 4;
    if start + len > buf.len() {
        return Err("read_bytes: truncated data".into());
    }
    Ok((buf[start..start + len].to_vec(), start + len))
}
