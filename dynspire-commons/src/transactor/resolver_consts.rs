pub const BOOTSTRAP_FIRST_USER_ID: u64 = 100;

pub const DB_IDENT_AID: u32 = 1;
pub const DB_CARDINALITY_AID: u32 = 2;
pub const DB_VALUE_TYPE_AID: u32 = 3;

pub const DB_TYPE_STRING: u32 = 0;
pub const DB_TYPE_REF: u32 = 1;
pub const DB_TYPE_LONG: u32 = 2;
pub const DB_TYPE_KEYWORD: u32 = 3;
pub const DB_TYPE_BOOLEAN: u32 = 4;
pub const DB_TYPE_INSTANT: u32 = 5;
pub const DB_TYPE_BYTES: u32 = 6;
pub const DB_TYPE_FLOAT: u32 = 7;
pub const DB_TYPE_BLOB: u32 = 8;
pub const DB_CARDINALITY_ONE: u32 = 35;
pub const DB_CARDINALITY_MANY: u32 = 36;
pub const DB_UNIQUE_AID: u32 = 5;
pub const DB_UNIQUE_VALUE: u32 = 37;

pub const DB_PART_ID_AID: u32 = 39;
pub const DB_TX_INSTANT_AID: u32 = 9;

pub const PART_DB: u64 = 0;
pub const PART_TX: u64 = 3;
pub const PART_USER: u64 = 4;

const PARTITION_SHIFT: u32 = 44;
const SEQ_MASK: u64 = 0xFFFFFFFFFFF; // 44 bits

pub fn partition_of(eid: u64) -> u64 {
    eid >> PARTITION_SHIFT
}

pub fn seq_of(eid: u64) -> u64 {
    eid & SEQ_MASK
}

pub fn make_entity_id(partition_id: u64, seq: u64) -> u64 {
    (partition_id << PARTITION_SHIFT) | seq
}

pub fn normalize_attr(name: &str) -> Result<String, String> {
    if name.starts_with(':') && name.contains('/') {
        Ok(name[1..].replace('/', "."))
    } else if !name.contains('.') {
        Err(format!("attribute name must include namespace (e.g. 'company.name'), got {:?}", name))
    } else {
        Ok(name.to_string())
    }
}
