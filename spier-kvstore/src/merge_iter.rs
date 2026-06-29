use std::collections::BinaryHeap;
use std::cmp::Reverse;



pub trait ScanSource: Send {
    fn valid(&self) -> bool;
    fn key(&self) -> Vec<u8>;
    fn value(&self) -> Vec<u8>;
    fn advance(&mut self);
    fn seek(&mut self, target: &[u8]);
    fn advance_to(&mut self, target: &[u8]);
    fn update_end(&mut self, end: &[u8]);
    fn skip_group(&mut self, group: &[u8]);
}

pub enum SourceKind {
    MemTable(PageStoreIter),
    PageStore(PageStoreIter),
}

pub struct PageStoreIter {
    keys: Vec<Vec<u8>>,
    idx: usize,
    end: Vec<u8>,
    valid: bool,
}

impl PageStoreIter {
    pub fn new(keys: Vec<Vec<u8>>, prefix: &[u8]) -> Self {
        let end = if prefix.is_empty() {
            vec![0xFF; 64]
        } else {
            let mut e = prefix.to_vec();
            e.extend_from_slice(&[0xFF; 32]);
            e
        };
        let start = keys.partition_point(|k| &k[..] < prefix);
        let mut it = PageStoreIter {
            keys,
            idx: start,
            end,
            valid: false,
        };
        it.valid = it.idx < it.keys.len() && &it.keys[it.idx][..] <= &it.end[..];
        it
    }
}

impl ScanSource for PageStoreIter {
    fn valid(&self) -> bool { self.valid }

    fn key(&self) -> Vec<u8> {
        self.keys[self.idx].clone()
    }

    fn value(&self) -> Vec<u8> { vec![] }

    fn advance(&mut self) {
        if !self.valid { return; }
        self.idx += 1;
        self.valid = self.idx < self.keys.len() && &self.keys[self.idx][..] <= &self.end[..];
    }

    fn seek(&mut self, target: &[u8]) {
        self.idx = self.keys.partition_point(|k| &k[..] < target);
        self.valid = self.idx < self.keys.len() && &self.keys[self.idx][..] <= &self.end[..];
    }

    fn advance_to(&mut self, target: &[u8]) { self.seek(target); }

    fn update_end(&mut self, end: &[u8]) {
        self.end = end.to_vec();
        if self.valid && &self.keys[self.idx][..] > &self.end[..] {
            self.valid = false;
        }
    }

    fn skip_group(&mut self, group: &[u8]) {
        if !self.valid { return; }
        let glen = group.len();
        self.idx += self.keys[self.idx..].partition_point(|k| {
            k.len() >= glen && k[..glen] == group[..]
        });
        self.valid = self.idx < self.keys.len() && &self.keys[self.idx][..] <= &self.end[..];
    }
}

impl ScanSource for SourceKind {
    fn valid(&self) -> bool {
        match self {
            SourceKind::MemTable(s) => s.valid(),
            SourceKind::PageStore(it) => it.valid(),
        }
    }

    fn key(&self) -> Vec<u8> {
        match self {
            SourceKind::MemTable(s) => s.key(),
            SourceKind::PageStore(it) => it.key(),
        }
    }

    fn value(&self) -> Vec<u8> {
        match self {
            SourceKind::MemTable(_) => vec![],
            SourceKind::PageStore(_) => vec![],
        }
    }

    fn advance(&mut self) {
        match self {
            SourceKind::MemTable(s) => s.advance(),
            SourceKind::PageStore(it) => it.advance(),
        }
    }

    fn seek(&mut self, target: &[u8]) {
        match self {
            SourceKind::MemTable(s) => s.seek(target),
            SourceKind::PageStore(it) => it.seek(target),
        }
    }

    fn advance_to(&mut self, target: &[u8]) {
        match self {
            SourceKind::MemTable(s) => s.advance_to(target),
            SourceKind::PageStore(it) => it.advance_to(target),
        }
    }

    fn update_end(&mut self, end: &[u8]) {
        match self {
            SourceKind::MemTable(s) => s.update_end(end),
            SourceKind::PageStore(it) => it.update_end(end),
        }
    }

