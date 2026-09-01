## shared.nim — Gateway shared state (schema snapshot cache).
##
## Single-threaded by construction: the query server runs on one chronos event
## loop, so this is a plain object — no locks.

import std/[times, tables]
import stats
import replica
import downstream

const SCHEMA_TTL_SECONDS = 30.0

type
  GatewayState* = ref object
    stats*: CompileStats
    fetchedAt*: float
    conn*: MultiplexedConn  # single shared connection to the transactor
    replica*: ReplicaEngine

proc initGatewayState*(downstreamPath: string): GatewayState =
  result = GatewayState(fetchedAt: -1.0)

proc getSnapshot*(gw: GatewayState): CompileStats {.raises: [].} =
  ## Build or return cached stats from the replica engine.
  ## Staleness degrades plan quality only (programs are position-independent).
  ## `schemaDirty` (datoms db.* chegaram via WAL) bypassa o TTL: o snapshot
  ## precisa refletir o schema novo no compile imediatamente.
  try:
    if gw.fetchedAt > 0 and not gw.replica.schemaDirty and
       epochTime() - gw.fetchedAt < SCHEMA_TTL_SECONDS and
       gw.stats.attrIds.len > 0:
      return gw.stats
    gw.stats = gw.replica.getStats()
    gw.replica.schemaDirty = false
    gw.fetchedAt = epochTime()
    gw.stats
  except Exception:
    gw.stats

proc invalidateSnapshot*(gw: GatewayState) =
  gw.fetchedAt = -1.0

proc statsSnapshot*(gw: GatewayState): stats.CompileStats =
  gw.getSnapshot()
