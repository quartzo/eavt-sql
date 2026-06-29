use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use crate::resolver::{self, Resolver};
use crate::keys::{self, EncodeMode, RawDatom};
use dynspire_commons::kvstore::{DynSpireKVStore, KVStoreEngine};
use dynspire_commons::value::{self, Value};

fn unpack_keys(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut keys = Vec::new();
    let mut pos = 0;
    while pos + 4 <= buf.len() {
        let len = u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;
        keys.push(buf[pos..pos + len].to_vec());
        pos += len;
    }
    keys
}

fn cf_name_to_id(name: &str) -> usize {
    match name {
        "eavt" => 0,
        "aevt" => 1,
        "avet" => 2,
        "vaet" => 3,
        _ => 0,
    }
}

fn build_ea_prefix(e: u64, a: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(12);
    buf.extend_from_slice(&e.to_be_bytes());
    buf.extend_from_slice(&a.to_be_bytes());
    buf
}

fn values_match(v1: &Value, v2: &Value) -> bool {
    v1 == v2
}

fn type_id_to_name(vt: u32) -> &'static str {
    match vt {
        resolver::DB_TYPE_STRING => "STRING",
        resolver::DB_TYPE_LONG => "LONG",
        resolver::DB_TYPE_REF => "REF",
        resolver::DB_TYPE_BOOLEAN => "BOOLEAN",
        resolver::DB_TYPE_FLOAT => "FLOAT",
        resolver::DB_TYPE_INSTANT => "INSTANT",
        resolver::DB_TYPE_BYTES => "BYTES",
        resolver::DB_TYPE_BLOB => "BLOB",
        resolver::DB_TYPE_KEYWORD => "KEYWORD",
        _ => "UNKNOWN",
    }
}

fn tag_to_type_name(tag: i8) -> &'static str {
    match tag {
        value::TAG_STR => "STRING",
        value::TAG_INT64 => "LONG",
        value::TAG_BOOL => "BOOLEAN",
        value::TAG_FLOAT64 => "FLOAT",
        -1 => "INSTANT",
        value::TAG_BYTES => "BYTES",
        _ => "UNKNOWN",
    }
}

fn now_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

fn current_t_or_alloc(current_t: Option<u64>, resolver: &mut Resolver) -> u64 {
    current_t.unwrap_or_else(|| resolver.allocate_t())
}

fn coerce_value(a_id: u32, v: &Value, resolver: &Resolver) -> Value {
    let expected_vt = match resolver.value_type_for(a_id) {
        Some(vt) => vt,
        None => return v.clone(),
    };
    match expected_vt {
        resolver::DB_TYPE_BOOLEAN => {
            if v.tag() == value::TAG_INT64 {
                return Value::Bool(v.raw_int() as u8);
            }
        }
        resolver::DB_TYPE_INSTANT => {
            if v.tag() == value::TAG_INT64 {
                return Value::Timestamp(v.raw_int());
            }
            if let Value::Text(s) = v {
                if let Ok(us) = value::parse_instant_to_us(s) {
                    return Value::Timestamp(us);
                }
            }
        }
        _ => {}
    }
    v.clone()
}

fn validate_value_type(a_id: u32, v: &Value, resolver: &Resolver) -> Result<(), String> {
    let expected_vt = match resolver.value_type_for(a_id) {
        Some(vt) => vt,
        None => return Ok(()),
    };
    let tag = v.tag();
    let ok = match expected_vt {
        resolver::DB_TYPE_STRING => tag == value::TAG_STR,
        resolver::DB_TYPE_LONG => tag == value::TAG_INT64,
        resolver::DB_TYPE_REF => tag == value::TAG_INT64,
        resolver::DB_TYPE_BOOLEAN => tag == value::TAG_BOOL,
        resolver::DB_TYPE_FLOAT => tag == value::TAG_FLOAT64,
        resolver::DB_TYPE_INSTANT => tag == -1,
        resolver::DB_TYPE_BYTES => tag == value::TAG_BYTES,
        resolver::DB_TYPE_BLOB => tag == value::TAG_BYTES,
        resolver::DB_TYPE_KEYWORD => tag == value::TAG_STR,
        _ => true,
    };
    if !ok {
        let attr_name = resolver.attr_name(a_id);
        let expected_name = type_id_to_name(expected_vt);
        let actual_name = tag_to_type_name(tag);
        return Err(format!(
            "type mismatch for attribute '{}': expected {}, got {}",
            attr_name, expected_name, actual_name
        ));
    }
    Ok(())
}

