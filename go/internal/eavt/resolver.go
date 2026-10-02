package eavt

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

func errf(format string, a ...any) error { return fmt.Errorf(format, a...) }

// resolver constants (resolver_consts.rs).
const (
	BootstrapFirstUserID = 100

	DbIdentAid       uint32 = 1
	DbCardinalityAid uint32 = 2
	DbValueTypeAid   uint32 = 3
	DbUniqueAid      uint32 = 5
	DbIndexAid       uint32 = 6
	DbTxInstantAid   uint32 = 9
	DbPartIDAid      uint32 = 39

	DbTypeString  uint32 = 20
	DbTypeRef     uint32 = 21
	DbTypeLong    uint32 = 22
	DbTypeKeyword uint32 = 23
	DbTypeBoolean uint32 = 24
	DbTypeInstant uint32 = 25
	DbTypeBytes   uint32 = 26
	DbTypeFloat   uint32 = 27
	DbTypeBlob    uint32 = 28

	DbCardinalityOneAid  uint32 = 35
	DbCardinalityManyAid uint32 = 36
	DbUniqueValueAid     uint32 = 37
	DbUniqueIdentityAid  uint32 = 38

	PartDb   uint64 = 0
	PartTx   uint64 = 3
	PartUser uint64 = 4

	firstCustomPartition = 64
	partitionShift       = 44
	seqMask              = 0xFFFFFFFFFFF
)

// BootstrapSchema is the system attribute table.
var BootstrapSchema = []struct {
	Name string
	Aid  uint32
}{
	{"db/ident", 1}, {"db/cardinality", 2}, {"db/valueType", 3},
	{"db/isComponent", 4}, {"db/unique", 5}, {"db/index", 6},
	{"db/fulltext", 7}, {"db/noHistory", 8}, {"db/txInstant", 9},
	{"db/type/string", 20}, {"db/type/ref", 21}, {"db/type/long", 22},
	{"db/type/keyword", 23}, {"db/type/boolean", 24}, {"db/type/instant", 25},
	{"db/type/bytes", 26}, {"db/type/float", 27}, {"db/type/blob", 28},
	{"db/cardinality/one", 35}, {"db/cardinality/many", 36},
	{"db/unique/value", 37}, {"db/unique/identity", 38},
	{"db.part/id", 39}, {"db.part/db", 40}, {"db.part/tx", 41},
	{"db.part/user", 42},
}

// PartitionOf extracts the partition id from an entity id.
func PartitionOf(eid int64) uint64 { return uint64(eid) >> partitionShift }

// SeqOf extracts the sequence from an entity id.
func SeqOf(eid int64) int64 { return int64(uint64(eid) & seqMask) }

// MakeEntityID composes a partition id and sequence.
func MakeEntityID(partitionID uint64, seq int64) int64 {
	return int64((partitionID << partitionShift) | uint64(seq))
}

// NormalizeAttr canonicalizes an attribute name to slash notation.
func NormalizeAttr(name string) (string, error) {
	switch {
	case len(name) > 0 && name[0] == ':':
		if !strings.Contains(name, "/") {
			return "", errf("attribute keyword must be namespaced (e.g. ':company/name'), got %s", name)
		}
		return name[1:], nil
	case strings.Contains(name, ".") && !strings.Contains(name, "/"):
		return strings.ReplaceAll(name, ".", "/"), nil
	case strings.Contains(name, "/"):
		return name, nil
	}
	return "", errf("attribute name must include namespace (e.g. 'company/name' or 'company.name'), got %s", name)
}

type partitionCounter struct{ nextSeq int64 }

