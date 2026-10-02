package pagestore

import (
	"os"
	"sync"

	"github.com/klauspost/compress/zstd"

	"eavt-go/internal/blobstore"
)

var (
	zstdEncOnce sync.Once
	zstdEnc     *zstd.Encoder
	zstdDecOnce sync.Once
	zstdDec     *zstd.Decoder
)

func encoder() *zstd.Encoder {
	zstdEncOnce.Do(func() {
		zstdEnc, _ = zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	})
	return zstdEnc
}

func decoder() *zstd.Decoder {
	zstdDecOnce.Do(func() {
		zstdDec, _ = zstd.NewReader(nil)
	})
	return zstdDec
}

func compress(data []byte) []byte {
	return encoder().EncodeAll(data, nil)
}

// Decompress returns data unchanged when it is not a zstd frame.
func Decompress(data []byte) ([]byte, error) {
	if len(data) < 4 || data[0] != 0x28 || data[1] != 0xb5 || data[2] != 0x2f || data[3] != 0xfd {
		return data, nil
	}
	return decoder().DecodeAll(data, nil)
}

// Config configures a PageStore.
type Config struct {
	Backend       string
	Path          string
	ReadOnly      bool
	PageCacheSize int
	NumCf         int
	OwnsPath      bool
}

// Store is a page store instance.
type Store struct {
	blobs       *blobstore.FileBlobStore
	trees       []CfTree
	numCf       int
	readOnly    bool
	currentRoot string
	cache       *pageCache
	dbPath      string
	ownsPath    bool
}

// Open opens (and optionally creates) a page store.
func Open(cfg Config) (*Store, error) {
	if cfg.Backend == "" {
		cfg.Backend = "file"
	}
	if cfg.Backend != "file" {
		return nil, errf("unsupported backend %q", cfg.Backend)
	}
	if cfg.Path == "" {
		return nil, errf("pagestore: path is required")
	}
	if cfg.NumCf == 0 {
		cfg.NumCf = 64
	}
	if cfg.PageCacheSize == 0 {
		cfg.PageCacheSize = 536870912
	}
	blobs, err := blobstore.New(cfg.Path, cfg.ReadOnly)
	if err != nil {
		return nil, err
	}
	s := &Store{
		blobs:    blobs,
		numCf:    cfg.NumCf,
		readOnly: cfg.ReadOnly,
		cache:    newPageCache(cfg.PageCacheSize),
		dbPath:   cfg.Path,
		ownsPath: cfg.OwnsPath,
	}
	roots, err := blobs.ListRoots()
	if err != nil {
		return nil, err
	}
	if len(roots) > 0 {
		data, ok, err := s.blobGetRoot(roots[0])
		if err != nil || !ok {
			return nil, errf("pagestore: latest root %s unreadable", roots[0])
		}
		trees, err := DeserializeRoot(data)
		if err != nil {
			return nil, err
		}
		s.trees = trees
		for len(s.trees) < s.numCf {
			s.trees = append(s.trees, EmptyTree())
		}
		s.currentRoot = roots[0]
	} else {
		s.trees = make([]CfTree, s.numCf)
		name := MakeRootName()
		if !s.blobPutRoot(name, SerializeRoot(s.trees)) {
			return nil, errf("pagestore: cannot write initial root")
		}
		s.currentRoot = name
	}
	return s, nil
}

// Close releases the store (and removes the dir when OwnsPath).
func (s *Store) Close() error {
	if s.ownsPath && s.dbPath != "" {
		_ = os.RemoveAll(s.dbPath)
	}
	return nil
}

// Trees returns the current CF trees.
func (s *Store) Trees() []CfTree { return s.trees }

// NumCf returns the configured CF count.
func (s *Store) NumCf() int { return s.numCf }

// CurrentRoot returns the current root name.
func (s *Store) CurrentRoot() string { return s.currentRoot }

