// CompileStats decode, mirroring nim_datalog/stats.nim (packStats format):
// a map of five keys; attrIds/partitionIds values are uint64, indexEstimates
// float64, ref/indexedAttrs string arrays.
package datalog

import "eavt-go/internal/msgpack"

// CompileStats is a schema snapshot used by resolve + the planner.
type CompileStats struct {
	AttrIDs        map[string]int32
	IndexEstimates map[string]float64
	PartitionIDs   map[string]int64
	RefAttrs       map[string]bool
	IndexedAttrs   map[string]bool
}

// NewCompileStats returns an empty stats snapshot.
func NewCompileStats() *CompileStats {
	return &CompileStats{
		AttrIDs:        map[string]int32{},
		IndexEstimates: map[string]float64{},
		PartitionIDs:   map[string]int64{},
		RefAttrs:       map[string]bool{},
		IndexedAttrs:   map[string]bool{},
	}
}

// AttrID returns the attribute id, if declared.
func (s *CompileStats) AttrID(name string) (int32, bool) {
	id, ok := s.AttrIDs[name]
	return id, ok
}

// IsRef reports whether the attribute is a reference.
func (s *CompileStats) IsRef(name string) bool { return s.RefAttrs[name] }

// IsIndexed reports whether the attribute is indexed.
func (s *CompileStats) IsIndexed(name string) bool { return s.IndexedAttrs[name] }

func memberMap(m msgpack.Map, key string) (msgpack.Map, bool) {
	if v, ok := msgpack.Member(m, msgpack.Str(key)); ok {
		mm, ok := v.(msgpack.Map)
		return mm, ok
	}
	return nil, false
}

// DecodeCompileStats decodes the packStats msgpack map.
func DecodeCompileStats(v msgpack.Value) *CompileStats {
	s := NewCompileStats()
	m, ok := v.(msgpack.Map)
	if !ok {
		return s
	}
	if ps, ok := memberMap(m, "attrIds"); ok {
		for _, p := range ps {
			name, ok1 := p.Key.(msgpack.Str)
			id, ok2 := p.Value.(msgpack.Int)
			if ok1 && ok2 {
				s.AttrIDs[string(name)] = int32(int64(id))
			}
		}
	}
	if ps, ok := memberMap(m, "indexEstimates"); ok {
		for _, p := range ps {
			name, ok1 := p.Key.(msgpack.Str)
			f, ok2 := p.Value.(msgpack.Float)
			if ok1 && ok2 {
				s.IndexEstimates[string(name)] = float64(f)
			}
		}
	}
	if ps, ok := memberMap(m, "partitionIds"); ok {
		for _, p := range ps {
			name, ok1 := p.Key.(msgpack.Str)
			id, ok2 := p.Value.(msgpack.Int)
			if ok1 && ok2 {
				s.PartitionIDs[string(name)] = int64(id)
			}
		}
	}
	strList := func(key string) map[string]bool {
		out := map[string]bool{}
		v, ok := msgpack.Member(m, msgpack.Str(key))
		if !ok {
			return out
		}
		arr, ok := v.(msgpack.Array)
		if !ok {
			return out
		}
		for _, e := range arr {
			if st, ok := e.(msgpack.Str); ok {
				out[string(st)] = true
			}
		}
		return out
	}
	s.RefAttrs = strList("refAttrs")
	s.IndexedAttrs = strList("indexedAttrs")
	return s
}

// EncodeCompileStats writes the packStats msgpack map (schema endpoint).
func EncodeCompileStats(s *CompileStats) []byte {
	enc := msgpack.NewEncoder()
	enc.EncodeMapHeader(5)
	enc.Encode(msgpack.Str("attrIds"))
	enc.EncodeMapHeader(len(s.AttrIDs))
	for k, v := range s.AttrIDs {
		enc.Encode(msgpack.Str(k))
		enc.Encode(msgpack.Int(int64(v)))
	}
	enc.Encode(msgpack.Str("indexEstimates"))
	enc.EncodeMapHeader(len(s.IndexEstimates))
	for k, v := range s.IndexEstimates {
		enc.Encode(msgpack.Str(k))
		enc.Encode(msgpack.Float(v))
	}
	enc.Encode(msgpack.Str("partitionIds"))
	enc.EncodeMapHeader(len(s.PartitionIDs))
	for k, v := range s.PartitionIDs {
		enc.Encode(msgpack.Str(k))
		enc.Encode(msgpack.Int(v))
	}
	strArr := func(key string, m map[string]bool) {
		enc.Encode(msgpack.Str(key))
		enc.EncodeArrayHeader(len(m))
		for k := range m {
			enc.Encode(msgpack.Str(k))
		}
	}
	strArr("refAttrs", s.RefAttrs)
	strArr("indexedAttrs", s.IndexedAttrs)
	return enc.Bytes()
}
