use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;

use crossbeam_skiplist::SkipMap;

#[derive(Clone)]
pub struct MemTableSnapshot {
    pub data: Arc<dyn std::any::Any + Send + Sync>,
}

include!(concat!(env!("OUT_DIR"), "/memtable_spier.rs"));

fn pack_keys(keys: &[Vec<u8>]) -> Vec<u8> {
    let mut buf = Vec::new();
    for k in keys {
        buf.extend_from_slice(&(k.len() as u32).to_be_bytes());
        buf.extend_from_slice(k);
    }
    buf
}

fn prefix_upper_bound(prefix: &[u8]) -> Vec<u8> {
    let mut e = prefix.to_vec();
    for b in e.iter_mut().rev() {
        if *b < 0xFF {
            *b += 1;
            return e;
        }
    }
    vec![0xFF; 64]
}

// Each CF holds an Arc<SkipMap>. Snapshots clone the Arc (O(1)); clear/drain
// swap in a fresh empty SkipMap (O(1)). Old snapshots keep the previous SkipMap
// alive via Arc until they drop — no tombstones, no GC, lock-free reads.
type CfMap = Arc<SkipMap<Vec<u8>, ()>>;

struct CfData {
    map: CfMap,
    size: usize,
}

impl CfData {
    fn new() -> Self {
        Self {
            map: Arc::new(SkipMap::new()),
            size: 0,
        }
    }
}

struct MemTableInner {
    cfs: Vec<CfData>,
}

impl MemTableInner {
    fn new(num_cf: usize) -> Self {
        Self {
            cfs: (0..num_cf).map(|_| CfData::new()).collect(),
        }
    }

    fn put(&mut self, cf_id: usize, key: &[u8]) -> usize {
        let cf = &mut self.cfs[cf_id];
        let is_new = !cf.map.contains_key(key);
        cf.map.insert(key.to_vec(), ());
        if is_new {
            cf.size += key.len();
        }
        self.total_size()
    }

    fn total_size(&self) -> usize {
        self.cfs.iter().map(|cf| cf.size).sum()
    }

    fn clear(&mut self) {
        for cf in &mut self.cfs {
            cf.map = Arc::new(SkipMap::new());
            cf.size = 0;
        }
    }
}

// Snapshot holds Arc clones of every CF's SkipMap. After clear()/drain() swaps
// in fresh empty maps, this still points at the pre-clear state — readers see a
// frozen view while the live MemTable continues mutating a different map.
type CfSnapshots = Vec<CfMap>;

struct MemTableState {
    inner: Mutex<MemTableInner>,
}

fn init(config: &HashMap<String, String>) -> Result<MemTableState, String> {
    let num_cf = config
        .get("num_cf")
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    Ok(MemTableState {
        inner: Mutex::new(MemTableInner::new(num_cf)),
    })
}

impl MemTableEngine for MemTableState {
    fn put(&self, cf: u32, key: &[u8]) -> Result<u64, String> {
        let mut inner = self.inner.lock().unwrap();
        Ok(inner.put(cf as usize, key) as u64)
    }

    fn batch_write(&self, ops: &[u8]) -> Result<u64, String> {
        let mut inner = self.inner.lock().unwrap();
        let mut pos = 0;
        while pos + 5 <= ops.len() {
            let cf = ops[pos] as usize;
            let klen = u32::from_be_bytes([ops[pos + 1], ops[pos + 2], ops[pos + 3], ops[pos + 4]]) as usize;
            if pos + 5 + klen > ops.len() {
                break;
            }
            inner.put(cf, &ops[pos + 5..pos + 5 + klen]);
            pos += 5 + klen;
        }
        Ok(inner.total_size() as u64)
    }

    fn clear(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        inner.clear();
        Ok(())
    }

    fn snapshot(&self) -> Result<MemTableSnapshot, String> {
        let inner = self.inner.lock().unwrap();
        let cfs: CfSnapshots = inner.cfs.iter().map(|c| c.map.clone()).collect();
        Ok(MemTableSnapshot { data: Arc::new(cfs) })
    }

    fn scan_prefix(&self, snap: MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let cfs = snap.data.downcast_ref::<CfSnapshots>()
            .ok_or("invalid snapshot type")?;
        let map = match cfs.get(cf as usize) {
            Some(m) => m,
            None => return Ok(Vec::new()),
        };
        let keys: Vec<Vec<u8>> = if prefix.is_empty() {
            map.iter().map(|e| e.key().clone()).collect()
        } else {
            let upper = prefix_upper_bound(prefix);
            map.range(prefix.to_vec()..upper)
                .map(|e| e.key().clone())
                .collect()
        };
        Ok(pack_keys(&keys))
    }

    fn scan_prefix_reverse(&self, snap: MemTableSnapshot, cf: u32, prefix: &[u8]) -> Result<Vec<u8>, String> {
        let cfs = snap.data.downcast_ref::<CfSnapshots>()
            .ok_or("invalid snapshot type")?;
        let map = match cfs.get(cf as usize) {
            Some(m) => m,
            None => return Ok(Vec::new()),
        };
        let keys: Vec<Vec<u8>> = if prefix.is_empty() {
            map.iter().rev().map(|e| e.key().clone()).collect()
        } else {
            let upper = prefix_upper_bound(prefix);
            map.range(prefix.to_vec()..upper)
                .rev()
                .map(|e| e.key().clone())
                .collect()
        };
        Ok(pack_keys(&keys))
    }

    fn contains(&self, snap: MemTableSnapshot, cf: u32, key: &[u8]) -> Result<bool, String> {
        let cfs = snap.data.downcast_ref::<CfSnapshots>()
            .ok_or("invalid snapshot type")?;
        Ok(cfs.get(cf as usize).map(|m| m.contains_key(key)).unwrap_or(false))
    }
}

impl_memtable_spier!(MemTableState, init, "spier_memtable");