fn validate_value_size(v: &Value) -> Result<(), String> {
    if v.is_variable() {
        let raw_len = match v {
            Value::Text(s) => s.len(),
            Value::Bytes(b) => b.len(),
            _ => return Ok(()),
        };
        if raw_len > 1_048_576 {
            return Err(format!(
                "value too large for index: {} bytes (max {})",
                raw_len, 1_048_576
            ));
        }
    }
    Ok(())
}

pub struct EavtEngine {
    pub kv: DynSpireKVStore,
    pub resolver: Mutex<Resolver>,
}

impl EavtEngine {
    pub fn new(kv: DynSpireKVStore) -> Self {
        Self {
            kv,
            resolver: Mutex::new(Resolver::new()),
        }
    }

    // ===== Lifecycle =====

    pub fn bootstrap_resolver(&self) {
        let mut resolver = self.resolver.lock().unwrap();
        let mut ident_map: HashMap<u64, String> = HashMap::new();
        let db_ident_prefix = resolver::DB_IDENT_AID.to_be_bytes().to_vec();
        for k in &unpack_keys(&self.kv.scan(1, &db_ident_prefix).unwrap_or_default()) {
            let raw = keys::unpack_key("aevt", k, &resolver);
            if raw.a != resolver::DB_IDENT_AID {
                continue;
            }
            if let Value::Text(ref s) = raw.v {
                if raw.e >= resolver::BOOTSTRAP_FIRST_USER_ID {
                    ident_map.insert(raw.e, s.clone());
                }
            }
        }

        let mut vt_map: HashMap<u64, u32> = HashMap::new();
        let db_vt_prefix = resolver::DB_VALUE_TYPE_AID.to_be_bytes().to_vec();
        for k in &unpack_keys(&self.kv.scan(1, &db_vt_prefix).unwrap_or_default()) {
            let raw = keys::unpack_key("aevt", k, &resolver);
            if raw.a != resolver::DB_VALUE_TYPE_AID {
                continue;
            }
            if let Value::Int64(tid) = &raw.v {
                vt_map.insert(raw.e, *tid as u32);
            }
        }

        let mut card_map: HashMap<u64, bool> = HashMap::new();
        let db_card_prefix = resolver::DB_CARDINALITY_AID.to_be_bytes().to_vec();
        for k in &unpack_keys(&self.kv.scan(1, &db_card_prefix).unwrap_or_default()) {
            let raw = keys::unpack_key("aevt", k, &resolver);
            if raw.a != resolver::DB_CARDINALITY_AID {
                continue;
            }
            if let Value::Int64(cid) = &raw.v {
                card_map.insert(raw.e, *cid as u32 == resolver::DB_CARDINALITY_MANY);
            }
        }

        let mut unique_set: HashSet<u64> = HashSet::new();
        let db_unique_prefix = resolver::DB_UNIQUE_AID.to_be_bytes().to_vec();
        for k in &unpack_keys(&self.kv.scan(1, &db_unique_prefix).unwrap_or_default()) {
            let raw = keys::unpack_key("aevt", k, &resolver);
            if raw.a != resolver::DB_UNIQUE_AID {
                continue;
            }
            unique_set.insert(raw.e);
        }

        for (eid, name) in &ident_map {
            let vt = vt_map.get(eid).copied().unwrap_or(resolver::DB_TYPE_STRING);
            let many = card_map.get(eid).copied().unwrap_or(false);
            let unique = unique_set.contains(eid);
            resolver.load_user_attr(name.clone(), *eid, vt, many, unique);
        }

        {
            let db_part_prefix = resolver::DB_PART_ID_AID.to_be_bytes().to_vec();
            for k in &unpack_keys(&self.kv.scan(1, &db_part_prefix).unwrap_or_default()) {
                let raw = keys::unpack_key("aevt", k, &resolver);
                if raw.a != resolver::DB_PART_ID_AID {
                    continue;
                }
                if let Value::Int64(p) = &raw.v {
                    let part_name =
                        ident_map.get(&raw.e).cloned().unwrap_or_else(|| raw.e.to_string());
                    resolver.register_partition(part_name, *p as u64);
                }
            }
        }

        let eavt_keys = unpack_keys(&self.kv.scan(0, &[]).unwrap_or_default());
        let eavt_pairs: Vec<(Vec<u8>, Vec<u8>)> =
            eavt_keys.iter().map(|k| (k.clone(), Vec::new())).collect();
        resolver.init_ent_id_from_eavt(eavt_pairs, vec![]);

        let mut max_t: u64 = 0;
        for k in &eavt_keys {
            if k.len() >= 8 {
                let suffix = u64::from_be_bytes(k[k.len() - 8..].try_into().unwrap());
                let (t, _) = keys::decode_suffix(suffix);
                if t > max_t {
                    max_t = t;
                }
            }
        }
        if max_t >= resolver.next_t() {
            resolver.set_next_t(max_t);
        }
    }

