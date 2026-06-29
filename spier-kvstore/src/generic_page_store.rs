use std::any::Any;
use std::collections::{BTreeSet, HashSet};
use std::sync::{Mutex, RwLock};

use crate::blob_store::make_root_name;
use crate::error::{TransactorError, TransactorResult};
use crate::page_store::{CfStatsData, DbStatsData, PageStore};
use crate::pages;
use crate::blobstore::BlobStoreEngine;
use crate::journal::JournalEngine;

const ROOT_MAGIC: &[u8; 4] = b"EVT1";
const ROOT_VERSION: u16 = 2;

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];

const INDEX_PAGE_MAX_SIZE: usize = 256 * 1024;

fn fmt_uuid(uuid: &[u8; 16]) -> String {
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        uuid[0], uuid[1], uuid[2], uuid[3],
        uuid[4], uuid[5], uuid[6], uuid[7],
        uuid[8], uuid[9], uuid[10], uuid[11],
        uuid[12], uuid[13], uuid[14], uuid[15],
    )
}

fn fmt_hex(data: &[u8], max_bytes: usize) -> String {
    let n = data.len().min(max_bytes);
    let mut s = String::with_capacity(n * 2);
    for &b in &data[..n] {
        s.push_str(&format!("{:02x}", b));
    }
    if data.len() > max_bytes {
        s.push_str("..");
    }
    s
}

/// Diagnose a page deserialization failure: report basic page info and
/// whether the data is actually a valid index page (type mismatch).
fn diagnose_page(data: &[u8], uuid: &[u8; 16], leaf_err: &str) -> String {
    let count = if data.len() >= 2 {
        u16::from_be_bytes([data[0], data[1]]) as usize
    } else {
        0
    };
    let index_info = match deserialize_index_page(data) {
        Ok(entries) => format!("index_page=OK({} entries)", entries.len()),
        Err(ie) => format!("index_page=FAIL({ie})"),
    };
    format!(
        "page deserialize: {leaf_err} | uuid={} data_len={} count={} first16={} {}",
        fmt_uuid(uuid),
        data.len(),
        count,
        fmt_hex(data, 16),
        index_info,
    )
}

fn compress(data: &[u8]) -> Result<Vec<u8>, String> {
    zstd::encode_all(data, 1).map_err(|e| format!("zstd compress: {e}"))
}

fn decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() >= 4 && data[0..4] == ZSTD_MAGIC {
        zstd::decode_all(data).map_err(|e| format!("zstd decompress: {e}"))
    } else {
        Ok(data.to_vec())
    }
}

fn blob_put(blobs: &dyn BlobStoreEngine, data: &[u8]) -> Result<[u8; 16], String> {
    let compressed = compress(data)?;
    blobs.put(&compressed)
}

fn blob_get(blobs: &dyn BlobStoreEngine, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
    match blobs.get(id)? {
        Some(data) => Ok(Some(decompress(&data)?)),
        None => Ok(None),
    }
}

fn blob_put_root(blobs: &dyn BlobStoreEngine, name: &str, data: &[u8]) -> Result<(), String> {
    let compressed = compress(data)?;
    blobs.put_root(name, &compressed)
}

fn blob_get_root(blobs: &dyn BlobStoreEngine, name: &str) -> Result<Option<Vec<u8>>, String> {
    match blobs.get_root(name)? {
        Some(data) => Ok(Some(decompress(&data)?)),
        None => Ok(None),
    }
}

// ── Index page serialization (prefix-compressed, same varint scheme as leaf pages) ──

fn common_prefix_len(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b.iter()).take_while(|(x, y)| x == y).count()
}

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

fn serialize_index_page(entries: &[(Vec<u8>, [u8; 16])]) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&(entries.len() as u16).to_be_bytes());
    let mut prev: &[u8] = &[];
    for (key, uuid) in entries {
        let plen = common_prefix_len(prev, key);
        let suffix = &key[plen..];
        write_varint(&mut buf, plen);
        write_varint(&mut buf, suffix.len());
        buf.extend_from_slice(suffix);
        buf.extend_from_slice(uuid);
        prev = key;
    }
    buf
}

fn deserialize_index_page(data: &[u8]) -> Result<Vec<(Vec<u8>, [u8; 16])>, String> {
    if data.len() < 2 {
        return Err("index page too short".into());
    }
    let count = u16::from_be_bytes(data[0..2].try_into().unwrap()) as usize;
    let mut entries = Vec::with_capacity(count);
    let mut offset = 2;
    let mut prev: Vec<u8> = Vec::new();
    for _ in 0..count {
        let (plen, next) = read_varint(data, offset)?;
        offset = next;
        let (slen, next) = read_varint(data, offset)?;
        offset = next;
        if offset + slen + 16 > data.len() {
            return Err("truncated index entry".into());
        }
        let mut key = Vec::with_capacity(plen + slen);
        key.extend_from_slice(&prev[..plen.min(prev.len())]);
        key.extend_from_slice(&data[offset..offset + slen]);
        offset += slen;
        let mut uuid = [0u8; 16];
        uuid.copy_from_slice(&data[offset..offset + 16]);
        offset += 16;
        prev = key.clone();
        entries.push((key, uuid));
    }
    Ok(entries)
}

// ── Root file format (v2): per-CF tree root UUID + height ──

fn serialize_root_v2(trees: &[CfTree]) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(ROOT_MAGIC);
    buf.extend_from_slice(&ROOT_VERSION.to_be_bytes());
    buf.extend_from_slice(&(trees.len() as u16).to_be_bytes());
    for tree in trees {
        buf.extend_from_slice(&tree.root_uuid);
        buf.push(tree.height);
        buf.extend_from_slice(&tree.num_leaves.to_be_bytes());
    }
    buf
}

fn deserialize_root_v2(data: &[u8]) -> TransactorResult<Vec<CfTree>> {
    if data.len() < 8 || &data[0..4] != ROOT_MAGIC {
        return Err(TransactorError::Format("invalid root".into()));
    }
    let version = u16::from_be_bytes([data[4], data[5]]);
    if version != ROOT_VERSION {
        return Err(TransactorError::Format(format!(
            "unsupported root version {version}, expected {ROOT_VERSION}"
        )));
    }
    let num_cf = u16::from_be_bytes([data[6], data[7]]) as usize;
    if data.len() < 8 + num_cf * (16 + 1 + 4) {
        return Err(TransactorError::Format("truncated root".into()));
    }
    let mut trees = Vec::with_capacity(num_cf);
    let mut off = 8;
    for _ in 0..num_cf {
        let mut uuid = [0u8; 16];
        uuid.copy_from_slice(&data[off..off + 16]);
        off += 16;
        let height = data[off];
        off += 1;
        let num_leaves = u32::from_be_bytes([
            data[off],
            data[off + 1],
            data[off + 2],
            data[off + 3],
        ]);
        off += 4;
        trees.push(CfTree {
            root_uuid: uuid,
            height,
            num_leaves,
        });
    }
    Ok(trees)
}

pub use dynspire_commons::transactor::types::GcFullResult;

fn parse_root_us(name: &str) -> Option<i64> {
    let hex = name.strip_prefix("root_")?;
    let bits = u64::from_str_radix(hex, 16).ok()?;
    let neg = bits as i64;
    Some(-neg)
}

