## shared.nim — Gateway shared state (schema snapshot cache).
##
## Single-threaded by construction: the gateway runs on one chronos event
## loop, so this is a plain object — no locks.

import std/[times, json, options, tables]
import chronos
import stats
import replica

const SCHEMA_TTL_SECONDS = 30.0

type
  GatewayState* = ref object
    stats*: CompileStats
    fetchedAt*: float
    downstreamPath*: string
    replica*: ReplicaEngine

proc initGatewayState*(downstream: string): GatewayState =
  result = GatewayState(
    fetchedAt: -1.0,
    downstreamPath: downstream,
  )

proc getSnapshot*(gw: GatewayState): CompileStats {.raises: [].} =
  ## Build or return cached stats from the replica engine.
  ## Staleness degrades plan quality only (programs are position-independent).
  try:
    if gw.fetchedAt > 0 and epochTime() - gw.fetchedAt < SCHEMA_TTL_SECONDS and
       gw.stats.attrIds.len > 0:
      return gw.stats
    gw.stats = gw.replica.getStats()
    gw.fetchedAt = epochTime()
    gw.stats
  except Exception:
    gw.stats

proc invalidateSnapshot*(gw: GatewayState) =
  gw.fetchedAt = -1.0

proc statsSnapshot*(gw: GatewayState): stats.CompileStats =
  gw.getSnapshot()