// Resolver holds the schema cache and id allocation.  An RWMutex makes reads
// (attribute lookup, value types) safe against concurrent WAL/snapshot apply:
// queries hold RLock only for the duration of each accessor call, never for a
// whole query.
type Resolver struct {
	mu                  sync.RWMutex
	attrs               map[string]uint32
	attrsRev            map[uint32]string
	nextAid             uint32
	partitions          map[uint64]*partitionCounter
	partitionNames      map[string]uint64
	nextCustomPartition uint64
	cardinality         map[uint32]bool
	declared            map[uint32]bool
	valueTypes          map[uint32]uint32
	uniqueAttrs         map[uint32]bool
	indexedAttrs        map[uint32]bool
	AttrDeclOrder       []string
	PartDeclOrder       []string
}

// NewResolver returns a resolver seeded with the bootstrap schema.
func NewResolver() *Resolver {
	r := &Resolver{
		attrs:               map[string]uint32{},
		attrsRev:            map[uint32]string{},
		nextAid:             1,
		partitions:          map[uint64]*partitionCounter{},
		partitionNames:      map[string]uint64{},
		nextCustomPartition: firstCustomPartition,
		cardinality:         map[uint32]bool{},
		declared:            map[uint32]bool{},
		valueTypes:          map[uint32]uint32{},
		uniqueAttrs:         map[uint32]bool{},
		indexedAttrs:        map[uint32]bool{},
	}
	for _, s := range BootstrapSchema {
		r.attrs[s.Name] = s.Aid
		r.attrsRev[s.Aid] = s.Name
		r.declared[s.Aid] = true
		if s.Aid >= r.nextAid {
			r.nextAid = s.Aid + 1
		}
	}
	r.valueTypes[DbValueTypeAid] = DbTypeRef
	r.valueTypes[DbCardinalityAid] = DbTypeRef
	r.valueTypes[DbUniqueAid] = DbTypeRef
	r.valueTypes[DbIdentAid] = DbTypeString
	r.valueTypes[DbPartIDAid] = DbTypeLong
	r.valueTypes[DbTxInstantAid] = DbTypeInstant
	r.indexedAttrs[DbIdentAid] = true
	for _, s := range BootstrapSchema {
		if _, ok := r.valueTypes[s.Aid]; ok {
			continue
		}
		var vt uint32
		switch {
		case s.Name == "db/ident" || s.Name == "db.part/id":
			vt = DbTypeString
		case s.Name == "db/txInstant":
			vt = DbTypeInstant
		case s.Name == "db/isComponent" || s.Name == "db/index" ||
			s.Name == "db/fulltext" || s.Name == "db/noHistory":
			vt = DbTypeBoolean
		case strings.HasPrefix(s.Name, "db.type/"):
			vt = DbTypeLong
		default:
			vt = DbTypeRef
		}
		r.valueTypes[s.Aid] = vt
	}
	r.partitions[PartDb] = &partitionCounter{nextSeq: BootstrapFirstUserID}
	r.partitionNames["db.part/db"] = PartDb
	r.partitions[PartTx] = &partitionCounter{nextSeq: 1}
	r.partitionNames["db.part/tx"] = PartTx
	r.partitions[PartUser] = &partitionCounter{nextSeq: 1}
	r.partitionNames["db.part/user"] = PartUser
	return r
}

func (r *Resolver) allocateInPartitionLocked(partitionID uint64) (int64, error) {
	pc, ok := r.partitions[partitionID]
	if !ok {
		return 0, errf("unknown partition: %d", partitionID)
	}
	seq := pc.nextSeq
	pc.nextSeq = seq + 1
	return MakeEntityID(partitionID, seq), nil
}

// AllocateInPartition reserves an entity id in a partition.
func (r *Resolver) AllocateInPartition(partitionID uint64) (int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.allocateInPartitionLocked(partitionID)
}

// AllocateEntityID reserves an id in the user partition.
func (r *Resolver) AllocateEntityID() (int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.allocateInPartitionLocked(PartUser)
}

// AllocateSchemaID reserves an id in the db partition.
func (r *Resolver) AllocateSchemaID() (int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.allocateInPartitionLocked(PartDb)
}

// PartitionIDFor returns the id for a partition name.
func (r *Resolver) PartitionIDFor(name string) (uint64, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.partitionNames[name]
	return p, ok
}