    fn skip_group(&mut self, group: &[u8]) {
        match self {
            SourceKind::MemTable(s) => s.skip_group(group),
            SourceKind::PageStore(it) => it.skip_group(group),
        }
    }
}

// Cursor trait is defined in dynspire-commons
pub use dynspire_commons::transactor::cursor::Cursor;

pub fn merge_collect(sources: Vec<SourceKind>) -> Vec<(Vec<u8>, Vec<u8>)> {
    let end = vec![0xFF; 64];
    let mut heap: BinaryHeap<Reverse<(Vec<u8>, usize)>> = BinaryHeap::new();
    for (i, s) in sources.iter().enumerate() {
        if s.valid() {
            heap.push(Reverse((s.key(), i)));
        }
    }
    let mut results: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
    let mut sources = sources;
    let mut last_key: Option<Vec<u8>> = None;
    while let Some(Reverse((key, idx))) = heap.pop() {
        if key.as_slice() > end.as_slice() {
            break;
        }
        let val = sources[idx].value();
        sources[idx].advance();
        if sources[idx].valid() {
            heap.push(Reverse((sources[idx].key(), idx)));
        }
        if last_key.as_ref() == Some(&key) {
            if let Some(last) = results.last_mut() {
                last.1 = val;
            }
        } else {
            last_key = Some(key.clone());
            results.push((key, val));
        }
    }
    results
}

pub struct MergedInner {
    pub sources: Vec<SourceKind>,
    pub end: Vec<u8>,
    pub heap: BinaryHeap<Reverse<(Vec<u8>, usize)>>,
    pub cur_key: Option<Vec<u8>>,
    pub cur_val: Vec<u8>,
    pub valid: bool,
}

impl MergedInner {
    pub fn new(sources: Vec<SourceKind>, prefix: &[u8]) -> Self {
        let end = if prefix.is_empty() {
            vec![0xFF; 64]
        } else {
            let mut e = prefix.to_vec();
            e.extend_from_slice(&[0xFF; 32]);
            e
        };
        let mut heap = BinaryHeap::new();
        for (i, s) in sources.iter().enumerate() {
            if s.valid() {
                heap.push(Reverse((s.key(), i)));
            }
        }
        let mut inner = MergedInner {
            sources,
            end,
            heap,
            cur_key: None,
            cur_val: Vec::new(),
            valid: false,
        };
        inner.step();
        inner
    }

    pub fn step(&mut self) {
        while let Some(Reverse((key, idx))) = self.heap.pop() {
            if key.as_slice() > self.end.as_slice() {
                self.valid = false;
                return;
            }
            let val = self.sources[idx].value();
            self.sources[idx].advance();
            if self.sources[idx].valid() {
                self.heap.push(Reverse((self.sources[idx].key(), idx)));
            }
            if self.cur_key.as_ref() == Some(&key) {
                self.cur_val = val;
                continue;
            }
            self.cur_key = Some(key);
            self.cur_val = val;
            self.valid = true;
            return;
        }
        self.valid = false;
    }

    pub fn seek(&mut self, target: &[u8]) {
        for s in self.sources.iter_mut() {
            s.seek(target);
        }
        self.heap.clear();
        for (i, s) in self.sources.iter().enumerate() {
            if s.valid() {
                self.heap.push(Reverse((s.key(), i)));
            }
        }
        self.cur_key = None;
        self.step();
    }

    pub fn skip_group(&mut self, group_end: usize) {
        let group: Vec<u8> = if let Some(ref ck) = self.cur_key {
            if ck.len() >= group_end {
                ck[..group_end].to_vec()
            } else {
                return;
            }
        } else {
            return;
        };
        for s in &mut self.sources {
            s.skip_group(&group);
        }
        self.heap.clear();
        for (i, s) in self.sources.iter().enumerate() {
            if s.valid() {
                self.heap.push(Reverse((s.key(), i)));
            }
        }
        if let Some(Reverse((key, idx))) = self.heap.pop() {
            if key.as_slice() > self.end.as_slice() {
                self.valid = false;
                return;
            }
            self.cur_key = Some(key);
            self.cur_val = self.sources[idx].value();
            self.sources[idx].advance();
            if self.sources[idx].valid() {
                self.heap.push(Reverse((self.sources[idx].key(), idx)));
            }
            self.valid = true;
        } else {
            self.valid = false;
        }
    }

