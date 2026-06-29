use std::collections::{HashMap, HashSet};

// Re-export constants and pure functions from dynspire-commons
pub use dynspire_commons::transactor::resolver_consts::{
    BOOTSTRAP_FIRST_USER_ID,
    DB_IDENT_AID, DB_CARDINALITY_AID, DB_VALUE_TYPE_AID,
    DB_TYPE_STRING, DB_TYPE_REF, DB_TYPE_LONG, DB_TYPE_KEYWORD,
    DB_TYPE_BOOLEAN, DB_TYPE_INSTANT, DB_TYPE_BYTES, DB_TYPE_BLOB, DB_TYPE_FLOAT,
    DB_CARDINALITY_ONE, DB_CARDINALITY_MANY,
    DB_UNIQUE_AID, DB_UNIQUE_VALUE,
    DB_PART_ID_AID, DB_TX_INSTANT_AID,
    PART_DB, PART_TX, PART_USER,
    partition_of, seq_of, make_entity_id, normalize_attr,
};

const FIRST_CUSTOM_PARTITION: u64 = 64;

const BOOTSTRAP_SCHEMA: &[(&str, u32)] = &[
    ("db.ident", 1),
    ("db.cardinality", 2),
    ("db.valueType", 3),
    ("db.isComponent", 4),
    ("db.unique", 5),
    ("db.index", 6),
    ("db.fulltext", 7),
    ("db.noHistory", 8),
    ("db.txInstant", 9),
    ("db.type.string", 20),
    ("db.type.ref", 21),
    ("db.type.long", 22),
    ("db.type.keyword", 23),
    ("db.type.boolean", 24),
    ("db.type.instant", 25),
    ("db.type.bytes", 26),
    ("db.type.float", 27),
    ("db.type.blob", 28),
    ("db.cardinality.one", 35),
    ("db.cardinality.many", 36),
    ("db.unique.value", 37),
    ("db.unique.identity", 38),
    ("db.part/id", 39),
    ("db.part/db", 40),
    ("db.part/tx", 41),
    ("db.part/user", 42),
];
struct PartitionCounter {
    next_seq: u64,
}

pub struct Resolver {
    attrs: HashMap<String, u32>,
    attrs_rev: HashMap<u32, String>,
    next_aid: u32,
    next_t: u64,
    partitions: HashMap<u64, PartitionCounter>,
    partition_names: HashMap<String, u64>,
    next_custom_partition: u64,
    cardinality: HashMap<u32, bool>,
    declared: HashSet<u32>,
    value_types: HashMap<u32, u32>,
    unique_attrs: HashSet<u32>,
}

impl Resolver {
    pub fn new() -> Self {
        let mut r = Self {
            attrs: HashMap::new(),
            attrs_rev: HashMap::new(),
            next_aid: 1,
            next_t: 1000,
            partitions: HashMap::new(),
            partition_names: HashMap::new(),
            next_custom_partition: FIRST_CUSTOM_PARTITION,
            cardinality: HashMap::new(),
            declared: HashSet::new(),
            value_types: HashMap::new(),
            unique_attrs: HashSet::new(),
        };
        for &(name, aid) in BOOTSTRAP_SCHEMA {
            r.attrs.insert(name.to_string(), aid);
            r.attrs_rev.insert(aid, name.to_string());
            r.declared.insert(aid);
            if aid >= r.next_aid {
                r.next_aid = aid + 1;
            }
        }
        r.value_types.insert(DB_VALUE_TYPE_AID, DB_TYPE_REF);
        r.value_types.insert(DB_CARDINALITY_AID, DB_TYPE_REF);
        r.value_types.insert(DB_UNIQUE_AID, DB_TYPE_REF);
        r.value_types.insert(DB_IDENT_AID, DB_TYPE_STRING);
        r.value_types.insert(DB_PART_ID_AID, DB_TYPE_LONG);
        r.value_types.insert(DB_TX_INSTANT_AID, DB_TYPE_INSTANT);

        r.partitions.insert(PART_DB, PartitionCounter { next_seq: BOOTSTRAP_FIRST_USER_ID });
        r.partition_names.insert("db.part/db".into(), PART_DB);
        r.partitions.insert(PART_TX, PartitionCounter { next_seq: 1 });
        r.partition_names.insert("db.part/tx".into(), PART_TX);
        r.partitions.insert(PART_USER, PartitionCounter { next_seq: 1 });
        r.partition_names.insert("db.part/user".into(), PART_USER);

        r
    }

