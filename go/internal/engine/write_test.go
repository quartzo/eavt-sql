package engine

import (
	"testing"

	"eavt-go/internal/kvstore"
	"eavt-go/internal/msgpack"
	"eavt-go/internal/query"
	"eavt-go/internal/scheme"
	"eavt-go/internal/sexpr"
)

func kw(s string) msgpack.Value { return msgpack.Ext{Type: msgpack.ExtKeyword, Data: []byte(s)} }
func op(items ...msgpack.Value) msgpack.Value {
	return msgpack.Array(items)
}
func txFrame(ops ...msgpack.Value) []byte {
	return msgpack.Marshal(msgpack.Map{
		{Key: msgpack.Str("type"), Value: msgpack.Str("tx")},
		{Key: msgpack.Str("txdata"), Value: msgpack.Array(ops)},
	})
}

func newWriteStore(t *testing.T) *QueryStore {
	t.Helper()
	kv, err := kvstore.New(kvstore.Config{Path: t.TempDir(), NumCf: 16, PageCacheSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kv.Close() })
	q := New(kv)
	q.Eavt.BootstrapSystemAttrs()
	return q
}

func transact(t *testing.T, q *QueryStore, frame []byte) query.TxReport {
	t.Helper()
	ops, err := scheme.TxOpsFromMsgpack(frame, q.Symtab())
	if err != nil {
		t.Fatal(err)
	}
	report, err := query.TransactTx(q, ops)
	if err != nil {
		t.Fatal(err)
	}
	return report
}

func TestTxSchemaAndData(t *testing.T) {
	q := newWriteStore(t)
	// Schema-as-data.
	transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(0), kw("db/ident"), kw("person/name")),
		op(kw("db/add"), msgpack.Int(0), kw("db/valueType"), kw("db.type/string")),
		op(kw("db/add"), msgpack.Int(0), kw("db/cardinality"), kw("db.cardinality/one")),
	))
	if _, ok := q.LookupAttr("person/name"); !ok {
		t.Fatal("person/name not declared")
	}
	// Data with a tempid.
	report := transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(-1), kw("person/name"), msgpack.Str("Alice")),
	))
	eid, ok := report.Tempids[-1]
	if !ok || eid == 0 {
		t.Fatalf("tempid not resolved: %#v", report.Tempids)
	}
	if v, ok := q.LookupValue(eid, "person/name"); !ok || v != sexpr.Str("Alice") {
		t.Fatalf("lookup = %#v %v", v, ok)
	}
	// Idempotent :db/add of a present datom.
	transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(eid), kw("person/name"), msgpack.Str("Alice")),
	))
	// Retract.
	transact(t, q, txFrame(
		op(kw("db/retract"), msgpack.Int(eid), kw("person/name"), msgpack.Str("Alice")),
	))
	if _, ok := q.LookupValue(eid, "person/name"); ok {
		t.Fatal("retract did not hide the datom")
	}
}

func TestTxUniqueUpsert(t *testing.T) {
	q := newWriteStore(t)
	transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(0), kw("db/ident"), kw("person/email")),
		op(kw("db/add"), msgpack.Int(0), kw("db/valueType"), kw("db.type/string")),
		op(kw("db/add"), msgpack.Int(0), kw("db/cardinality"), kw("db.cardinality/one")),
		op(kw("db/add"), msgpack.Int(0), kw("db/unique"), kw("db.unique/identity")),
	))
	r1 := transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(-1), kw("person/email"), msgpack.Str("a@b.c")),
	))
	e1 := r1.Tempids[-1]
	// Same unique value with a different tempid → upsert to the same eid.
	r2 := transact(t, q, txFrame(
		op(kw("db/add"), msgpack.Int(-2), kw("person/email"), msgpack.Str("a@b.c")),
	))
	if r2.Tempids[-2] != e1 {
		t.Fatalf("upsert eid = %d, want %d", r2.Tempids[-2], e1)
	}
}
