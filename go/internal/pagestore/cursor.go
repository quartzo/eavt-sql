package pagestore

// Cursor is a lazy forward cursor over one CF's B-tree, pinned to the root
// captured at construction (COW snapshots stay consistent).  Port of
// nim_page_store/page_cursor.nim.
type Cursor struct {
	s          *Store
	cf         int
	AtEnd      bool
	indexStack []indexPos
	keys       [][]byte
	pairs      [][2][]byte
	leafIdx    int
	hasKey     bool
	curKey     []byte
	hasPair    bool
	curPair    [2][]byte
	rootUUID   UUID
	height     uint8
	isKv       bool
}

type indexPos struct {
	entries []IndexEntry
	pos     int
}

// NewCursor creates a cursor over cf.  When root is the empty UUID the cursor
// is immediately at end.
func NewCursor(s *Store, cf int, root UUID, height uint8, isKv bool) *Cursor {
	return &Cursor{s: s, cf: cf, rootUUID: root, height: height,
		isKv: isKv, leafIdx: -1, AtEnd: root == (UUID{})}
}

func (c *Cursor) loadLeaf(u UUID) error {
	if c.isKv {
		pairs, err := c.s.loadLeafPairs(u)
		if err != nil {
			return err
		}
		c.pairs = pairs
	} else {
		keys, err := c.s.loadLeafKeys(u)
		if err != nil {
			return err
		}
		c.keys = keys
	}
	c.leafIdx = -1
	return nil
}

func (c *Cursor) keyCount() int {
	if c.isKv {
		return len(c.pairs)
	}
	return len(c.keys)
}

func (c *Cursor) cmpKeyAt(i int, target []byte) int {
	if c.isKv {
		return CmpSeq(c.pairs[i][0], target)
	}
	return CmpSeq(c.keys[i], target)
}

func (c *Cursor) firstKeyAt(i int) []byte {
	if c.isKv {
		return c.pairs[i][0]
	}
	return c.keys[i]
}

func (c *Cursor) descendToFirstLeaf(u UUID, h uint8) error {
	c.indexStack = nil
	cur := u
	for h > 0 {
		entries, err := c.s.loadIndexPage(cur)
		if err != nil {
			return err
		}
		c.indexStack = append(c.indexStack, indexPos{entries: entries, pos: 0})
		cur = entries[0].UUID
		h--
	}
	return c.loadLeaf(cur)
}