    pub fn resolve_entity(&self, name_or_id: impl Into<EntityInput>) -> u64 {
        match name_or_id.into() {
            EntityInput::Int(id) => id,
            EntityInput::Str(_) => panic!("string entities are not supported"),
        }
    }

    pub fn lookup_attr(&self, name: &str) -> Option<u32> {
        let normalized = normalize_attr(name).ok()?;
        self.attrs.get(&normalized).copied()
    }

    pub fn is_declared(&self, aid: u32) -> bool {
        self.declared.contains(&aid)
    }

    pub fn intern_attr(&mut self, name: &str) -> Result<u32, String> {
        let normalized = normalize_attr(name)?;
        if let Some(&aid) = self.attrs.get(&normalized) {
            return Ok(aid);
        }
        let eid = self.allocate_in_partition(PART_DB);
        let aid = eid as u32;
        self.next_aid = aid + 1;
        self.attrs.insert(normalized.clone(), aid);
        self.attrs_rev.insert(aid, normalized);
        Ok(aid)
    }

    pub fn declare_attr(&mut self, name: &str, value_type: u32, many: bool) -> Result<(u32, bool), String> {
        let normalized = normalize_attr(name)?;
        if let Some(&aid) = self.attrs.get(&normalized) {
            if self.declared.contains(&aid) {
                return Ok((aid, false));
            }
        }
        let seq = self.allocate_in_partition(PART_DB);
        let aid = seq as u32;
        self.next_aid = aid + 1;
        self.attrs.insert(normalized.clone(), aid);
        self.attrs_rev.insert(aid, normalized);
        self.declared.insert(aid);
        self.value_types.insert(aid, value_type);
        if many {
            self.cardinality.insert(aid, true);
        }
        Ok((aid, true))
    }

    pub fn value_type_for(&self, aid: u32) -> Option<u32> {
        self.value_types.get(&aid).copied()
    }

    pub fn attr_name(&self, aid: u32) -> String {
        self.attrs_rev.get(&aid).cloned().unwrap_or_else(|| aid.to_string())
    }

    pub fn load_attrs(&mut self, store_items: impl Iterator<Item = (Vec<u8>, Vec<u8>)>) {
        for (k, v) in store_items {
            let name = String::from_utf8(k).unwrap();
            if v.len() < 4 { continue; }
            let aid = u32::from_be_bytes([v[0], v[1], v[2], v[3]]);
            self.attrs.insert(name.clone(), aid);
            self.attrs_rev.insert(aid, name);
            if aid >= self.next_aid {
                self.next_aid = aid + 1;
            }
        }
    }

