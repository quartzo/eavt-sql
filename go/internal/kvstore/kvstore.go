// Package kvstore coordinates the MemTable + PageStore (+ journal) into the
// KVStore the EAVT layer and query engine read from.  Port of
// nim_kvstore/kvstore.nim (sync read + apply + flush + scan paths).
package kvstore

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"eavt-go/internal/cursor"
	"eavt-go/internal/memtable"
	"eavt-go/internal/pagestore"
)

const (
	maxJournalKeyLen = 65536
	maxJournalValLen = 65536
	journalResync    = 3
)

// Config configures a KVStore.
type Config struct {
	Backend        string
	Path           string
	ReadOnly       bool
	NumCf          int
	FlushThreshold uint64
	ReplayOff      bool
	PageCacheSize  int
	OwnsPath       bool
	GcMaxAgeSecs   uint64
	GcMaxRootCount int
}

// FromMap builds a Config from a string map (server config shape).
func FromMap(m map[string]string) Config {
	get := func(k, def string) string {
		if v, ok := m[k]; ok {
			return v
		}
		return def
	}
	cfg := Config{
		Backend:        get("backend", "file"),
		Path:           get("path", ""),
		ReadOnly:       get("read_only", "false") == "true",
		ReplayOff:      get("replay_off", "false") == "true",
		OwnsPath:       get("owns_path", "false") == "true",
		FlushThreshold: 16777216,
		NumCf:          64,
		GcMaxAgeSecs:   43200,
		GcMaxRootCount: 10,
	}
	if v, err := strconv.ParseUint(get("flush_threshold", "16777216"), 10, 64); err == nil {
		cfg.FlushThreshold = v
	}
	if v, err := strconv.Atoi(get("num_cf", "64")); err == nil {
		cfg.NumCf = v
	}
	if v, err := strconv.Atoi(get("page_cache_size", "0")); err == nil {
		cfg.PageCacheSize = v
	}
	if v, err := strconv.ParseUint(get("gc_max_age_secs", "43200"), 10, 64); err == nil {
		cfg.GcMaxAgeSecs = v
	}
	if v, err := strconv.Atoi(get("gc_root_count", "10")); err == nil {
		cfg.GcMaxRootCount = v
	}
	return cfg
}

// KVStore is the storage facade.
type KVStore struct {
	PS             *pagestore.Store
	MT             *memtable.MemTable
	memSize        uint64
	ReadOnly       bool
	NumCf          int
	FlushThreshold uint64
	GcMaxAgeSecs   uint64
	GcMaxRootCount int
	// snapshotMu makes "capture the run set + page-store root" atomic with
	// respect to publish (which swaps the root and clears draining).  Without
	// it a cursor opening mid-publish could see the new root AND the old
	// draining runs, double-counting the flushed data.
	snapshotMu  sync.RWMutex
	flushActive bool
	path        string
	ownsPath    bool

	// JournalSink, when set, receives journal entries instead of the file
	// fallback (the transactor wires it to the WAL).
	JournalSink func(entries []memtable.CfKey)
	// JournalSeal is called at flush capture time; it returns the logical WAL
	// boundary whose records the flush makes durable.
	JournalSeal func() int64
	// WalDurableUpTo holds the logical WAL position made durable by the last
	// published flush (the WAL deletes covered segments).
	WalDurableUpTo *atomic.Int64
	// OnFlushRequest arms a background flusher (server). nil => explicit Flush.
	OnFlushRequest func()
	// OnFlushPublish is called after a flush publishes a new root.
	OnFlushPublish func(rootName string, maxT int64)
}