    pub fn recover_journal(&self) {
        let packed = match self.kv.journal_scan() {
            Ok(e) => e,
            Err(_) => return,
        };
        if packed.is_empty() {
            return;
        }
        let mut per_cf: [Vec<u8>; 4] = [Vec::new(), Vec::new(), Vec::new(), Vec::new()];
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos + 1], packed[pos + 2], packed[pos + 3]]) as usize;
            pos += 4;
            if pos + klen + 4 > packed.len() { break; }
            let eavt_key = &packed[pos..pos + klen];
            pos += klen;
            let vlen = u32::from_be_bytes([packed[pos], packed[pos + 1], packed[pos + 2], packed[pos + 3]]) as usize;
            pos += 4;
            if pos + vlen > packed.len() { break; }
            let meta = &packed[pos..pos + vlen];
            pos += vlen;

            let is_ref = !meta.is_empty() && meta[0] & 1 != 0;
            let key_len = eavt_key.len();
            if key_len < 20 { continue; }
            let suffix = &eavt_key[key_len - 8..];
            let e = &eavt_key[0..8];
            let a = &eavt_key[8..12];
            let v = &eavt_key[12..key_len - 8];

            for (cf_id, key) in [
                (0usize, eavt_key.to_vec()),
                (1usize, [a, e, v, suffix].concat()),
                (2usize, [a, v, e, suffix].concat()),
            ] {
                per_cf[cf_id].extend_from_slice(&(key.len() as u32).to_be_bytes());
                per_cf[cf_id].extend_from_slice(&key);
            }
            if is_ref {
                let key = [v, a, e, suffix].concat();
                per_cf[3].extend_from_slice(&(key.len() as u32).to_be_bytes());
                per_cf[3].extend_from_slice(&key);
            }
        }
        for cf_id in 0..4u32 {
            if !per_cf[cf_id as usize].is_empty() {
                let _ = self.kv.replay(cf_id, &per_cf[cf_id as usize]);
            }
        }
    }

    // ===== Write helpers =====

    fn write_entries(&self, entries: keys::IndexEntries, is_ref: bool) {
        let mut journal_key: Option<&[u8]> = None;
        for (cf, k, _val) in &entries.entries {
            if *cf == "eavt" {
                journal_key = Some(k);
                break;
            }
        }
        if let Some(jk) = journal_key {
            let flag = vec![if is_ref { 1u8 } else { 0u8 }];
            let _ = self.kv.journal_put(jk, &flag);
        }
        let mut buf = Vec::new();
        for (cf, k, _val) in entries.entries {
            let cf_id = cf_name_to_id(cf) as u8;
            buf.push(cf_id);
            buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
            buf.extend_from_slice(&k);
        }
        let _ = self.kv.batch_write(&buf);
    }

    fn put_schema_entries(&self, entries: keys::IndexEntries) {
        let is_ref = entries.entries.iter().any(|(cf, _, _)| *cf == "vaet");
        self.write_entries(entries, is_ref);
    }

    /// Scan a CF prefix and return only the latest active (non-retracted) datom per group.
    /// Uses simple MergedInner iteration (no ValueScanner) to avoid eavt-query dependency.
    fn collect_active_raw(
        &self,
        cf: &str,
        prefix: &[u8],
        as_of_us: Option<u64>,
        resolver: &Resolver,
    ) -> Vec<RawDatom> {
        let cf_id = cf_name_to_id(cf);
        let keys = unpack_keys(&self.kv.scan(cf_id as u32, prefix).unwrap_or_default());
        let mut results = Vec::new();
        let mut prev_group: Option<Vec<u8>> = None;
        let mut best: Option<RawDatom> = None;
        for key in &keys {
            let group = key[..key.len() - 8].to_vec();
            let raw = keys::unpack_key(cf, key, resolver);
            if let Some(as_of) = as_of_us {
                if raw.t > as_of {
                    continue;
                }
            }
            if Some(&group) != prev_group.as_ref() {
                if let Some(b) = best.take() {
                    if !b.retracted {
                        results.push(b);
                    }
                }
                prev_group = Some(group);
                best = Some(raw);
            } else if let Some(ref mut b) = best {
                if raw.t > b.t {
                    *b = raw;
                }
            }
        }
        if let Some(b) = best {
            if !b.retracted {
                results.push(b);
            }
        }
        results
    }

    fn check_unique_constraint(
        &self,
        e_id: u64,
        a_id: u32,
        v: &Value,
        as_of_us: Option<u64>,
        resolver: &Resolver,
    ) -> Result<(), String> {
        let mode = keys::encode_mode_for(resolver.value_type_for(a_id));
        let prefix = keys::avet_value_prefix(a_id, v, mode);
        let active = self.collect_active_raw("avet", &prefix, as_of_us, resolver);
        for dv in &active {
            if dv.e != e_id {
                let attr_name = resolver.attr_name(a_id);
                return Err(format!(
                    "unique constraint violation: {}.value = {:?} already held by entity {}",
                    attr_name, v, dv.e
                ));
            }
        }
        Ok(())
    }

    fn build_retract_entries(
        &self,
        e_id: u64,
        a_id: u32,
        v_new: &Value,
        t: u64,
        is_retract: bool,
        as_of_us: Option<u64>,
        resolver: &Resolver,
    ) -> Option<Vec<(usize, Vec<u8>, Vec<u8>)>> {
        let mode = keys::encode_mode_for(resolver.value_type_for(a_id));
        let prefix = build_ea_prefix(e_id, a_id);
        let active = self.collect_active_raw("eavt", &prefix, as_of_us, resolver);

        let mut batch: Vec<(usize, Vec<u8>, Vec<u8>)> = Vec::new();
        let mut already_active = false;

        for dv in &active {
            if is_retract || !values_match(v_new, &dv.v) {
                let entries = keys::build_entries(dv.e, dv.a, &dv.v, t, true, mode);
                for (cf, k, val) in entries.entries {
                    let cf_id = cf_name_to_id(&cf);
                    batch.push((cf_id, k, val));
                }
            } else {
                already_active = true;
            }
        }

        if !is_retract && !already_active {
            let entries = keys::build_entries(e_id, a_id, v_new, t, false, mode);
            for (cf, k, val) in entries.entries {
                let cf_id = cf_name_to_id(&cf);
                batch.push((cf_id, k, val));
            }
        }

        if batch.is_empty() {
            None
        } else {
            Some(batch)
        }
    }

    // ===== Public write API =====

    pub fn save_at_t(
        &self,
        e_id: u64,
        attr: &str,
        v: &Value,
        t: u64,
        as_of_us: Option<u64>,
    ) -> Result<(), String> {
        let mut resolver = self.resolver.lock().unwrap();
        let a_id = resolver.lookup_attr(attr).ok_or_else(|| {
            format!("undeclared attribute '{}'", attr)
        })?;
        if !resolver.is_declared(a_id) {
            return Err(format!("attribute '{}' is not declared", attr));
        }
        resolver.advance_past(e_id);
        validate_value_size(v)?;
        let v = coerce_value(a_id, v, &resolver);
        validate_value_type(a_id, &v, &resolver)?;

        if resolver.is_unique(a_id) {
            self.check_unique_constraint(e_id, a_id, &v, as_of_us, &resolver)?;
        }

        if resolver.is_many(a_id) {
            let mode = keys::encode_mode_for(resolver.value_type_for(a_id));
            let entries = keys::build_entries(e_id, a_id, &v, t, false, mode);
            self.write_entries(entries, mode == EncodeMode::Ref);
        } else if let Some(batch) = self.build_retract_entries(e_id, a_id, &v, t, false, as_of_us, &resolver) {
            let is_ref = batch.iter().any(|(cf_id, _, _)| *cf_id == 3);
            self.write_entries(keys::IndexEntries {
                entries: batch.into_iter()
                    .map(|(cf_id, k, val)| {
                        let cf_name = match cf_id {
                            0 => "eavt", 1 => "aevt", 2 => "avet", 3 => "vaet", _ => "eavt"
                        };
                        (cf_name, k, val)
                    })
                    .collect(),
            }, is_ref);
        }
        Ok(())
    }

    pub fn retract_at_t(
        &self,
        e_id: u64,
        attr: &str,
        v: &Value,
        current_t: Option<u64>,
        as_of_us: Option<u64>,
    ) {
        let mut resolver = self.resolver.lock().unwrap();
        let a_id = match resolver.lookup_attr(attr) {
            Some(id) => id,
            None => return,
        };
        resolver.advance_past(e_id);
        let t = current_t_or_alloc(current_t, &mut resolver);
        let v = coerce_value(a_id, v, &resolver);

        if resolver.is_many(a_id) {
            let mode = keys::encode_mode_for(resolver.value_type_for(a_id));
            let entries = keys::build_entries(e_id, a_id, &v, t, true, mode);
            self.write_entries(entries, mode == EncodeMode::Ref);
        } else if let Some(batch) = self.build_retract_entries(e_id, a_id, &v, t, true, as_of_us, &resolver) {
            let is_ref = batch.iter().any(|(cf_id, _, _)| *cf_id == 3);
            self.write_entries(keys::IndexEntries {
                entries: batch.into_iter()
                    .map(|(cf_id, k, val)| {
                        let cf_name = match cf_id {
                            0 => "eavt", 1 => "aevt", 2 => "avet", 3 => "vaet", _ => "eavt"
                        };
                        (cf_name, k, val)
                    })
                    .collect(),
            }, is_ref);
        }
    }

    // ===== Schema management =====

    pub fn declare_attr_with_t(
        &self,
        name: &str,
        value_type: u32,
        many: bool,
        current_t: Option<u64>,
    ) -> u32 {
        let mut resolver = self.resolver.lock().unwrap();
        let (aid, is_new) = resolver.declare_attr(name, value_type, many)
            .expect("declare_attr failed");
        if is_new {
            let t = current_t_or_alloc(current_t, &mut resolver);
            let ident_v = Value::text(name.to_string());
            let entries = keys::build_entries(
                aid as u64,
                resolver::DB_IDENT_AID,
                &ident_v,
                t,
                false,
                EncodeMode::Variable,
            );
            self.put_schema_entries(entries);

            let vt_v = Value::entity_id(value_type as u64);
            let entries = keys::build_entries(
                aid as u64,
                resolver::DB_VALUE_TYPE_AID,
                &vt_v,
                t,
                false,
                EncodeMode::Ref,
            );
            self.put_schema_entries(entries);

            let card_id = if many {
                resolver::DB_CARDINALITY_MANY
            } else {
                resolver::DB_CARDINALITY_ONE
            };
            let card_v = Value::entity_id(card_id as u64);
            let entries = keys::build_entries(
                aid as u64,
                resolver::DB_CARDINALITY_AID,
                &card_v,
                t,
                false,
                EncodeMode::Ref,
            );
            self.put_schema_entries(entries);
        }
        aid
    }

    pub fn declare_attr_from_sql_with_t(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        current_t: Option<u64>,
    ) -> Result<(), String> {
        let mut resolver = self.resolver.lock().unwrap();
        let _ = resolver::normalize_attr(attr)?;
        let vt = match type_name {
            "STRING" => resolver::DB_TYPE_STRING,
            "LONG" => resolver::DB_TYPE_LONG,
            "REF" => resolver::DB_TYPE_REF,
            "BOOLEAN" => resolver::DB_TYPE_BOOLEAN,
            "INSTANT" => resolver::DB_TYPE_INSTANT,
            "BYTES" => resolver::DB_TYPE_BYTES,
            "BLOB" => resolver::DB_TYPE_BLOB,
            "FLOAT" => resolver::DB_TYPE_FLOAT,
            "KEYWORD" => resolver::DB_TYPE_KEYWORD,
            _ => resolver::DB_TYPE_STRING,
        };
        if let Some(aid) = resolver.lookup_attr(attr) {
            let existing_vt = resolver
                .value_type_for(aid)
                .unwrap_or(resolver::DB_TYPE_STRING);
            if existing_vt != vt {
                let name = resolver.attr_name(aid);
                return Err(format!(
                    "attribute '{}' declared as {}, cannot change to {}",
                    name,
                    type_id_to_name(existing_vt),
                    type_id_to_name(vt)
                ));
            }
            let cur_many = resolver.is_many(aid);
            if cur_many != many {
                resolver.set_cardinality(aid, many);
                let card_id = if many {
                    resolver::DB_CARDINALITY_MANY
                } else {
                    resolver::DB_CARDINALITY_ONE
                };
                let t = current_t_or_alloc(current_t, &mut resolver);
                let old_card_id = if cur_many {
                    resolver::DB_CARDINALITY_MANY
                } else {
                    resolver::DB_CARDINALITY_ONE
                };
                let old_card_v = Value::entity_id(old_card_id as u64);
                let card_v = Value::entity_id(card_id as u64);
                let entries = keys::build_entries(
                    aid as u64,
                    resolver::DB_CARDINALITY_AID,
                    &old_card_v,
                    t,
                    true,
                    EncodeMode::Ref,
                );
                self.put_schema_entries(entries);
                let entries = keys::build_entries(
                    aid as u64,
                    resolver::DB_CARDINALITY_AID,
                    &card_v,
                    t,
                    false,
                    EncodeMode::Ref,
                );
                self.put_schema_entries(entries);
            }
            resolver.set_unique(aid, unique);
            return Ok(());
        }
        drop(resolver);
        // declare_attr_with_t acquires the lock itself
        self.declare_attr_with_t(attr, vt, many, current_t);
        if unique {
            let mut resolver = self.resolver.lock().unwrap();
            if let Some(aid) = resolver.lookup_attr(attr) {
                resolver.set_unique(aid, true);
                let t = current_t_or_alloc(current_t, &mut resolver);
                let unique_v = Value::entity_id(resolver::DB_UNIQUE_VALUE as u64);
                let entries = keys::build_entries(
                    aid as u64,
                    resolver::DB_UNIQUE_AID,
                    &unique_v,
                    t,
                    false,
                    EncodeMode::Ref,
                );
                self.put_schema_entries(entries);
            }
        }
        Ok(())
    }

    pub fn declare_partition_with_t(
        &self,
        name: &str,
        current_t: Option<u64>,
    ) -> Result<u64, String> {
        let mut resolver = self.resolver.lock().unwrap();
        if let Some(p) = resolver.partition_id_for(name) {
            return Ok(p);
        }
        let p = resolver.declare_partition(name);
        let entity_id = resolver.allocate_schema_id();
        let t = current_t_or_alloc(current_t, &mut resolver);
        let ident_v = Value::Text(name.to_string());
        let part_id_v = Value::Int64(p as i64);
        let entries =
            keys::build_entries(entity_id, resolver::DB_IDENT_AID, &ident_v, t, false, EncodeMode::Variable);
        self.put_schema_entries(entries);
        let entries =
            keys::build_entries(entity_id, resolver::DB_PART_ID_AID, &part_id_v, t, false, EncodeMode::Fixed);
        self.put_schema_entries(entries);
        Ok(p)
    }

    pub fn allocate_t_and_write_tx(&self) -> u64 {
        let mut resolver = self.resolver.lock().unwrap();
        let t = resolver.allocate_t();
        let tx_eid = resolver::make_entity_id(resolver::PART_TX, t);
        let now_us = now_micros();
        let instant_v = Value::Timestamp(now_us as i64);
        let entries = keys::build_entries(tx_eid, resolver::DB_TX_INSTANT_AID, &instant_v, t, false, EncodeMode::Fixed);
        self.put_schema_entries(entries);
        t
    }

    // ===== Resolver accessors (for StoreEngine delegation) =====

    pub fn lookup_attr_locked(&self, name: &str) -> Option<u32> {
        self.resolver.lock().unwrap().lookup_attr(name)
    }

    pub fn is_declared_locked(&self, aid: u32) -> bool {
        self.resolver.lock().unwrap().is_declared(aid)
    }

    pub fn attr_name_locked(&self, aid: u32) -> String {
        self.resolver.lock().unwrap().attr_name(aid)
    }

    pub fn value_type_for_locked(&self, aid: u32) -> Option<u32> {
        self.resolver.lock().unwrap().value_type_for(aid)
    }

    pub fn is_unique_locked(&self, aid: u32) -> bool {
        self.resolver.lock().unwrap().is_unique(aid)
    }

    pub fn is_many_locked(&self, aid: u32) -> bool {
        self.resolver.lock().unwrap().is_many(aid)
    }

    pub fn allocate_entity_id_locked(&self) -> u64 {
        self.resolver.lock().unwrap().allocate_entity_id()
    }

    pub fn allocate_in_partition_locked(&self, partition_id: u64) -> u64 {
        self.resolver.lock().unwrap().allocate_in_partition(partition_id)
    }

    pub fn allocate_t_locked(&self) -> u64 {
        self.resolver.lock().unwrap().allocate_t()
    }

    pub fn default_user_partition_locked(&self) -> u64 {
        self.resolver.lock().unwrap().default_user_partition()
    }

    pub fn partition_id_for_locked(&self, name: &str) -> Option<u64> {
        self.resolver.lock().unwrap().partition_id_for(name)
    }

    pub fn is_unique_attr_locked(&self, attr_name: &str) -> bool {
        let resolver = self.resolver.lock().unwrap();
        match resolver.lookup_attr(attr_name) {
            Some(aid) => resolver.is_unique(aid),
            None => false,
        }
    }

    pub fn lookup_entity_locked(&self, attr_name: &str, value: &Value, as_of_us: Option<u64>) -> Option<u64> {
        let resolver = self.resolver.lock().unwrap();
        let aid = resolver.lookup_attr(attr_name)?;
        let mode = keys::encode_mode_for(resolver.value_type_for(aid));
        let prefix = keys::avet_value_prefix(aid, value, mode);
        let datoms = self.collect_active_raw("avet", &prefix, as_of_us, &resolver);
        for d in &datoms {
            if !d.retracted {
                return Some(d.e);
            }
        }
        None
    }
}
