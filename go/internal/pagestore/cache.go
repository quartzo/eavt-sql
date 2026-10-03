package pagestore

import "sync"

type cacheKind int

const (
	ckBytes cacheKind = iota
	ckIndex
	ckLeafKeys
	ckLeafKV
)

type cacheEntry struct {
	kind    cacheKind
	data    []byte
	entries []IndexEntry
	leaf    *FlatLeaf
	leafKV  *FlatLeafKV
	size    int
	order   int64
}

type pageCache struct {
	mu        sync.Mutex
	m         map[UUID]*cacheEntry
	maxBytes  int
	curBytes  int
	nextOrder int64
}

func newPageCache(maxBytes int) *pageCache {
	return &pageCache{m: map[UUID]*cacheEntry{}, maxBytes: maxBytes, nextOrder: 1}
}

func (c *pageCache) evictToBudget(incoming int) {
	for c.curBytes+incoming > c.maxBytes && len(c.m) > 0 {
		var minKey UUID
		minOrder := int64(1<<63 - 1)
		found := false
		for k, v := range c.m {
			if !found || v.order < minOrder {
				minOrder = v.order
				minKey = k
				found = true
			}
		}
		c.curBytes -= c.m[minKey].size
		delete(c.m, minKey)
	}
}

func (c *pageCache) slotFor(u UUID, sz int) bool {
	if e, ok := c.m[u]; ok {
		c.curBytes -= e.size
		delete(c.m, u)
	}
	c.evictToBudget(sz)
	return sz <= c.maxBytes
}

func (c *pageCache) touch(e *cacheEntry) {
	e.order = c.nextOrder
	c.nextOrder++
}

func (c *pageCache) getBytes(u UUID) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.m[u]; ok && e.kind == ckBytes {
		c.touch(e)
		return e.data, true
	}
	return nil, false
}

func (c *pageCache) putBytes(u UUID, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.slotFor(u, len(data)) {
		return
	}
	c.curBytes += len(data)
	c.m[u] = &cacheEntry{kind: ckBytes, data: data, size: len(data), order: c.nextOrder}
	c.nextOrder++
}

func (c *pageCache) getIndex(u UUID) ([]IndexEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.m[u]; ok && e.kind == ckIndex {
		c.touch(e)
		return e.entries, true
	}
	return nil, false
}

func (c *pageCache) putIndex(u UUID, entries []IndexEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()

	sz := 0
	for _, e := range entries {
		sz += len(e.Key) + 16 + 32
	}
	if !c.slotFor(u, sz) {
		return
	}
	c.curBytes += sz
	c.m[u] = &cacheEntry{kind: ckIndex, entries: entries, size: sz, order: c.nextOrder}
	c.nextOrder++
}

func (c *pageCache) getLeafKeys(u UUID) (*FlatLeaf, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.m[u]; ok && e.kind == ckLeafKeys {
		c.touch(e)
		return e.leaf, true
	}
	return nil, false
}

func (c *pageCache) putLeafKeys(u UUID, leaf *FlatLeaf) {
	c.mu.Lock()
	defer c.mu.Unlock()

	sz := leaf.Bytes()
	if !c.slotFor(u, sz) {
		return
	}
	c.curBytes += sz
	c.m[u] = &cacheEntry{kind: ckLeafKeys, leaf: leaf, size: sz, order: c.nextOrder}
	c.nextOrder++
}

func (c *pageCache) getLeafKV(u UUID) (*FlatLeafKV, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.m[u]; ok && e.kind == ckLeafKV {
		c.touch(e)
		return e.leafKV, true
	}
	return nil, false
}

func (c *pageCache) putLeafKV(u UUID, leaf *FlatLeafKV) {
	c.mu.Lock()
	defer c.mu.Unlock()

	sz := leaf.Bytes()
	if !c.slotFor(u, sz) {
		return
	}
	c.curBytes += sz
	c.m[u] = &cacheEntry{kind: ckLeafKV, leafKV: leaf, size: sz, order: c.nextOrder}
	c.nextOrder++
}