// New opens a KVStore.
func New(cfg Config) (*KVStore, error) {
	if cfg.Backend == "" {
		cfg.Backend = "file"
	}
	if cfg.NumCf == 0 {
		cfg.NumCf = 64
	}
	if cfg.Path == "" {
		return nil, fmt.Errorf("kvstore: path is required")
	}
	if cfg.FlushThreshold == 0 {
		cfg.FlushThreshold = 16777216
	}
	ps, err := pagestore.Open(pagestore.Config{
		Backend:       cfg.Backend,
		Path:          cfg.Path,
		ReadOnly:      cfg.ReadOnly,
		NumCf:         cfg.NumCf,
		PageCacheSize: cfg.PageCacheSize,
		OwnsPath:      false,
	})
	if err != nil {
		return nil, err
	}
	kv := &KVStore{
		PS:             ps,
		MT:             memtable.New(cfg.NumCf),
		ReadOnly:       cfg.ReadOnly,
		NumCf:          cfg.NumCf,
		FlushThreshold: cfg.FlushThreshold,
		GcMaxAgeSecs:   cfg.GcMaxAgeSecs,
		GcMaxRootCount: cfg.GcMaxRootCount,
		path:           cfg.Path,
		ownsPath:       cfg.OwnsPath,
	}
	if !cfg.ReadOnly && !cfg.ReplayOff {
		if err := kv.replayJournals(); err != nil {
			return nil, err
		}
	}
	return kv, nil
}

// Close releases the store.
func (kv *KVStore) Close() error {
	var err error
	if kv.PS != nil {
		err = kv.PS.Close()
		kv.PS = nil
	}
	if kv.ownsPath && kv.path != "" {
		_ = os.RemoveAll(kv.path)
	}
	return err
}

// MemtableSize returns the active memtable size.
func (kv *KVStore) MemtableSize() uint64 { return kv.memSize }

func (kv *KVStore) journaling() bool { return kv.path != "" && !kv.ReadOnly }

// ── journal format ───────────────────────────────────────────────────────

func journalRecordLenAt(data []byte, pos int) int {
	if pos+10 > len(data) {
		return -1
	}
	klen := int(data[pos])<<24 | int(data[pos+1])<<16 | int(data[pos+2])<<8 | int(data[pos+3])
	if klen < 1 || klen > maxJournalKeyLen {
		return -1
	}
	if pos+4+klen+4 > len(data) {
		return -1
	}
	if int(data[pos+4]) > 63 {
		return -1
	}
	vp := pos + 4 + klen
	vlen := int(data[vp])<<24 | int(data[vp+1])<<16 | int(data[vp+2])<<8 | int(data[vp+3])
	if vlen > maxJournalValLen {
		return -1
	}
	if vp+4+vlen > len(data) {
		return -1
	}
	return 4 + klen + 4 + vlen
}

func journalChainLenAt(data []byte, pos int) int {
	p := pos
	n := 0
	for p+10 <= len(data) {
		rl := journalRecordLenAt(data, p)
		if rl < 0 {
			break
		}
		p += rl
		n++
	}
	return n
}

func journalResyncFrom(data []byte, broken int) int {
	c := broken + 1
	for c+10 <= len(data) {
		p := c
		chain := 0
		for p+10 <= len(data) {
			rl := journalRecordLenAt(data, p)
			if rl < 0 {
				break
			}
			p += rl
			chain++
		}
		if chain >= journalResync {
			return c
		}
		if chain > 0 && p+10 > len(data) {
			return c
		}
		c++
	}
	return -1
}

// ParseJournalRecords parses journal-format bytes into key-only CfKey entries.
func ParseJournalRecords(data []byte) []memtable.CfKey {
	var out []memtable.CfKey
	pos := 0
	for pos+10 <= len(data) {
		rl := journalRecordLenAt(data, pos)
		if rl > 0 {
			klen := int(data[pos])<<24 | int(data[pos+1])<<16 | int(data[pos+2])<<8 | int(data[pos+3])
			cf := data[pos+4]
			if cf <= 3 {
				key := make([]byte, klen-1)
				copy(key, data[pos+5:pos+5+klen-1])
				out = append(out, memtable.CfKey{Cf: cf, Key: key})
			}
			pos += rl
			continue
		}
		c := journalResyncFrom(data, pos)
		if c < 0 {
			break
		}
		pos = c
	}
	return out
}

