package memtable

// RunCursor iterates one immutable sorted run (bisect seek + pointer advance).
// Port of nim_memtable/run_cursor.nim.
type RunCursor struct {
	run   *Run
	pos   int
	atEnd bool
}

// NewRunCursor creates a cursor over a run.
func NewRunCursor(r *Run) *RunCursor {
	c := &RunCursor{run: r}
	c.atEnd = r == nil || len(r.Records) == 0
	return c
}

func (c *RunCursor) seekStack(target []byte) {
	lo, hi := 0, len(c.run.Records)
	for lo < hi {
		mid := (lo + hi) >> 1
		if CmpKeys(recKey(c.run.Records[mid]), target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	c.pos = lo
}

func (c *RunCursor) advance() {
	if c.atEnd {
		return
	}
	c.pos++
	if c.pos >= len(c.run.Records) {
		c.atEnd = true
	}
}

// Peek returns the current key (including tombstones).
func (c *RunCursor) Peek() ([]byte, bool) {
	if c.atEnd || c.pos >= len(c.run.Records) {
		return nil, false
	}
	return copyBytes(recKey(c.run.Records[c.pos])), true
}

// Next returns the current key and advances.
func (c *RunCursor) Next() ([]byte, bool) {
	k, ok := c.Peek()
	if ok {
		c.advance()
	}
	return k, ok
}

// PeekKv returns the next active pair (skips tombstones).
func (c *RunCursor) PeekKv() ([2][]byte, bool) {
	for !c.atEnd {
		p := c.run.Records[c.pos]
		if !recDeleted(p) {
			return [2][]byte{copyBytes(recKey(p)), copyBytes(recValue(p))}, true
		}
		c.advance()
	}
	return [2][]byte{}, false
}

// NextKv returns the next active pair and advances past it.
func (c *RunCursor) NextKv() ([2][]byte, bool) {
	got, ok := c.PeekKv()
	if ok {
		c.advance()
	}
	return got, ok
}

// NextDeleted returns the next tombstone.
func (c *RunCursor) NextDeleted() ([]byte, bool) {
	for !c.atEnd {
		p := c.run.Records[c.pos]
		if recDeleted(p) {
			k := copyBytes(recKey(p))
			c.advance()
			return k, true
		}
		c.advance()
	}
	return nil, false
}

// Seek positions at the first key >= target.
func (c *RunCursor) Seek(target []byte) {
	c.seekStack(target)
	c.atEnd = c.pos >= len(c.run.Records)
}

// AtEnd reports whether the cursor is exhausted.
func (c *RunCursor) AtEnd() bool { return c.atEnd }

// SetAtEnd forces the end state.
func (c *RunCursor) SetAtEnd(v bool) { c.atEnd = v }
