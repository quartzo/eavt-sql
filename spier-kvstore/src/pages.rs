const MAX_RAW_SIZE: usize = 256 * 1024;

fn common_prefix_len(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b.iter()).take_while(|(x, y)| x == y).count()
}

/// Serializa um usize como varint: 7 bits por byte, MSB=1 indica continuação.
/// 0..=127 → 1 byte, 128..=16383 → 2 bytes, e assim por diante.
fn write_varint(buf: &mut Vec<u8>, mut value: usize) {
    loop {
        let byte = (value & 0x7F) as u8;
        value >>= 7;
        if value == 0 {
            buf.push(byte);
            break;
        }
        buf.push(byte | 0x80);
    }
}

fn read_varint(data: &[u8], mut offset: usize) -> Result<(usize, usize), String> {
    let mut result: usize = 0;
    let mut shift: u32 = 0;
    loop {
        if offset >= data.len() {
            return Err("truncated varint".into());
        }
        let byte = data[offset];
        offset += 1;
        result |= ((byte & 0x7F) as usize) << shift;
        if byte & 0x80 == 0 {
            return Ok((result, offset));
        }
        shift += 7;
        if shift >= usize::BITS {
            return Err("varint too long".into());
        }
    }
}

fn serialize_page(keys: &[Vec<u8>]) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&(keys.len() as u16).to_be_bytes());
    let mut prev: &[u8] = &[];
    for key in keys {
        let plen = common_prefix_len(prev, key);
        let suffix = &key[plen..];
        write_varint(&mut buf, plen);
        write_varint(&mut buf, suffix.len());
        buf.extend_from_slice(suffix);
        prev = key;
    }
    buf
}

pub fn deserialize_page(data: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if data.len() < 2 {
        return Err("page too short".into());
    }
    let count = u16::from_be_bytes(data[0..2].try_into().unwrap()) as usize;
    let mut keys = Vec::with_capacity(count);
    let mut offset = 2;
    let mut prev: Vec<u8> = Vec::new();
    for _ in 0..count {
        let (plen_raw, next) = read_varint(data, offset)?;
        offset = next;
        let (slen, next) = read_varint(data, offset)?;
        offset = next;
        let end = match offset.checked_add(slen) {
            Some(e) if e <= data.len() => e,
            _ => return Err(format!("truncated key: offset={offset} slen={slen} data_len={}", data.len())),
        };
        let plen = plen_raw.min(prev.len());
        let mut key = Vec::with_capacity(plen + slen);
        key.extend_from_slice(&prev[..plen]);
        key.extend_from_slice(&data[offset..end]);
        offset = end;
        prev = key.clone();
        keys.push(key);
    }
    Ok(keys)
}