fn prefix_end(prefix: &[u8]) -> Option<Vec<u8>> {
    let mut e = prefix.to_vec();
    while let Some(last) = e.pop() {
        if last < 0xFF {
            e.push(last + 1);
            return Some(e);
        }
    }
    None
}

fn find_prefix_range(entries: &[(Vec<u8>, [u8; 16])], prefix: &[u8]) -> (usize, usize) {
    if prefix.is_empty() {
        return (0, entries.len());
    }
    let pe = prefix_end(prefix);
    let start = entries.partition_point(|(k, _)| k.as_slice() < prefix);
    let start = start.saturating_sub(1);
    let end = match &pe {
        Some(pe) => entries.partition_point(|(k, _)| k.as_slice() < pe.as_slice()),
        None => entries.len(),
    };
    (start.min(end), end)
}

#[derive(Clone)]
struct CfTree {
    root_uuid: [u8; 16],
    height: u8,
    num_leaves: u32,
}

impl CfTree {
    fn empty() -> Self {
        Self {
            root_uuid: [0u8; 16],
            height: 0,
            num_leaves: 0,
        }
    }
}

struct Inner {
    trees: Vec<CfTree>,
    num_cf: usize,
    read_only: bool,
    current_root: String,
}

fn page_keys_size(keys: &[Vec<u8>]) -> usize {
    keys.iter().map(|k| k.len()).sum::<usize>() + keys.len() * 8
}

struct PageCache {
    map: lru::LruCache<[u8; 16], Vec<Vec<u8>>>,
    max_bytes: usize,
    current_bytes: usize,
}

impl PageCache {
    fn new(max_bytes: usize) -> Self {
        Self {
            map: lru::LruCache::unbounded(),
            max_bytes,
            current_bytes: 0,
        }
    }

    fn get(&mut self, uuid: &[u8; 16]) -> Option<Vec<Vec<u8>>> {
        self.map.get(uuid).cloned()
    }

    fn put(&mut self, uuid: [u8; 16], keys: Vec<Vec<u8>>) {
        let sz = page_keys_size(&keys);
        if self.map.contains(&uuid) {
            return;
        }
        while self.current_bytes + sz > self.max_bytes {
            match self.map.pop_lru() {
                Some((_, old_keys)) => {
                    self.current_bytes -= page_keys_size(&old_keys);
                }
                None => break,
            }
        }
        if sz <= self.max_bytes {
            self.current_bytes += sz;
            self.map.put(uuid, keys);
        }
    }
}

pub struct GenericPageStore {
    blobs: Box<dyn BlobStoreEngine + Send + Sync>,
    journal: Option<Box<dyn JournalEngine + Send + Sync>>,
    inner: RwLock<Inner>,
    page_cache: Mutex<PageCache>,
}

impl GenericPageStore {
    pub fn open(
        blobs: Box<dyn BlobStoreEngine + Send + Sync>,
        journal: Option<Box<dyn JournalEngine + Send + Sync>>,
        num_cf: usize,
        page_cache_bytes: usize,
    ) -> TransactorResult<Self> {
        let roots = blobs.list_roots()?;
        let (trees, current_root) = if let Some(latest) = roots.first() {
            let root_data = blob_get_root(blobs.as_ref(), latest)?
                .ok_or_else(|| TransactorError::Format("root listed but unreadable".into()))?;
            let mut trees = deserialize_root_v2(&root_data)?;
            while trees.len() < num_cf {
                trees.push(CfTree::empty());
            }
            (trees, latest.clone())
        } else {
            let trees = vec![CfTree::empty(); num_cf];
            let name = make_root_name();
            blob_put_root(blobs.as_ref(), &name, &serialize_root_v2(&trees))?;
            (trees, name)
        };

        Ok(Self {
            blobs,
            journal,
            inner: RwLock::new(Inner {
                trees,
                num_cf,
                read_only: false,
                current_root,
            }),
            page_cache: Mutex::new(PageCache::new(page_cache_bytes)),
        })
    }

    pub fn open_read_only(
        blobs: Box<dyn BlobStoreEngine + Send + Sync>,
        journal: Option<Box<dyn JournalEngine + Send + Sync>>,
        num_cf: usize,
        page_cache_bytes: usize,
    ) -> TransactorResult<Self> {
        let roots = blobs.list_roots()?;
        let latest = roots.first().ok_or_else(|| {
            TransactorError::InvalidArg("database not found".into())
        })?;
        let root_data = blob_get_root(blobs.as_ref(), latest)?
            .ok_or_else(|| TransactorError::Format("root listed but unreadable".into()))?;
        let mut trees = deserialize_root_v2(&root_data)?;
        while trees.len() < num_cf {
            trees.push(CfTree::empty());
        }

        Ok(Self {
            blobs,
            journal,
            inner: RwLock::new(Inner {
                trees,
                num_cf,
                read_only: true,
                current_root: latest.clone(),
            }),
            page_cache: Mutex::new(PageCache::new(page_cache_bytes)),
        })
    }

    pub fn reload_root(&self) -> TransactorResult<()> {
        let mut inner = self.inner.write().unwrap();
        let roots = self.blobs.list_roots()?;
        let latest = roots.first().ok_or_else(|| {
            TransactorError::Format("no root found during reload".into())
        })?;
        let root_data = blob_get_root(self.blobs.as_ref(), latest)?
            .ok_or_else(|| TransactorError::Format("root listed but unreadable".into()))?;
        let trees = deserialize_root_v2(&root_data)?;
        for (cf, tree) in trees.iter().enumerate() {
            if cf < inner.num_cf {
                inner.trees[cf] = tree.clone();
            }
        }
        inner.current_root = latest.clone();
        Ok(())
    }

    pub fn has_old_roots(&self, max_age_secs: u64, max_root_count: usize) -> bool {
        let roots = self.blobs.list_roots().unwrap_or_default();
        if roots.len() <= 1 {
            return false;
        }
        if max_root_count > 0 && roots.len() > max_root_count {
            return true;
        }
        let latest_us = parse_root_us(&roots[0]).unwrap_or(0);
        let max_age_us: i64 = (max_age_secs as i64) * 1_000_000;
        roots.iter().skip(1).any(|r| {
            let us = parse_root_us(r).unwrap_or(0);
            latest_us - us > max_age_us
        })
    }

    pub fn gc_full(&self, dry_run: bool) -> TransactorResult<GcFullResult> {
        self.gc_full_with_age(dry_run, 12 * 3600, 0)
    }

    pub fn gc_full_with_age(&self, dry_run: bool, max_age_secs: u64, max_root_count: usize) -> TransactorResult<GcFullResult> {
        let inner = self.inner.read().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }

        let roots = self.blobs.list_roots()?;
        let roots_scanned = roots.len();

        if roots.is_empty() {
            return Ok(GcFullResult {
                roots_scanned: 0,
                roots_removed: 0,
                blobs_scanned: 0,
                blobs_removed: 0,
                live_uuids: 0,
                dry_run,
            });
        }

        let latest_us = parse_root_us(&roots[0]).unwrap_or(0);
        let max_age_us: i64 = (max_age_secs as i64) * 1_000_000;