func (kv *KVStore) replayJournals() error {
	jdir := filepath.Join(kv.path, "journal")
	legacy := filepath.Join(jdir, "journal")
	var files []string
	if _, err := os.Stat(legacy); err == nil {
		files = append(files, legacy)
	}
	entries, err := os.ReadDir(jdir)
	if err == nil {
		type seg struct {
			idx  int
			path string
		}
		var segs []seg
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() || !strings.HasPrefix(name, "journal.") {
				continue
			}
			idx, err := strconv.Atoi(name[len("journal."):])
			if err != nil {
				continue
			}
			segs = append(segs, seg{idx: idx, path: filepath.Join(jdir, name)})
		}
		sort.Slice(segs, func(i, j int) bool { return segs[i].idx < segs[j].idx })
		for _, s := range segs {
			files = append(files, s.path)
		}
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil || len(data) == 0 {
			continue
		}
		recs := ParseJournalRecords(data)
		if len(recs) > 0 {
			kv.memSize = kv.MT.Batch(recs)
		}
	}
	return nil
}

func writeJournalRecord(cf uint8, key, value []byte, deleted bool) []byte {
	totKlen := 1 + len(key)
	out := make([]byte, 0, 4+totKlen+4+len(value)+1)
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(totKlen))
	out = append(out, hdr[:]...)
	out = append(out, cf)
	out = append(out, key...)
	if deleted {
		out = append(out, 0xff, 0xff, 0xff, 0xff, 0)
		return out
	}
	binary.BigEndian.PutUint32(hdr[:], uint32(len(value)))
	out = append(out, hdr[:]...)
	out = append(out, value...)
	out = append(out, 0)
	return out
}

func (kv *KVStore) journalDeliver(entries []memtable.CfKey) {
	if kv.JournalSink != nil {
		kv.JournalSink(entries)
		return
	}
	path := filepath.Join(kv.path, "journal", "journal")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	for _, e := range entries {
		_, _ = f.Write(writeJournalRecord(e.Cf, e.Key, nil, false))
	}
}

// ── apply (replica stream) ───────────────────────────────────────────────

// ApplyJournalRecords applies journal-format bytes to the memtable.
func (kv *KVStore) ApplyJournalRecords(data []byte) {
	if len(data) == 0 {
		return
	}
	entries := ParseJournalRecords(data)
	if len(entries) > 0 {
		kv.memSize = kv.MT.Batch(entries)
	}
}

// ApplyJournalRecordsExpanded applies pre-parsed CfKey entries.
func (kv *KVStore) ApplyJournalRecordsExpanded(entries []memtable.CfKey) {
	if len(entries) == 0 {
		return
	}
	kv.memSize = kv.MT.Batch(entries)
}

// SealLiveToFlush freezes the live memtable into draining runs.
func (kv *KVStore) SealLiveToFlush() {
	kv.MT.FreezeAllCapture()
	kv.flushActive = true
	kv.memSize = 0
}

// RootHasData reports whether any of CFs 0..3 carries leaves.
func (kv *KVStore) RootHasData() bool {
	trees := kv.PS.Trees()
	n := 4
	if len(trees) < n {
		n = len(trees)
	}
	for cf := 0; cf < n; cf++ {
		if trees[cf].NumLeaves > 0 {
			return true
		}
	}
	return false
}

// PublishRoot loads a root and discards the pending draining runs.
func (kv *KVStore) PublishRoot(rootName string) {
	kv.snapshotMu.Lock()
	loaded, err := kv.PS.LoadRoot(rootName)
	if err == nil && loaded {
		kv.MT.Publish()
		kv.flushActive = false
		kv.memSize = 0
	}
	kv.snapshotMu.Unlock()
}

// ── point operations ─────────────────────────────────────────────────────

// Get reports whether a key-only key exists.
func (kv *KVStore) Get(cf int, key []byte) (bool, error) {
	if kv.MT.ContainsAny(cf, key) {
		return true, nil
	}
	return kv.PS.KeyExists(cf, key)
}

// GetKv returns a KV value.
func (kv *KVStore) GetKv(cf int, key []byte) ([]byte, bool, error) {
	switch kv.MT.LookupKv(cf, key) {
	case memtable.KvValue:
		v, ok := kv.MT.GetValue(cf, key)
		return v, ok, nil
	case memtable.KvDeleted:
		return nil, false, nil
	}
	return kv.PS.KeyExistsKv(cf, key)
}

