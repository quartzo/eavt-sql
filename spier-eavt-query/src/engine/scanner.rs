use std::cell::RefCell;
use std::sync::Arc;

use dynspire_commons::transactor::keys::{decode_suffix, decode_float64, decode_int64, decode_fixed, decode_variable, decode_variable_unordered, encode_fixed, encode_variable, encode_variable_unordered};
use dynspire_commons::transactor::cursor::Cursor;
use dynspire_commons::transactor::resolver_consts::{DB_TYPE_BOOLEAN, DB_TYPE_BYTES, DB_TYPE_BLOB, DB_TYPE_FLOAT, DB_TYPE_INSTANT, DB_TYPE_REF, DB_TYPE_STRING};
use dynspire_commons::value::{Value, TAG_BYTES, TAG_INT64, TAG_STR};

#[derive(Debug, Clone)]
pub struct TimestampInfo;

pub struct InvalidCursor;

impl dynspire_commons::transactor::cursor::Cursor for InvalidCursor {
    fn is_valid(&self) -> bool { false }
    fn current_key(&self) -> Option<&[u8]> { None }
    fn step(&mut self) {}
    fn skip_group(&mut self, _group_end: usize) {}
    fn seek(&mut self, _target: &[u8]) {}
    fn update_end(&mut self, _end: &[u8]) {}
    fn invalidate(&mut self) {}
}