    pub fn find_max_ent_id(&mut self, store_items: impl Iterator<Item = (Vec<u8>, Vec<u8>)>) {
        for (k, _) in store_items {
            if k.len() == 8 {
                let eid = u64::from_be_bytes([k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]]);
                let p = partition_of(eid);
                let s = seq_of(eid);
                if let Some(counter) = self.partitions.get_mut(&p) {
                    if s >= counter.next_seq {
                        counter.next_seq = s + 1;
                    }
                }
            }
        }
    }

    pub fn init_ent_id_from_eavt(
        &mut self,
        sstable_keys: Vec<(Vec<u8>, Vec<u8>)>,
        memtable_items: Vec<(Vec<u8>, Vec<u8>)>,
    ) {
        let mut max_per_partition: HashMap<u64, u64> = HashMap::new();

        for (k, _) in sstable_keys {
            if k.len() >= 8 {
                let eid = u64::from_be_bytes([
                    k[0], k[1], k[2], k[3],
                    k[4], k[5], k[6], k[7],
                ]);
                let p = partition_of(eid);
                let s = seq_of(eid);
                max_per_partition.entry(p).and_modify(|m| *m = (*m).max(s)).or_insert(s);
            }
        }

        for (k, _) in memtable_items {
            if k.len() >= 8 {
                let eid = u64::from_be_bytes([
                    k[0], k[1], k[2], k[3],
                    k[4], k[5], k[6], k[7],
                ]);
                let p = partition_of(eid);
                let s = seq_of(eid);
                max_per_partition.entry(p).and_modify(|m| *m = (*m).max(s)).or_insert(s);
            }
        }

        for (&p, &max_s) in &max_per_partition {
            if let Some(counter) = self.partitions.get_mut(&p) {
                if max_s + 1 > counter.next_seq {
                    counter.next_seq = max_s + 1;
                }
            }
        }
    }

    pub fn set_cardinality(&mut self, aid: u32, many: bool) {
        if many {
            self.cardinality.insert(aid, true);
        } else {
            self.cardinality.remove(&aid);
        }
    }

    pub fn is_many(&self, aid: u32) -> bool {
        self.cardinality.contains_key(&aid)
    }

    pub fn is_unique(&self, aid: u32) -> bool {
        self.unique_attrs.contains(&aid)
    }

    pub fn set_unique(&mut self, aid: u32, unique: bool) {
        if unique {
            self.unique_attrs.insert(aid);
        } else {
            self.unique_attrs.remove(&aid);
        }
    }

    pub fn next_ent_id(&self) -> u64 {
        self.partitions.get(&PART_DB).map(|c| c.next_seq).unwrap_or(BOOTSTRAP_FIRST_USER_ID)
    }

    pub fn advance_past(&mut self, eid: u64) {
        let p = partition_of(eid);
        let s = seq_of(eid);
        if let Some(counter) = self.partitions.get_mut(&p) {
            if s >= counter.next_seq {
                counter.next_seq = s + 1;
            }
        }
    }

    pub fn allocate_t(&mut self) -> u64 {
        let t = self.next_t;
        self.next_t += 1;
        t
    }

    pub fn set_next_t(&mut self, t: u64) {
        if t >= self.next_t {
            self.next_t = t + 1;
        }
    }

    pub fn next_t(&self) -> u64 {
        self.next_t
    }

    pub fn allocate_entity_id(&mut self) -> u64 {
        self.allocate_in_partition(PART_USER)
    }

    pub fn allocate_in_partition(&mut self, partition_id: u64) -> u64 {
        let counter = self.partitions.get_mut(&partition_id)
            .unwrap_or_else(|| panic!("unknown partition: {}", partition_id));
        let seq = counter.next_seq;
        counter.next_seq += 1;
        make_entity_id(partition_id, seq)
    }

    pub fn allocate_schema_id(&mut self) -> u64 {
        self.allocate_in_partition(PART_DB)
    }

    pub fn partition_id_for(&self, name: &str) -> Option<u64> {
        self.partition_names.get(name).copied()
    }

    pub fn declare_partition(&mut self, name: &str) -> u64 {
        if let Some(&p) = self.partition_names.get(name) {
            return p;
        }
        let p = self.next_custom_partition;
        self.next_custom_partition += 1;
        self.partitions.insert(p, PartitionCounter { next_seq: 1 });
        self.partition_names.insert(name.to_string(), p);
        p
    }

    pub fn register_partition(&mut self, name: String, partition_id: u64) {
        if self.partition_names.contains_key(&name) {
            return;
        }
        if !self.partitions.contains_key(&partition_id) {
            self.partitions.insert(partition_id, PartitionCounter { next_seq: 1 });
        }
        self.partition_names.insert(name, partition_id);
        if partition_id >= FIRST_CUSTOM_PARTITION && partition_id >= self.next_custom_partition {
            self.next_custom_partition = partition_id + 1;
        }
    }

    pub fn set_partition_seq(&mut self, partition_id: u64, seq: u64) {
        if let Some(counter) = self.partitions.get_mut(&partition_id) {
            if seq > counter.next_seq {
                counter.next_seq = seq;
            }
        }
    }

    pub fn load_user_attr(&mut self, name: String, eid: u64, value_type: u32, many: bool, unique: bool) {
        let aid = eid as u32;
        self.attrs.insert(name.clone(), aid);
        self.attrs_rev.insert(aid, name);
        self.declared.insert(aid);
        self.value_types.insert(aid, value_type);
        if many {
            self.cardinality.insert(aid, true);
        }
        if unique {
            self.unique_attrs.insert(aid);
        }
        if let Some(counter) = self.partitions.get_mut(&partition_of(eid)) {
            if seq_of(eid) >= counter.next_seq {
                counter.next_seq = seq_of(eid) + 1;
            }
        }
        if aid >= self.next_aid {
            self.next_aid = aid + 1;
        }
    }

    pub fn default_user_partition(&self) -> u64 {
        PART_USER
    }
}

pub enum EntityInput {
    Int(u64),
    Str(String),
}

impl From<u64> for EntityInput {
    fn from(v: u64) -> Self { EntityInput::Int(v) }
}

impl From<&str> for EntityInput {
    fn from(v: &str) -> Self { EntityInput::Str(v.to_string()) }
}