// Put writes a key-only entry.
func (kv *KVStore) Put(cf int, key []byte) {
	kv.memSize = kv.MT.Put(cf, key)
	if kv.journaling() {
		kv.journalDeliver([]memtable.CfKey{{Cf: uint8(cf), Key: append([]byte(nil), key...)}})
	}
	kv.maybeArmFlush()
}

// PutKv writes a key-value entry.
func (kv *KVStore) PutKv(cf int, key, value []byte) {
	kv.memSize = kv.MT.PutKv(cf, key, value)
	if kv.journaling() {
		kv.journalDeliver([]memtable.CfKey{{Cf: uint8(cf), Key: append([]byte(nil), key...)}})
	}
	kv.maybeArmFlush()
}

// DeleteKv writes a tombstone.
func (kv *KVStore) DeleteKv(cf int, key []byte) {
	kv.MT.DeleteKv(cf, key)
	if kv.journaling() {
		path := filepath.Join(kv.path, "journal", "journal")
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err == nil {
			_, _ = f.Write(writeJournalRecord(uint8(cf), key, nil, true))
			_ = f.Close()
		}
	}
	kv.maybeArmFlush()
}

// BatchWrite applies a batch of key-only entries.
func (kv *KVStore) BatchWrite(entries []memtable.CfKey, journal bool) {
	if journal && kv.journaling() && len(entries) > 0 {
		kv.journalDeliver(entries)
	}
	kv.memSize = kv.MT.Batch(entries)
	kv.maybeArmFlush()
}

// JournalOnly journals entries without inserting them.
func (kv *KVStore) JournalOnly(entries []memtable.CfKey) {
	if kv.journaling() && len(entries) > 0 {
		kv.journalDeliver(entries)
	}
}

func (kv *KVStore) maybeArmFlush() {
	if kv.memSize >= kv.FlushThreshold && kv.OnFlushRequest != nil {
		kv.OnFlushRequest()
	}
}

// ── flush ────────────────────────────────────────────────────────────────

// FlushBatch is the captured state of one flush.
type FlushBatch struct {
	KeysByCf     map[int][][]byte
	PairsByCf    map[int][][2][]byte
	DeletedByCf  map[int][][]byte
	BaseTrees    []pagestore.CfTree
	SealBoundary int64
	MaxT         int64
}

// FlushActive reports whether a capture is in flight.
func (kv *KVStore) FlushActive() bool { return kv.flushActive }

// CaptureFlush freezes the memtable and collects the draining data.  Call
// under the engine lock; returns false when read-only or a flush is in flight.
func (kv *KVStore) CaptureFlush() (*FlushBatch, bool) {
	if kv.ReadOnly || kv.flushActive {
		return nil, false
	}
	captured := kv.MT.FreezeAllCapture()
	kv.flushActive = true
	kv.memSize = 0
	b := &FlushBatch{
		KeysByCf: map[int][][]byte{}, PairsByCf: map[int][][2][]byte{},
		DeletedByCf: map[int][][]byte{}, SealBoundary: -1, MaxT: -1,
	}
	if kv.JournalSeal != nil {
		b.SealBoundary = kv.JournalSeal()
	}
	for cf := 0; cf < kv.NumCf; cf++ {
		runs := captured[cf]
		if len(runs) == 0 {
			continue
		}
		if cf >= 10 {
			pairs, deleted := memtable.DrainKvSorted(runs)
			if len(pairs) > 0 {
				b.PairsByCf[cf] = pairs
			}
			if len(deleted) > 0 {
				b.DeletedByCf[cf] = deleted
			}
		} else {
			keys := memtable.DrainSorted(runs)
			if len(keys) > 0 {
				b.KeysByCf[cf] = keys
			}
		}
	}
	for cf, keys := range b.KeysByCf {
		if cf >= 10 {
			continue
		}
		for _, k := range keys {
			if len(k) < 8 {
				continue
			}
			var sf uint64
			for _, x := range k[len(k)-8:] {
				sf = (sf << 8) | uint64(x)
			}
			if kt := int64(sf >> 1); kt > b.MaxT {
				b.MaxT = kt
			}
		}
	}
	b.BaseTrees = kv.PS.BaseTrees()
	return b, true
}