        let mut roots_to_keep: Vec<String> = Vec::new();
        let mut roots_to_remove: Vec<String> = Vec::new();
        for (idx, name) in roots.iter().enumerate() {
            let us = parse_root_us(name).unwrap_or(0);
            let too_old = latest_us - us > max_age_us;
            let beyond_count = max_root_count > 0 && idx >= max_root_count;
            if too_old || beyond_count {
                roots_to_remove.push(name.clone());
            } else {
                roots_to_keep.push(name.clone());
            }
        }

        let mut live_uuids: HashSet<[u8; 16]> = HashSet::new();
        for name in &roots_to_keep {
            if let Some(data) = blob_get_root(self.blobs.as_ref(), name)? {
                if let Ok(trees) = deserialize_root_v2(&data) {
                    for tree in &trees {
                        self.collect_tree_uuids(tree, &mut live_uuids)?;
                    }
                }
            }
        }

        let roots_removed = roots_to_remove.len();
        if !dry_run {
            for name in &roots_to_remove {
                let _ = self.blobs.delete_root(name);
            }
        }

        let all_blobs = self.blobs.list()?;
        let blobs_scanned = all_blobs.len();
        let mut blobs_removed = 0usize;
        for id in all_blobs {
            if !live_uuids.contains(&id) {
                if !dry_run {
                    let _ = self.blobs.delete(id);
                }
                blobs_removed += 1;
            }
        }
        let live_count = live_uuids.len();
        drop(live_uuids);

