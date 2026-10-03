// Package replica is the query server's read-only replica engine: it opens
// the shared data dir read-only and applies the transactor's replication
// stream (snapshot + wal/seal/root events).  Port of
// eavt_query_nim/replica.nim.
package replica

import (
	"os"
	"sync/atomic"

	"eavt-go/internal/blobstore"
	"eavt-go/internal/datalog"
	"eavt-go/internal/eavt"
	"eavt-go/internal/engine"
	"eavt-go/internal/kvstore"
	"eavt-go/internal/memtable"
)

// WalSchemaAids are the db.* datom aids that mark a schema change.
var WalSchemaAids = []uint32{eavt.DbIdentAid, eavt.DbCardinalityAid, eavt.DbValueTypeAid, eavt.DbUniqueAid}

// ReplicaEngine is the read-only replica.
type ReplicaEngine struct {
	KV          *kvstore.KVStore
	Store       *engine.QueryStore
	Path        string
	Connected   bool
	schemaDirty atomic.Bool

	EvWalCount  int64
	EvWalBytes  int64
	EvSealCount int64
	EvRootCount int64
}

// Config configures a read-only replica.
type Config struct {
	Dir     string
	Backend string // "file" (default) | "s3"
	S3      blobstore.S3Config
}

// Open opens a read-only replica on dir with the file backend.
func Open(dir string) *ReplicaEngine {
	return OpenConfig(Config{Dir: dir})
}

// OpenConfig opens a read-only replica (journal replay off — the stream
// delivers everything).  The backend must match the transactor's so adopted
// roots and page blobs resolve.
func OpenConfig(cfg Config) *ReplicaEngine {
	kv, err := kvstore.New(kvstore.Config{
		Path:      cfg.Dir,
		ReadOnly:  true,
		ReplayOff: true,
		NumCf:     64,
		Backend:   cfg.Backend,
		S3:        cfg.S3,
	})
	if err != nil {
		return nil
	}
	store := engine.New(kv)
	return &ReplicaEngine{KV: kv, Store: store, Path: cfg.Dir}
}

// Close releases the replica.
func (r *ReplicaEngine) Close() {
	if r != nil && r.KV != nil {
		r.KV.Close()
	}
}

// GetStats rebuilds the resolver and returns a fresh CompileStats snapshot.
func (r *ReplicaEngine) GetStats() *datalog.CompileStats {
	r.Store.Eavt.BootstrapResolver()
	r.Store.Eavt.InvalidateStats()
	return r.Store.Eavt.BuildCompileStats()
}

// RefreshResolverOnSchemaWal re-bootstraps the resolver after schema datoms.
func (r *ReplicaEngine) RefreshResolverOnSchemaWal() {
	r.Store.Eavt.BootstrapResolver()
	r.schemaDirty.Store(true)
}

// SchemaDirty reports whether schema datoms arrived since the last stats snapshot.
func (r *ReplicaEngine) SchemaDirty() bool { return r.schemaDirty.Load() }

// ClearSchemaDirty resets the schema-dirty flag after a stats refresh.
func (r *ReplicaEngine) ClearSchemaDirty() { r.schemaDirty.Store(false) }

func (r *ReplicaEngine) expand(recs []memtable.CfKey) []memtable.CfKey {
	var out []memtable.CfKey
	for _, rec := range recs {
		if rec.Cf != 0 || len(rec.Key) < 20 {
			continue
		}
		k := rec.Key
		out = append(out, memtable.CfKey{Cf: 0, Key: k})
		aid := eavt.BeUint32(k, 8)
		isRef := false
		if vt, ok := r.Store.Eavt.ValueTypeFor(aid); ok && vt == eavt.DbTypeRef {
			isRef = true
		}
		for _, d := range eavt.DeriveIndexKeys(k, r.Store.Eavt.Resolver.IsIndexed(aid), isRef) {
			out = append(out, memtable.CfKey{Cf: d.CF, Key: d.Key})
		}
	}
	return out
}

// ApplyWal applies incoming WAL bytes (journal-format, CF-0 datoms).
func (r *ReplicaEngine) ApplyWal(data []byte) {
	r.EvWalCount++
	r.EvWalBytes += int64(len(data))
	recs := kvstore.ParseJournalRecords(data)
	if len(recs) == 0 {
		return
	}
	r.applyRecords(recs)
}

// applyRecords routes one WAL/snapshot chunk through the unified write path.
// When the chunk carries schema datoms, the CF-0 keys are written FIRST and
// the resolver is refreshed BEFORE deriving the CF-1/2/3 indexes — otherwise
// a `:db/unique` datom in the same chunk is not yet visible to IsIndexed and
// the CF-2 (AVET) keys are never derived until a flush/root adoption brings
// them from the primary.
func (r *ReplicaEngine) applyRecords(recs []memtable.CfKey) {
	hasSchema := false
	for _, rec := range recs {
		if rec.Cf == 0 && len(rec.Key) >= 12 {
			aid := eavt.BeUint32(rec.Key, 8)
			for _, s := range WalSchemaAids {
				if aid == s {
					hasSchema = true
				}
			}
		}
	}
	if hasSchema {
		var cf0 []eavt.EavtEntry
		for _, rec := range recs {
			if rec.Cf == 0 && len(rec.Key) >= 20 {
				cf0 = append(cf0, eavt.EavtEntry{CF: 0, Key: rec.Key})
			}
		}
		if len(cf0) > 0 {
			r.Store.Eavt.BatchWriteForeign(cf0)
		}
		r.RefreshResolverOnSchemaWal()
	}
	expanded := r.expand(recs)
	if len(expanded) > 0 {
		r.Store.Eavt.BatchWriteForeign(toEntries(expanded))
	}
}

func toEntries(keys []memtable.CfKey) []eavt.EavtEntry {
	out := make([]eavt.EavtEntry, len(keys))
	for i, k := range keys {
		out[i] = eavt.EavtEntry{CF: k.Cf, Key: k.Key}
	}
	return out
}

// ApplySnapshot applies the initial snapshot (sealed segment paths + open tail).
func (r *ReplicaEngine) ApplySnapshot(sealed []string, openTail []byte, rootName string) {
	for _, seg := range sealed {
		data, err := os.ReadFile(seg)
		if err != nil {
			continue
		}
		r.applyChunk(data)
	}
	if len(openTail) > 0 {
		r.applyChunk(openTail)
	}
	if rootName != "" {
		r.KV.PublishRoot(rootName)
	}
	r.RefreshResolverOnSchemaWal()
	r.Connected = true
}

func (r *ReplicaEngine) applyChunk(data []byte) {
	recs := kvstore.ParseJournalRecords(data)
	if len(recs) == 0 {
		return
	}
	r.applyRecords(recs)
}

// ApplySeal promotes the live memtable to the pending set.
func (r *ReplicaEngine) ApplySeal() {
	r.EvSealCount++
	r.KV.SealLiveToFlush()
}

// ApplyRoot adopts a newly published page-store root.
func (r *ReplicaEngine) ApplyRoot(rootName string, maxT int64) {
	r.EvRootCount++
	r.KV.PublishRoot(rootName)
	if !r.KV.RootHasData() {
		return
	}
}