pub fn encode_bound_value(val: &Value) -> Vec<u8> {
    match val {
        Value::Text(_) | Value::Bytes(_) => encode_variable(val),
        _ => encode_fixed(val),
    }
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

fn is_unordered_attr(vt: Option<u32>) -> bool {
    vt == Some(DB_TYPE_BLOB)
}

// ---------------------------------------------------------------------------
// V2Scanner — scanner-centric triejoin: one scanner per clause, position-aware
// ---------------------------------------------------------------------------

pub struct V2Scanner {
    cursor: Arc<RefCell<dyn Cursor>>,
    index_name: String,
    idx_order: Vec<String>,
    prefix_values: Vec<(String, Value)>,
    prefix_bytes_cache: Vec<u8>,
    positions_filled: usize,
    as_of_us: Option<u64>,
    value_attr_type: Option<u32>,
    current_active_key: Option<Vec<u8>>,
    at_end: bool,
    history_mode: bool,
    pub depth_positions: std::collections::HashMap<usize, usize>,
}

impl V2Scanner {
    pub fn new(
        index_name: &str,
        idx_order: Vec<String>,
        as_of_us: Option<u64>,
        value_attr_type: Option<u32>,
    ) -> Self {
        Self {
            cursor: Arc::new(RefCell::new(InvalidCursor)),
            index_name: index_name.to_ascii_uppercase(),
            idx_order,
            prefix_values: Vec::new(),
            prefix_bytes_cache: Vec::new(),
            positions_filled: 0,
            as_of_us,
            value_attr_type,
            current_active_key: None,
            at_end: true,
            history_mode: false,
            depth_positions: std::collections::HashMap::new(),
        }
    }

    pub fn set_history_mode(&mut self) {
        self.history_mode = true;
    }

    pub fn index_name(&self) -> &str {
        &self.index_name
    }

    pub fn prefix_bytes(&self) -> &[u8] {
        &self.prefix_bytes_cache
    }

    pub fn is_open(&self) -> bool {
        !self.at_end || self.current_active_key.is_some()
    }

    pub fn push_prefix_at(&mut self, pos_in_idx: usize, val: &Value) {
        let pos_name = self.idx_order.get(pos_in_idx)
            .map(|s| s.as_str()).unwrap_or("v").to_string();
        self.prefix_values.push((pos_name, val.clone()));
        self.positions_filled += 1;
    }

    pub fn build_prefix_bytes(&mut self) {
        let mut buf = Vec::new();
        for (pos_name, val) in &self.prefix_values {
            match pos_name.as_str() {
                "a" => buf.extend_from_slice(&(val.raw_int() as u32).to_be_bytes()),
                "e" => buf.extend_from_slice(&(val.raw_int() as u64).to_be_bytes()),
                "v" => {
                    if self.value_attr_type == Some(DB_TYPE_REF) {
                        buf.extend_from_slice(&(val.raw_int() as u64).to_be_bytes());
                    } else if self.is_unordered() {
                        buf.extend_from_slice(&encode_variable_unordered(val));
                    } else {
                        let enc = encode_bound_value(val);
                        buf.extend_from_slice(&enc);
                    }
                }
                _ => {
                    let enc = encode_bound_value(val);
                    buf.extend_from_slice(&enc);
                }
            }
        }
        self.prefix_bytes_cache = buf;
    }

    pub fn attr_id_from_prefix(&self) -> Option<u32> {
        for (pos_name, val) in &self.prefix_values {
            if pos_name == "a" {
                return Some(val.raw_int() as u32);
            }
        }
        None
    }

    pub fn attr_id_from_key(&self) -> Option<u32> {
        let key = self.current_active_key.as_ref()?;
        let idx = &self.index_name;
        let off = match idx.as_str() {
            "EAVT" | "VAET" => 8usize,
            "AEVT" | "AVET" => 0usize,
            _ => 8,
        };
        if key.len() >= off + 4 {
            Some(u32::from_be_bytes(key[off..off + 4].try_into().ok()?))
        } else {
            None
        }
    }

    pub fn value_attr_type(&self) -> Option<u32> {
        self.value_attr_type
    }

    pub fn prefix_values_is_empty(&self) -> bool {
        self.prefix_values.is_empty()
    }

    pub fn set_value_attr_type(&mut self, vt: Option<u32>) {
        self.value_attr_type = vt;
    }

    pub fn clear_at_end(&mut self) {
        self.at_end = false;
    }

    pub fn check_same_var_pairs(&self, pairs: &[(usize, usize)]) -> bool {
        let key = match self.current_active_key.as_ref() {
            Some(k) => k,
            None => return false,
        };
        for (a, b) in pairs {
            let raw_a = self.extract_raw(key, *a);
            let raw_b = self.extract_raw(key, *b);
            if raw_a != raw_b {
                return false;
            }
        }
        true
    }

    #[allow(dead_code)]
    pub fn current_timestamp(&self) -> Option<u64> {
        let key = self.current_active_key.as_ref()?;
        if key.len() < 8 { return None; }
        let suffix = Self::extract_suffix(key);
        let (t, _) = decode_suffix(suffix);
        Some(t)
    }

    #[allow(dead_code)]
    pub fn current_added(&self) -> Option<bool> {
        let key = self.current_active_key.as_ref()?;
        if key.len() < 8 { return None; }
        let suffix = Self::extract_suffix(key);
        let (_, retracted) = decode_suffix(suffix);
        Some(!retracted)
    }

    pub fn seek_to_prefix_start(&mut self) {
        let target = self.prefix_bytes_cache.clone();
        self.cursor.borrow_mut().seek(&target);
        self.at_end = false;
        self.current_active_key = None;
    }

    pub fn bind_depth(&mut self, depth: usize, pos_idx: usize) {
        self.depth_positions.insert(depth, pos_idx);
    }

    pub fn depth_position(&self, depth: usize) -> usize {
        self.depth_positions.get(&depth).copied().unwrap_or(0)
    }

    pub fn unbind_depth(&mut self, depth: usize) {
        self.depth_positions.remove(&depth);
    }

    pub fn set_cursor(&mut self, cursor: Arc<RefCell<dyn Cursor>>) {
        self.cursor = cursor;
        self.at_end = false;
    }

    pub fn at_end(&self) -> bool {
        self.at_end
    }

    fn pos_name(&self, pos_idx: usize) -> &str {
        if pos_idx >= self.idx_order.len() {
            return "t";
        }
        self.idx_order.get(pos_idx).map(|s| s.as_str()).unwrap_or("v")
    }

    fn is_variable_value(&self, key_len: usize) -> bool {
        if matches!(self.value_attr_type, Some(DB_TYPE_STRING) | Some(DB_TYPE_BYTES) | Some(DB_TYPE_BLOB)) {
            return true;
        }
        key_len != 28
    }

    fn is_unordered(&self) -> bool {
        is_unordered_attr(self.value_attr_type)
    }

    fn value_start(&self, key: &[u8], pos_idx: usize) -> usize {
        let pos_name = self.pos_name(pos_idx);
        if pos_idx >= self.idx_order.len() || pos_name == "t" || pos_name == "added" {
            return key.len() - 8;
        }
        match self.index_name.as_str() {
            "EAVT" => match pos_idx { 0 => 0, 1 => 8, _ => 12 },
            "AEVT" => match pos_idx { 0 => 0, 1 => 4, _ => 12 },
            "AVET" => match pos_idx {
                0 => 0,
                1 => 4,
                _ => {
                    let vs = 4usize;
                    if self.is_variable_value(key.len()) {
                        find_v_end(key, vs, self.is_unordered())
                    } else {
                        vs + 8
                    }
                }
            },
            "VAET" => match pos_idx { 0 => 0, 1 => 8, _ => 12 },
            _ => 12,
        }
    }

    fn value_end(&self, key: &[u8], pos_idx: usize) -> usize {
        if pos_idx >= self.idx_order.len() {
            return key.len();
        }
        let pos_name = self.pos_name(pos_idx);
        let start = self.value_start(key, pos_idx);
        match pos_name {
            "e" => start + 8,
            "a" => start + 4,
            "v" => {
                if self.is_variable_value(key.len()) {
                    find_v_end(key, start, self.is_unordered())
                } else {
                    start + 8
                }
            }
            _ => key.len(),
        }
    }

    fn extract_raw(&self, key: &[u8], pos_idx: usize) -> Extracted {
        let pos_name = self.pos_name(pos_idx);
        if pos_idx >= self.idx_order.len() || pos_name == "t" || pos_name == "added" {
            let suffix = Self::extract_suffix(key);
            let (t, retracted) = decode_suffix(suffix);
            return if pos_name == "added" {
                Extracted::Int(if retracted { 0 } else { 1 })
            } else {
                Extracted::Int(t)
            };
        }
        let pos_name = self.pos_name(pos_idx);
        let start = self.value_start(key, pos_idx);
        let end = self.value_end(key, pos_idx);
        match pos_name {
            "a" => Extracted::Int(u32::from_be_bytes(
                key[start..start + 4].try_into().unwrap(),
            ) as u64),
            "e" => Extracted::Int(u64::from_be_bytes(
                key[start..start + 8].try_into().unwrap(),
            )),
            _ => {
                if self.is_variable_value(key.len()) {
                    Extracted::Bytes(key[start..end].to_vec())
                } else {
                    Extracted::Int(u64::from_be_bytes(
                        key[start..start + 8].try_into().unwrap(),
                    ))
                }
            }
        }
    }

    pub fn extract_value(&self, pos_idx: usize) -> Option<Value> {
        let key = self.current_active_key.as_ref()?;
        let raw = self.extract_raw(key, pos_idx);
        let pos_name = self.pos_name(pos_idx);
        Some(match pos_name {
            "e" => {
                if let Extracted::Int(n) = raw { Value::entity_id(n) }
                else { Value::Int64(0) }
            }
            "a" => {
                if let Extracted::Int(n) = raw { Value::Int64(n as i64) }
                else { Value::Int64(0) }
            }
            "t" => {
                if let Extracted::Int(n) = raw {
                    let tx_eid = dynspire_commons::transactor::resolver_consts::make_entity_id(
                        dynspire_commons::transactor::resolver_consts::PART_TX, n,
                    );
                    Value::Int64(tx_eid as i64)
                } else { Value::Int64(0) }
            }
            "added" => {
                if let Extracted::Int(n) = raw { Value::Bool(n as u8) }
                else { Value::Bool(0) }
            }
            _ => self.decode_v(&raw, key),
        })
    }

    fn decode_v(&self, raw: &Extracted, key: &[u8]) -> Value {
        if self.is_variable_value(key.len()) {
            if let Extracted::Bytes(b) = raw {
                match self.value_attr_type {
                    Some(DB_TYPE_BYTES) => decode_variable(TAG_BYTES, b),
                    Some(DB_TYPE_BLOB) => decode_variable_unordered(b),
                    _ => decode_variable(TAG_STR, b),
                }
            } else {
                Value::Int64(0)
            }
        } else if let Extracted::Int(n) = raw {
            match self.value_attr_type {
                Some(DB_TYPE_FLOAT) => Value::Float64(decode_float64(*n)),
                Some(DB_TYPE_BOOLEAN) => Value::Bool(*n as u8),
                Some(DB_TYPE_REF) => Value::entity_id(*n),
                Some(DB_TYPE_INSTANT) => Value::Timestamp(decode_int64(*n)),
                _ => decode_fixed(TAG_INT64, *n),
            }
        } else {
            Value::Int64(0)
        }
    }

    fn extract_suffix(key: &[u8]) -> u64 {
        let start = key.len() - 8;
        u64::from_be_bytes(key[start..start + 8].try_into().unwrap())
    }

    pub fn advance_to_active_at(&mut self, pos_idx: usize) {
        let pos_name = self.pos_name(pos_idx);

        if pos_name == "added" {
            if self.current_active_key.is_some() {
                self.at_end = false;
            } else {
                self.at_end = true;
            }
            return;
        }

        let as_of_us = self.as_of_us;
        let is_t_pos = pos_name == "t";

        if self.history_mode && is_t_pos {
            self.advance_history_each(pos_idx);
            return;
        }

        let bound_prefix: Option<Vec<u8>> = self.current_active_key.as_ref().map(|k| {
            let end = self.value_start(k, pos_idx);
            k[..end].to_vec()
        });

        while self.cursor.borrow().is_valid() {
            let first_key = self.cursor.borrow().current_key().unwrap().to_vec();
            if first_key.len() < 8 {
                self.cursor.borrow_mut().step();
                continue;
            }
            if let Some(ref bp) = bound_prefix {
                let bs = self.value_start(&first_key, pos_idx).min(bp.len());
                if bs != bp.len() || first_key[..bp.len()] != bp[..] {
                    self.at_end = true;
                    return;
                }
            }
            let first_raw = self.extract_raw(&first_key, pos_idx);
            let group_end = first_key.len() - 8;
            let mut cur_group = first_key[..group_end].to_vec();
            let mut found_key: Option<Vec<u8>> = None;

            while self.cursor.borrow().is_valid() {
                let key = self.cursor.borrow().current_key().unwrap().to_vec();
                if key.len() < 8 {
                    self.cursor.borrow_mut().step();
                    continue;
                }
                let ge = key.len() - 8;
                if key[..ge] != cur_group[..] {
                    if found_key.is_some() {
                        break;
                    }
                    cur_group = key[..ge].to_vec();
                }

                let raw = self.extract_raw(&key, pos_idx);
                if raw != first_raw {
                    break;
                }

                let suffix = Self::extract_suffix(&key);
                let (t, retracted) = decode_suffix(suffix);

                if as_of_us.is_some() && t > as_of_us.unwrap() {
                    self.cursor.borrow_mut().step();
                    continue;
                }

                if self.history_mode || !retracted {
                    found_key = Some(key.clone());
                }

                self.cursor.borrow_mut().skip_group(ge);

                if found_key.is_some() {
                    break;
                }
            }

            if let Some(bk) = found_key {
                self.current_active_key = Some(bk.clone());
                self.at_end = false;
                return;
            }
        }
        self.current_active_key = None;
        self.at_end = true;
    }

    fn advance_history_each(&mut self, pos_idx: usize) {
        let as_of_us = self.as_of_us;

        let bound_prefix: Option<Vec<u8>> = self.current_active_key.as_ref().map(|k| {
            let end = self.value_start(k, pos_idx);
            k[..end].to_vec()
        });

        while self.cursor.borrow().is_valid() {
            let key = self.cursor.borrow().current_key().unwrap().to_vec();
            if key.len() < 8 {
                self.cursor.borrow_mut().step();
                continue;
            }
            if let Some(ref bp) = bound_prefix {
                let bs = self.value_start(&key, pos_idx).min(bp.len());
                if bs != bp.len() || key[..bp.len()] != bp[..] {
                    self.at_end = true;
                    return;
                }
            }

            let suffix = Self::extract_suffix(&key);
            let (t, _) = decode_suffix(suffix);

            if as_of_us.is_some() && t > as_of_us.unwrap() {
                self.cursor.borrow_mut().step();
                continue;
            }

            self.current_active_key = Some(key);
            self.at_end = false;
            return;
        }
        self.current_active_key = None;
        self.at_end = true;
    }

    pub fn leap_next_at(&mut self, pos_idx: usize) {
        let pos_name = self.pos_name(pos_idx);
        if pos_name == "added" {
            self.at_end = true;
            return;
        }
        if let Some(key) = self.current_active_key.clone() {
            let raw = self.extract_raw(&key, pos_idx);
            self.seek_past_value_at(&raw, pos_idx);
        }
        self.advance_to_active_at(pos_idx);
    }

    fn seek_past_value_at(&mut self, current_raw: &Extracted, pos_idx: usize) {
        let pos_name = self.pos_name(pos_idx);
        let key = match self.current_active_key.as_ref() {
            Some(k) => k.clone(),
            None => { self.cursor.borrow_mut().invalidate(); return; }
        };
        let vs = self.value_start(&key, pos_idx);

        let mut target = key[..vs].to_vec();

        if pos_name == "t" {
            let suffix = Self::extract_suffix(&key);
            if suffix == 0 {
                self.cursor.borrow_mut().invalidate();
            } else {
                target.extend_from_slice(&(suffix + 1).to_be_bytes());
                self.cursor.borrow_mut().seek(&target);
            }
            return;
        }

        let overflow = match current_raw {
            Extracted::Int(n) => {
                if pos_name == "a" {
                    let cur = *n as u32;
                    if cur == u32::MAX { true } else {
                        target.extend_from_slice(&(cur + 1).to_be_bytes());
                        false
                    }
                } else {
                    if *n == u64::MAX { true } else {
                        target.extend_from_slice(&(*n + 1).to_be_bytes());
                        false
                    }
                }
            }
            Extracted::Bytes(b) => {
                let mut inc = b.clone();
                let mut carry = true;
                for i in (0..inc.len()).rev() {
                    if carry {
                        if inc[i] < 0xFF {
                            inc[i] += 1;
                            carry = false;
                        } else {
                            inc[i] = 0;
                        }
                    }
                }
                if carry { true } else {
                    target.extend_from_slice(&inc);
                    false
                }
            }
        };
        if overflow {
            self.cursor.borrow_mut().invalidate();
        } else {
            self.cursor.borrow_mut().seek(&target);
        }
    }

    pub fn seek_to_value(&mut self, pos_idx: usize, value: &Value) {
        let pos_name = self.pos_name(pos_idx);
        let key = match self.current_active_key.as_ref() {
            Some(k) => k.clone(),
            None => { self.cursor.borrow_mut().invalidate(); return; }
        };
        let vs = self.value_start(&key, pos_idx);
        let mut target = key[..vs].to_vec();

        match pos_name {
            "e" => {
                target.extend_from_slice(&(value.raw_int() as u64).to_be_bytes());
            }
            "a" => {
                target.extend_from_slice(&(value.raw_int() as u32).to_be_bytes());
            }
            "v" => {
                if self.is_unordered() {
                    target.extend_from_slice(&encode_variable_unordered(value));
                } else if value.is_variable() {
                    target.extend_from_slice(&encode_variable(value));
                } else if self.value_attr_type == Some(DB_TYPE_REF) {
                    target.extend_from_slice(&(value.raw_int() as u64).to_be_bytes());
                } else {
                    target.extend_from_slice(&encode_fixed(value));
                }
            }
            _ => {}
        }
        target.extend_from_slice(&[0u8; 8]);
        self.cursor.borrow_mut().seek(&target);
        self.advance_to_active_at(pos_idx);
    }
}

pub struct ValueScanner {
    inner: Arc<RefCell<dyn Cursor>>,
    index_name: String,
    value_pos: String,
    as_of_us: Option<u64>,
    prefix: Vec<u8>,
    current_value: Option<Value>,
    current_ts: Option<TimestampInfo>,
    current_key: Option<Vec<u8>>,
    at_end_flag: bool,
    value_attr_type: Option<u32>,
}

#[allow(dead_code)]
impl ValueScanner {
    pub fn new(
        cursor: Arc<RefCell<dyn Cursor>>,
        prefix: Vec<u8>,
        index_name: &str,
        value_pos: &str,
        as_of_us: Option<u64>,
        value_attr_type: Option<u32>,
    ) -> Self {
        let mut scanner = Self {
            inner: cursor,
            index_name: index_name.to_ascii_uppercase(),
            value_pos: value_pos.to_string(),
            as_of_us,
            prefix,
            current_value: None,
            current_ts: None,
            current_key: None,
            at_end_flag: false,
            value_attr_type,
        };
        scanner.advance_to_active();
        scanner
    }

    fn extract_suffix(key: &[u8]) -> u64 {
        let start = key.len() - 8;
        u64::from_be_bytes([key[start], key[start + 1], key[start + 2], key[start + 3],
                           key[start + 4], key[start + 5], key[start + 6], key[start + 7]])
    }

    fn a_offset(index_name: &str) -> usize {
        if index_name == "EAVT" || index_name == "VAET" {
            8
        } else {
            0
        }
    }

    fn v_data_start(index_name: &str) -> usize {
        match index_name {
            "EAVT" | "AEVT" | "VAET" => 12,
            "AVET" => 4,
            _ => 12,
        }
    }

    fn is_variable_value(&self, key_len: usize) -> bool {
        if matches!(self.value_attr_type, Some(DB_TYPE_STRING) | Some(DB_TYPE_BYTES) | Some(DB_TYPE_BLOB)) {
            return true;
        }
        key_len != 28
    }

    fn is_unordered(&self) -> bool {
        is_unordered_attr(self.value_attr_type)
    }

    fn extract_value(&self, key: &[u8]) -> Extracted {
        let idx = &self.index_name;
        let vp = &self.value_pos;

        if vp == "a" {
            let off = Self::a_offset(idx);
            return Extracted::Int(u32::from_be_bytes([key[off], key[off + 1], key[off + 2], key[off + 3]]) as u64);
        }

        if vp == "e" {
            return match idx.as_str() {
                "EAVT" => Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap())),
                "AEVT" => Extracted::Int(u64::from_be_bytes(key[4..12].try_into().unwrap())),
                "AVET" => {
                    let v_start = 4usize;
                    if self.is_variable_value(key.len()) {
                        let v_end = find_v_end(key, v_start, self.is_unordered());
                        Extracted::Int(u64::from_be_bytes(key[v_end..v_end + 8].try_into().unwrap()))
                    } else {
                        Extracted::Int(u64::from_be_bytes(key[v_start + 8..v_start + 16].try_into().unwrap()))
                    }
                }
                "VAET" => Extracted::Int(u64::from_be_bytes(key[12..20].try_into().unwrap())),
                _ => Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap())),
            };
        }

        if idx == "VAET" {
            return Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap()));
        }

        let v_start = Self::v_data_start(idx);
        if self.is_variable_value(key.len()) {
            let v_end = find_v_end(key, v_start, self.is_unordered());
            Extracted::Bytes(key[v_start..v_end].to_vec())
        } else {
            Extracted::Int(u64::from_be_bytes(key[v_start..v_start + 8].try_into().unwrap()))
        }
    }

    fn extract_position_raw(&self, key: &[u8], pos: &str) -> Extracted {
        let idx = &self.index_name;

        if pos == "a" {
            let off = Self::a_offset(&idx);
            return Extracted::Int(u32::from_be_bytes([key[off], key[off + 1], key[off + 2], key[off + 3]]) as u64);
        }

        if pos == "e" {
            return match idx.as_str() {
                "EAVT" => Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap())),
                "AEVT" => Extracted::Int(u64::from_be_bytes(key[4..12].try_into().unwrap())),
                "AVET" => {
                    let v_start = 4usize;
                    if self.is_variable_value(key.len()) {
                        let v_end = find_v_end(key, v_start, self.is_unordered());
                        Extracted::Int(u64::from_be_bytes(key[v_end..v_end + 8].try_into().unwrap()))
                    } else {
                        Extracted::Int(u64::from_be_bytes(key[v_start + 8..v_start + 16].try_into().unwrap()))
                    }
                }
                "VAET" => Extracted::Int(u64::from_be_bytes(key[12..20].try_into().unwrap())),
                _ => Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap())),
            };
        }

        if idx == "VAET" {
            return Extracted::Int(u64::from_be_bytes(key[0..8].try_into().unwrap()));
        }

        let v_start = Self::v_data_start(&idx);
        if self.is_variable_value(key.len()) {
            let v_end = find_v_end(key, v_start, self.is_unordered());
            Extracted::Bytes(key[v_start..v_end].to_vec())
        } else {
            Extracted::Int(u64::from_be_bytes(key[v_start..v_start + 8].try_into().unwrap()))
        }
    }

    fn make_value(&self, raw: &Extracted, key: &[u8]) -> Value {
        if self.value_pos == "e" {
            if let Extracted::Int(n) = raw {
                Value::entity_id(*n)
            } else {
                Value::Int64(0)
            }
        } else if self.value_pos == "a" {
            if let Extracted::Int(n) = raw {
                Value::Int64(*n as i64)
            } else {
                Value::Int64(0)
            }
        } else {
            if self.is_variable_value(key.len()) {
                if let Extracted::Bytes(b) = raw {
                    match self.value_attr_type {
                        Some(DB_TYPE_BYTES) => decode_variable(TAG_BYTES, b),
                        Some(DB_TYPE_BLOB) => decode_variable_unordered(b),
                        _ => decode_variable(TAG_STR, b),
                    }
                } else {
                    Value::Int64(0)
                }
            } else if let Extracted::Int(n) = raw {
                match self.value_attr_type {
                    Some(DB_TYPE_FLOAT) => Value::Float64(decode_float64(*n)),
                    Some(DB_TYPE_BOOLEAN) => Value::Bool(*n as u8),
                    Some(DB_TYPE_REF) => Value::entity_id(*n),
                    Some(DB_TYPE_INSTANT) => Value::Timestamp(decode_int64(*n)),
                    _ => decode_fixed(TAG_INT64, *n),
                }
            } else {
                Value::Int64(0)
            }
        }
    }

    fn seek_prefix_valid(&self, key: &[u8]) -> bool {
        let idx = self.index_name.as_str();
        let vp = self.value_pos.as_str();
        let expected = match (idx, vp) {
            ("EAVT", "a") | ("VAET", "a") => 8,
            ("EAVT", "e") => 0,
            ("EAVT", "v") | ("AEVT", "v") => 12,
            ("AEVT", "a") | ("AVET", "a") => 0,
            ("AEVT", "e") => 4,
            ("AVET", "v") => 4,
            ("AVET", "e") => {
                let v_start = 4usize;
                if self.is_variable_value(key.len()) {
                    find_v_end(key, v_start, self.is_unordered())
                } else {
                    v_start + 8
                }
            }
            ("VAET", "v") => 0,
            ("VAET", "e") => 12,
            _ => return false,
        };
        self.prefix.len() == expected
    }

    fn seek_past_value(&mut self, current_value: &Extracted) {
        let target = match current_value {
            Extracted::Int(n) => {
                if self.value_pos == "a" {
                    let cur = *n as u32;
                    if cur == u32::MAX {
                        self.inner.borrow_mut().invalidate();
                        return;
                    }
                    let mut t = self.prefix.clone();
                    t.extend_from_slice(&(cur + 1).to_be_bytes());
                    t
                } else {
                    if *n == u64::MAX {
                        self.inner.borrow_mut().invalidate();
                        return;
                    }
                    let mut t = self.prefix.clone();
                    t.extend_from_slice(&(*n + 1).to_be_bytes());
                    t
                }
            }
            Extracted::Bytes(b) => {
                let mut inc = b.clone();
                let mut carry = true;
                for i in (0..inc.len()).rev() {
                    if carry {
                        if inc[i] < 0xFF {
                            inc[i] += 1;
                            carry = false;
                        } else {
                            inc[i] = 0;
                        }
                    }
                }
                if carry {
                    self.inner.borrow_mut().invalidate();
                    return;
                }
                let mut t = self.prefix.clone();
                t.extend_from_slice(&inc);
                t
            }
        };
        self.inner.borrow_mut().seek(&target);
    }

    fn report_advance_timing(t0: &Option<std::time::Instant>) {
        if let Some(t) = t0 {
            crate::engine::opcodes::scanner_advance_elapsed(t.elapsed().as_nanos() as u64);
        }
    }

    fn advance_to_active(&mut self) {
        let t0 = crate::engine::opcodes::debug_timing_enabled().then(std::time::Instant::now);
        let as_of_us = self.as_of_us;

        while self.inner.borrow().is_valid() {
            let first_key = self.inner.borrow().current_key().unwrap().to_vec();
            let first_value = self.extract_value(&first_key);
            let key_len = first_key.len();
            let group_end = key_len - 8;
            let first_group: Vec<u8> = first_key[..group_end].to_vec();
            let mut found_key: Option<Vec<u8>> = None;
            let mut found_ts: Option<TimestampInfo> = None;
            let mut cur_group = first_group;

            while self.inner.borrow().is_valid() {
                let key = self.inner.borrow().current_key().unwrap().to_vec();
                if key.len() < 8 { self.inner.borrow_mut().step(); continue; }

                let group_changed = key[..group_end] != cur_group[..];
                if group_changed {
                    if found_key.is_some() { break; }
                    cur_group = key[..group_end].to_vec();
                }

                let val = self.extract_value(&key);
                if val != first_value { break; }

                let suffix = Self::extract_suffix(&key);
                let (t, retracted) = decode_suffix(suffix);

                if as_of_us.is_some() && t > as_of_us.unwrap() {
                    self.inner.borrow_mut().step();
                    continue;
                }

                if !retracted {
                    found_key = Some(key.clone());
                    found_ts = Some(TimestampInfo);
                }

                self.inner.borrow_mut().skip_group(group_end);

                if found_key.is_some() { break; }
            }

            if let Some(bk) = found_key {
                let ts = found_ts.unwrap();
                self.current_value = Some(self.make_value(&first_value, &bk));
                self.current_key = Some(bk.clone());
                self.current_ts = Some(ts);
                self.at_end_flag = false;
                if self.seek_prefix_valid(&bk) {
                    self.seek_past_value(&first_value);
                } else {
                    while self.inner.borrow().is_valid() {
                        let key = self.inner.borrow().current_key().unwrap().to_vec();
                        if self.extract_value(&key) != first_value { break; }
                        self.inner.borrow_mut().skip_group(group_end);
                    }
                }
                Self::report_advance_timing(&t0);
                return;
            }
        }
        self.current_value = None;
        self.current_key = None;
        self.current_ts = None;
        self.at_end_flag = true;
        Self::report_advance_timing(&t0);
    }

    pub fn next(&mut self) {
        self.advance_to_active();
    }

    pub fn seek(&mut self, value: &Value) {
        let t0 = crate::engine::opcodes::debug_timing_enabled().then(std::time::Instant::now);
        let target = self.build_seek_target(value);
        self.inner.borrow_mut().seek(&target);
        self.advance_to_active();
        if let Some(t) = t0 {
            crate::engine::opcodes::scanner_seek_elapsed(t.elapsed().as_nanos() as u64);
        }
    }

    fn build_seek_target(&self, value: &Value) -> Vec<u8> {
        let mut buf = self.prefix.clone();
        if self.value_pos == "v" {
            if self.is_unordered() {
                buf.extend_from_slice(&encode_variable_unordered(value));
            } else if value.is_variable() {
                buf.extend_from_slice(&encode_variable(value));
            } else if self.value_attr_type == Some(DB_TYPE_REF) {
                buf.extend_from_slice(&(value.raw_int() as u64).to_be_bytes());
            } else {
                buf.extend_from_slice(&encode_fixed(value));
            }
            buf.extend_from_slice(&[0u8; 8]);
        } else if self.value_pos == "a" {
            buf.extend_from_slice(&(value.raw_int() as u32).to_be_bytes());
            buf.extend_from_slice(&[0u8; 16]);
        } else {
            buf.extend_from_slice(&(value.raw_int() as u64).to_be_bytes());
            buf.extend_from_slice(&[0u8; 8]);
        }
        buf
    }

    pub fn key(&self) -> Option<&Value> {
        self.current_value.as_ref()
    }

    pub fn current_ts(&self) -> Option<&TimestampInfo> {
        self.current_ts.as_ref()
    }

    pub fn at_end(&self) -> bool {
        self.at_end_flag
    }

    pub fn extract_position_raw_from_current(&self, pos: &str) -> Option<Extracted> {
        self.current_key.as_ref().map(|k| self.extract_position_raw(k, pos))
    }

    pub fn current_key(&self) -> Option<&[u8]> {
        self.current_key.as_ref().map(|k| k.as_slice())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Extracted {
    Int(u64),
    Bytes(Vec<u8>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_suffix() {
        let suffix = dynspire_commons::transactor::keys::encode_suffix(1000, false);
        let mut key = vec![0u8; 20];
        key[12..20].copy_from_slice(&suffix.to_be_bytes());
        let extracted = ValueScanner::extract_suffix(&key);
        assert_eq!(extracted, suffix);
    }

    #[test]
    fn test_a_offset() {
        assert_eq!(ValueScanner::a_offset("EAVT"), 8);
        assert_eq!(ValueScanner::a_offset("VAET"), 8);
        assert_eq!(ValueScanner::a_offset("AEVT"), 0);
        assert_eq!(ValueScanner::a_offset("AVET"), 0);
    }

    #[test]
    fn test_v_data_start() {
        assert_eq!(ValueScanner::v_data_start("EAVT"), 12);
        assert_eq!(ValueScanner::v_data_start("AEVT"), 12);
        assert_eq!(ValueScanner::v_data_start("AVET"), 4);
        assert_eq!(ValueScanner::v_data_start("VAET"), 12);
    }

    #[test]
    fn test_extracted_eq() {
        assert_eq!(Extracted::Int(42), Extracted::Int(42));
        assert_eq!(Extracted::Bytes(b"hello".to_vec()), Extracted::Bytes(b"hello".to_vec()));
        assert!(Extracted::Int(42) != Extracted::Int(43));
    }
}

#[cfg(test)]
mod v2_tests {
    use super::*;
    use std::cell::RefCell;

    struct MockCursor {
        keys: Vec<Vec<u8>>,
        pos: usize,
        end_prefix: Option<Vec<u8>>,
    }

    impl MockCursor {
        fn new(keys: Vec<Vec<u8>>) -> Self {
            Self { keys, pos: 0, end_prefix: None }
        }
    }

    impl Cursor for MockCursor {
        fn is_valid(&self) -> bool {
            if self.pos >= self.keys.len() { return false; }
            if let Some(ref end) = self.end_prefix {
                let k = &self.keys[self.pos];
                if k.starts_with(end) { return false; }
            }
            true
        }

        fn current_key(&self) -> Option<&[u8]> {
            self.keys.get(self.pos).map(|k| k.as_slice())
        }

        fn step(&mut self) {
            self.pos += 1;
        }

        fn skip_group(&mut self, group_end: usize) {
            if self.pos >= self.keys.len() { return; }
            let cur = &self.keys[self.pos][..group_end];
            while self.pos < self.keys.len() && self.keys[self.pos][..group_end] == *cur {
                self.pos += 1;
            }
        }

        fn seek(&mut self, target: &[u8]) {
            self.pos = self.keys.partition_point(|k| k.as_slice() < target);
        }

        fn update_end(&mut self, end: &[u8]) {
            self.end_prefix = Some(end.to_vec());
        }

        fn invalidate(&mut self) {
            self.pos = self.keys.len();
        }
    }

    fn build_avet_key(a: u32, v: i64, e: u64, t: u64, retracted: bool) -> Vec<u8> {
        let suffix = dynspire_commons::transactor::keys::encode_suffix(t, retracted);
        let mut buf = Vec::new();
        buf.extend_from_slice(&a.to_be_bytes());
        buf.extend_from_slice(&dynspire_commons::transactor::keys::encode_int64(v).to_be_bytes());
        buf.extend_from_slice(&e.to_be_bytes());
        buf.extend_from_slice(&suffix.to_be_bytes());
        buf
    }

    #[test]
    fn test_v2_scanner_advance_eavt() {
        let t1 = 1000u64;
        let mut keys = vec![
            build_avet_key(10, 1, 100, t1, false),
            build_avet_key(10, 2, 101, t1, false),
            build_avet_key(10, 3, 102, t1, false),
        ];
        keys.sort();
        let cursor = Arc::new(RefCell::new(MockCursor::new(keys)));
        let mut scanner = V2Scanner::new(
            "AVET", vec!["a".into(), "v".into(), "e".into()],
            None, None,
        );
        scanner.set_cursor(cursor);

        scanner.advance_to_active_at(1);
        assert!(!scanner.at_end());
        let val = scanner.extract_value(1).unwrap();
        assert_eq!(val.raw_int(), 1);

        scanner.advance_to_active_at(1);
        assert!(!scanner.at_end());
        let val = scanner.extract_value(1).unwrap();
        assert_eq!(val.raw_int(), 2);

        scanner.advance_to_active_at(1);
        assert!(!scanner.at_end());
        let val = scanner.extract_value(1).unwrap();
        assert_eq!(val.raw_int(), 3);

        scanner.advance_to_active_at(1);
        assert!(scanner.at_end());
    }

    #[test]
    fn test_v2_scanner_extract_e_from_same_key() {
        let t1 = 1000u64;
        let mut keys = vec![
            build_avet_key(10, 42, 777, t1, false),
        ];
        keys.sort();
        let cursor = Arc::new(RefCell::new(MockCursor::new(keys)));
        let mut scanner = V2Scanner::new(
            "AVET", vec!["a".into(), "v".into(), "e".into()],
            None, None,
        );
        scanner.set_cursor(cursor);

        scanner.advance_to_active_at(1);
        assert!(!scanner.at_end());
        let v_val = scanner.extract_value(1).unwrap();
        assert_eq!(v_val.raw_int(), 42);

        let e_val = scanner.extract_value(2).unwrap();
        assert_eq!(e_val.raw_int(), 777);
    }

    #[test]
    fn test_v2_scanner_retracted() {
        let t1 = 1000u64;
        let t2 = 2000u64;
        let mut keys = vec![
            build_avet_key(10, 5, 200, t1, false),
            build_avet_key(10, 5, 200, t2, true),
            build_avet_key(10, 6, 201, t1, false),
        ];
        keys.sort();
        let cursor = Arc::new(RefCell::new(MockCursor::new(keys)));
        let mut scanner = V2Scanner::new(
            "AVET", vec!["a".into(), "v".into(), "e".into()],
            None, None,
        );
        scanner.set_cursor(cursor);

        scanner.advance_to_active_at(1);
        assert!(!scanner.at_end());
        let val = scanner.extract_value(1).unwrap();
        assert_eq!(val.raw_int(), 6);

        scanner.advance_to_active_at(1);
        assert!(scanner.at_end());
    }
}