    pub fn is_valid(&self) -> bool {
        self.valid
    }

    pub fn current_key(&self) -> Option<&[u8]> {
        self.cur_key.as_deref()
    }

    pub fn invalidate(&mut self) {
        self.valid = false;
    }

    pub fn update_end(&mut self, end: &[u8]) {
        self.end = end.to_vec();
        for s in &mut self.sources {
            s.update_end(end);
        }
        if self.valid {
            if let Some(ref key) = self.cur_key {
                if key.as_slice() > end {
                    self.valid = false;
                }
            }
        }
    }
}

impl Cursor for MergedInner {
    fn is_valid(&self) -> bool { self.valid }
    fn current_key(&self) -> Option<&[u8]> { self.cur_key.as_deref() }
    fn step(&mut self) { MergedInner::step(self); }
    fn skip_group(&mut self, group_end: usize) { MergedInner::skip_group(self, group_end); }
    fn seek(&mut self, target: &[u8]) { MergedInner::seek(self, target); }
    fn update_end(&mut self, end: &[u8]) { MergedInner::update_end(self, end); }
    fn invalidate(&mut self) { self.valid = false; }
}

pub trait ReverseScanSource: Send {
    fn valid(&self) -> bool;
    fn key(&self) -> Vec<u8>;
    fn value(&self) -> Vec<u8>;
    fn prev(&mut self);
    fn seek_reverse(&mut self, target: &[u8]);
}

pub enum ReverseSourceKind {
    MemTable(ReversePageStoreIter),
    PageStore(ReversePageStoreIter),
}

pub struct ReversePageStoreIter {
    keys: Vec<Vec<u8>>,
    idx: usize,
    start: Vec<u8>,
    valid: bool,
}

impl ReversePageStoreIter {
    pub fn new(keys: Vec<Vec<u8>>, prefix: &[u8]) -> Self {
        let start = prefix.to_vec();
        let idx = 0;
        let valid = !keys.is_empty() && keys[idx].as_slice() >= start.as_slice();
        ReversePageStoreIter { keys, idx, start, valid }
    }
}

impl ReverseScanSource for ReversePageStoreIter {
    fn valid(&self) -> bool { self.valid }

    fn key(&self) -> Vec<u8> { self.keys[self.idx].clone() }

    fn value(&self) -> Vec<u8> { vec![] }

    fn prev(&mut self) {
        if !self.valid { return; }
        if self.idx + 1 < self.keys.len() {
            self.idx += 1;
            self.valid = self.keys[self.idx].as_slice() >= self.start.as_slice();
        } else {
            self.valid = false;
        }
    }

    fn seek_reverse(&mut self, target: &[u8]) {
        self.idx = self.keys.partition_point(|k| &k[..] > target);
        if self.idx < self.keys.len() {
            self.valid = self.keys[self.idx].as_slice() >= self.start.as_slice();
        } else {
            self.valid = false;
        }
    }
}

impl ReverseScanSource for ReverseSourceKind {
    fn valid(&self) -> bool {
        match self {
            ReverseSourceKind::MemTable(s) => s.valid(),
            ReverseSourceKind::PageStore(it) => it.valid(),
        }
    }

    fn key(&self) -> Vec<u8> {
        match self {
            ReverseSourceKind::MemTable(s) => s.key(),
            ReverseSourceKind::PageStore(it) => it.key(),
        }
    }

    fn value(&self) -> Vec<u8> {
        match self {
            ReverseSourceKind::MemTable(_) => vec![],
            ReverseSourceKind::PageStore(_) => vec![],
        }
    }

    fn prev(&mut self) {
        match self {
            ReverseSourceKind::MemTable(s) => s.prev(),
            ReverseSourceKind::PageStore(it) => it.prev(),
        }
    }