        Ok(GcFullResult {
            roots_scanned,
            roots_removed,
            blobs_scanned,
            blobs_removed,
            live_uuids: live_count,
            dry_run,
        })
    }

    fn dump_tree_node(
        &self,
        uuid: [u8; 16],
        height: u8,
        depth: usize,
        out: &mut String,
    ) -> TransactorResult<()> {
        let indent = "  ".repeat(depth);
        if height == 0 {
            let keys = self.load_leaf_keys(&uuid)?;
            let n = keys.len();
            let first = keys.first().map(|k| fmt_hex(k, 16)).unwrap_or_default();
            let last = keys.last().map(|k| fmt_hex(k, 16)).unwrap_or_default();
            out.push_str(&format!(
                "{indent}leaf {} keys={n} range={first}..{last}\n",
                fmt_uuid(&uuid),
            ));
        } else {
            let data = match blob_get(self.blobs.as_ref(), uuid)? {
                Some(d) => d,
                None => {
                    out.push_str(&format!("{indent}[{}] blob not found\n", fmt_uuid(&uuid)));
                    return Ok(());
                }
            };
            let entries = deserialize_index_page(&data)
                .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
            let n = entries.len();
            let first = entries.first().map(|(k, _)| fmt_hex(k, 16)).unwrap_or_default();
            let last = entries.last().map(|(k, _)| fmt_hex(k, 16)).unwrap_or_default();
            out.push_str(&format!(
                "{indent}index {} entries={n} range={first}..{last}\n",
                fmt_uuid(&uuid),
            ));
            for (_boundary_key, child_uuid) in &entries {
                self.dump_tree_node(*child_uuid, height - 1, depth + 1, out)?;
            }
        }
        Ok(())
    }

    /// Recursively collect all live UUIDs (index pages + leaf pages) from a tree.
    fn collect_tree_uuids(
        &self,
        tree: &CfTree,
        live: &mut HashSet<[u8; 16]>,
    ) -> TransactorResult<()> {
        if tree.root_uuid == [0u8; 16] {
            return Ok(());
        }
        live.insert(tree.root_uuid);
        if tree.height == 0 {
            return Ok(());
        }
        let data = match blob_get(self.blobs.as_ref(), tree.root_uuid)? {
            Some(d) => d,
            None => return Ok(()),
        };
        let entries = match deserialize_index_page(&data) {
            Ok(e) => e,
            Err(_) => return Ok(()),
        };
        for (_, child_uuid) in &entries {
            live.insert(*child_uuid);
            if tree.height > 1 {
                let child_tree = CfTree {
                    root_uuid: *child_uuid,
                    height: tree.height - 1,
                    num_leaves: 0,
                };
                self.collect_tree_uuids(&child_tree, live)?;
            }
        }
        Ok(())
    }

    /// Load all entries from the root index page of a CF (height >= 1).
    /// For height 0, returns empty (single leaf page has no index).
    fn load_root_entries(&self, tree: &CfTree) -> TransactorResult<Vec<(Vec<u8>, [u8; 16])>> {
        if tree.root_uuid == [0u8; 16] || tree.height == 0 {
            return Ok(Vec::new());
        }
        let data = blob_get(self.blobs.as_ref(), tree.root_uuid)?
            .ok_or_else(|| TransactorError::Internal("root index blob not found".into()))?;
        deserialize_index_page(&data)
            .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))
    }

    /// Load and deserialize a leaf page, with LRU caching by UUID.
    fn load_leaf_keys(&self, uuid: &[u8; 16]) -> TransactorResult<Vec<Vec<u8>>> {
        {
            let mut cache = self.page_cache.lock().unwrap();
            if let Some(keys) = cache.get(uuid) {
                return Ok(keys);
            }
        }
        let data = blob_get(self.blobs.as_ref(), *uuid)?
            .ok_or_else(|| TransactorError::Internal("leaf blob not found".into()))?;
        let keys = pages::deserialize_page(&data).map_err(|e| {
            TransactorError::Internal(diagnose_page(&data, uuid, &e))
        })?;
        let mut cache = self.page_cache.lock().unwrap();
        cache.put(*uuid, keys.clone());
        Ok(keys)
    }

    /// Load leaf keys checking cache but NOT populating it.
    /// Used in flush/merge path — pages are about to be replaced (dead UUIDs).
    fn load_leaf_keys_noput(&self, uuid: &[u8; 16]) -> TransactorResult<Vec<Vec<u8>>> {
        {
            let mut cache = self.page_cache.lock().unwrap();
            if let Some(keys) = cache.get(uuid) {
                return Ok(keys);
            }
        }
        let data = blob_get(self.blobs.as_ref(), *uuid)?
            .ok_or_else(|| TransactorError::Internal("leaf blob not found".into()))?;
        let keys = pages::deserialize_page(&data).map_err(|e| {
            TransactorError::Internal(diagnose_page(&data, uuid, &e))
        })?;
        Ok(keys)
    }

    /// Recursively collect keys from leaf pages starting at a given index page UUID.
    fn collect_keys_from_index(
        &self,
        page_uuid: [u8; 16],
        height: u8,
        prefix: &[u8],
    ) -> TransactorResult<Vec<Vec<u8>>> {
        let data = blob_get(self.blobs.as_ref(), page_uuid)?
            .ok_or_else(|| TransactorError::Internal("index blob not found".into()))?;
        let entries = deserialize_index_page(&data)
            .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;

        let (start, end) = find_prefix_range(&entries, prefix);
        let mut result = Vec::new();
        for (_, child_uuid) in &entries[start..end] {
            if height == 1 {
                let keys = self.load_leaf_keys(child_uuid)?;
                result.extend(keys.into_iter().filter(|k| k.starts_with(prefix)));
            } else {
                result.extend(self.collect_keys_from_index(*child_uuid, height - 1, prefix)?);
            }
        }
        Ok(result)
    }

    /// Find leaf pages affected by new_keys (for flush merge).
    /// Returns (boundary_key, leaf_uuid) pairs.
    fn find_affected_leaves(
        &self,
        tree: &CfTree,
        new_keys: &[Vec<u8>],
    ) -> TransactorResult<Vec<(Vec<u8>, [u8; 16])>> {
        if tree.root_uuid == [0u8; 16] || new_keys.is_empty() {
            return Ok(Vec::new());
        }

        if tree.height == 0 {
            let keys = self.load_leaf_keys_noput(&tree.root_uuid)?;
            if keys.is_empty() {
                return Ok(Vec::new());
            }
            return Ok(vec![(keys[0].clone(), tree.root_uuid)]);
        }

        if tree.height == 1 {
            let entries = self.load_root_entries(tree)?;
            let mut affected: BTreeSet<usize> = BTreeSet::new();
            for nk in new_keys {
                let idx = entries.partition_point(|(k, _)| k.as_slice() <= nk);
                if idx > 0 {
                    affected.insert(idx - 1);
                }
            }
            if !affected.is_empty() {
                let min_i = *affected.iter().next().unwrap();
                let max_i = *affected.iter().next_back().unwrap();
                for i in min_i..=max_i {
                    affected.insert(i);
                }
            }
            return Ok(affected
                .iter()
                .map(|&i| (entries[i].0.clone(), entries[i].1))
                .collect());
        }

        // height > 1: traverse each level
        let mut current_level: Vec<(Vec<u8>, [u8; 16])> = {
            let entries = self.load_root_entries(tree)?;
            let mut affected: BTreeSet<usize> = BTreeSet::new();
            for nk in new_keys {
                let idx = entries.partition_point(|(k, _)| k.as_slice() <= nk);
                if idx > 0 {
                    affected.insert(idx - 1);
                }
            }
            if !affected.is_empty() {
                let min_i = *affected.iter().next().unwrap();
                let max_i = *affected.iter().next_back().unwrap();
                for i in min_i..=max_i {
                    affected.insert(i);
                }
            }
            affected.iter().map(|&i| entries[i].clone()).collect()
        };

        for _h in (1..tree.height).rev() {
            let mut next_level: Vec<(Vec<u8>, [u8; 16])> = Vec::new();
            for (_, uuid) in &current_level {
                let data = blob_get(self.blobs.as_ref(), *uuid)?
                    .ok_or_else(|| TransactorError::Internal("index blob not found".into()))?;
                let entries = deserialize_index_page(&data)
                    .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
                let mut affected: BTreeSet<usize> = BTreeSet::new();
                for nk in new_keys {
                    let idx = entries.partition_point(|(k, _)| k.as_slice() <= nk);
                    if idx > 0 {
                        affected.insert(idx - 1);
                    }
                }
                if !affected.is_empty() {
                    let min_i = *affected.iter().next().unwrap();
                    let max_i = *affected.iter().next_back().unwrap();
                    for i in min_i..=max_i {
                        affected.insert(i);
                    }
                }
                for &i in &affected {
                    next_level.push(entries[i].clone());
                }
            }
            current_level = next_level;
        }

        Ok(current_level)
    }

    /// Build index page(s) from a sorted entry list. Returns (root_uuid, height).
    /// Splits when a single page exceeds INDEX_PAGE_MAX_SIZE.
    ///
    /// `child_height`: height of the nodes that `entries`' UUIDs point to.
    ///   - 0 = entries point to leaf pages (initial tree build)
    ///   - H = entries point to index pages at height H (root split in tree of height H)
    fn build_index_tree(
        &self,
        entries: Vec<(Vec<u8>, [u8; 16])>,
        child_height: u8,
    ) -> TransactorResult<([u8; 16], u8)> {
        if entries.is_empty() {
            return Ok(([0u8; 16], 0));
        }

        let serialized = serialize_index_page(&entries);
        if serialized.len() <= INDEX_PAGE_MAX_SIZE {
            let uuid = blob_put(self.blobs.as_ref(), &serialized)?;
            return Ok((uuid, child_height + 1));
        }

        // Split entries into pages
        let pages = self.split_index_entries(&entries)?;
        if pages.len() == 1 {
            let uuid = blob_put(self.blobs.as_ref(), &pages[0])?;
            return Ok((uuid, child_height + 1));
        }

        // Build level 1: write each split page, collect (boundary, uuid)
        let mut level_entries: Vec<(Vec<u8>, [u8; 16])> = Vec::new();
        for page_data in &pages {
            let page_entries = deserialize_index_page(page_data)
                .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
            if let Some((first_key, _)) = page_entries.first() {
                let uuid = blob_put(self.blobs.as_ref(), page_data)?;
                level_entries.push((first_key.clone(), uuid));
            }
        }

        // Recursively build upper levels
        let mut height = child_height + 2;
        loop {
            let serialized = serialize_index_page(&level_entries);
            if serialized.len() <= INDEX_PAGE_MAX_SIZE {
                let uuid = blob_put(self.blobs.as_ref(), &serialized)?;
                return Ok((uuid, height));
            }

            let pages = self.split_index_entries(&level_entries)?;

            // No progress: each entry is already its own page (oversized entries).
            // Emit as a single root page and stop.
            if pages.len() == level_entries.len() {
                let uuid = blob_put(self.blobs.as_ref(), &serialized)?;
                return Ok((uuid, height));
            }

            let mut next_level: Vec<(Vec<u8>, [u8; 16])> = Vec::new();
            for page_data in &pages {
                let page_entries = deserialize_index_page(page_data)
                    .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
                if let Some((first_key, _)) = page_entries.first() {
                    let uuid = blob_put(self.blobs.as_ref(), page_data)?;
                    next_level.push((first_key.clone(), uuid));
                }
            }
            level_entries = next_level;
            height += 1;
        }
    }

    /// Split entries into serialized pages, each ≤ INDEX_PAGE_MAX_SIZE.
    fn split_index_entries(
        &self,
        entries: &[(Vec<u8>, [u8; 16])],
    ) -> TransactorResult<Vec<Vec<u8>>> {
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        let total_size = serialize_index_page(entries).len();
        if total_size <= INDEX_PAGE_MAX_SIZE {
            return Ok(vec![serialize_index_page(entries)]);
        }
        if entries.len() == 1 {
            return Ok(vec![serialize_index_page(entries)]);
        }

        let mid = entries.len() / 2;
        let mut result = Vec::new();
        result.extend(self.split_index_entries(&entries[..mid])?);
        result.extend(self.split_index_entries(&entries[mid..])?);
        Ok(result)
    }

    // ── COW recursive merge ────────────────────────────────────────────────

    /// Count leaf pages in a subtree by traversing index pages only.
    /// Fast: O(index_pages), not O(leaf_pages).
    fn count_subtree_leaves(&self, uuid: [u8; 16], height: u8) -> TransactorResult<u32> {
        if height == 0 {
            return Ok(1);
        }
        let data = blob_get(self.blobs.as_ref(), uuid)?
            .ok_or_else(|| TransactorError::Internal("blob not found for leaf count".into()))?;
        let entries = deserialize_index_page(&data)
            .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
        let mut count = 0u32;
        for (_, child_uuid) in &entries {
            count += self.count_subtree_leaves(*child_uuid, height - 1)?;
        }
        Ok(count)
    }

    /// Recursively merge new keys into a subtree.
    ///
    /// - `node_uuid`: the blob UUID of this node
    /// - `height`: 0 = leaf page, 1+ = index page
    /// - `range_end`: exclusive upper bound for keys in this subtree (None = unbounded)
    /// - `iter`: sorted iterator over new keys, positioned at the first key that might overlap
    ///
    /// Returns:
    /// - `None` if the subtree is unchanged (UUID stays the same)
    /// - `Some(entries)` if changed — 1+ `(boundary_key, new_uuid)` pairs at this node's level
    fn merge_subtree(
        &self,
        node_uuid: [u8; 16],
        height: u8,
        range_end: Option<&[u8]>,
        iter: &mut std::slice::Iter<'_, Vec<u8>>,
        deleted: &mut Vec<Vec<u8>>,
    ) -> TransactorResult<Option<Vec<(Vec<u8>, [u8; 16])>>> {
        if height == 0 {
            return self.merge_leaf(node_uuid, range_end, iter, deleted);
        }

        // Index page: load child entries
        let data = blob_get(self.blobs.as_ref(), node_uuid)?
            .ok_or_else(|| TransactorError::Internal("index blob not found".into()))?;
        let entries = deserialize_index_page(&data)
            .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;

        let mut new_entries: Vec<(Vec<u8>, [u8; 16])> = Vec::with_capacity(entries.len() + 1);
        let mut changed = false;

        for (i, (boundary, child_uuid)) in entries.iter().enumerate() {
            let child_range_end = entries
                .get(i + 1)
                .map(|(k, _)| k.as_slice())
                .or(range_end);

            // A key belongs to this child if it's < child_range_end.
            // Keys before the first boundary go to child 0 (leftmost).
            let has_keys = iter
                .as_slice()
                .first()
                .map_or(false, |k| match child_range_end {
                    Some(re) => k.as_slice() < re,
                    None => true,
                });
            if !has_keys {
                new_entries.push((boundary.clone(), *child_uuid));
                continue;
            }

            // Recurse into child
            let child_result =
                self.merge_subtree(*child_uuid, height - 1, child_range_end, iter, deleted)?;

            match child_result {
                None => {
                    new_entries.push((boundary.clone(), *child_uuid));
                }
                Some(child_entries) => {
                    changed = true;
                    new_entries.extend(child_entries);
                }
            }
        }

        if !changed {
            return Ok(None);
        }

        // Write new index page(s) for this node
        Ok(Some(self.write_index_level(&new_entries)?))
    }

    /// Merge new keys into a single leaf page.
    fn merge_leaf(
        &self,
        leaf_uuid: [u8; 16],
        range_end: Option<&[u8]>,
        iter: &mut std::slice::Iter<'_, Vec<u8>>,
        deleted: &mut Vec<Vec<u8>>,
    ) -> TransactorResult<Option<Vec<(Vec<u8>, [u8; 16])>>> {
        // Load existing keys from leaf (cache-read-only — page will be replaced)
        let existing = self.load_leaf_keys_noput(&leaf_uuid)?;

        // Collect new keys that fall in [first_existing_or_zero, range_end)
        let mut new_keys = Vec::new();
        while let Some(front) = iter.as_slice().first() {
            if let Some(re) = range_end {
                if front.as_slice() >= re {
                    break;
                }
            }
            new_keys.push(front.clone());
            iter.next();
        }

        if new_keys.is_empty() {
            return Ok(None);
        }

        // Record old boundary for GC
        if let Some(first) = existing.first() {
            deleted.push(first.clone());
        }

        // Merge existing + new keys (sorted, deduplicated)
        let mut merged: BTreeSet<Vec<u8>> = existing.into_iter().collect();
        for k in new_keys {
            merged.insert(k);
        }
        let merged_vec: Vec<Vec<u8>> = merged.into_iter().collect();

        // Build leaf page(s)
        let page_list = pages::build_pages(&merged_vec);
        let mut entries = Vec::with_capacity(page_list.len());
        for (boundary, page_data) in &page_list {
            if let Err(e) = pages::deserialize_page(page_data) {
                return Err(TransactorError::Internal(format!(
                    "BUG: serialize_page round-trip failed: {e} | keys={} boundary={} page_len={}",
                    merged_vec.len(),
                    fmt_hex(boundary, 32),
                    page_data.len(),
                )));
            }
            let uuid = blob_put(self.blobs.as_ref(), page_data)?;
            entries.push((boundary.clone(), uuid));
        }

        Ok(Some(entries))
    }

    /// Write index entries as one or more index page blobs.
    /// Returns entries at this level (1 if fits, 2+ if split).
    fn write_index_level(
        &self,
        entries: &[(Vec<u8>, [u8; 16])],
    ) -> TransactorResult<Vec<(Vec<u8>, [u8; 16])>> {
        let serialized = serialize_index_page(entries);
        if serialized.len() <= INDEX_PAGE_MAX_SIZE || entries.len() <= 1 {
            let uuid = blob_put(self.blobs.as_ref(), &serialized)?;
            let first_key = entries[0].0.clone();
            return Ok(vec![(first_key, uuid)]);
        }

        // Overflow: split into pages
        let pages = self.split_index_entries(entries)?;
        let mut result = Vec::with_capacity(pages.len());
        for page_data in &pages {
            let page_entries = deserialize_index_page(page_data)
                .map_err(|e| TransactorError::Internal(format!("index deserialize: {e}")))?;
            if let Some((first_key, _)) = page_entries.first() {
                let uuid = blob_put(self.blobs.as_ref(), page_data)?;
                result.push((first_key.clone(), uuid));
            }
        }
        Ok(result)
    }
}

