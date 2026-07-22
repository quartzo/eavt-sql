pub mod constants;
pub mod eavt;
pub mod keys;
pub mod resolver;
pub mod resolver_consts;

pub use eavt::EavtEngine;
pub use resolver::Resolver;

use std::collections::HashMap;

use crate::storage_traits::CursorHandle;
use spier_value::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ValueType {
    String,
    Ref,
    Long,
    Keyword,
    Boolean,
    Instant,
    Bytes,
    Float,
    Blob,
}

pub fn value_type_to_eid(vt: ValueType) -> u32 {
    use resolver_consts::{
        DB_TYPE_BLOB, DB_TYPE_BOOLEAN, DB_TYPE_BYTES, DB_TYPE_FLOAT, DB_TYPE_INSTANT,
        DB_TYPE_KEYWORD, DB_TYPE_LONG, DB_TYPE_REF, DB_TYPE_STRING,
    };
    match vt {
        ValueType::String => DB_TYPE_STRING,
        ValueType::Ref => DB_TYPE_REF,
        ValueType::Long => DB_TYPE_LONG,
        ValueType::Keyword => DB_TYPE_KEYWORD,
        ValueType::Boolean => DB_TYPE_BOOLEAN,
        ValueType::Instant => DB_TYPE_INSTANT,
        ValueType::Bytes => DB_TYPE_BYTES,
        ValueType::Float => DB_TYPE_FLOAT,
        ValueType::Blob => DB_TYPE_BLOB,
    }
}

pub trait TransactorEngine: Send + Sync {
    fn put(&self, cf: u32, key: &[u8]) -> Result<(), String>;
    fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
    fn batch_write(&self, ops: &[u8]) -> Result<(), String>;
    fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String>;
    fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String>;
    fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
    fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String>;
    fn items(&self, cf: u32) -> Result<Vec<u8>, String>;
    fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
    fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String>;
    fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String>;
    fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String>;
    fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String>;
    fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String>;
    fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String>;
    fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String>;
    fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn journal_scan(&self) -> Result<Vec<u8>, String>;
    fn journal_size(&self) -> Result<u64, String>;
    fn memtable_size(&self) -> Result<u64, String>;
    fn memtable_count(&self, cf: u32) -> Result<u64, String>;
    fn path(&self) -> Result<String, String>;
    fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String>;
    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String>;
    fn db_stats(&self) -> Result<Vec<u8>, String>;
    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String>;
    fn internal_status(&self, target: &str) -> Result<String, String>;
    fn flush(&self) -> Result<(), String>;
    fn close(&self) -> Result<(), String>;

    fn eavt_save(
        &self,
        e_id: u64,
        attr: &str,
        v: Value,
        t: u64,
        as_of_us: u64,
    ) -> Result<(), String>;
    fn eavt_retract(
        &self,
        e_id: u64,
        attr: &str,
        v: Value,
        current_t: u64,
        as_of_us: u64,
    ) -> Result<(), String>;
    fn eavt_declare_attr(
        &self,
        name: &str,
        value_type: ValueType,
        many: bool,
        current_t: u64,
    ) -> Result<u32, String>;
    fn eavt_declare_attr_from_sql(
        &self,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        current_t: u64,
    ) -> Result<(), String>;
    fn eavt_declare_partition(&self, name: &str, current_t: u64) -> Result<u64, String>;
    fn eavt_allocate_tx(&self) -> Result<u64, String>;
    fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String>;
    fn is_declared(&self, aid: u32) -> Result<bool, String>;
    fn attr_name(&self, aid: u32) -> Result<String, String>;
    fn attr_name_opt(&self, aid: u32) -> Result<Option<String>, String>;
    fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String>;
    fn is_many(&self, aid: u32) -> Result<bool, String>;
    fn is_unique(&self, aid: u32) -> Result<bool, String>;
    fn is_unique_attr(&self, name: &str) -> Result<bool, String>;
    fn is_indexed(&self, aid: u32) -> Result<bool, String>;
    fn default_user_partition(&self) -> Result<u64, String>;
    fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String>;
    fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String>;
    fn allocate_entity_id(&self) -> Result<u64, String>;
    fn allocate_in_partition(&self, partition_id: u64) -> Result<u64, String>;
    fn allocate_t(&self) -> Result<u64, String>;
    fn resolve_as_of(&self, as_of_us: u64) -> Result<Option<u64>, String>;
}

pub struct TransactorState;

impl TransactorState {
    pub fn open(_config: &HashMap<String, String>) -> Result<Self, String> {
        todo!()
    }
}