    fn seek_reverse(&mut self, target: &[u8]) {
        match self {
            ReverseSourceKind::MemTable(s) => s.seek_reverse(target),
            ReverseSourceKind::PageStore(it) => it.seek_reverse(target),
        }
    }
}

pub struct ReverseMergedInner {
    pub sources: Vec<ReverseSourceKind>,
    pub start: Vec<u8>,
    pub heap: BinaryHeap<(Vec<u8>, usize)>,
    pub cur_key: Option<Vec<u8>>,
    pub cur_val: Vec<u8>,
    pub valid: bool,
}

impl ReverseMergedInner {
    pub fn new(sources: Vec<ReverseSourceKind>, prefix: &[u8]) -> Self {
        let start = prefix.to_vec();
        let mut heap = BinaryHeap::new();
        for (i, s) in sources.iter().enumerate() {
            if s.valid() {
                heap.push((s.key(), i));
            }
        }
        let mut inner = ReverseMergedInner {
            sources,
            start,
            heap,
            cur_key: None,
            cur_val: Vec::new(),
            valid: false,
        };
        inner.step();
        inner
    }

    pub fn step(&mut self) {
        while let Some((key, idx)) = self.heap.pop() {
            if key.as_slice() < self.start.as_slice() {
                self.valid = false;
                return;
            }
            let val = self.sources[idx].value();
            self.sources[idx].prev();
            if self.sources[idx].valid() {
                self.heap.push((self.sources[idx].key(), idx));
            }
            if self.cur_key.as_ref() == Some(&key) {
                self.cur_val = val;
                continue;
            }
            self.cur_key = Some(key);
            self.cur_val = val;
            self.valid = true;
            return;
        }
        self.valid = false;
    }

    pub fn seek_reverse(&mut self, target: &[u8]) {
        for s in &mut self.sources {
            s.seek_reverse(target);
        }
        self.heap.clear();
        for (i, s) in self.sources.iter().enumerate() {
            if s.valid() {
                self.heap.push((s.key(), i));
            }
        }
        self.step();
    }
}

impl Cursor for ReverseMergedInner {
    fn is_valid(&self) -> bool { self.valid }
    fn current_key(&self) -> Option<&[u8]> { self.cur_key.as_deref() }
    fn step(&mut self) { ReverseMergedInner::step(self); }
    fn skip_group(&mut self, _: usize) {}
    fn seek(&mut self, target: &[u8]) { self.seek_reverse(target); }
    fn update_end(&mut self, _: &[u8]) {}
    fn invalidate(&mut self) { self.valid = false; }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mt_source(keys: Vec<&[u8]>) -> PageStoreIter {
        let owned: Vec<Vec<u8>> = keys.into_iter().map(|k| k.to_vec()).collect();
        PageStoreIter::new(owned, b"")
    }

    #[test]
    fn test_merge_single_source() {
        let s1 = mt_source(vec![b"a", b"b", b"c"]);
        let sources = vec![SourceKind::MemTable(s1)];
        let result = merge_collect(sources);
        assert_eq!(result.len(), 3);
        assert_eq!(result[0], (b"a".to_vec(), vec![]));
        assert_eq!(result[2], (b"c".to_vec(), vec![]));
    }