impl From<String> for EntityInput {
    fn from(v: String) -> Self { EntityInput::Str(v) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_attr() {
        assert_eq!(normalize_attr("company.name").unwrap(), "company.name");
        assert_eq!(normalize_attr(":company/name").unwrap(), "company.name");
    }

    #[test]
    fn test_normalize_attr_rejects_bare() {
        assert!(normalize_attr("foo").is_err());
    }

    #[test]
    fn test_resolver_bootstrap() {
        let r = Resolver::new();
        assert_eq!(r.attrs.get("db.ident"), Some(&1u32));
        assert_eq!(r.attrs.get("db.type.ref"), Some(&21u32));
        assert_eq!(r.attrs.get("db.cardinality.many"), Some(&36u32));
        assert_eq!(r.attrs.get("db.part/id"), Some(&39u32));
        assert_eq!(r.attr_name(1), "db.ident");
        assert_eq!(r.attr_name(21), "db.type.ref");
    }

    #[test]
    fn test_resolver_intern_attr_new() {
        let mut r = Resolver::new();
        let aid = r.intern_attr("company.name").unwrap();
        assert_eq!(aid, 100);
        let aid2 = r.intern_attr("company.name").unwrap();
        assert_eq!(aid2, 100, "should return same id for same attr");
    }

    #[test]
    fn test_resolver_intern_attr_sequential() {
        let mut r = Resolver::new();
        let a1 = r.intern_attr("company.name").unwrap();
        let a2 = r.intern_attr("person.age").unwrap();
        assert_eq!(a1, 100);
        assert_eq!(a2, 101);
    }

    #[test]
    fn test_resolver_attr_name() {
        let mut r = Resolver::new();
        let aid = r.intern_attr("company.name").unwrap();
        assert_eq!(r.attr_name(aid), "company.name");
    }

    #[test]
    fn test_resolve_entity_int() {
        let r = Resolver::new();
        assert_eq!(r.resolve_entity(42u64), 42);
    }

    #[test]
    fn test_cardinality() {
        let mut r = Resolver::new();
        let aid = r.intern_attr("test.tags").unwrap();
        assert!(!r.is_many(aid));
        r.set_cardinality(aid, true);
        assert!(r.is_many(aid));
        r.set_cardinality(aid, false);
        assert!(!r.is_many(aid));
    }

    #[test]
    fn test_partition_bit_layout() {
        assert_eq!(partition_of(100), 0);
        assert_eq!(seq_of(100), 100);
        assert_eq!(partition_of(make_entity_id(4, 1)), 4);
        assert_eq!(seq_of(make_entity_id(4, 1)), 1);
        assert_eq!(partition_of(make_entity_id(64, 42)), 64);
        assert_eq!(seq_of(make_entity_id(64, 42)), 42);
    }

    #[test]
    fn test_allocate_in_partition_user() {
        let mut r = Resolver::new();
        let eid = r.allocate_entity_id();
        assert_eq!(partition_of(eid), PART_USER);
        assert_eq!(seq_of(eid), 1);
        let eid2 = r.allocate_entity_id();
        assert_eq!(seq_of(eid2), 2);
    }

    #[test]
    fn test_allocate_schema_partition() {
        let mut r = Resolver::new();
        let eid = r.allocate_schema_id();
        assert_eq!(partition_of(eid), PART_DB);
        assert_eq!(seq_of(eid), BOOTSTRAP_FIRST_USER_ID);
    }

    #[test]
    fn test_declare_partition_custom() {
        let mut r = Resolver::new();
        let p = r.declare_partition("cnpj");
        assert_eq!(p, 64);
        let p2 = r.declare_partition("empresa");
        assert_eq!(p2, 65);
        assert_eq!(r.declare_partition("cnpj"), 64, "idempotent");

        let eid = r.allocate_in_partition(p);
        assert_eq!(partition_of(eid), 64);
        assert_eq!(seq_of(eid), 1);
    }

    #[test]
    fn test_partition_id_lookup() {
        let mut r = Resolver::new();
        assert_eq!(r.partition_id_for("db.part/user"), Some(PART_USER));
        assert_eq!(r.partition_id_for("db.part/tx"), Some(PART_TX));
        assert_eq!(r.partition_id_for("nonexistent"), None);
        r.declare_partition("cnpj");
        assert_eq!(r.partition_id_for("cnpj"), Some(64));
    }
}
