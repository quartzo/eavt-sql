package scheme

// SymId is a per-process interned keyword/symbol id.
type SymId uint32

// SymTab interns keyword/symbol payloads at the wire boundary.
type SymTab struct {
	m     map[string]uint32
	names []string

	DbAdd         SymId
	DbRetract     SymId
	DbIdent       SymId
	DbType        SymId
	DbCardinality SymId
	DbUnique      SymId
	DbCurrentTx   SymId
}

// NewSymTab returns a symbol table with the well-known ids interned.
func NewSymTab() *SymTab {
	t := &SymTab{m: map[string]uint32{}}
	t.DbAdd = t.InternSym("db/add")
	t.DbRetract = t.InternSym("db/retract")
	t.DbIdent = t.InternSym("db/ident")
	t.DbType = t.InternSym("db/valueType")
	t.DbCardinality = t.InternSym("db/cardinality")
	t.DbUnique = t.InternSym("db/unique")
	t.DbCurrentTx = t.InternSym("db/current-tx")
	return t
}

// InternSym returns the stable id for a payload.
func (t *SymTab) InternSym(payload string) SymId {
	if id, ok := t.m[payload]; ok && id != 0 {
		return SymId(id)
	}
	id := uint32(len(t.names) + 1)
	t.m[payload] = id
	t.names = append(t.names, payload)
	return SymId(id)
}

// SymName is the reverse lookup (rare paths).
func (t *SymTab) SymName(id SymId) string {
	i := uint32(id)
	if i == 0 || int(i) > len(t.names) {
		return ""
	}
	return t.names[int(i)-1]
}

// SymCount returns the number of distinct interned payloads.
func (t *SymTab) SymCount() int { return len(t.names) }