    #[test]
    fn test_merge_two_sources() {
        let s1 = mt_source(vec![b"a", b"c"]);
        let s2 = mt_source(vec![b"b", b"d"]);
        let sources = vec![SourceKind::MemTable(s1), SourceKind::MemTable(s2)];
        let result = merge_collect(sources);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].0, b"a".to_vec());
        assert_eq!(result[3].0, b"d".to_vec());
    }

    #[test]
    fn test_merge_overlapping_last_writer_wins() {
        let s1 = mt_source(vec![b"a"]);
        let s2 = mt_source(vec![b"a"]);
        let sources = vec![SourceKind::MemTable(s1), SourceKind::MemTable(s2)];
        let result = merge_collect(sources);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, b"a".to_vec());
    }

    #[test]
    fn test_merge_empty() {
        let sources: Vec<SourceKind> = vec![];
        let result = merge_collect(sources);
        assert!(result.is_empty());
    }

    #[test]
    fn test_merged_inner_seek() {
        let s1 = mt_source(vec![b"a", b"b", b"c", b"d"]);
        let sources = vec![SourceKind::MemTable(s1)];
        let mut merged = MergedInner::new(sources, b"");
        assert!(merged.valid);
        assert_eq!(merged.cur_key, Some(b"a".to_vec()));
        merged.seek(b"c");
        assert!(merged.valid);
        assert_eq!(merged.cur_key, Some(b"c".to_vec()));
    }

    #[test]
    fn test_merged_inner_skip_group() {
        let s1 = mt_source(vec![b"aa1", b"aa2", b"aa3", b"bb1"]);
        let sources = vec![SourceKind::MemTable(s1)];
        let mut merged = MergedInner::new(sources, b"");
        assert_eq!(merged.cur_key, Some(b"aa1".to_vec()));
        merged.skip_group(2);
        assert!(merged.valid);
        assert_eq!(merged.cur_key, Some(b"bb1".to_vec()));
    }

    #[test]
    fn test_reverse_merge() {
        let keys: Vec<Vec<u8>> = vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()];
        let mut rev_keys = keys.clone();
        rev_keys.reverse();
        let s = ReversePageStoreIter::new(rev_keys, b"");
        let sources = vec![ReverseSourceKind::MemTable(s)];
        let mut merged = ReverseMergedInner::new(sources, b"");
        assert!(merged.valid);
        assert_eq!(merged.cur_key, Some(b"c".to_vec()));
        merged.step();
        assert_eq!(merged.cur_key, Some(b"b".to_vec()));
        merged.step();
        assert_eq!(merged.cur_key, Some(b"a".to_vec()));
        merged.step();
        assert!(!merged.valid);
    }

    #[test]
    fn test_merged_inner_seek_19_entities() {
        let base: u64 = 0x40000000000001;
        let partner_aid: u32 = 100;
        let name_aid: u32 = 101;
        let mut all_keys: Vec<Vec<u8>> = Vec::new();
        for i in 0..19u64 {
            let e = base + i;
            let t = e;
            let suffix = !((t << 1) | 0);
            let mut key = Vec::new();
            key.extend_from_slice(&e.to_be_bytes());
            key.extend_from_slice(&partner_aid.to_be_bytes());
            key.extend_from_slice(&e.to_be_bytes());
            key.extend_from_slice(&suffix.to_be_bytes());
            all_keys.push(key);
        }
        for i in 0..19u64 {
            let e = base + i;
            let t = e;
            let suffix = !((t << 1) | 0);
            let mut key = Vec::new();
            key.extend_from_slice(&e.to_be_bytes());
            key.extend_from_slice(&name_aid.to_be_bytes());
            key.extend_from_slice(&e.to_be_bytes());
            key.extend_from_slice(&suffix.to_be_bytes());
            all_keys.push(key);
        }
        all_keys.sort();

        let s = PageStoreIter::new(all_keys, b"");
        let sources = vec![SourceKind::MemTable(s)];
        let mut merged = MergedInner::new(sources, b"");
        assert!(merged.valid);

        let mut seek_count = 0;
        let mut seek_found = Vec::new();
        loop {
            if !merged.valid { break; }
            let key = merged.cur_key.clone().unwrap();
            let a = u32::from_be_bytes(key[8..12].try_into().unwrap());
            if a == partner_aid {
                seek_count += 1;
                let e = u64::from_be_bytes(key[..8].try_into().unwrap());
                seek_found.push(e);
                let next_e = e + 1;
                let mut target = Vec::new();
                target.extend_from_slice(&next_e.to_be_bytes());
                target.extend_from_slice(&partner_aid.to_be_bytes());
                merged.seek(&target);
            } else {
                merged.step();
            }
        }
        assert_eq!(seek_count, 19, "merged seek: expected 19, got {} ({:?})", seek_count, seek_found);
    }
}