// DeclarePartition registers a custom partition.
func (r *Resolver) DeclarePartition(name string) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	if p, ok := r.partitionNames[name]; ok {
		return p
	}
	p := r.nextCustomPartition
	r.nextCustomPartition++
	r.partitions[p] = &partitionCounter{nextSeq: 1}
	r.partitionNames[name] = p
	r.PartDeclOrder = append(r.PartDeclOrder, name)
	return p
}

// RegisterPartition registers a partition with a known id.
func (r *Resolver) RegisterPartition(name string, partitionID uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.partitionNames[name]; ok {
		return
	}
	if _, ok := r.partitions[partitionID]; !ok {
		r.partitions[partitionID] = &partitionCounter{nextSeq: 1}
	}
	r.partitionNames[name] = partitionID
	if partitionID >= firstCustomPartition && partitionID >= r.nextCustomPartition {
		r.nextCustomPartition = partitionID + 1
	}
}

// DefaultUserPartition returns the user partition.
func (r *Resolver) DefaultUserPartition() uint64 { return PartUser }

// KnownPartitions returns all known partition ids.
func (r *Resolver) KnownPartitions() []uint64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]uint64, 0, len(r.partitions))
	for k := range r.partitions {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// LookupAttr resolves an attribute name.
func (r *Resolver) LookupAttr(name string) (uint32, bool) {
	n, err := NormalizeAttr(name)
	if err != nil {
		return 0, false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	a, ok := r.attrs[n]
	return a, ok
}

// IsDeclared reports whether an aid is declared.
func (r *Resolver) IsDeclared(aid uint32) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.declared[aid]
}

// InternAttr resolves or allocates an attribute id.
func (r *Resolver) InternAttr(name string) (uint32, error) {
	n, err := NormalizeAttr(name)
	if err != nil {
		return 0, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attrs[n]; ok {
		return a, nil
	}
	eid, err := r.allocateInPartitionLocked(PartDb)
	if err != nil {
		return 0, err
	}
	aid := uint32(eid)
	r.nextAid = aid + 1
	r.attrs[n] = aid
	r.attrsRev[aid] = n
	return aid, nil
}

// DeclareAttr declares a user attribute (idempotent).
func (r *Resolver) DeclareAttr(name string, valueType uint32, many bool) (uint32, bool, error) {
	n, err := NormalizeAttr(name)
	if err != nil {
		return 0, false, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attrs[n]; ok && r.declared[a] {
		return a, false, nil
	}
	seq, err := r.allocateInPartitionLocked(PartDb)
	if err != nil {
		return 0, false, err
	}
	aid := uint32(seq)
	r.nextAid = aid + 1
	r.attrs[n] = aid
	r.attrsRev[aid] = n
	r.declared[aid] = true
	r.valueTypes[aid] = valueType
	if many {
		r.cardinality[aid] = true
	}
	r.AttrDeclOrder = append(r.AttrDeclOrder, n)
	return aid, true, nil
}

// ValueTypeFor returns the value type for an aid.
func (r *Resolver) ValueTypeFor(aid uint32) (uint32, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	vt, ok := r.valueTypes[aid]
	return vt, ok
}

// AttrName returns the name for an aid (id as string fallback).
func (r *Resolver) AttrName(aid uint32) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if n, ok := r.attrsRev[aid]; ok {
		return n
	}
	return fmt.Sprintf("%d", aid)
}

// AttrNameOpt returns the name for an aid, if known.
func (r *Resolver) AttrNameOpt(aid uint32) (string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	n, ok := r.attrsRev[aid]
	return n, ok
}

// IsMany reports cardinality-many.
func (r *Resolver) IsMany(aid uint32) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cardinality[aid]
}

// SetCardinality sets cardinality-many.
func (r *Resolver) SetCardinality(aid uint32, many bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if many {
		r.cardinality[aid] = true
	} else {
		delete(r.cardinality, aid)
	}
}

// IsUnique reports whether an aid is unique.
func (r *Resolver) IsUnique(aid uint32) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.uniqueAttrs[aid]
}