func (c *Cursor) descendToLeafAt(u UUID, h uint8, target []byte) error {
	c.indexStack = nil
	cur := u
	for h > 0 {
		entries, err := c.s.loadIndexPage(cur)
		if err != nil {
			return err
		}
		lo, hi := 0, len(entries)
		for lo < hi {
			mid := (lo + hi) >> 1
			if CmpSeq(entries[mid].Key, target) <= 0 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		pos := 0
		if lo > 0 {
			pos = lo - 1
		}
		c.indexStack = append(c.indexStack, indexPos{entries: entries, pos: pos})
		cur = entries[pos].UUID
		h--
	}
	return c.loadLeaf(cur)
}

func (c *Cursor) advanceToNextLeaf() error {
	for len(c.indexStack) > 0 {
		top := &c.indexStack[len(c.indexStack)-1]
		top.pos++
		if top.pos < len(top.entries) {
			cur := top.entries[top.pos].UUID
			if c.height == 1 && len(c.indexStack) == 1 {
				return c.loadLeaf(cur)
			}
			for {
				entries, err := c.s.loadIndexPage(cur)
				if err != nil {
					return err
				}
				if len(entries) > 0 {
					c.indexStack = append(c.indexStack, indexPos{entries: entries, pos: 0})
					cur = entries[0].UUID
				} else {
					break
				}
			}
			return c.loadLeaf(cur)
		}
		c.indexStack = c.indexStack[:len(c.indexStack)-1]
	}
	c.AtEnd = true
	return nil
}

func (c *Cursor) advance() error {
	if c.AtEnd {
		return nil
	}
	c.hasKey = false
	c.hasPair = false
	for {
		c.leafIdx++
		if c.isKv {
			if c.leafIdx < len(c.pairs) {
				c.curPair = c.pairs[c.leafIdx]
				c.hasPair = true
				c.curKey = c.pairs[c.leafIdx][0]
				c.hasKey = true
				return nil
			}
		} else {
			if c.leafIdx < len(c.keys) {
				c.curKey = c.keys[c.leafIdx]
				c.hasKey = true
				return nil
			}
		}
		if len(c.indexStack) > 0 {
			if err := c.advanceToNextLeaf(); err != nil {
				return err
			}
			if c.AtEnd {
				return nil
			}
			continue
		}
		c.AtEnd = true
		return nil
	}
}

func (c *Cursor) ensure() error {
	if !c.hasKey && !c.AtEnd {
		if c.rootUUID == (UUID{}) {
			c.AtEnd = true
			return nil
		}
		if c.keyCount() == 0 && len(c.indexStack) == 0 {
			if c.height == 0 {
				if err := c.loadLeaf(c.rootUUID); err != nil {
					return err
				}
			} else if err := c.descendToFirstLeaf(c.rootUUID, c.height); err != nil {
				return err
			}
		}
		return c.advance()
	}
	return nil
}

// Peek returns the current key.
func (c *Cursor) Peek() ([]byte, bool, error) {
	if err := c.ensure(); err != nil {
		return nil, false, err
	}
	if c.AtEnd {
		return nil, false, nil
	}
	return c.curKey, c.hasKey, nil
}

// Next returns the current key and advances.
func (c *Cursor) Next() ([]byte, bool, error) {
	if err := c.ensure(); err != nil {
		return nil, false, err
	}
	key := c.curKey
	has := c.hasKey
	if err := c.advance(); err != nil {
		return nil, false, err
	}
	return key, has, nil
}

// PeekKv returns the current key-value pair.
func (c *Cursor) PeekKv() ([2][]byte, bool, error) {
	if err := c.ensure(); err != nil {
		return [2][]byte{}, false, err
	}
	if c.AtEnd {
		return [2][]byte{}, false, nil
	}
	return c.curPair, c.hasPair, nil
}

// NextKv returns the current pair and advances.
func (c *Cursor) NextKv() ([2][]byte, bool, error) {
	if err := c.ensure(); err != nil {
		return [2][]byte{}, false, err
	}
	pair := c.curPair
	has := c.hasPair
	if err := c.advance(); err != nil {
		return [2][]byte{}, false, err
	}
	return pair, has, nil
}

// Seek positions the cursor at the first key >= target.
func (c *Cursor) Seek(target []byte) error {
	if c.rootUUID == (UUID{}) {
		c.AtEnd = true
		return nil
	}
	keyCount := c.keyCount()
	if keyCount > 0 {
		if c.cmpKeyAt(0, target) <= 0 && c.cmpKeyAt(keyCount-1, target) >= 0 {
			lo, hi := 0, keyCount
			for lo < hi {
				mid := (lo + hi) >> 1
				if c.cmpKeyAt(mid, target) < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			c.leafIdx = lo - 1
			c.hasKey = false
			c.hasPair = false
			c.AtEnd = false
			return c.advance()
		}
	}
	if c.height == 0 {
		if err := c.loadLeaf(c.rootUUID); err != nil {
			return err
		}
	} else if err := c.descendToLeafAt(c.rootUUID, c.height, target); err != nil {
		return err
	}
	keyCount = c.keyCount()
	lo, hi := 0, keyCount
	for lo < hi {
		mid := (lo + hi) >> 1
		if c.cmpKeyAt(mid, target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	c.leafIdx = lo - 1
	c.hasKey = false
	c.hasPair = false
	c.AtEnd = false
	for !c.AtEnd {
		if err := c.advance(); err != nil {
			return err
		}
		if c.hasKey && CmpSeq(c.curKey, target) >= 0 {
			return nil
		}
	}
	c.AtEnd = true
	return nil
}

// Update repoints the cursor at a new root (clears internal state).
func (c *Cursor) Update(root UUID, height uint8) {
	c.rootUUID = root
	c.height = height
	c.indexStack = nil
	c.keys = nil
	c.pairs = nil
	c.leafIdx = 0
	c.hasKey = false
	c.hasPair = false
	c.AtEnd = root == (UUID{})
}