// SetReadOnly flips the read-only flag (not used by the replica read path).
func (s *Store) ReadOnly() bool { return s.readOnly }

// ── blob helpers ─────────────────────────────────────────────────────────

func (s *Store) blobPut(data []byte) (UUID, error) {
	id, err := s.blobs.Put(compress(data))
	if err != nil {
		return UUID{}, err
	}
	var u UUID
	copy(u[:], id[:])
	return u, nil
}

func (s *Store) blobGet(u UUID) ([]byte, bool, error) {
	var id blobstore.ID
	copy(id[:], u[:])
	data, ok, err := s.blobs.Get(id)
	if err != nil || !ok {
		return nil, ok, err
	}
	out, err := Decompress(data)
	return out, true, err
}

func (s *Store) blobPutRoot(name string, data []byte) bool {
	return s.blobs.PutRoot(name, compress(data)) == nil
}

func (s *Store) blobGetRoot(name string) ([]byte, bool, error) {
	data, ok, err := s.blobs.GetRoot(name)
	if err != nil || !ok {
		return nil, ok, err
	}
	out, err := Decompress(data)
	return out, true, err
}

// ── B-tree reads ─────────────────────────────────────────────────────────

func (s *Store) loadLeafRaw(u UUID) ([]byte, error) {
	if cached, ok := s.cache.getBytes(u); ok {
		return cached, nil
	}
	data, ok, err := s.blobGet(u)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errf("leaf blob not found")
	}
	s.cache.putBytes(u, data)
	return data, nil
}

func (s *Store) loadLeafKeys(u UUID) ([][]byte, error) {
	if cached, ok := s.cache.getLeafKeys(u); ok {
		return cached, nil
	}
	raw, err := s.loadLeafRaw(u)
	if err != nil {
		return nil, err
	}
	keys, err := DeserializePage(raw)
	if err != nil {
		return nil, err
	}
	s.cache.putLeafKeys(u, keys)
	return keys, nil
}

func (s *Store) loadLeafPairs(u UUID) ([][2][]byte, error) {
	if cached, ok := s.cache.getLeafKV(u); ok {
		return cached, nil
	}
	raw, err := s.loadLeafRaw(u)
	if err != nil {
		return nil, err
	}
	pairs, err := DeserializePageKv(raw)
	if err != nil {
		return nil, err
	}
	s.cache.putLeafKV(u, pairs)
	return pairs, nil
}

func (s *Store) loadIndexPage(u UUID) ([]IndexEntry, error) {
	if cached, ok := s.cache.getIndex(u); ok {
		return cached, nil
	}
	raw, err := s.loadLeafRaw(u)
	if err != nil {
		return nil, err
	}
	entries, err := DeserializeIndexPage(raw)
	if err != nil {
		return nil, err
	}
	s.cache.putIndex(u, entries)
	return entries, nil
}

func hasPrefix(k, prefix []byte) bool {
	if len(k) < len(prefix) {
		return false
	}
	for i := range prefix {
		if k[i] != prefix[i] {
			return false
		}
	}
	return true
}

func (s *Store) collectKeysFromIndex(pageUUID UUID, height uint8, prefix []byte) ([][]byte, error) {
	data, ok, err := s.blobGet(pageUUID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errf("prefix scan: index page %s unreadable", uuidToHex(pageUUID))
	}
	entries, err := DeserializeIndexPage(data)
	if err != nil {
		return nil, err
	}
	start, end := FindPrefixRange(entries, prefix)
	var out [][]byte
	for i := start; i < end; i++ {
		child := entries[i].UUID
		if height == 1 {
			keys, err := s.loadLeafKeys(child)
			if err != nil {
				return nil, err
			}
			for _, k := range keys {
				if hasPrefix(k, prefix) {
					out = append(out, k)
				}
			}
		} else {
			sub, err := s.collectKeysFromIndex(child, height-1, prefix)
			if err != nil {
				return nil, err
			}
			out = append(out, sub...)
		}
	}
	return out, nil
}

