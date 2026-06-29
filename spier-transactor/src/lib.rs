// --- EAVT Transactor — loads spier-kvstore as KV dependency ---
pub mod eavt;
pub mod resolver;
pub mod keys;

pub use eavt::EavtEngine;
pub use resolver::Resolver;

// --- Spier FFI layer ---

use std::collections::HashMap;

use dynspire_commons::kvstore::{DynSpireKVStore, KVStoreEngine};
use dynspire_commons::transactor::cursor::CursorHandle;
use dynspire_commons::transactor::{Value, ValueType};

include!(concat!(env!("OUT_DIR"), "/transactor_spier.rs"));

struct TransactorState {
    eavt: EavtEngine,
}

fn init(config: &HashMap<String, String>) -> Result<TransactorState, String> {
    let kv = DynSpireKVStore::connect("spier_kvstore", config)?;
    let eavt = EavtEngine::new(kv);
    eavt.recover_journal();
    eavt.bootstrap_resolver();
    Ok(TransactorState { eavt })
}

impl TransactorEngine for TransactorState {
    // -----------------------------------------------------------------------
    // 1-9. KV — delegate to spier-kvstore via tower
    // -----------------------------------------------------------------------

    fn put(&self, cf: u32, key: &[u8]) -> Result<(), String> {
        self.eavt.kv.put(cf, key)
    }

    fn batch_put(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        self.eavt.kv.batch_put(cf, keys)
    }

    fn batch_write(&self, ops: &[u8]) -> Result<(), String> {
        self.eavt.kv.batch_write(ops)
    }

    fn replay(&self, cf: u32, keys: &[u8]) -> Result<(), String> {
        self.eavt.kv.replay(cf, keys)
    }

    fn get(&self, cf: u32, key: &[u8]) -> Result<bool, String> {
        self.eavt.kv.get(cf, key)
    }

    fn scan(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        self.eavt.kv.scan(cf, prefix)
    }

    fn scan_reverse(&self, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        self.eavt.kv.scan_reverse(cf, prefix)
    }

    fn items(&self, cf: u32) -> Result<Vec<u8>, String> {
        self.eavt.kv.items(cf)
    }