impl TransactorEngine for TransactorState {
    fn put(&self, _cf: u32, _key: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn batch_put(&self, _cf: u32, _keys: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn batch_write(&self, _ops: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn replay(&self, _cf: u32, _keys: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn get(&self, _cf: u32, _key: &[u8]) -> Result<bool, String> {
        todo!()
    }
    fn scan(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn scan_reverse(&self, _cf: u32, _prefix: &[u8]) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn items(&self, _cf: u32) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn open_cursor_direct(&self, _cf: u32, _prefix: &[u8]) -> Result<CursorHandle, String> {
        todo!()
    }
    fn open_cursor_reverse_direct(&self, _cf: u32, _prefix: &[u8]) -> Result<CursorHandle, String> {
        todo!()
    }
    fn cursor_valid(&self, _cursor: CursorHandle) -> Result<bool, String> {
        todo!()
    }
    fn cursor_current_key(
        &self,
        _cursor: CursorHandle,
        _buf: &mut Vec<u8>,
    ) -> Result<bool, String> {
        todo!()
    }
    fn cursor_step(&self, _cursor: CursorHandle) -> Result<(), String> {
        todo!()
    }
    fn cursor_seek(&self, _cursor: CursorHandle, _target: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn cursor_skip_group(&self, _cursor: CursorHandle, _group_end: u32) -> Result<(), String> {
        todo!()
    }
    fn cursor_update_end(&self, _cursor: CursorHandle, _end: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn journal_put(&self, _key: &[u8], _value: &[u8]) -> Result<(), String> {
        todo!()
    }
    fn journal_scan(&self) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn journal_size(&self) -> Result<u64, String> {
        todo!()
    }
    fn memtable_size(&self) -> Result<u64, String> {
        todo!()
    }
    fn memtable_count(&self, _cf: u32) -> Result<u64, String> {
        todo!()
    }
    fn path(&self) -> Result<String, String> {
        todo!()
    }
    fn approximate_sizes(
        &self,
        _cf: u32,
        _start: &[u8],
        _end: &[u8],
    ) -> Result<u64, String> {
        todo!()
    }
    fn cf_stats(&self, _cf: u32) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn db_stats(&self) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn gc_full(&self, _dry_run: bool, _nowait: bool) -> Result<Vec<u8>, String> {
        todo!()
    }
    fn internal_status(&self, _target: &str) -> Result<String, String> {
        todo!()
    }
    fn flush(&self) -> Result<(), String> {
        todo!()
    }
    fn close(&self) -> Result<(), String> {
        todo!()
    }

    fn eavt_save(
        &self,
        _e_id: u64,
        _attr: &str,
        _v: Value,
        _t: u64,
        _as_of_us: u64,
    ) -> Result<(), String> {
        todo!()
    }
    fn eavt_retract(
        &self,
        _e_id: u64,
        _attr: &str,
        _v: Value,
        _current_t: u64,
        _as_of_us: u64,
    ) -> Result<(), String> {
        todo!()
    }
    fn eavt_declare_attr(
        &self,
        _name: &str,
        _value_type: ValueType,
        _many: bool,
        _current_t: u64,
    ) -> Result<u32, String> {
        todo!()
    }
    fn eavt_declare_attr_from_sql(
        &self,
        _attr: &str,
        _type_name: &str,
        _many: bool,
        _unique: bool,
        _current_t: u64,
    ) -> Result<(), String> {
        todo!()
    }
    fn eavt_declare_partition(
        &self,
        _name: &str,
        _current_t: u64,
    ) -> Result<u64, String> {
        todo!()
    }
    fn eavt_allocate_tx(&self) -> Result<u64, String> {
        todo!()
    }
    fn lookup_attr(&self, _name: &str) -> Result<Option<u32>, String> {
        todo!()
    }
    fn is_declared(&self, _aid: u32) -> Result<bool, String> {
        todo!()
    }
    fn attr_name(&self, _aid: u32) -> Result<String, String> {
        todo!()
    }
    fn attr_name_opt(&self, _aid: u32) -> Result<Option<String>, String> {
        todo!()
    }
    fn value_type_for(&self, _aid: u32) -> Result<Option<ValueType>, String> {
        todo!()
    }
    fn is_many(&self, _aid: u32) -> Result<bool, String> {
        todo!()
    }
    fn is_unique(&self, _aid: u32) -> Result<bool, String> {
        todo!()
    }
    fn is_unique_attr(&self, _name: &str) -> Result<bool, String> {
        todo!()
    }
    fn is_indexed(&self, _aid: u32) -> Result<bool, String> {
        todo!()
    }
    fn default_user_partition(&self) -> Result<u64, String> {
        todo!()
    }
    fn partition_id_for(&self, _name: &str) -> Result<Option<u64>, String> {
        todo!()
    }
    fn lookup_entity(&self, _attr_name: &str, _value: Value) -> Result<Option<u64>, String> {
        todo!()
    }
    fn allocate_entity_id(&self) -> Result<u64, String> {
        todo!()
    }
    fn allocate_in_partition(&self, _partition_id: u64) -> Result<u64, String> {
        todo!()
    }
    fn allocate_t(&self) -> Result<u64, String> {
        todo!()
    }
    fn resolve_as_of(&self, _as_of_us: u64) -> Result<Option<u64>, String> {
        todo!()
    }
}