// GetKeysInPrefix returns all keys in cf with the given prefix.
func (s *Store) GetKeysInPrefix(cf int, prefix []byte) ([][]byte, error) {
	if cf >= s.numCf {
		return nil, nil
	}
	tree := s.trees[cf]
	if tree.RootUUID == (UUID{}) {
		return nil, nil
	}
	if tree.Height == 0 {
		keys, err := s.loadLeafKeys(tree.RootUUID)
		if err != nil {
			return nil, err
		}
		var out [][]byte
		for _, k := range keys {
			if hasPrefix(k, prefix) {
				out = append(out, k)
			}
		}
		return out, nil
	}
	return s.collectKeysFromIndex(tree.RootUUID, tree.Height, prefix)
}

// KeyExists reports whether an exact key exists in cf.
func (s *Store) KeyExists(cf int, key []byte) (bool, error) {
	keys, err := s.GetKeysInPrefix(cf, key)
	if err != nil {
		return false, err
	}
	for _, k := range keys {
		if CmpSeq(k, key) == 0 {
			return true, nil
		}
	}
	return false, nil
}

// GetPairsInPrefix returns all (key, value) pairs in cf with the prefix.
func (s *Store) GetPairsInPrefix(cf int, prefix []byte) ([][2][]byte, error) {
	if cf >= s.numCf {
		return nil, nil
	}
	tree := s.trees[cf]
	if tree.RootUUID == (UUID{}) {
		return nil, nil
	}
	if tree.Height == 0 {
		pairs, err := s.loadLeafPairs(tree.RootUUID)
		if err != nil {
			return nil, err
		}
		var out [][2][]byte
		for _, p := range pairs {
			if hasPrefix(p[0], prefix) {
				out = append(out, p)
			}
		}
		return out, nil
	}
	data, ok, err := s.blobGet(tree.RootUUID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errf("prefix scan: root index page %s unreadable", uuidToHex(tree.RootUUID))
	}
	entries, err := DeserializeIndexPage(data)
	if err != nil {
		return nil, err
	}
	start, end := FindPrefixRange(entries, prefix)
	var out [][2][]byte
	for i := start; i < end; i++ {
		child := entries[i].UUID
		if tree.Height == 1 {
			pairs, err := s.loadLeafPairs(child)
			if err != nil {
				return nil, err
			}
			for _, p := range pairs {
				if hasPrefix(p[0], prefix) {
					out = append(out, p)
				}
			}
			continue
		}
		type node struct {
			uuid   UUID
			height uint8
		}
		stack := []node{{child, tree.Height - 1}}
		for len(stack) > 0 {
			n := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			d, ok, err := s.blobGet(n.uuid)
			if err != nil {
				return nil, err
			}
			if !ok {
				return nil, errf("prefix scan: child page %s unreadable", uuidToHex(n.uuid))
			}
			ents, err := DeserializeIndexPage(d)
			if err != nil {
				return nil, err
			}
			s2, e2 := FindPrefixRange(ents, prefix)
			for j := s2; j < e2; j++ {
				cu := ents[j].UUID
				if n.height == 1 {
					pairs, err := s.loadLeafPairs(cu)
					if err != nil {
						return nil, err
					}
					for _, p := range pairs {
						if hasPrefix(p[0], prefix) {
							out = append(out, p)
						}
					}
				} else {
					stack = append(stack, node{cu, n.height - 1})
				}
			}
		}
	}
	return out, nil
}

// KeyExistsKv returns the value for an exact key in a KV cf.
func (s *Store) KeyExistsKv(cf int, key []byte) ([]byte, bool, error) {
	pairs, err := s.GetPairsInPrefix(cf, key)
	if err != nil {
		return nil, false, err
	}
	for _, p := range pairs {
		if CmpSeq(p[0], key) == 0 {
			return p[1], true, nil
		}
	}
	return nil, false, nil
}