impl PageStore for GenericPageStore {
    fn get_keys_in_prefix(&self, cf: usize, prefix: &[u8]) -> TransactorResult<Vec<Vec<u8>>> {
        let inner = self.inner.read().unwrap();
        if cf >= inner.num_cf {
            return Ok(Vec::new());
        }
        let tree = &inner.trees[cf];
        if tree.root_uuid == [0u8; 16] {
            return Ok(Vec::new());
        }

        if tree.height == 0 {
            let keys = self.load_leaf_keys(&tree.root_uuid)?;
            Ok(keys.into_iter().filter(|k| k.starts_with(prefix)).collect())
        } else {
            self.collect_keys_from_index(tree.root_uuid, tree.height, prefix)
        }
    }

    fn get_keys_for_merge(
        &self,
        cf: usize,
        new_keys: &[Vec<u8>],
    ) -> TransactorResult<(Vec<Vec<u8>>, Vec<Vec<u8>>)> {
        let inner = self.inner.read().unwrap();
        if cf >= inner.num_cf {
            return Ok((Vec::new(), Vec::new()));
        }
        let tree = &inner.trees[cf];

        let affected = self.find_affected_leaves(tree, new_keys)?;

        let mut existing_keys = Vec::new();
        let mut boundaries = Vec::new();
        for (boundary, uuid) in &affected {
            boundaries.push(boundary.clone());
            if let Ok(keys) = self.load_leaf_keys_noput(uuid) {
                existing_keys.extend(keys);
            }
        }

        Ok((existing_keys, boundaries))
    }

