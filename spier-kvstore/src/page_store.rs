use std::any::Any;
use std::collections::HashSet;

use crate::error::TransactorResult;

pub trait PageStore: Send + Sync {
    /// Get all keys from leaf pages whose range overlaps the given prefix.
    /// Traverses the B-tree on demand — no global in-memory index.
    fn get_keys_in_prefix(&self, cf: usize, prefix: &[u8]) -> TransactorResult<Vec<Vec<u8>>>;

    /// For flush: given new MemTable keys for a CF, find affected existing leaf pages,
    /// load their keys, and return (existing_keys, affected_boundary_keys).
    fn get_keys_for_merge(
        &self,
        cf: usize,
        new_keys: &[Vec<u8>],
    ) -> TransactorResult<(Vec<Vec<u8>>, Vec<Vec<u8>>)>;

    /// Approximate number of leaf pages overlapping [start, end) range.
    fn page_count_in_range(
        &self,
        cf: usize,
        start: &[u8],
        end: &[u8],
    ) -> TransactorResult<usize>;

    /// Total number of leaf pages in a CF.
    fn page_count(&self, cf: usize) -> TransactorResult<usize>;

    /// Point lookup: does this key exist in any leaf page?
    fn key_exists(&self, cf: usize, key: &[u8]) -> TransactorResult<bool>;

    fn commit(
        &self,
        puts: &[(usize, Vec<u8>, Vec<u8>)],
        deletes: &[(usize, Vec<u8>)],
        clear_journal: bool,
    ) -> TransactorResult<()>;

    /// COW merge: recursively descend tree per CF, merge sorted_keys at leaf level,
    /// only rewrite affected branches. Unchanged subtrees keep their blob UUIDs.
    fn commit_merge(
        &self,
        keys_by_cf: &[(usize, Vec<Vec<u8>>)],
        clear_journal: bool,
    ) -> TransactorResult<()>;

    fn journal_put(&self, key: &[u8], value: &[u8]) -> TransactorResult<()>;
    fn journal_scan(&self) -> TransactorResult<Vec<u8>>;

    /// Collect all live blob UUIDs (index pages + leaf pages) reachable from
    /// the current root. Used by GC.
    fn collect_live_uuids(&self) -> TransactorResult<HashSet<[u8; 16]>>;

    fn cf_stats(&self, cf: usize) -> TransactorResult<CfStatsData>;
    fn db_stats(&self) -> TransactorResult<DbStatsData>;

    /// Describe internal B-tree structure for operational inspection.
    /// `target`: "btree" (all CFs), "btree:eavt"/"btree:aevt"/"btree:avet"/"btree:vaet" (specific CF).
    fn internal_status(&self, target: &str) -> TransactorResult<String>;

    fn as_any(&self) -> &dyn Any;
}

pub struct CfStatsData {
    pub num_keys: u64,
    pub live_size: u64,
    pub sst_size: u64,
    pub num_sst: u64,
    pub memtable_size: u64,
}

pub struct DbStatsData {
    pub total_sst_size: u64,
    pub total_live_size: u64,
}

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