// LoadRoot swaps the store onto a named root (replica replica publication).
func (s *Store) LoadRoot(rootName string) (bool, error) {
	data, ok, err := s.blobGetRoot(rootName)
	if err != nil || !ok {
		return false, err
	}
	trees, err := DeserializeRoot(data)
	if err != nil {
		return false, err
	}
	s.trees = trees
	for len(s.trees) < s.numCf {
		s.trees = append(s.trees, EmptyTree())
	}
	s.currentRoot = rootName
	return true, nil
}

// ── COW write path ───────────────────────────────────────────────────────

func (s *Store) splitIndexEntries(entries []IndexEntry) [][]byte {
	return SplitIndexEntries(entries)
}

func (s *Store) writeIndexLevel(entries []IndexEntry) ([]IndexEntry, error) {
	ser := SerializeIndexPage(entries)
	if len(ser) <= IndexPageMaxSize || len(entries) <= 1 {
		uuid, err := s.blobPut(ser)
		if err != nil {
			return nil, err
		}
		return []IndexEntry{{Key: entries[0].Key, UUID: uuid}}, nil
	}
	pages := s.splitIndexEntries(entries)
	var out []IndexEntry
	for _, pageData := range pages {
		pageEntries, err := DeserializeIndexPage(pageData)
		if err != nil {
			return nil, err
		}
		if len(pageEntries) > 0 {
			uuid, err := s.blobPut(pageData)
			if err != nil {
				return nil, err
			}
			out = append(out, IndexEntry{Key: pageEntries[0].Key, UUID: uuid})
		}
	}
	return out, nil
}

func (s *Store) buildIndexTree(entries []IndexEntry, childHeight uint8) (UUID, uint8, error) {
	if len(entries) == 0 {
		return UUID{}, 0, nil
	}
	ser := SerializeIndexPage(entries)
	if len(ser) <= IndexPageMaxSize {
		uuid, err := s.blobPut(ser)
		return uuid, childHeight + 1, err
	}
	pages := s.splitIndexEntries(entries)
	if len(pages) == 1 {
		uuid, err := s.blobPut(pages[0])
		return uuid, childHeight + 1, err
	}
	var levelEntries []IndexEntry
	for _, pageData := range pages {
		pageEntries, err := DeserializeIndexPage(pageData)
		if err != nil {
			return UUID{}, 0, err
		}
		if len(pageEntries) > 0 {
			uuid, err := s.blobPut(pageData)
			if err != nil {
				return UUID{}, 0, err
			}
			levelEntries = append(levelEntries, IndexEntry{Key: pageEntries[0].Key, UUID: uuid})
		}
	}
	height := childHeight + 2
	for {
		ser2 := SerializeIndexPage(levelEntries)
		if len(ser2) <= IndexPageMaxSize {
			uuid, err := s.blobPut(ser2)
			return uuid, height, err
		}
		pages2 := s.splitIndexEntries(levelEntries)
		if len(pages2) == len(levelEntries) {
			uuid, err := s.blobPut(ser2)
			return uuid, height, err
		}
		var nextLevel []IndexEntry
		for _, pageData := range pages2 {
			pageEntries, err := DeserializeIndexPage(pageData)
			if err != nil {
				return UUID{}, 0, err
			}
			if len(pageEntries) > 0 {
				uuid, err := s.blobPut(pageData)
				if err != nil {
					return UUID{}, 0, err
				}
				nextLevel = append(nextLevel, IndexEntry{Key: pageEntries[0].Key, UUID: uuid})
			}
		}
		levelEntries = nextLevel
		height++
	}
}