    fn page_count_in_range(
        &self,
        cf: usize,
        start: &[u8],
        end: &[u8],
    ) -> TransactorResult<usize> {
        let inner = self.inner.read().unwrap();
        if cf >= inner.num_cf {
            return Ok(0);
        }
        let tree = &inner.trees[cf];
        if tree.root_uuid == [0u8; 16] || tree.num_leaves == 0 {
            return Ok(0);
        }

        let entries = self.load_root_entries(tree)?;
        if entries.is_empty() {
            return Ok(if start.is_empty() { 1 } else { 0 });
        }

        let lo = entries.partition_point(|(k, _)| k.as_slice() < start);
        let lo = lo.saturating_sub(1);
        let hi = entries.partition_point(|(k, _)| k.as_slice() < end);
        Ok(hi.saturating_sub(lo).max(1))
    }

    fn page_count(&self, cf: usize) -> TransactorResult<usize> {
        let inner = self.inner.read().unwrap();
        if cf >= inner.num_cf {
            return Ok(0);
        }
        Ok(inner.trees[cf].num_leaves as usize)
    }

    fn key_exists(&self, cf: usize, key: &[u8]) -> TransactorResult<bool> {
        let keys = self.get_keys_in_prefix(cf, key)?;
        Ok(keys.iter().any(|k| k.as_slice() == key))
    }

    fn commit(
        &self,
        puts: &[(usize, Vec<u8>, Vec<u8>)],
        deletes: &[(usize, Vec<u8>)],
        clear_journal: bool,
    ) -> TransactorResult<()> {
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }

        let num_cf = inner.num_cf;

        for (cf, _key, _value) in puts {
            if *cf >= num_cf {
                continue;
            }
        }

        let mut puts_by_cf: Vec<Vec<(Vec<u8>, Vec<u8>)>> = vec![Vec::new(); num_cf];
        let mut deletes_by_cf: Vec<Vec<Vec<u8>>> = vec![Vec::new(); num_cf];

        for (cf, key, value) in puts {
            if *cf < num_cf {
                puts_by_cf[*cf].push((key.clone(), value.clone()));
            }
        }
        for (cf, key) in deletes {
            if *cf < num_cf {
                deletes_by_cf[*cf].push(key.clone());
            }
        }

        for cf in 0..num_cf {
            let cf_puts = &puts_by_cf[cf];
            let cf_deletes = &deletes_by_cf[cf];
            if cf_puts.is_empty() && cf_deletes.is_empty() {
                continue;
            }

            let tree = &inner.trees[cf];

            // Load current entries (for height >= 1)
            let mut current_entries = self.load_root_entries(tree)?;

            // Handle height 0 (single leaf page): load its boundary
            if tree.height == 0 && tree.root_uuid != [0u8; 16] {
                if let Ok(keys) = self.load_leaf_keys_noput(&tree.root_uuid) {
                    if let Some(first) = keys.first() {
                        current_entries = vec![(first.clone(), tree.root_uuid)];
                    }
                }
            }

            // Remove deleted entries
            let delete_set: HashSet<&Vec<u8>> = cf_deletes.iter().collect();
            current_entries.retain(|(k, _)| !delete_set.contains(k));

            // Write new leaf page blobs and add entries
            for (boundary, page_data) in cf_puts {
                let uuid = blob_put(self.blobs.as_ref(), page_data)?;
                current_entries.push((boundary.clone(), uuid));
            }

            // Sort entries by boundary key
            current_entries.sort_by(|a, b| a.0.cmp(&b.0));

            let num_leaves = current_entries.len() as u32;

            // Build new index tree (COW: all new blobs)
            let (new_root_uuid, new_height) = self.build_index_tree(current_entries, 0)?;

            let num_leaves = if new_height == 0 { 0 } else { num_leaves };

            inner.trees[cf] = CfTree {
                root_uuid: new_root_uuid,
                height: new_height,
                num_leaves,
            };
        }

        // Write new root file (old root kept for GC — cleaned on open or by gc_max_age)
        let new_root = make_root_name();
        blob_put_root(
            self.blobs.as_ref(),
            &new_root,
            &serialize_root_v2(&inner.trees),
        )?;
        inner.current_root = new_root;

        if clear_journal {
            if let Some(ref j) = self.journal {
                j.journal_truncate().map_err(TransactorError::from)?;
            }
        }