pub fn build_pages(keys: &[Vec<u8>]) -> Vec<(Vec<u8>, Vec<u8>)> {
    if keys.is_empty() {
        return Vec::new();
    }
    if keys.len() == 1 {
        return vec![(keys[0].clone(), serialize_page(keys))];
    }
    let total: usize = keys.iter().map(|k| k.len()).sum();
    if total <= MAX_RAW_SIZE {
        return vec![(keys[0].clone(), serialize_page(keys))];
    }
    let mid = keys.len() / 2;
    let mut result = Vec::new();
    result.extend(build_pages(&keys[..mid]));
    result.extend(build_pages(&keys[mid..]));
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty() {
        let keys: Vec<Vec<u8>> = vec![];
        let pages = build_pages(&keys);
        assert!(pages.is_empty());
    }

    #[test]
    fn test_single_key() {
        let keys = vec![b"hello".to_vec()];
        let pages = build_pages(&keys);
        assert_eq!(pages.len(), 1);
        let out = deserialize_page(&pages[0].1).unwrap();
        assert_eq!(out, keys);
    }

    #[test]
    fn test_prefix_compression() {
        let keys = vec![
            b"entity:42:attr:3".to_vec(),
            b"entity:42:attr:5".to_vec(),
            b"entity:42:attr:7".to_vec(),
            b"entity:99:attr:1".to_vec(),
        ];
        let pages = build_pages(&keys);
        assert_eq!(pages.len(), 1);
        let out = deserialize_page(&pages[0].1).unwrap();
        assert_eq!(out, keys);
    }

    #[test]
    fn test_varint_encoding_boundaries() {
        let cases = [0usize, 1, 127, 128, 255, 256, 16383, 16384, 65535, 65536, 1_000_000];
        let mut buf = Vec::new();
        for &v in &cases {
            write_varint(&mut buf, v);
        }
        let mut offset = 0;
        for &expected in &cases {
            let (v, next) = read_varint(&buf, offset).unwrap();
            assert_eq!(v, expected);
            offset = next;
        }
        // 0..=127 cabe em 1 byte
        let mut b = Vec::new();
        write_varint(&mut b, 127);
        assert_eq!(b.len(), 1);
        // 128 precisa de 2 bytes
        let mut b = Vec::new();
        write_varint(&mut b, 128);
        assert_eq!(b.len(), 2);
    }

    #[test]
    fn test_key_above_255_bytes() {
        let prefix: &[u8] = b"entity:42:attr:";
        let long_a = [prefix, &vec![b'x'; 250][..]].concat();
        let long_b = [prefix, &vec![b'y'; 300][..]].concat();
        let keys = vec![long_a.clone(), long_b.clone()];
        let pages = build_pages(&keys);
        let out = deserialize_page(&pages[0].1).unwrap();
        assert_eq!(out, keys);
        assert!(out[1].len() > 255);
    }

    #[test]
    fn test_eavt_style_long_value_keys() {
        let mut keys = Vec::new();
        for i in 0..50u32 {
            let mut key = Vec::new();
            key.extend_from_slice(&(i as u64).to_be_bytes());
            key.extend_from_slice(&5u32.to_be_bytes());
            key.extend_from_slice(format!("long-value-payload-{i:04}").as_bytes());
            key.extend_from_slice(&0u64.to_be_bytes());
            keys.push(key);
        }
        let pages = build_pages(&keys);
        let mut all = Vec::new();
        for (_, data) in &pages {
            all.extend(deserialize_page(data).unwrap());
        }
        assert_eq!(all, keys);
    }

    #[test]
    fn test_70kb_keys_with_prefix_compression() {
        let common = b"shared_prefix_for_large_keys_";
        let mut keys = Vec::new();
        for i in 0..10u32 {
            let mut key = Vec::new();
            key.extend_from_slice(common);
            key.extend_from_slice(&vec![b'A' + (i % 26) as u8; 70_000]);
            key.extend_from_slice(&i.to_be_bytes());
            keys.push(key);
        }
        assert!(keys[0].len() > 70_000, "key should exceed 70KB");
        assert!(keys.iter().map(|k| k.len()).sum::<usize>() > MAX_RAW_SIZE,
            "total raw size should trigger page split");
        let pages = build_pages(&keys);
        assert!(pages.len() > 1, "70KB keys should produce multiple pages");
        let mut all = Vec::new();
        for (_, data) in &pages {
            let decoded = deserialize_page(data).unwrap();
            assert!(decoded.iter().all(|k| k.len() > 70_000),
                "every decoded key should exceed 70KB");
            all.extend(decoded);
        }
        assert_eq!(all, keys);
    }

    #[test]
    fn test_varint_large_suffix_length() {
        let key_a = b"prefix".to_vec();
        let key_b = [b"prefix".as_ref(), &vec![b'Z'; 70_000][..]].concat();
        let pages = build_pages(&[key_a.clone(), key_b.clone()]);
        let mut out = Vec::new();
        for (_, data) in &pages {
            out.extend(deserialize_page(data).unwrap());
        }
        assert_eq!(out.len(), 2);
        assert_eq!(out[1].len(), 70_006);
        assert_eq!(out, vec![key_a, key_b]);
    }

    #[test]
    fn test_split() {
        let keys: Vec<Vec<u8>> = (0..15_000)
            .map(|i| format!("{i:020}").into_bytes())
            .collect();
        let total_raw: usize = keys.iter().map(|k| k.len()).sum();
        assert!(total_raw > MAX_RAW_SIZE, "need more keys to trigger split");
        let pages = build_pages(&keys);
        assert!(pages.len() > 1, "expected split but got {} pages", pages.len());
        let mut all = Vec::new();
        for (_, data) in &pages {
            all.extend(deserialize_page(data).unwrap());
        }
        assert_eq!(all, keys);
        for (i, (_, data)) in pages.iter().enumerate() {
            let deserialized = deserialize_page(data).unwrap();
            let expected = &keys[keys.len() * i / pages.len() .. keys.len() * (i + 1) / pages.len()];
            assert_eq!(deserialized.last().unwrap(), expected.last().unwrap());
        }
    }
}