func (s *Store) mergeLeaf(leafUUID UUID, hasRangeEnd bool, rangeEnd []byte,
	newKeys [][]byte, idx *int) ([]IndexEntry, error) {
	data, ok, err := s.blobGet(leafUUID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errf("leaf blob not found")
	}
	existing, err := DeserializePage(data)
	if err != nil {
		return nil, err
	}
	var toMerge [][]byte
	for *idx < len(newKeys) {
		if hasRangeEnd && CmpSeq(newKeys[*idx], rangeEnd) >= 0 {
			break
		}
		toMerge = append(toMerge, newKeys[*idx])
		*idx = *idx + 1
	}
	if len(toMerge) == 0 {
		return nil, nil
	}
	merged := make([][]byte, 0, len(existing)+len(toMerge))
	ei, mi := 0, 0
	for ei < len(existing) || mi < len(toMerge) {
		switch {
		case ei >= len(existing):
			merged = append(merged, toMerge[mi])
			mi++
		case mi >= len(toMerge):
			merged = append(merged, existing[ei])
			ei++
		case CmpSeq(existing[ei], toMerge[mi]) < 0:
			merged = append(merged, existing[ei])
			ei++
		case CmpSeq(toMerge[mi], existing[ei]) < 0:
			merged = append(merged, toMerge[mi])
			mi++
		default:
			merged = append(merged, existing[ei])
			ei++
			mi++
		}
	}
	pageList := BuildPages(merged)
	var entries []IndexEntry
	for _, pl := range pageList {
		if _, err := DeserializePage(pl[1]); err != nil {
			return nil, err
		}
		uuid, err := s.blobPut(pl[1])
		if err != nil {
			return nil, err
		}
		entries = append(entries, IndexEntry{Key: pl[0], UUID: uuid})
	}
	return entries, nil
}