        Ok(())
    }

    fn commit_merge(
        &self,
        keys_by_cf: &[(usize, Vec<Vec<u8>>)],
        clear_journal: bool,
    ) -> TransactorResult<()> {
        let mut inner = self.inner.write().unwrap();
        if inner.read_only {
            return Err(TransactorError::ReadOnly);
        }

        for (cf, sorted_keys) in keys_by_cf {
            if *cf >= inner.num_cf || sorted_keys.is_empty() {
                continue;
            }

            let tree = inner.trees[*cf].clone();
            let mut iter = sorted_keys.iter();
            let mut deleted_boundaries = Vec::new();

            let new_tree = if tree.root_uuid == [0u8; 16] {
                // Empty tree — build from scratch
                let page_list = pages::build_pages(sorted_keys);
                let mut entries = Vec::with_capacity(page_list.len());
                for (boundary, page_data) in &page_list {
                    if let Err(e) = pages::deserialize_page(page_data) {
                        return Err(TransactorError::Internal(format!(
                            "BUG: serialize_page round-trip failed (new tree): {e} | keys={} boundary={} page_len={}",
                            sorted_keys.len(),
                            fmt_hex(boundary, 32),
                            page_data.len(),
                        )));
                    }
                    let uuid = blob_put(self.blobs.as_ref(), page_data)?;
                    entries.push((boundary.clone(), uuid));
                }
                let num_leaves = entries.len() as u32;
                let (root, height) = self.build_index_tree(entries, 0)?;
                CfTree { root_uuid: root, height, num_leaves }
            } else {
                // Recursively merge into existing tree
                let result = self.merge_subtree(
                    tree.root_uuid,
                    tree.height,
                    None,
                    &mut iter,
                    &mut deleted_boundaries,
                )?;

                match result {
                    None => tree, // unchanged
                    Some(entries) => {
                        if entries.len() == 1 {
                            // No structural change at root — one entry returned
                            let new_uuid = entries[0].1;
                            let num_leaves = if tree.height == 0 {
                                1
                            } else {
                                self.count_subtree_leaves(new_uuid, tree.height)?
                            };
                            CfTree {
                                root_uuid: new_uuid,
                                height: tree.height,
                                num_leaves,
                            }
                        } else {
                            // Root split — build upper levels
                            let (root, height) = self.build_index_tree(entries, tree.height)?;
                            let num_leaves = self.count_subtree_leaves(root, height)?;
                            CfTree {
                                root_uuid: root,
                                height,
                                num_leaves,
                            }
                        }
                    }
                }
            };

            inner.trees[*cf] = new_tree;
        }

        // Write new root file (old root kept for GC — cleaned on open or by gc_max_age)
        let new_root = make_root_name();
        blob_put_root(
            self.blobs.as_ref(),
            &new_root,
            &serialize_root_v2(&inner.trees),
        )?;
        inner.current_root = new_root;

        if clear_journal {
            if let Some(ref j) = self.journal {
                j.journal_truncate().map_err(TransactorError::from)?;
            }
        }

        Ok(())
    }

    fn journal_put(&self, key: &[u8], value: &[u8]) -> TransactorResult<()> {
        match &self.journal {
            Some(j) => j.journal_append(key, value).map_err(Into::into),
            None => Ok(()),
        }
    }

    fn journal_scan(&self) -> TransactorResult<Vec<u8>> {
        match &self.journal {
            Some(j) => j.journal_read().map_err(Into::into),
            None => Ok(Vec::new()),
        }
    }

    fn collect_live_uuids(&self) -> TransactorResult<HashSet<[u8; 16]>> {
        let inner = self.inner.read().unwrap();
        let mut live = HashSet::new();
        for tree in &inner.trees {
            self.collect_tree_uuids(tree, &mut live)?;
        }
        Ok(live)
    }

    fn cf_stats(&self, cf: usize) -> TransactorResult<CfStatsData> {
        let inner = self.inner.read().unwrap();
        if cf >= inner.num_cf {
            return Err(TransactorError::InvalidArg(format!("cf {cf} out of range")));
        }
        Ok(CfStatsData {
            num_keys: inner.trees[cf].num_leaves as u64,
            live_size: 0,
            sst_size: 0,
            num_sst: 0,
            memtable_size: 0,
        })
    }

    fn db_stats(&self) -> TransactorResult<DbStatsData> {
        Ok(DbStatsData {
            total_sst_size: 0,
            total_live_size: 0,
        })
    }

    fn internal_status(&self, target: &str) -> TransactorResult<String> {
        let inner = self.inner.read().unwrap();

        let do_cf: Vec<usize> = if target.is_empty()
            || target == "btree"
            || target == "all"
        {
            (0..inner.num_cf).collect()
        } else if let Some(rest) = target.strip_prefix("btree:") {
            let cf_id = crate::page_store::cf_id_for_name(rest)
                .ok_or_else(|| TransactorError::InvalidArg(format!("unknown CF name: {rest}")))?;
            vec![cf_id]
        } else {
            return Err(TransactorError::InvalidArg(format!(
                "unknown internal_status target: {target}"
            )));
        };

        let mut out = String::new();
        for &cf in &do_cf {
            let name = crate::page_store::cf_name_for(cf);
            let tree = &inner.trees[cf];
            if tree.root_uuid == [0u8; 16] {
                out.push_str(&format!("CF {cf} ({name}): empty\n"));
                continue;
            }
            out.push_str(&format!(
                "CF {cf} ({name}): root={}, height={}, leaves={}\n",
                fmt_uuid(&tree.root_uuid),
                tree.height,
                tree.num_leaves,
            ));
            self.dump_tree_node(
                tree.root_uuid,
                tree.height,
                1,
                &mut out,
            )?;
        }
        Ok(out)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use super::*;
    use crate::blobstore::BlobStoreEngine;
    use crate::journal::JournalEngine;

    struct TestBlobStore {
        blobs: Mutex<HashMap<[u8; 16], Vec<u8>>>,
        roots: Mutex<std::collections::BTreeMap<String, Vec<u8>>>,
    }

    impl TestBlobStore {
        fn new() -> Self {
            Self {
                blobs: Mutex::new(HashMap::new()),
                roots: Mutex::new(std::collections::BTreeMap::new()),
            }
        }
    }

    impl BlobStoreEngine for TestBlobStore {
        fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
            let id = uuid::Uuid::new_v4().into_bytes();
            self.blobs.lock().unwrap().insert(id, data.to_vec());
            Ok(id)
        }
        fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
            self.blobs.lock().unwrap().insert(id, data.to_vec());
            Ok(())
        }
        fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
            Ok(self.blobs.lock().unwrap().get(&id).cloned())
        }
        fn delete(&self, id: [u8; 16]) -> Result<(), String> {
            self.blobs.lock().unwrap().remove(&id);
            Ok(())
        }
        fn list(&self) -> Result<Vec<[u8; 16]>, String> {
            Ok(self.blobs.lock().unwrap().keys().copied().collect())
        }
        fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
            self.roots.lock().unwrap().insert(name.to_string(), data.to_vec());
            Ok(())
        }
        fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
            Ok(self.roots.lock().unwrap().get(name).cloned())
        }
        fn list_roots(&self) -> Result<Vec<String>, String> {
            Ok(self.roots.lock().unwrap().keys().cloned().collect())
        }
        fn delete_root(&self, name: &str) -> Result<(), String> {
            self.roots.lock().unwrap().remove(name);
            Ok(())
        }
    }

    struct TestJournalStore {
        journal: Mutex<Vec<(Vec<u8>, Vec<u8>)>>,
    }

    impl TestJournalStore {
        fn new() -> Self {
            Self {
                journal: Mutex::new(Vec::new()),
            }
        }
    }

    impl JournalEngine for TestJournalStore {
        fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
            self.journal
                .lock()
                .unwrap()
                .push((key.to_vec(), value.to_vec()));
            Ok(())
        }
        fn journal_read(&self) -> Result<Vec<u8>, String> {
            let entries = self.journal.lock().unwrap();
            let mut buf = Vec::new();
            for (k, v) in entries.iter() {
                buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
                buf.extend_from_slice(k);
                buf.extend_from_slice(&(v.len() as u32).to_be_bytes());
                buf.extend_from_slice(v);
            }
            Ok(buf)
        }
        fn journal_truncate(&self) -> Result<(), String> {
            self.journal.lock().unwrap().clear();
            Ok(())
        }
    }

    fn make_test_store(num_cf: usize) -> GenericPageStore {
        let blobs = Box::new(TestBlobStore::new());
        let journal: Option<Box<dyn JournalEngine + Send + Sync>> =
            Some(Box::new(TestJournalStore::new()));
        GenericPageStore::open(blobs, journal, num_cf, 64 * 1024 * 1024).unwrap()
    }

    fn make_page(keys: &[&[u8]]) -> (Vec<u8>, Vec<u8>) {
        let owned: Vec<Vec<u8>> = keys.iter().map(|k| k.to_vec()).collect();
        let pages = pages::build_pages(&owned);
        pages.into_iter().next().unwrap()
    }

    #[test]
    fn put_get_roundtrip() {
        let store = make_test_store(4);
        let (boundary, data) = make_page(&[b"key1"]);
        store.commit(&[(0, boundary, data)], &[], false).unwrap();
        let keys = store.get_keys_in_prefix(0, b"key1").unwrap();
        assert_eq!(keys, vec![b"key1".to_vec()]);
    }

    #[test]
    fn overwrite() {
        let store = make_test_store(4);
        let (b1, d1) = make_page(&[b"k"]);
        let (b2, d2) = make_page(&[b"k"]);
        store.commit(&[(0, b1, d1)], &[], false).unwrap();
        store.commit(&[(0, b2, d2)], &[(0, b"k".to_vec())], false).unwrap();
        let keys = store.get_keys_in_prefix(0, b"k").unwrap();
        assert_eq!(keys, vec![b"k".to_vec()]);
        assert_eq!(store.page_count(0).unwrap(), 1);
    }

    #[test]
    fn delete_removes_key() {
        let store = make_test_store(4);
        let (b1, d1) = make_page(&[b"k1"]);
        let (b2, d2) = make_page(&[b"k2"]);
        store
            .commit(&[(0, b1, d1), (0, b2, d2)], &[], false)
            .unwrap();
        store
            .commit(&[], &[(0, b"k1".to_vec())], false)
            .unwrap();
        assert!(!store.key_exists(0, b"k1").unwrap());
        assert!(store.key_exists(0, b"k2").unwrap());
    }

    #[test]
    fn prefix_scan_sorted() {
        let store = make_test_store(4);
        let (ba, da) = make_page(&[b"a"]);
        let (bb, db) = make_page(&[b"b"]);
        let (bc, dc) = make_page(&[b"c"]);
        store
            .commit(&[(1, bc, dc), (1, ba, da), (1, bb, db)], &[], false)
            .unwrap();
        let keys = store.get_keys_in_prefix(1, b"").unwrap();
        assert_eq!(
            keys,
            vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]
        );
    }

    #[test]
    fn journal_roundtrip() {
        let store = make_test_store(4);
        store.journal_put(b"k1", b"v1").unwrap();
        store.journal_put(b"k2", b"v2").unwrap();
        let entries = crate::store::unpack_kv(&store.journal_scan().unwrap());
        assert_eq!(entries.len(), 2);
    }

    #[test]
    fn journal_cleared_on_commit() {
        let store = make_test_store(4);
        store.journal_put(b"k1", b"v1").unwrap();
        store.commit(&[], &[], true).unwrap();
        assert!(store.journal_scan().unwrap().is_empty());
    }

    #[test]
    fn gc_full_removes_orphan_blobs() {
        let store = make_test_store(4);
        let (b1, d1) = make_page(&[b"k"]);
        let (b2, d2) = make_page(&[b"k"]);
        store.commit(&[(0, b1, d1)], &[], false).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        store.commit(&[(0, b2, d2)], &[(0, b"k".to_vec())], false).unwrap();

        // max_age=0: only the latest root is kept, old root's blobs become orphan
        let dry = store.gc_full_with_age(true, 0, 0).unwrap();
        assert!(dry.dry_run);
        assert!(dry.blobs_removed > 0, "dry run should detect orphan blobs");

        let live = store.gc_full_with_age(false, 0, 0).unwrap();
        assert!(!live.dry_run);
        assert!(live.blobs_removed > 0, "live gc should remove orphan blobs");

        let keys = store.get_keys_in_prefix(0, b"k").unwrap();
        assert_eq!(keys, vec![b"k".to_vec()]);
    }

    #[test]
    fn gc_full_dry_run_preserves_everything() {
        let store = make_test_store(4);
        let (b, d) = make_page(&[b"k"]);
        store.commit(&[(0, b, d)], &[], false).unwrap();

        let all_before = store.blobs.list().unwrap().len();
        let _dry = store.gc_full(true).unwrap();
        let all_after = store.blobs.list().unwrap().len();

        assert_eq!(all_before, all_after, "dry run must not delete any blobs");
    }

    #[test]
    fn gc_count_based_keeps_n_newest_roots() {
        let store = make_test_store(4);
        for i in 0..5u8 {
            let key = format!("k{i}");
            let (b, d) = make_page(&[key.as_bytes()]);
            store.commit(&[(0, b, d)], &[], false).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let roots_before = store.blobs.list_roots().unwrap();
        assert!(roots_before.len() > 3, "expected more than 3 roots before GC");

        let result = store.gc_full_with_age(false, 365 * 24 * 3600, 3).unwrap();
        assert_eq!(result.roots_removed, roots_before.len() - 3, "should keep 3 newest roots");

        let roots_after = store.blobs.list_roots().unwrap();
        assert_eq!(roots_after.len(), 3, "expected 3 roots after count-based GC");

        for i in 0..5u8 {
            let key = format!("k{i}");
            let keys = store.get_keys_in_prefix(0, key.as_bytes()).unwrap();
            assert_eq!(keys, vec![key.into_bytes()], "key k{i} should survive GC");
        }
    }

    #[test]
    fn index_page_serde_roundtrip() {
        let entries = vec![
            (b"key_aaa".to_vec(), [1u8; 16]),
            (b"key_aab".to_vec(), [2u8; 16]),
            (b"key_aac".to_vec(), [3u8; 16]),
        ];
        let serialized = serialize_index_page(&entries);
        let deserialized = deserialize_index_page(&serialized).unwrap();
        assert_eq!(deserialized, entries);
    }

    #[test]
    fn index_page_prefix_compression() {
        let entries = vec![
            (b"entity:42:attr:3".to_vec(), [0u8; 16]),
            (b"entity:42:attr:5".to_vec(), [1u8; 16]),
            (b"entity:42:attr:7".to_vec(), [2u8; 16]),
            (b"entity:99:attr:1".to_vec(), [3u8; 16]),
        ];
        let serialized = serialize_index_page(&entries);
        let deserialized = deserialize_index_page(&serialized).unwrap();
        assert_eq!(deserialized, entries);
    }

    #[test]
    fn large_key_commit() {
        let store = make_test_store(4);
        let big_key = vec![0xABu8; 30_000];
        let (boundary, data) = make_page(&[&big_key]);
        store.commit(&[(0, boundary, data)], &[], false).unwrap();
        let keys = store.get_keys_in_prefix(0, b"").unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0], big_key);
    }

    #[test]
    fn multiple_large_keys_commit() {
        let store = make_test_store(4);
        for size in [25_000, 30_000, 20_000] {
            let key = vec![0xCDu8; size];
            let (boundary, data) = make_page(&[&key]);
            store.commit(&[(0, boundary, data)], &[], false).unwrap();
        }
        let keys = store.get_keys_in_prefix(0, b"").unwrap();
        assert_eq!(keys.len(), 3);
    }

    #[test]
    fn root_split_preserves_height() {
        let store = make_test_store(1);
        let mut all_keys = Vec::new();
        let prefix = vec![b'x'; 200];

        for batch in 0..20u32 {
            let mut keys_by_cf = vec![(0usize, Vec::new())];
            for i in 0..10_000u32 {
                let mut key = prefix.clone();
                key.extend_from_slice(format!("{batch:04}/{i:08}").as_bytes());
                keys_by_cf[0].1.push(key.clone());
                all_keys.push(key);
            }
            keys_by_cf[0].1.sort();
            store.commit_merge(&keys_by_cf, false).unwrap();
        }

        all_keys.sort();
        all_keys.dedup();

        let inner = store.inner.read().unwrap();
        let tree = &inner.trees[0];
        assert!(tree.height >= 1, "expected height >= 1 after inserts, got {}", tree.height);

        drop(inner);

        let read_keys = store.get_keys_in_prefix(0, b"").unwrap();
        assert_eq!(read_keys.len(), all_keys.len(), "key count mismatch");
        assert_eq!(read_keys, all_keys, "keys mismatch after root split");
    }
}
