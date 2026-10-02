// gc.go — page-store garbage collection: roots and blobs no longer reachable
// from the retained root set are deleted.  Port of nim_page_store's GC.
package pagestore

import "encoding/binary"

// ClassifyRoots splits roots (newest-first) into keep/remove by age and count.
func ClassifyRoots(roots []string, maxAgeSecs uint64, maxRootCount int) (keep, remove []string) {
	if len(roots) == 0 {
		return nil, nil
	}
	latestUs := ParseRootUs(roots[0])
	maxAgeUs := int64(maxAgeSecs) * 1_000_000
	for i, name := range roots {
		us := ParseRootUs(name)
		tooOld := latestUs-us > maxAgeUs
		beyondCount := maxRootCount > 0 && i >= maxRootCount
		if tooOld || beyondCount {
			remove = append(remove, name)
		} else {
			keep = append(keep, name)
		}
	}
	return keep, remove
}

func uuidFromID(id [16]byte) UUID { return UUID(id) }

func (s *Store) collectTreeUUIDs(tree CfTree, live map[UUID]bool) {
	if tree.RootUUID == (UUID{}) {
		return
	}
	live[tree.RootUUID] = true
	if tree.Height == 0 {
		return
	}
	data, ok, err := s.blobGet(tree.RootUUID)
	if err != nil || !ok {
		return
	}
	entries, err := DeserializeIndexPage(data)
	if err != nil {
		return
	}
	for _, e := range entries {
		live[e.UUID] = true
		if tree.Height > 1 {
			s.collectTreeUUIDs(CfTree{RootUUID: e.UUID, Height: tree.Height - 1}, live)
		}
	}
}

// HasOldRoots is a cheap GC-candidate check (lists roots only).
func (s *Store) HasOldRoots(maxAgeSecs uint64, maxRootCount int) bool {
	roots, err := s.blobs.ListRoots()
	if err != nil {
		return false
	}
	_, remove := ClassifyRoots(roots, maxAgeSecs, maxRootCount)
	return len(remove) > 0
}

// GcFull removes unreachable roots and blobs; returns a 41-byte report
// (5 little-endian uint64 + dry-run flag).
func (s *Store) GcFull(maxAgeSecs uint64, maxRootCount int, dryRun bool) ([]byte, error) {
	if s.readOnly {
		return nil, errf("read-only")
	}
	roots, err := s.blobs.ListRoots()
	if err != nil {
		return nil, err
	}
	if len(roots) == 0 {
		return nil, nil
	}
	rootsScanned := len(roots)
	keep, remove := ClassifyRoots(roots, maxAgeSecs, maxRootCount)

	// Fail-stop: any unreadable kept root aborts before any deletion.
	live := map[UUID]bool{}
	for _, name := range keep {
		data, ok, err := s.blobGetRoot(name)
		if err != nil || !ok {
			return nil, errf("gcFull: root %s unreadable while building live-set", name)
		}
		trees, err := DeserializeRoot(data)
		if err != nil {
			return nil, err
		}
		for _, t := range trees {
			s.collectTreeUUIDs(t, live)
		}
	}
	rootsRemoved := len(remove)
	if !dryRun {
		for _, name := range remove {
			_ = s.blobs.DeleteRoot(name)
		}
	}

	all, err := s.blobs.List()
	if err != nil {
		return nil, err
	}
	blobsScanned := len(all)
	blobsRemoved := 0
	for _, id := range all {
		if live[uuidFromID(id)] {
			continue
		}
		if dryRun {
			continue
		}
		if err := s.blobs.Delete(id); err != nil {
			continue
		}
		blobsRemoved++
	}

	out := make([]byte, 41)
	binary.LittleEndian.PutUint64(out[0:], uint64(rootsScanned))
	binary.LittleEndian.PutUint64(out[8:], uint64(rootsRemoved))
	binary.LittleEndian.PutUint64(out[16:], uint64(blobsScanned))
	binary.LittleEndian.PutUint64(out[24:], uint64(blobsRemoved))
	binary.LittleEndian.PutUint64(out[32:], uint64(len(live)))
	if dryRun {
		out[40] = 1
	}
	return out, nil
}