func (s *Store) mergeSubtree(nodeUUID UUID, height uint8, hasRangeEnd bool, rangeEnd []byte,
	newKeys [][]byte, idx *int) ([]IndexEntry, error) {
	if height == 0 {
		return s.mergeLeaf(nodeUUID, hasRangeEnd, rangeEnd, newKeys, idx)
	}
	data, ok, err := s.blobGet(nodeUUID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	entries, err := DeserializeIndexPage(data)
	if err != nil {
		return nil, err
	}
	var newEntries []IndexEntry
	changed := false
	for i, e := range entries {
		childEnd := rangeEnd
		childHasEnd := hasRangeEnd
		if i+1 < len(entries) {
			childEnd = entries[i+1].Key
			childHasEnd = true
		}
		hasKeys := *idx < len(newKeys) && (!childHasEnd || CmpSeq(newKeys[*idx], childEnd) < 0)
		if !hasKeys {
			newEntries = append(newEntries, e)
			continue
		}
		childResult, err := s.mergeSubtree(e.UUID, height-1, childHasEnd, childEnd, newKeys, idx)
		if err != nil {
			return nil, err
		}
		if childResult == nil {
			newEntries = append(newEntries, e)
		} else {
			changed = true
			newEntries = append(newEntries, childResult...)
		}
	}
	if !changed {
		return nil, nil
	}
	return s.writeIndexLevel(newEntries)
}

type cfKeys struct {
	cf   int
	keys [][]byte
}

// CommitMerge merges sorted keys into the key-only CFs and publishes a root.
// BaseTrees returns a copy of the current CF trees.
func (s *Store) BaseTrees() []CfTree {
	out := make([]CfTree, len(s.trees))
	copy(out, s.trees)
	return out
}

// PublishTrees swaps in prepared trees and the new root (call under the lock).
func (s *Store) PublishTrees(trees []CfTree, root string) {
	s.trees = trees
	s.currentRoot = root
}

// PrepareMerge computes merged key-only trees and writes the new root WITHOUT
// mutating the store, so the blob I/O can run off the engine lock.
func (s *Store) PrepareMerge(baseTrees []CfTree, keysByCf []cfKeys) ([]CfTree, string, error) {
	if s.readOnly {
		return nil, "", errf("read-only")
	}
	newTrees := make([]CfTree, len(baseTrees))
	copy(newTrees, baseTrees)
	for _, ck := range keysByCf {
		if ck.cf >= len(newTrees) || len(ck.keys) == 0 {
			continue
		}
		tree := newTrees[ck.cf]
		idx := 0
		var newTree CfTree
		if tree.RootUUID == (UUID{}) {
			pageList := BuildPages(ck.keys)
			var entries []IndexEntry
			for _, pl := range pageList {
				if _, err := DeserializePage(pl[1]); err != nil {
					return nil, "", err
				}
				uuid, err := s.blobPut(pl[1])
				if err != nil {
					return nil, "", err
				}
				entries = append(entries, IndexEntry{Key: pl[0], UUID: uuid})
			}
			numLeaves := uint32(len(entries))
			root, height, err := s.buildIndexTree(entries, 0)
			if err != nil {
				return nil, "", err
			}
			if height == 0 {
				newTree = CfTree{RootUUID: root}
			} else {
				newTree = CfTree{RootUUID: root, Height: height, NumLeaves: numLeaves}
			}
		} else {
			res, err := s.mergeSubtree(tree.RootUUID, tree.Height, false, nil, ck.keys, &idx)
			if err != nil {
				return nil, "", err
			}
			switch {
			case res == nil:
				newTree = tree
			case len(res) == 1:
				newTree = CfTree{RootUUID: res[0].UUID, Height: tree.Height, NumLeaves: tree.NumLeaves}
			default:
				root, height, err := s.buildIndexTree(res, tree.Height)
				if err != nil {
					return nil, "", err
				}
				newTree = CfTree{RootUUID: root, Height: height, NumLeaves: tree.NumLeaves}
			}
		}
		newTrees[ck.cf] = newTree
	}
	newRoot := MakeRootName()
	if !s.blobPutRoot(newRoot, SerializeRoot(newTrees)) {
		return nil, "", errf("commitMerge: cannot write root")
	}
	return newTrees, newRoot, nil
}

// PrepareMergeMap is the map-based entry to PrepareMerge.
func (s *Store) PrepareMergeMap(baseTrees []CfTree, keysByCf map[int][][]byte) ([]CfTree, string, error) {
	var list []cfKeys
	for cf, keys := range keysByCf {
		list = append(list, cfKeys{cf: cf, keys: keys})
	}
	return s.PrepareMerge(baseTrees, list)
}

// CommitMerge is the synchronous (prepare + publish) convenience wrapper.
func (s *Store) CommitMerge(keysByCf []cfKeys) (string, error) {
	trees, root, err := s.PrepareMerge(s.BaseTrees(), keysByCf)
	if err != nil {
		return "", err
	}
	s.PublishTrees(trees, root)
	return root, nil
}

func (s *Store) CommitMergeMap(keysByCf map[int][][]byte) (string, error) {
	var list []cfKeys
	for cf, keys := range keysByCf {
		list = append(list, cfKeys{cf: cf, keys: keys})
	}
	return s.CommitMerge(list)
}

// CommitMergeKv merges (and deletes) key-value pairs in CFs >= 10.
func (s *Store) PrepareMergeKv(baseTrees []CfTree, pairsByCf map[int][][2][]byte, deletedByCf map[int][][]byte) ([]CfTree, string, error) {
	if s.readOnly {
		return nil, "", errf("read-only")
	}
	newTrees := make([]CfTree, len(baseTrees))
	copy(newTrees, baseTrees)
	deleted := map[int]map[string]bool{}
	for cf, keys := range deletedByCf {
		set := map[string]bool{}
		for _, k := range keys {
			set[string(k)] = true
		}
		deleted[cf] = set
	}
	inPairs := map[int]bool{}
	for cf := range pairsByCf {
		inPairs[cf] = true
	}
	rebuild := func(cf int, pairs [][2][]byte) error {
		if len(pairs) == 0 {
			newTrees[cf] = EmptyTree()
			return nil
		}
		pageList := BuildPagesKv(pairs)
		var entries []IndexEntry
		for _, pl := range pageList {
			if _, err := DeserializePageKv(pl[1]); err != nil {
				return err
			}
			uuid, err := s.blobPut(pl[1])
			if err != nil {
				return err
			}
			entries = append(entries, IndexEntry{Key: pl[0], UUID: uuid})
		}
		numLeaves := uint32(len(entries))
		root, height, err := s.buildIndexTree(entries, 0)
		if err != nil {
			return err
		}
		if height == 0 {
			newTrees[cf] = CfTree{RootUUID: root}
		} else {
			newTrees[cf] = CfTree{RootUUID: root, Height: height, NumLeaves: numLeaves}
		}
		return nil
	}

	for cf := range deletedByCf {
		if inPairs[cf] || cf >= s.numCf {
			continue
		}
		if newTrees[cf].RootUUID == (UUID{}) {
			continue
		}
		all, err := s.GetPairsInPrefix(cf, nil)
		if err != nil {
			return nil, "", err
		}
		delSet := deleted[cf]
		var live [][2][]byte
		for _, p := range all {
			if !delSet[string(p[0])] {
				live = append(live, p)
			}
		}
		if err := rebuild(cf, live); err != nil {
			return nil, "", err
		}
	}
	for cf, sortedPairs := range pairsByCf {
		if cf >= s.numCf || len(sortedPairs) == 0 {
			continue
		}
		tree := newTrees[cf]
		delSet := deleted[cf]
		if tree.RootUUID == (UUID{}) {
			var filtered [][2][]byte
			for _, p := range sortedPairs {
				if !delSet[string(p[0])] {
					filtered = append(filtered, p)
				}
			}
			if err := rebuild(cf, filtered); err != nil {
				return nil, "", err
			}
			continue
		}
		all, err := s.GetPairsInPrefix(cf, nil)
		if err != nil {
			return nil, "", err
		}
		var live [][2][]byte
		for _, p := range all {
			if !delSet[string(p[0])] {
				live = append(live, p)
			}
		}
		var merged [][2][]byte
		ai, bi := 0, 0
		for ai < len(live) && bi < len(sortedPairs) {
			c := CmpSeq(live[ai][0], sortedPairs[bi][0])
			switch {
			case c < 0:
				if !delSet[string(live[ai][0])] {
					merged = append(merged, live[ai])
				}
				ai++
			case c > 0:
				if !delSet[string(sortedPairs[bi][0])] {
					merged = append(merged, sortedPairs[bi])
				}
				bi++
			default:
				if !delSet[string(sortedPairs[bi][0])] {
					merged = append(merged, sortedPairs[bi])
				}
				ai++
				bi++
			}
		}
		for ; ai < len(live); ai++ {
			if !delSet[string(live[ai][0])] {
				merged = append(merged, live[ai])
			}
		}
		for ; bi < len(sortedPairs); bi++ {
			if !delSet[string(sortedPairs[bi][0])] {
				merged = append(merged, sortedPairs[bi])
			}
		}
		if err := rebuild(cf, merged); err != nil {
			return nil, "", err
		}
	}
	newRoot := MakeRootName()
	if !s.blobPutRoot(newRoot, SerializeRoot(newTrees)) {
		return nil, "", errf("commitMergeKv: cannot write root")
	}
	return newTrees, newRoot, nil
}

// CommitMergeKv is the synchronous (prepare + publish) convenience wrapper.
func (s *Store) CommitMergeKv(pairsByCf map[int][][2][]byte, deletedByCf map[int][][]byte) (string, error) {
	trees, root, err := s.PrepareMergeKv(s.BaseTrees(), pairsByCf, deletedByCf)
	if err != nil {
		return "", err
	}
	s.PublishTrees(trees, root)
	return root, nil
}
