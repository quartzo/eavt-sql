// Package replica is the query server's read-only replica engine: it opens
// the shared data dir read-only and applies the transactor's replication
// stream (snapshot + wal/seal/root events).  Port of
// eavt_query_nim/replica.nim.
package replica

import (
	"os"

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
	SchemaDirty bool

	EvWalCount  int64
	EvWalBytes  int64
	EvSealCount int64
	EvRootCount int64
}

// Open opens a read-only replica on dir (journal replay off — the stream
// delivers everything).
func Open(dir string) *ReplicaEngine {
	kv, err := kvstore.New(kvstore.Config{
		Path:      dir,
		ReadOnly:  true,
		ReplayOff: true,
		NumCf:     64,
	})
	if err != nil {
		return nil
	}
	store := engine.New(kv)
	return &ReplicaEngine{KV: kv, Store: store, Path: dir}
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
	r.SchemaDirty = true
}

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
		r.RefreshResolverOnSchemaWal()
	}
	expanded := r.expand(recs)
	if len(expanded) > 0 {
		r.KV.BatchWrite(expanded, false)
	}
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
	expanded := r.expand(recs)
	if len(expanded) > 0 {
		r.KV.BatchWrite(expanded, false)
	}
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