// PrepareFlush does the heavy blob I/O off the engine lock.
func (kv *KVStore) PrepareFlush(b *FlushBatch) ([]pagestore.CfTree, string, error) {
	trees, root, err := kv.PS.PrepareMergeMap(b.BaseTrees, b.KeysByCf)
	if err != nil {
		return nil, "", err
	}
	if len(b.PairsByCf) > 0 || len(b.DeletedByCf) > 0 {
		trees, root, err = kv.PS.PrepareMergeKv(trees, b.PairsByCf, b.DeletedByCf)
		if err != nil {
			return nil, "", err
		}
	}
	return trees, root, nil
}

// PublishFlush swaps in the prepared trees.  Call under the engine lock.
func (kv *KVStore) PublishFlush(b *FlushBatch, trees []pagestore.CfTree, root string) {
	kv.snapshotMu.Lock()
	kv.PS.PublishTrees(trees, root)
	kv.MT.Publish()
	kv.flushActive = false
	kv.memSize = 0
	kv.snapshotMu.Unlock()
	if b.SealBoundary >= 0 && kv.WalDurableUpTo != nil {
		kv.WalDurableUpTo.Store(b.SealBoundary)
	}
	if kv.OnFlushPublish != nil {
		kv.OnFlushPublish(root, b.MaxT)
	}
}

// Flush is the synchronous capture+prepare+publish (tests, sync callers).
func (kv *KVStore) Flush() error {
	b, ok := kv.CaptureFlush()
	if !ok {
		return nil
	}
	trees, root, err := kv.PrepareFlush(b)
	if err != nil {
		return err
	}
	kv.PublishFlush(b, trees, root)
	return nil
}

// ── scan cursors ─────────────────────────────────────────────────────────

// OpenScanCursor opens a key-only scan cursor over cf.
func (kv *KVStore) OpenScanCursor(cf int) *cursor.MergedCursor {
	kv.snapshotMu.RLock()
	runs := kv.MT.SnapshotRuns(cf)
	tree := kv.PS.Tree(cf)
	kv.snapshotMu.RUnlock()
	psc := pagestore.NewCursor(kv.PS, cf, tree.RootUUID, tree.Height, false)
	var sources []cursor.Cursor
	sources = append(sources, cursor.NewPageStoreCursor(psc))
	for _, r := range runs {
		sources = append(sources, cursor.NewRunCursor(memtable.NewRunCursor(r)))
	}
	mc := cursor.NewMergedCursor(sources)
	mc.CF = cf
	mc.PSRootUUID = tree.RootUUID
	mc.PSHeight = tree.Height
	mc.RunGen = kv.MT.Gen()
	return mc
}

// OpenScanCursorKv opens a key-value scan cursor over cf (>= 10).
func (kv *KVStore) OpenScanCursorKv(cf int) *cursor.MergedCursor {
	kv.snapshotMu.RLock()
	runs := kv.MT.SnapshotRuns(cf)
	tree := kv.PS.Tree(cf)
	kv.snapshotMu.RUnlock()
	var sources []cursor.Cursor
	if tree.RootUUID != (pagestore.UUID{}) {
		psc := pagestore.NewCursor(kv.PS, cf, tree.RootUUID, tree.Height, true)
		sources = append(sources, cursor.NewPageStoreCursor(psc))
	}
	for _, r := range runs {
		sources = append(sources, cursor.NewRunKvCursor(memtable.NewRunCursor(r)))
	}
	mc := cursor.NewMergedCursor(sources)
	mc.IsKv = true
	mc.CF = cf
	mc.PSRootUUID = tree.RootUUID
	mc.PSHeight = tree.Height
	mc.RunGen = kv.MT.Gen()
	return mc
}