    fn open_cursor_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        self.eavt.kv.open_cursor_direct(cf, prefix)
    }

    fn open_cursor_reverse_direct(&self, cf: u32, prefix: &[u8]) -> Result<CursorHandle, String> {
        self.eavt.kv.open_cursor_reverse_direct(cf, prefix)
    }

    fn cursor_valid(&self, cursor: CursorHandle) -> Result<bool, String> {
        self.eavt.kv.cursor_valid(cursor)
    }

    fn cursor_current_key(&self, cursor: CursorHandle, buf: &mut Vec<u8>) -> Result<bool, String> {
        self.eavt.kv.cursor_current_key(cursor, buf)
    }

    fn cursor_step(&self, cursor: CursorHandle) -> Result<(), String> {
        self.eavt.kv.cursor_step(cursor)
    }

    fn cursor_seek(&self, cursor: CursorHandle, target: &[u8]) -> Result<(), String> {
        self.eavt.kv.cursor_seek(cursor, target)
    }

    fn cursor_skip_group(&self, cursor: CursorHandle, group_end: u32) -> Result<(), String> {
        self.eavt.kv.cursor_skip_group(cursor, group_end)
    }

    fn cursor_update_end(&self, cursor: CursorHandle, end: &[u8]) -> Result<(), String> {
        self.eavt.kv.cursor_update_end(cursor, end)
    }

    fn journal_put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.eavt.kv.journal_put(key, value)
    }

    fn journal_scan(&self) -> Result<Vec<u8>, String> {
        self.eavt.kv.journal_scan()
    }

    fn journal_size(&self) -> Result<u64, String> {
        self.eavt.kv.journal_size()
    }

    fn memtable_size(&self) -> Result<u64, String> {
        self.eavt.kv.memtable_size()
    }

    fn memtable_count(&self, cf: u32) -> Result<u64, String> {
        self.eavt.kv.memtable_count(cf)
    }

    fn path(&self) -> Result<String, String> {
        self.eavt.kv.path()
    }

    fn approximate_sizes(&self, cf: u32, start: &[u8], end: &[u8]) -> Result<u64, String> {
        self.eavt.kv.approximate_sizes(cf, start, end)
    }

    fn cf_stats(&self, cf: u32) -> Result<Vec<u8>, String> {
        self.eavt.kv.cf_stats(cf)
    }

    fn db_stats(&self) -> Result<Vec<u8>, String> {
        self.eavt.kv.db_stats()
    }

    fn gc_full(&self, dry_run: bool, nowait: bool) -> Result<Vec<u8>, String> {
        self.eavt.kv.gc_full(dry_run, nowait)
    }

    fn internal_status(&self, target: &str) -> Result<String, String> {
        self.eavt.kv.internal_status(target)
    }

    fn flush(&self) -> Result<(), String> {
        self.eavt.kv.flush()
    }

    fn close(&self) -> Result<(), String> {
        self.eavt.kv.close()
    }

    // -----------------------------------------------------------------------
    // 10-12. EAVT — delegate to EavtEngine
    // -----------------------------------------------------------------------

    fn eavt_save(&self, e_id: u64, attr: &str, v: Value, t: u64, as_of_us: u64) -> Result<(), String> {
        let as_of = if as_of_us == u64::MAX { None } else { Some(as_of_us) };
        self.eavt.save_at_t(e_id, attr, &v, t, as_of)
    }

    fn eavt_retract(&self, e_id: u64, attr: &str, v: Value, current_t: u64, as_of_us: u64) -> Result<(), String> {
        let ct = if current_t == u64::MAX { None } else { Some(current_t) };
        let as_of = if as_of_us == u64::MAX { None } else { Some(as_of_us) };
        self.eavt.retract_at_t(e_id, attr, &v, ct, as_of);
        Ok(())
    }

    fn eavt_declare_attr(&self, name: &str, value_type: ValueType, many: bool, current_t: u64) -> Result<u32, String> {
        let ct = if current_t == u64::MAX { None } else { Some(current_t) };
        Ok(self.eavt.declare_attr_with_t(name, value_type as u32, many, ct))
    }

    fn eavt_declare_attr_from_sql(&self, attr: &str, type_name: &str, many: bool, unique: bool, current_t: u64) -> Result<(), String> {
        let ct = if current_t == u64::MAX { None } else { Some(current_t) };
        self.eavt.declare_attr_from_sql_with_t(attr, type_name, many, unique, ct)?;
        Ok(())
    }

    fn eavt_declare_partition(&self, name: &str, current_t: u64) -> Result<u64, String> {
        let ct = if current_t == u64::MAX { None } else { Some(current_t) };
        self.eavt.declare_partition_with_t(name, ct)
    }

    fn eavt_allocate_tx(&self) -> Result<u64, String> {
        Ok(self.eavt.allocate_t_and_write_tx())
    }

    fn lookup_attr(&self, name: &str) -> Result<Option<u32>, String> {
        Ok(self.eavt.resolver.lock().unwrap().lookup_attr(name))
    }

    fn is_declared(&self, aid: u32) -> Result<bool, String> {
        Ok(self.eavt.resolver.lock().unwrap().is_declared(aid))
    }

    fn attr_name(&self, aid: u32) -> Result<String, String> {
        Ok(self.eavt.resolver.lock().unwrap().attr_name(aid))
    }

    fn value_type_for(&self, aid: u32) -> Result<Option<ValueType>, String> {
        Ok(self.eavt.resolver.lock().unwrap().value_type_for(aid).map(|vt| match vt {
            resolver::DB_TYPE_STRING => ValueType::String,
            resolver::DB_TYPE_REF => ValueType::Ref,
            resolver::DB_TYPE_LONG => ValueType::Long,
            resolver::DB_TYPE_KEYWORD => ValueType::Keyword,
            resolver::DB_TYPE_BOOLEAN => ValueType::Boolean,
            resolver::DB_TYPE_INSTANT => ValueType::Instant,
            resolver::DB_TYPE_BYTES => ValueType::Bytes,
            resolver::DB_TYPE_BLOB => ValueType::Blob,
            resolver::DB_TYPE_FLOAT => ValueType::Float,
            _ => ValueType::String,
        }))
    }

    fn is_many(&self, aid: u32) -> Result<bool, String> {
        Ok(self.eavt.resolver.lock().unwrap().is_many(aid))
    }

    fn is_unique(&self, aid: u32) -> Result<bool, String> {
        Ok(self.eavt.resolver.lock().unwrap().is_unique(aid))
    }

    fn is_unique_attr(&self, name: &str) -> Result<bool, String> {
        Ok(self.eavt.is_unique_attr_locked(name))
    }

    fn default_user_partition(&self) -> Result<u64, String> {
        Ok(self.eavt.default_user_partition_locked())
    }

    fn partition_id_for(&self, name: &str) -> Result<Option<u64>, String> {
        Ok(self.eavt.partition_id_for_locked(name))
    }

    fn lookup_entity(&self, attr_name: &str, value: Value) -> Result<Option<u64>, String> {
        Ok(self.eavt.lookup_entity_locked(attr_name, &value, None))
    }

    fn allocate_entity_id(&self) -> Result<u64, String> {
        Ok(self.eavt.allocate_entity_id_locked())
    }

    fn allocate_in_partition(&self, partition_id: u64) -> Result<u64, String> {
        Ok(self.eavt.allocate_in_partition_locked(partition_id))
    }

    fn allocate_t(&self) -> Result<u64, String> {
        Ok(self.eavt.allocate_t_locked())
    }
}

impl_transactor_spier!(TransactorState, init, "spier_transactor");