// SetUnique sets the unique flag.
func (r *Resolver) SetUnique(aid uint32, unique bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if unique {
		r.uniqueAttrs[aid] = true
	} else {
		delete(r.uniqueAttrs, aid)
	}
}

// IsIndexed reports whether an aid is indexed (or unique).
func (r *Resolver) IsIndexed(aid uint32) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.uniqueAttrs[aid] || r.indexedAttrs[aid]
}

// SetIndexed sets the indexed flag.
func (r *Resolver) SetIndexed(aid uint32, indexed bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if indexed {
		r.indexedAttrs[aid] = true
	} else {
		delete(r.indexedAttrs, aid)
	}
}

// AdvancePast advances a partition sequence past eid.
func (r *Resolver) AdvancePast(eid int64) {
	p := PartitionOf(eid)
	s := SeqOf(eid)
	r.mu.Lock()
	defer r.mu.Unlock()
	if pc, ok := r.partitions[p]; ok {
		if s >= pc.nextSeq {
			pc.nextSeq = s + 1
		}
	}
}

// SetPartitionSeq raises a partition sequence.
func (r *Resolver) SetPartitionSeq(partitionID uint64, seq int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if pc, ok := r.partitions[partitionID]; ok {
		if seq > pc.nextSeq {
			pc.nextSeq = seq
		}
	}
}

// NextEntID returns the db partition's next sequence.
func (r *Resolver) NextEntID() int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if pc, ok := r.partitions[PartDb]; ok {
		return pc.nextSeq
	}
	return BootstrapFirstUserID
}

// AttrsSnapshot returns a copy of the name→aid table.
func (r *Resolver) AttrsSnapshot() map[string]uint32 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]uint32, len(r.attrs))
	for k, v := range r.attrs {
		out[k] = v
	}
	return out
}

// LoadAttrs bulk-loads (name, aid-bytes) pairs.
func (r *Resolver) LoadAttrs(items [][2][]byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, kv := range items {
		name := string(kv[0])
		v := kv[1]
		if len(v) < 4 {
			continue
		}
		aid := uint32(v[0])<<24 | uint32(v[1])<<16 | uint32(v[2])<<8 | uint32(v[3])
		r.attrs[name] = aid
		r.attrsRev[aid] = name
		if aid >= r.nextAid {
			r.nextAid = aid + 1
		}
	}
}

// LoadUserAttr registers a user attribute discovered during bootstrap.
func (r *Resolver) LoadUserAttr(name string, eid int64, valueType uint32, many, unique, indexed bool) {
	aid := uint32(eid)
	r.mu.Lock()
	defer r.mu.Unlock()
	isNew := !r.declared[aid]
	r.attrs[name] = aid
	r.attrsRev[aid] = name
	r.declared[aid] = true
	r.valueTypes[aid] = valueType
	if many {
		r.cardinality[aid] = true
	}
	if unique {
		r.uniqueAttrs[aid] = true
	}
	if indexed {
		r.indexedAttrs[aid] = true
	}
	if isNew {
		insPos := len(r.AttrDeclOrder)
		for i, n := range r.AttrDeclOrder {
			if r.attrs[n] > aid {
				insPos = i
				break
			}
		}
		r.AttrDeclOrder = append(r.AttrDeclOrder, "")
		copy(r.AttrDeclOrder[insPos+1:], r.AttrDeclOrder[insPos:])
		r.AttrDeclOrder[insPos] = name
	}
	p := PartitionOf(eid)
	if pc, ok := r.partitions[p]; ok {
		if SeqOf(eid) >= pc.nextSeq {
			pc.nextSeq = SeqOf(eid) + 1
		}
	}
	if aid >= r.nextAid {
		r.nextAid = aid + 1
	}
}
